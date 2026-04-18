import Foundation

/// Configurable thresholds for sleep onset detection.
/// Defaults are based on published norms but will need per-user tuning.
struct SleepDetectionConfig: Sendable, Codable {
    /// Duration of the initial calibration phase (seconds)
    var calibrationDuration: TimeInterval = 300  // 5 minutes

    /// Required HR drop below baseline to indicate sleep (fraction, e.g. 0.05 = 5%)
    var hrDropPercent: Double = 0.05

    /// Required RMSSD increase above baseline in standard deviations
    var rmssdIncreaseSD: Double = 1.0

    /// Whether LF/HF ratio must decrease below baseline
    var lfHfRatioDecrease: Bool = true

    /// Number of consecutive 30-second epochs meeting all criteria
    var requiredConsecutiveEpochs: Int = 2

    /// Duration of each evaluation epoch (seconds)
    var epochDuration: TimeInterval = 30

    /// HRV sliding window duration (seconds)
    var slidingWindowDuration: TimeInterval = 300  // 5 minutes

    /// Nap duration after sleep onset (minutes). Also used as the backstop:
    /// if sleep is never detected, the alarm fires this long after Start.
    var napDurationMinutes: Int = 20

    /// Whether to auto-cancel alarm if early wake is detected
    var autoCancelOnWake: Bool = true

    /// Snooze duration (minutes)
    var snoozeDurationMinutes: Int = 5
}
