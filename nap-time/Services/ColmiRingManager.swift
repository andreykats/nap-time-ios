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
        stopPPGStreaming()
        hrContinuation?.finish()
        ppgContinuation?.finish()
        hrContinuation = nil
        ppgContinuation = nil
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
                self?.writeCommand(BLEConstants.keepAliveHRPacket())
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
        logger.debug("RX [\(data.count) bytes]: \(hex)")

        guard data.count >= 4 else {
            logger.debug("Ignoring very short packet (\(data.count) bytes)")
            return
        }

        let commandByte = data[0]

        switch commandByte {
        case BLEConstants.Command.startRealTime.rawValue:
            parseHeartRateResponse(data: data)

        case BLEConstants.Command.rawSensor.rawValue:
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
        let bpmValue = Int(data[3])

        logger.info("HR response: type=\(readingType) error=\(errorCode) bpm=\(bpmValue)")

        guard errorCode == 0,
              readingType == BLEConstants.ReadingType.heartRate.rawValue,
              bpmValue > 0 else {
            return
        }

        // Always update latestHR so the UI can show BPM even outside a nap session
        latestHR = bpmValue

        let reading = HeartRateReading(timestamp: .now, bpm: bpmValue)
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

            // Once both characteristics are ready, request battery and start HR streaming
            if rxCharacteristic != nil && txCharacteristic != nil {
                requestBattery()
                startHeartRateMonitoring()
                logger.info("Auto-started HR streaming after connection")
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
