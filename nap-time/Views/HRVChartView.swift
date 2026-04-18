import Charts
import SwiftUI

/// Dual-series chart showing heart rate and RMSSD over elapsed nap time.
/// Subtle vertical rules mark phase boundaries: end-of-calibration (gray dashed)
/// and sleep-onset (green dashed).
struct HRVChartView: View {
    let hrvHistory: [HRVFeatures]
    let startTime: Date?
    let calibrationEndTime: Date?
    let sleepOnsetTime: Date?

    var body: some View {
        if hrvHistory.isEmpty {
            ContentUnavailableView(
                "No HRV Data",
                systemImage: "waveform.path.ecg",
                description: Text("HRV features will appear here after calibration begins.")
            )
            .frame(height: 250)
        } else {
            Chart {
                ForEach(hrvHistory) { features in
                    LineMark(
                        x: .value("Time", elapsed(features.timestamp)),
                        y: .value("HR", features.meanHR),
                        series: .value("Metric", "HR")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Time", elapsed(features.timestamp)),
                        y: .value("RMSSD", features.rmssd),
                        series: .value("Metric", "RMSSD")
                    )
                    .foregroundStyle(.blue.opacity(0.2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", elapsed(features.timestamp)),
                        y: .value("RMSSD", features.rmssd),
                        series: .value("Metric", "RMSSD")
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }

                if let calibEnd = calibrationEndTime {
                    RuleMark(x: .value("Calibration end", elapsed(calibEnd)))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }

                if let onset = sleepOnsetTime {
                    RuleMark(x: .value("Sleep onset", elapsed(onset)))
                        .foregroundStyle(.green.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .chartForegroundStyleScale([
                "HR": .red,
                "RMSSD": .blue
            ])
            .chartLegend(position: .top, alignment: .leading)
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
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .foregroundStyle(.red)
                    AxisGridLine()
                }
            }
            .frame(height: 250)
        }
    }

    private func elapsed(_ date: Date) -> TimeInterval {
        guard let start = startTime else { return 0 }
        return date.timeIntervalSince(start)
    }
}

func mmss(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
