import Foundation

/// An inter-beat interval extracted from PPG peak detection.
struct InterBeatInterval: Sendable {
    let timestamp: Date
    let intervalMs: Double   // milliseconds between successive systolic peaks
    let isValid: Bool        // false if artifact-rejected
}
