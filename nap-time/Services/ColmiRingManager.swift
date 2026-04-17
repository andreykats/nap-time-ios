@preconcurrency import CoreBluetooth
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "BLE")

/// Manages BLE communication with the Colmi R02 smart ring.
/// Exposes both processed heart rate and raw PPG data streams.
@Observable
final class ColmiRingManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published State

    var isScanning = false
    var discoveredDevices: [CBPeripheral] = []
    var connectedPeripheral: CBPeripheral?
    var connectionState: ConnectionState = .disconnected
    var batteryLevel: Int?
    var isCharging = false
    var latestHR: Int = 0

    enum ConnectionState: Sendable {
        case disconnected
        case scanning
        case connecting
        case connected
        case disconnecting
    }

    // MARK: - Private State

    private var centralManager: CBCentralManager!
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var keepAliveTimer: Timer?
    private var shouldReconnect = false

    // Stream continuations
    private var hrContinuation: AsyncStream<HeartRateReading>.Continuation?
    private var ppgContinuation: AsyncStream<PPGSample>.Continuation?
    private var ibiContinuation: AsyncStream<InterBeatInterval>.Continuation?

    // Rolling packet-rate instrumentation
    private var ppgPacketsInWindow = 0
    private var hrPacketsInWindow = 0
    private var rateWindowStart: Date = .now
    // Per-(command, subtype) packet counts for diagnosing firmware output
    private var packetHistogram: [String: Int] = [:]

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan: Bluetooth not powered on (state: \(self.centralManager.state.rawValue))")
            return
        }
        isScanning = true
        connectionState = .scanning
        discoveredDevices = []

        // First, check for rings already connected at the system level.
        // scanForPeripherals won't find these since they're no longer advertising.
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: [BLEConstants.serviceUUID])
        for peripheral in alreadyConnected {
            if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                discoveredDevices.append(peripheral)
                logger.info("Found already-connected ring: \(peripheral.name ?? "unknown", privacy: .public)")
            }
        }

        // Also scan for rings that are advertising (not yet connected)
        centralManager.scanForPeripherals(withServices: nil)
        logger.info("Started scanning for Colmi rings (name-based discovery)")
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        if connectionState == .scanning {
            connectionState = .disconnected
        }
        logger.info("Stopped scanning")
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        shouldReconnect = true
        centralManager.connect(peripheral)
        logger.info("Connecting to \(peripheral.name ?? "unknown", privacy: .public)")
    }

    func disconnect() {
        shouldReconnect = false
        stopMonitoring()
        guard let peripheral = connectedPeripheral else { return }
        connectionState = .disconnecting
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func startHeartRateMonitoring() {
        writeCommand(BLEConstants.startHRPacket())
        startKeepAliveTimer()
        logger.info("Started real-time HR monitoring")
    }

    func stopHeartRateMonitoring() {
        writeCommand(BLEConstants.stopHRPacket())
        stopKeepAliveTimer()
        logger.info("Stopped real-time HR monitoring")
    }

    func startHRVMonitoring() {
        writeCommand(BLEConstants.startHRVPacket())
        startKeepAliveTimer()
        logger.info("Started real-time HRV monitoring")
    }

    func stopHRVMonitoring() {
        writeCommand(BLEConstants.stopHRVPacket())
        stopKeepAliveTimer()
        logger.info("Stopped real-time HRV monitoring")
    }

    func startPPGStreaming() {
        writeCommand(BLEConstants.enablePPGPacket())
        logger.info("Started raw PPG streaming")
    }

    func stopPPGStreaming() {
        writeCommand(BLEConstants.disablePPGPacket())
        logger.info("Stopped raw PPG streaming")
    }

    func requestBattery() {
        writeCommand(BLEConstants.batteryPacket())
    }

    func stopMonitoring() {
        stopHeartRateMonitoring()
        stopHRVMonitoring()
        stopPPGStreaming()
        hrContinuation?.finish()
        ppgContinuation?.finish()
        ibiContinuation?.finish()
        hrContinuation = nil
        ppgContinuation = nil
        ibiContinuation = nil
    }

    // MARK: - Stream Factories

    func makeHeartRateStream() -> AsyncStream<HeartRateReading> {
        hrContinuation?.finish()
        return AsyncStream { continuation in
            self.hrContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // Continuation cleaned up
            }
        }
    }

    func makePPGStream() -> AsyncStream<PPGSample> {
        ppgContinuation?.finish()
        return AsyncStream { continuation in
            self.ppgContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // Continuation cleaned up
            }
        }
    }

    /// Native ring-computed inter-beat intervals (ms), emitted ~once per heartbeat
    /// from the `0x69 0x0A` (HRV) real-time command.
    func makeIBIStream() -> AsyncStream<InterBeatInterval> {
        ibiContinuation?.finish()
        return AsyncStream { continuation in
            self.ibiContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // Continuation cleaned up
            }
        }
    }

    // MARK: - Private Helpers

    private func writeCommand(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let rx = rxCharacteristic else {
            logger.warning("Cannot write: no connected peripheral or RX characteristic")
            return
        }
        peripheral.writeValue(data, for: rx, type: .withoutResponse)
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Re-send the HRV CONTINUE packet to prevent the ring from timing out
                // the real-time session. The generic `0x1E` keep-alive only applies to the
                // HR (0x69 0x01) stream; HRV (0x69 0x0A) needs `0x69 [0x0A, CONTINUE]`.
                self?.writeCommand(BLEConstants.continueHRVPacket())
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - Packet Parsing

    private func handleNotification(data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.info("RX [\(data.count) bytes]: \(hex)")

        // Per-(cmd, subtype) histogram for diagnosing what the firmware is emitting
        if data.count >= 2 {
            let key = String(format: "cmd=%02x sub=%02x", data[0], data[1])
            packetHistogram[key, default: 0] += 1
        } else if data.count >= 1 {
            let key = String(format: "cmd=%02x sub=--", data[0])
            packetHistogram[key, default: 0] += 1
        }

        let now = Date.now
        let elapsed = now.timeIntervalSince(rateWindowStart)
        if elapsed >= 1.0 {
            let ppgRate = Double(ppgPacketsInWindow) / elapsed
            let hrRate  = Double(hrPacketsInWindow)  / elapsed
            let histo = packetHistogram.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            logger.info("Packet rate over \(elapsed, format: .fixed(precision: 2))s — PPG: \(ppgRate, format: .fixed(precision: 2))/s, HR: \(hrRate, format: .fixed(precision: 2))/s | histo: \(histo)")
            ppgPacketsInWindow = 0
            hrPacketsInWindow = 0
            packetHistogram.removeAll(keepingCapacity: true)
            rateWindowStart = now
        }

        guard data.count >= 4 else {
            logger.debug("Ignoring very short packet (\(data.count) bytes)")
            return
        }

        let commandByte = data[0]

        switch commandByte {
        case BLEConstants.Command.startRealTime.rawValue:
            hrPacketsInWindow += 1
            parseHeartRateResponse(data: data)

        case BLEConstants.Command.rawSensor.rawValue:
            if data[1] == BLEConstants.PPGResponseType.ppgWaveform.rawValue {
                ppgPacketsInWindow += 1
            }
            parseRawSensorResponse(data: data)

        case BLEConstants.Command.battery.rawValue:
            parseBatteryResponse(data: data)

        default:
            break // Ignore undocumented command bytes (e.g. 0x9E firmware ack)
        }
    }

    private func parseHeartRateResponse(data: Data) {
        let readingType = data[1]
        let errorCode = data[2]
        let value = Int(data[3])

        // HRV response: inter-beat interval (ms) lives in bytes 6–7 (little-endian UInt16).
        // Empirically discovered from live packet capture: `69 0a 00 00 00 00 LO HI 00 00 ...`.
        // Warm-up packets have all zeros; valid IBIs show up at ~2 Hz (one per heartbeat).
        if readingType == BLEConstants.ReadingType.hrv.rawValue {
            guard data.count >= 8 else { return }
            let ibiMs = Int(UInt16(data[6]) | (UInt16(data[7]) << 8))
            logger.info("HRV response: error=\(errorCode) ibi=\(ibiMs)ms")
            guard errorCode == 0, ibiMs >= 300, ibiMs <= 2000 else { return }

            let now = Date.now
            let ibi = InterBeatInterval(timestamp: now, intervalMs: Double(ibiMs), isValid: true)
            ibiContinuation?.yield(ibi)

            // Derive instantaneous BPM from the IBI so the UI has a live heart-rate readout
            // even though the native HR stream (0x69 0x01) is mutually exclusive with HRV.
            let bpm = Int((60000.0 / Double(ibiMs)).rounded())
            latestHR = bpm
            hrContinuation?.yield(HeartRateReading(timestamp: now, bpm: bpm))
            return
        }

        logger.info("HR response: type=\(readingType) error=\(errorCode) bpm=\(value)")

        guard errorCode == 0,
              readingType == BLEConstants.ReadingType.heartRate.rawValue,
              value > 0 else {
            return
        }

        // Always update latestHR so the UI can show BPM even outside a nap session
        latestHR = value

        let reading = HeartRateReading(timestamp: .now, bpm: value)
        hrContinuation?.yield(reading)
    }

    private func parseRawSensorResponse(data: Data) {
        let subtype = data[1]

        guard subtype == BLEConstants.PPGResponseType.ppgWaveform.rawValue else {
            return
        }

        // Parse 16-bit little-endian values
        let rawValue = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let maxVal   = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let minVal   = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let diffVal  = UInt16(data[8]) | (UInt16(data[9]) << 8)

        let sample = PPGSample(
            timestamp: .now,
            rawValue: rawValue,
            max: maxVal,
            min: minVal,
            diff: diffVal
        )
        ppgContinuation?.yield(sample)
    }

    private func parseBatteryResponse(data: Data) {
        batteryLevel = Int(data[1])
        isCharging = data[2] != 0
        logger.info("Battery: \(self.batteryLevel ?? 0)%, charging: \(self.isCharging)")
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            logger.info("Bluetooth state: \(central.state.rawValue)")
            if central.state != .poweredOn {
                connectionState = .disconnected
                isScanning = false
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Extract name before entering MainActor context (advertisementData isn't Sendable)
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name

        guard BLEConstants.isColmiRing(name: name) else { return }

        MainActor.assumeIsolated {
            if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                discoveredDevices.append(peripheral)
                logger.info("Discovered Colmi ring: \(name ?? "unknown", privacy: .public) (RSSI: \(RSSI))")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectionState = .connected
            logger.info("Connected to \(peripheral.name ?? "unknown", privacy: .public)")
            peripheral.discoverServices([BLEConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionState = .disconnected
            logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionState = .disconnected
            rxCharacteristic = nil
            txCharacteristic = nil
            stopKeepAliveTimer()

            if let error {
                logger.warning("Disconnected with error: \(error.localizedDescription)")
            } else {
                logger.info("Disconnected")
            }

            // Auto-reconnect if the disconnect was unexpected
            if shouldReconnect {
                logger.info("Auto-reconnecting...")
                connectionState = .connecting
                central.connect(peripheral)
            }
        }
    }

    // MARK: - CBPeripheralDelegate

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == BLEConstants.serviceUUID {
                peripheral.discoverCharacteristics(
                    [BLEConstants.rxCharUUID, BLEConstants.txCharUUID],
                    for: service
                )
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let characteristics = service.characteristics else { return }
            for char in characteristics {
                switch char.uuid {
                case BLEConstants.rxCharUUID:
                    rxCharacteristic = char
                    logger.info("Found RX characteristic")
                case BLEConstants.txCharUUID:
                    txCharacteristic = char
                    peripheral.setNotifyValue(true, for: char)
                    logger.info("Found TX characteristic, subscribed to notifications")
                default:
                    break
                }
            }

            // Once both characteristics are ready, request battery and start HRV streaming.
            // HRV uses the same 0x69 command slot as HR — only one can run at a time, and
            // HRV gives us per-beat IBIs from which we can derive instantaneous BPM.
            if rxCharacteristic != nil && txCharacteristic != nil {
                requestBattery()
                startHRVMonitoring()
                logger.info("Auto-started HRV streaming after connection")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == BLEConstants.txCharUUID,
                  let data = characteristic.value else {
                return
            }
            handleNotification(data: data)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                logger.error("Notification state error: \(error.localizedDescription)")
            } else {
                logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
            }
        }
    }
}
