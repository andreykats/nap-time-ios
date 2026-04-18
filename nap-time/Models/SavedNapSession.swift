import Foundation
import SwiftData

@Model
final class SavedNapSession {
    var startTime: Date
    var endTime: Date
    var calibrationDurationSeconds: Double
    var sleepOnsetTime: Date?
    var napDurationMinutes: Int
    var averageHR: Double
    var averageRMSSD: Double
    var hrHistory: [HeartRateReading]
    var hrvHistory: [HRVFeatures]

    init(
        startTime: Date,
        endTime: Date,
        calibrationDurationSeconds: Double,
        sleepOnsetTime: Date?,
        napDurationMinutes: Int,
        averageHR: Double,
        averageRMSSD: Double,
        hrHistory: [HeartRateReading],
        hrvHistory: [HRVFeatures]
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.calibrationDurationSeconds = calibrationDurationSeconds
        self.sleepOnsetTime = sleepOnsetTime
        self.napDurationMinutes = napDurationMinutes
        self.averageHR = averageHR
        self.averageRMSSD = averageRMSSD
        self.hrHistory = hrHistory
        self.hrvHistory = hrvHistory
    }

    var totalDurationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}
