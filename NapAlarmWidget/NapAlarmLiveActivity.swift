import ActivityKit
import SwiftUI
import WidgetKit

// TODO: When AlarmKit is available, replace ActivityConfiguration(for: NapAlarmAttributes.self)
// with ActivityConfiguration(for: AlarmAttributes<NapAlarmMetadata>.self)

/// Live Activity attributes for the nap alarm countdown.
struct NapAlarmAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var sleepDetectedAt: Date
        var wakeUpAt: Date
        var currentHeartRate: Int
        var isAlarming: Bool
    }

    var napDurationMinutes: Int
}

struct NapAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NapAlarmAttributes.self) { context in
            // Lock Screen / StandBy presentation
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Nap", systemImage: "bed.double.fill")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label("\(context.state.currentHeartRate)", systemImage: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.isAlarming {
                        Text("Wake Up!")
                            .font(.headline)
                            .foregroundStyle(.red)
                    } else {
                        Text(context.state.wakeUpAt, style: .timer)
                            .font(.system(.title2, design: .rounded))
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Sleep detected at \(context.state.sleepDetectedAt, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(.indigo)
            } compactTrailing: {
                if context.state.isAlarming {
                    Image(systemName: "alarm.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(context.state.wakeUpAt, style: .timer)
                        .monospacedDigit()
                        .frame(width: 50)
                        .font(.caption2)
                }
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.indigo)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<NapAlarmAttributes>) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(.indigo)
                Text("Nap Alarm")
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                    Text("\(context.state.currentHeartRate) BPM")
                        .font(.subheadline)
                }
            }

            if context.state.isAlarming {
                Text("Time to Wake Up!")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
            } else {
                VStack(spacing: 4) {
                    Text("Waking you in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(context.state.wakeUpAt, style: .timer)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                }
            }

            Text("Sleep detected at \(context.state.sleepDetectedAt, style: .time)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
