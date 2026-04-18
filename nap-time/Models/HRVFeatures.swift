import Foundation

/// Computed HRV feature set from a 5-minute sliding window of IBIs.
struct HRVFeatures: Sendable, Identifiable, Codable {
    var id = UUID()
    let timestamp: Date

    // Time domain
    let rmssd: Double     // root mean square of successive IBI differences (ms)
    let sdnn: Double      // standard deviation of all NN intervals (ms)
    let pnn50: Double     // percentage of successive diffs > 50ms
    let meanHR: Double    // beats per minute

    // Frequency domain
    let lfPower: Double   // low frequency power 0.04-0.15 Hz (ms^2)
    let hfPower: Double   // high frequency power 0.15-0.40 Hz (ms^2)
    let lfHfRatio: Double // sympathovagal balance indicator
}
