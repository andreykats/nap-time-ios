import CoreBluetooth

/// BLE protocol constants for the Colmi R02 smart ring.
/// All packets are exactly 16 bytes with a checksum at byte 15.
/// Protocol reverse-engineered by github.com/tahnok/colmi_r02_client
enum BLEConstants {
    static let serviceUUID = CBUUID(string: "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let packetSize  = 16

    /// Known device name prefixes for Colmi-compatible rings.
    /// The ring does NOT advertise its service UUID — discovery is name-based only.
    /// Source: github.com/tahnok/colmi_r02_client
    nonisolated(unsafe) static let knownNamePrefixes = [
        "R01", "R02", "R03", "R04", "R05", "R06", "R07", "R09", "R10",
        "COLMI", "VK-5098", "MERLIN", "Hello Ring", "RING1", "boAtring",
        "TR-R02", "SE", "EVOLVEO", "GL-SR2", "Blaupunkt", "KSIX RING",
    ]

    /// Check if a device name matches a known Colmi ring prefix.
    nonisolated static func isColmiRing(name: String?) -> Bool {
        guard let name else { return false }
        let upper = name.uppercased()
        return knownNamePrefixes.contains { upper.hasPrefix($0.uppercased()) }
    }

    enum Command: UInt8 {
        case startRealTime    = 0x69  // 105
        case stopRealTime     = 0x6A  // 106
        case realTimeKeepAlive = 0x1E // 30
        case rawSensor        = 0xA1  // 161
        case battery          = 0x03
    }

    enum ReadingType: UInt8 {
        case heartRate = 0x01
        case spo2      = 0x03
        case hrv       = 0x0A  // tahnok: RealTimeReading.HRV = 10
    }

    enum SensorAction: UInt8 {
        case start    = 0x01
        case pause    = 0x02
        case `continue` = 0x03
        case stop     = 0x04
    }

    enum RawSensorSubcommand: UInt8 {
        case enablePPG  = 0x04
        case disablePPG = 0x02
    }

    enum PPGResponseType: UInt8 {
        case spo2         = 0x01
        case ppgWaveform  = 0x02
        case accelerometer = 0x03
    }

    // MARK: - Packet Builders

    /// Build a 16-byte packet: [command, ...payload padded to 14 bytes, checksum]
    static func makePacket(command: UInt8, payload: [UInt8] = []) -> Data {
        var bytes = [UInt8](repeating: 0, count: packetSize)
        bytes[0] = command
        for (i, b) in payload.prefix(14).enumerated() {
            bytes[i + 1] = b
        }
        let sum = bytes[0..<15].reduce(0, &+)
        bytes[15] = sum & 0xFF
        return Data(bytes)
    }

    /// Start real-time heart rate streaming
    static func startHRPacket() -> Data {
        makePacket(command: Command.startRealTime.rawValue,
                   payload: [ReadingType.heartRate.rawValue, SensorAction.start.rawValue])
    }

    /// Keep-alive for real-time HR stream (send every ~10s)
    static func keepAliveHRPacket() -> Data {
        makePacket(command: Command.realTimeKeepAlive.rawValue,
                   payload: [0x33])
    }

    /// Stop real-time heart rate streaming
    static func stopHRPacket() -> Data {
        makePacket(command: Command.stopRealTime.rawValue,
                   payload: [ReadingType.heartRate.rawValue])
    }

    /// Start real-time HRV streaming (native ring-computed HRV)
    static func startHRVPacket() -> Data {
        makePacket(command: Command.startRealTime.rawValue,
                   payload: [ReadingType.hrv.rawValue, SensorAction.start.rawValue])
    }

    /// Keep-alive for real-time HRV stream (send every ~10s to prevent the
    /// ring from timing out the session). Format: `0x69 [HRV, CONTINUE]`.
    static func continueHRVPacket() -> Data {
        makePacket(command: Command.startRealTime.rawValue,
                   payload: [ReadingType.hrv.rawValue, SensorAction.continue.rawValue])
    }

    /// Stop real-time HRV streaming
    static func stopHRVPacket() -> Data {
        makePacket(command: Command.stopRealTime.rawValue,
                   payload: [ReadingType.hrv.rawValue])
    }

    /// Enable raw PPG sensor streaming
    static func enablePPGPacket() -> Data {
        makePacket(command: Command.rawSensor.rawValue,
                   payload: [RawSensorSubcommand.enablePPG.rawValue])
    }

    /// Disable raw PPG sensor streaming
    static func disablePPGPacket() -> Data {
        makePacket(command: Command.rawSensor.rawValue,
                   payload: [RawSensorSubcommand.disablePPG.rawValue])
    }

    /// Request battery status
    static func batteryPacket() -> Data {
        makePacket(command: Command.battery.rawValue)
    }
}
