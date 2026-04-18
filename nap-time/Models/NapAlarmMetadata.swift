import ActivityKit
import AlarmKit
import Foundation

nonisolated struct NapAlarmMetadata: AlarmMetadata {
    var sleepDetectedAt: Date
    var napDurationMinutes: Int
}

/// Live Activity attributes shared between the main app (which starts / updates / ends
/// the activity) and the widget extension (which renders it).
nonisolated struct NapAlarmAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// nil before sleep-onset detection — the widget shows a "Monitoring" state.
        var sleepDetectedAt: Date?
        /// nil until sleep is detected and the alarm is scheduled.
        var wakeUpAt: Date?
        var currentHeartRate: Int
        var isAlarming: Bool
    }

    var napDurationMinutes: Int
}
