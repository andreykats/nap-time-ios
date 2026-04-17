import Foundation

struct HeartRateReading: Sendable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let bpm: Int
}
