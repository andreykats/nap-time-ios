import CoreBluetooth
import SwiftUI

struct SettingsView: View {
    @Bindable var ringManager: ColmiRingManager

    @AppStorage("calibrationDuration") private var calibrationDuration: Double = 300
    @AppStorage("sensitivity") private var sensitivity: Double = 1.0
    @AppStorage("napDuration") private var napDuration: Int = 20
    @AppStorage("autoCancelOnWake") private var autoCancelOnWake: Bool = true
    @AppStorage("snoozeDuration") private var snoozeDuration: Int = 5

    var body: some View {
        Form {
            connectionStatusSection
            batterySection
            discoveredDevicesSection
            detectionSection
            calibrationSection
            alarmSection
            aboutSection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if ringManager.isScanning {
                        ringManager.stopScanning()
                    } else {
                        ringManager.startScanning()
                    }
                } label: {
                    Text(ringManager.isScanning ? "Stop" : "Scan")
                }
            }
        }
    }

    // MARK: - Ring Sections

    @ViewBuilder
    private var connectionStatusSection: some View {
        Section("Ring") {
            HStack {
                Label {
                    Text(connectionStatusText)
                } icon: {
                    Image(systemName: connectionStatusIcon)
                        .foregroundStyle(connectionStatusColor)
                }

                Spacer()

                if ringManager.connectionState == .connecting {
                    ProgressView()
                }
            }

            if let peripheral = ringManager.connectedPeripheral {
                HStack {
                    Text("Connected to")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(peripheral.name ?? "Unknown Ring")
                        .fontWeight(.medium)
                }

                Button("Disconnect", role: .destructive) {
                    ringManager.disconnect()
                }
            }
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        if let battery = ringManager.batteryLevel {
            Section("Battery") {
                HStack {
                    Label {
                        Text("\(battery)%")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    } icon: {
                        Image(systemName: batteryIconName(level: battery, charging: ringManager.isCharging))
                            .foregroundStyle(batteryColor(level: battery))
                    }

                    Spacer()

                    if ringManager.isCharging {
                        Text("Charging")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredDevicesSection: some View {
        Section {
            if ringManager.isScanning && ringManager.discoveredDevices.isEmpty {
                HStack {
                    ProgressView()
                    Text("Scanning for Colmi rings...")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }

            ForEach(ringManager.discoveredDevices, id: \.identifier) { peripheral in
                Button {
                    ringManager.connect(to: peripheral)
                } label: {
                    HStack {
                        Image(systemName: "circle.circle")
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading) {
                            Text(peripheral.name ?? "Unknown Ring")
                                .fontWeight(.medium)
                            Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text("Discovered Rings")
        } footer: {
            if ringManager.discoveredDevices.isEmpty && !ringManager.isScanning {
                Text("Tap Scan to search for nearby Colmi R02 rings. Make sure your ring is charged and nearby.")
            }
        }
    }

    // MARK: - Settings Sections

    @ViewBuilder
    private var detectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sensitivity, in: 0.5...2.0, step: 0.1)
                    .tint(.indigo)
            }
        } header: {
            Text("Sleep Detection")
        } footer: {
            Text("Higher sensitivity detects sleep onset earlier but may trigger false alarms. Lower sensitivity is more conservative. The default (1.0) uses published research thresholds.")
        }
    }

    @ViewBuilder
    private var calibrationSection: some View {
        Section {
            Picker("Calibration Duration", selection: $calibrationDuration) {
                Text("3 minutes").tag(180.0)
                Text("5 minutes").tag(300.0)
                Text("7 minutes").tag(420.0)
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("How long to collect baseline measurements while you're awake. Longer calibration gives more accurate baselines but delays monitoring.")
        }
    }

    @ViewBuilder
    private var alarmSection: some View {
        Section("Alarm") {
            Picker("Default Nap Duration", selection: $napDuration) {
                Text("15 minutes").tag(15)
                Text("20 minutes").tag(20)
                Text("25 minutes").tag(25)
                Text("30 minutes").tag(30)
            }

            Toggle("Auto-cancel on early wake", isOn: $autoCancelOnWake)

            Picker("Snooze Duration", selection: $snoozeDuration) {
                Text("3 minutes").tag(3)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "1.0 (POC)")
            LabeledContent("Ring Protocol", value: "Colmi R02")

            VStack(alignment: .leading, spacing: 4) {
                Text("Sleep Detection Method")
                    .font(.subheadline)
                Text("Multi-feature HRV threshold analysis based on published research (Burgess et al., de Zambotti et al., Fonseca et al.). Uses RMSSD, mean HR, and LF/HF ratio with configurable thresholds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    private var sensitivityLabel: String {
        switch sensitivity {
        case ..<0.8: "Low"
        case 0.8..<1.2: "Normal"
        case 1.2..<1.6: "High"
        default: "Very High"
        }
    }

    private var connectionStatusText: String {
        switch ringManager.connectionState {
        case .disconnected: "Disconnected"
        case .scanning: "Scanning..."
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .disconnecting: "Disconnecting..."
        }
    }

    private var connectionStatusIcon: String {
        switch ringManager.connectionState {
        case .disconnected: "circle.slash"
        case .scanning: "antenna.radiowaves.left.and.right"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .disconnecting: "arrow.triangle.2.circlepath"
        }
    }

    private var connectionStatusColor: Color {
        switch ringManager.connectionState {
        case .disconnected: .gray
        case .scanning: .orange
        case .connecting: .orange
        case .connected: .green
        case .disconnecting: .orange
        }
    }

    private func batteryIconName(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 0..<25: return "battery.25percent"
        case 25..<50: return "battery.50percent"
        case 50..<75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(level: Int) -> Color {
        switch level {
        case 0..<20: .red
        case 20..<50: .orange
        default: .green
        }
    }
}
