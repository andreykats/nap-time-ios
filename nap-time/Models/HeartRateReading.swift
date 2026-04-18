import Foundation

struct HeartRateReading: Sendable, Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let bpm: Int
}
