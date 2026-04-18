import Charts
import SwiftData
import SwiftUI

struct NapHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedNapSession.startTime, order: .reverse) private var sessions: [SavedNapSession]

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Nap History",
                    systemImage: "moon.zzz",
                    description: Text("Completed naps will appear here once you finish your first session.")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        SavedNapCard(session: session)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Nap History")
    }

    private func delete(_ session: SavedNapSession) {
        modelContext.delete(session)
        try? modelContext.save()
    }
}

private struct SavedNapCard: View {
    let session: SavedNapSession

    private var calibrationEndTime: Date {
        session.startTime.addingTimeInterval(session.calibrationDurationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            hrChart

            HRVChartView(
                hrvHistory: session.hrvHistory,
                startTime: session.startTime,
                calibrationEndTime: calibrationEndTime,
                sleepOnsetTime: session.sleepOnsetTime
            )

            HStack(spacing: 16) {
                metric(label: "Avg HR", value: String(format: "%.0f", session.averageHR), unit: "bpm")
                metric(label: "Avg RMSSD", value: String(format: "%.0f", session.averageRMSSD), unit: "ms")
                metric(label: "Length", value: mmss(session.totalDurationSeconds), unit: "")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var hrChart: some View {
        let readings = session.hrHistory
        if !readings.isEmpty {
            Chart {
                ForEach(readings) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp.timeIntervalSince(session.startTime)),
                        y: .value("BPM", reading.bpm)
                    )
                    .foregroundStyle(.red.gradient)
                    .interpolationMethod(.catmullRom)
                }

                RuleMark(x: .value("Calibration end", session.calibrationDurationSeconds))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))

                if let onset = session.sleepOnsetTime {
                    RuleMark(x: .value("Sleep onset", onset.timeIntervalSince(session.startTime)))
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

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startTime, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.headline)
                if let onset = session.sleepOnsetTime {
                    Text("Slept at \(mmss(onset.timeIntervalSince(session.startTime)))")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Sleep not detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(mmss(session.totalDurationSeconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func yAxisDomain(for readings: [HeartRateReading]) -> ClosedRange<Int> {
        let bpms = readings.map(\.bpm)
        let minBPM = max(30, (bpms.min() ?? 40) - 10)
        let maxBPM = min(200, (bpms.max() ?? 120) + 10)
        return minBPM...maxBPM
    }

    @ViewBuilder
    private func metric(label: String, value: String, unit: String) -> some View {
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
}
