import Charts
import SwiftUI

/// Dual-series chart showing heart rate and RMSSD over time.
struct HRVChartView: View {
    let hrvHistory: [HRVFeatures]

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
                    // Heart rate line (red)
                    LineMark(
                        x: .value("Time", features.timestamp),
                        y: .value("HR", features.meanHR),
                        series: .value("Metric", "HR")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    // RMSSD area (blue)
                    AreaMark(
                        x: .value("Time", features.timestamp),
                        y: .value("RMSSD", features.rmssd),
                        series: .value("Metric", "RMSSD")
                    )
                    .foregroundStyle(.blue.opacity(0.2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", features.timestamp),
                        y: .value("RMSSD", features.rmssd),
                        series: .value("Metric", "RMSSD")
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .chartForegroundStyleScale([
                "HR": .red,
                "RMSSD": .blue
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel()
                        .foregroundStyle(.red)
                    AxisGridLine()
                }
            }
            .frame(height: 250)
        }
    }
}
