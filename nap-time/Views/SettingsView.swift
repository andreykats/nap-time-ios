import SwiftUI

struct SettingsView: View {
    @AppStorage("calibrationDuration") private var calibrationDuration: Double = 300
    @AppStorage("sensitivity") private var sensitivity: Double = 1.0
    @AppStorage("napDuration") private var napDuration: Int = 20
    @AppStorage("autoCancelOnWake") private var autoCancelOnWake: Bool = true
    @AppStorage("snoozeDuration") private var snoozeDuration: Int = 5

    var body: some View {
        Form {
            detectionSection
            calibrationSection
            alarmSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    // MARK: - Sections

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
}
