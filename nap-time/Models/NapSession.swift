import Foundation
import Observation

@Observable
final class NapSession {
    enum State: Sendable {
        case idle
        case connecting
        case calibrating(progress: Double) // 0.0 to 1.0
        case monitoring
        case sleepDetected(at: Date)
        case alarming
        case completed(summary: NapSummary)
        case error(String)
    }

    struct NapSummary: Sendable {
        let startTime: Date
        let sleepOnsetTime: Date?
        let endTime: Date
        let averageHR: Double
        let averageRMSSD: Double
    }

    var state: State = .idle
    var currentHR: Int = 0
    var hrHistory: [HeartRateReading] = []
    var hrvHistory: [HRVFeatures] = []
    var napDurationMinutes: Int = 20
    var startTime: Date?
    var sleepOnsetTime: Date?
    var calibrationDurationSeconds: TimeInterval = 300

    var isActive: Bool {
        switch state {
        case .idle, .completed, .error:
            return false
        default:
            return true
        }
    }

    var statusText: String {
        switch state {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting..."
        case .calibrating(let progress):
            return "Calibrating... \(Int(progress * 100))%"
        case .monitoring:
            return "Waiting for sleep.."
        case .sleepDetected(let at):
            let remaining = Double(napDurationMinutes * 60) - Date.now.timeIntervalSince(at)
            let mins = max(0, Int(remaining) / 60)
            let secs = max(0, Int(remaining) % 60)
            return "Sleep detected! Waking in \(mins):\(String(format: "%02d", secs))"
        case .alarming:
            return "WAKE UP!"
        case .completed:
            return "Nap complete"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    func reset() {
        state = .idle
        currentHR = 0
        hrHistory = []
        hrvHistory = []
        startTime = nil
        sleepOnsetTime = nil
    }
}
