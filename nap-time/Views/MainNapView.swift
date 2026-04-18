import Charts
import SwiftUI

struct MainNapView: View {
    @Bindable var controller: NapAlarmController
    let ringManager: ColmiRingManager

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusCard
                controlSection
                hrChartSection
                hrvSection
            }
            .padding()
        }
        .navigationTitle("Nap Time")
    }

    // MARK: - Status Card

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusColor.opacity(0.5), radius: 4)

            Text(displayedStatusText)
                .font(.headline)

            Spacer()

            if case .calibrating(let progress) = controller.session.state {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(.indigo)
            }

            if displayedHR > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                    Text("\(displayedHR)")
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayedHR)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    // MARK: - Heart Rate Display

    /// Show session HR during nap, or live ring HR otherwise
    private var displayedHR: Int {
        controller.session.isActive ? controller.session.currentHR : ringManager.latestHR
    }

    // MARK: - Heart Rate Chart

    @ViewBuilder
    private var hrChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart Rate")
                .font(.headline)

            let recentReadings = Array(controller.session.hrHistory.suffix(300))
            if recentReadings.isEmpty {
                ContentUnavailableView(
                    "No Data Yet",
                    systemImage: "heart.text.clipboard",
                    description: Text("Heart rate readings will appear here once the ring starts streaming.")
                )
                .frame(height: 180)
            } else {
                Chart(recentReadings) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("BPM", reading.bpm)
                    )
                    .foregroundStyle(.red.gradient)
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: yAxisDomain(for: recentReadings))
                .frame(height: 180)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    // MARK: - HRV Section

    @ViewBuilder
    private var hrvSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HRV Analysis")
                .font(.headline)

            HRVChartView(hrvHistory: Array(controller.session.hrvHistory.suffix(30)))

            if let latest = controller.session.hrvHistory.last {
                HStack(spacing: 16) {
                    metricView(label: "RMSSD", value: String(format: "%.0f", latest.rmssd), unit: "ms")
                    metricView(label: "SDNN", value: String(format: "%.0f", latest.sdnn), unit: "ms")
                    metricView(label: "LF/HF", value: String(format: "%.2f", latest.lfHfRatio), unit: "")
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func metricView(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlSection: some View {
        VStack(spacing: 16) {
            if !controller.session.isActive {
                Picker("Nap Duration", selection: $controller.session.napDurationMinutes) {
                    Text("15 min").tag(15)
                    Text("20 min").tag(20)
                    Text("25 min").tag(25)
                    Text("30 min").tag(30)
                }
                .pickerStyle(.segmented)
            }

            Button(action: toggleNap) {
                Label(
                    controller.session.isActive ? "Stop" : "Start Nap",
                    systemImage: controller.session.isActive ? "stop.fill" : "play.fill"
                )
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.session.isActive ? .red : .indigo)
            .controlSize(.large)
            .disabled(!controller.session.isActive && (isRingDisconnected || isWarmingUp))
        }
    }

    // MARK: - Helpers

    private var isWarmingUp: Bool {
        if case .idle = controller.session.state,
           ringManager.connectionState == .connected,
           ringManager.latestHR == 0 {
            return true
        }
        return false
    }

    private var isRingDisconnected: Bool {
        if case .idle = controller.session.state {
            return ringManager.connectionState != .connected
        }
        return false
    }

    private var displayedStatusText: String {
        if isRingDisconnected {
            switch ringManager.connectionState {
            case .scanning: return "Scanning for ring.."
            case .connecting: return "Connecting to ring.."
            case .disconnecting: return "Disconnecting.."
            case .disconnected, .connected: return "Ring not connected"
            }
        }
        return isWarmingUp ? "Warming up.." : controller.session.statusText
    }

    private var statusColor: Color {
        if isRingDisconnected { return .gray }
        if isWarmingUp { return .orange }
        switch controller.session.state {
        case .idle: return .gray
        case .connecting: return .orange
        case .calibrating: return .yellow
        case .monitoring: return .blue
        case .sleepDetected: return .green
        case .alarming: return .red
        case .completed: return .indigo
        case .error: return .red
        }
    }

    private func toggleNap() {
        if controller.session.isActive {
            controller.stopNap()
        } else {
            controller.startNap()
        }
    }

    private func yAxisDomain(for readings: [HeartRateReading]) -> ClosedRange<Int> {
        let bpms = readings.map(\.bpm)
        let minBPM = max(30, (bpms.min() ?? 40) - 10)
        let maxBPM = min(200, (bpms.max() ?? 120) + 10)
        return minBPM...maxBPM
    }
}
