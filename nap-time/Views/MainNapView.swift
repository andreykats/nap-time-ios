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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(ringManager: ringManager)
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
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
        NavigationLink {
            NapHistoryView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart Rate")
                    .font(.headline)

                let readings = controller.session.hrHistory
                if readings.isEmpty {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "heart.text.clipboard",
                        description: Text("Heart rate readings will appear here once the ring starts streaming.")
                    )
                    .frame(height: 180)
                } else {
                    Chart {
                        ForEach(readings) { reading in
                            LineMark(
                                x: .value("Time", elapsed(reading.timestamp)),
                                y: .value("BPM", reading.bpm)
                            )
                            .foregroundStyle(.red.gradient)
                            .interpolationMethod(.catmullRom)
                        }

                        if let calibEnd = calibrationEndTime {
                            RuleMark(x: .value("Calibration end", elapsed(calibEnd)))
                                .foregroundStyle(.secondary.opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }

                        if let onset = controller.session.sleepOnsetTime {
                            RuleMark(x: .value("Sleep onset", elapsed(onset)))
                                .foregroundStyle(.green.opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let s = value.as(TimeInterval.self) {
                                    Text(mmss(s))
                                }
                            }
                        }
                    }
                    .chartYScale(domain: yAxisDomain(for: readings))
                    .frame(height: 180)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - HRV Section

    @ViewBuilder
    private var hrvSection: some View {
        NavigationLink {
            NapHistoryView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("HRV Analysis")
                    .font(.headline)

                HRVChartView(
                    hrvHistory: controller.session.hrvHistory,
                    startTime: controller.session.startTime,
                    calibrationEndTime: calibrationEndTime,
                    sleepOnsetTime: controller.session.sleepOnsetTime
                )

                if let latest = controller.session.hrvHistory.last {
                    HStack(spacing: 16) {
                        metricView(label: "RMSSD", value: String(format: "%.0f", latest.rmssd), unit: "ms")
                        metricView(label: "SDNN", value: String(format: "%.0f", latest.sdnn), unit: "ms")
                        metricView(label: "LF/HF", value: String(format: "%.2f", latest.lfHfRatio), unit: "")
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func elapsed(_ date: Date) -> TimeInterval {
        guard let start = controller.session.startTime else { return 0 }
        return date.timeIntervalSince(start)
    }

    private var calibrationEndTime: Date? {
        guard let start = controller.session.startTime else { return nil }
        return start.addingTimeInterval(controller.session.calibrationDurationSeconds)
    }

    private func yAxisDomain(for readings: [HeartRateReading]) -> ClosedRange<Int> {
        let bpms = readings.map(\.bpm)
        let minBPM = max(30, (bpms.min() ?? 40) - 10)
        let maxBPM = min(200, (bpms.max() ?? 120) + 10)
        return minBPM...maxBPM
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
                    Text("1 min").tag(1)
                    Text("15 min").tag(15)
                    Text("20 min").tag(20)
                    Text("25 min").tag(25)
                    Text("30 min").tag(30)
                }
                .pickerStyle(.segmented)
            }

            Button(action: toggleNap) {
                HStack(spacing: 8) {
                    if let start = controller.session.startTime, controller.session.isActive {
                        Text(start, style: .timer)
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Image(systemName: controller.session.isActive ? "stop.fill" : "play.fill")
                    Text(controller.session.isActive ? "Stop" : "Start Nap")
                }
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
            case .connecting: return "Connecting.."
            case .disconnecting: return "Disconnecting.."
            case .disconnected, .connected: return "Ring not connected"
            }
        }
        return isWarmingUp ? "Waiting for heartbeat.." : controller.session.statusText
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

}
