import ActivityKit
import Foundation

// TODO: AlarmKit conformance — uncomment when AlarmKit is available in the SDK.
// AlarmKit is new in iOS 26 and the exact API shape may need adjustment.
//
// import AlarmKit
//
// nonisolated struct NapAlarmMetadata: AlarmMetadata {
//     var sleepDetectedAt: Date
//     var napDurationMinutes: Int
//     var currentHeartRate: Int
// }

/// Placeholder metadata for the nap alarm, used by both app and widget targets.
/// Will conform to AlarmMetadata once AlarmKit SDK is integrated.
nonisolated struct NapAlarmMetadata: Codable, Hashable, Sendable {
    var sleepDetectedAt: Date
    var napDurationMinutes: Int
    var currentHeartRate: Int
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
