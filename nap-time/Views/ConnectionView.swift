import CoreBluetooth
import SwiftUI

struct ConnectionView: View {
    @Bindable var ringManager: ColmiRingManager

    var body: some View {
        List {
            connectionStatusSection
            batterySection
            discoveredDevicesSection
        }
        .navigationTitle("Ring")
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

    // MARK: - Sections

    @ViewBuilder
    private var connectionStatusSection: some View {
        Section("Status") {
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

    // MARK: - Helpers

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
