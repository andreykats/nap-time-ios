import Foundation
import os

nonisolated(unsafe) private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "Sleep")

/// Detects sleep onset using multi-feature HRV threshold analysis.
///
/// Two phases:
/// 1. Calibration: collects baseline HRV metrics while the user is awake but resting
/// 2. Detection: monitors for simultaneous RMSSD increase, HR decrease, and LF/HF decrease
///    sustained over multiple consecutive epochs
///
/// Based on published research: Burgess et al. (1999), de Zambotti et al. (2011, 2016),
/// Tobaldini et al. (2013), Fonseca et al. (2023).
nonisolated final class SleepOnsetDetector: Sendable {

    enum Result: Sendable {
        case calibrating(progress: Double)
        case calibrationComplete
        case awake
        case sleepOnsetDetected
    }

    struct Baseline: Sendable {
        let meanRMSSD: Double
        let sdRMSSD: Double
        let meanHR: Double
        let sdHR: Double
        let meanLFHF: Double
        let sdLFHF: Double
    }

    private let state: DetectorState

    private final class DetectorState: @unchecked Sendable {
        var calibrationSamples: [HRVFeatures] = []
        var baseline: Baseline?
        var consecutiveSleepEpochs = 0
        var startTime: Date?
        var config: SleepDetectionConfig

        init(config: SleepDetectionConfig) {
            self.config = config
        }
    }

    var isCalibrating: Bool { state.baseline == nil }

    var calibrationProgress: Double {
        guard let start = state.startTime else { return 0 }
        return min(1.0, Date.now.timeIntervalSince(start) / state.config.calibrationDuration)
    }

    init(config: SleepDetectionConfig = SleepDetectionConfig()) {
        self.state = DetectorState(config: config)
        state.startTime = .now
    }

    /// Update detection thresholds without rebuilding the detector. Safe to call
    /// between naps; calibration samples are preserved (use `reset()` to clear).
    func updateConfig(_ newConfig: SleepDetectionConfig) {
        state.config = newConfig
    }

    /// Add a new HRV feature set and evaluate sleep onset.
    func addFeatures(_ features: HRVFeatures) -> Result {
        if state.baseline == nil {
            return handleCalibration(features)
        }
        return evaluateSleepOnset(features)
    }

    func reset() {
        state.calibrationSamples = []
        state.baseline = nil
        state.consecutiveSleepEpochs = 0
        state.startTime = .now
    }

    // MARK: - Calibration

    private func handleCalibration(_ features: HRVFeatures) -> Result {
        state.calibrationSamples.append(features)

        let requiredSamples = Int(state.config.calibrationDuration / state.config.epochDuration)
        let progress = min(1.0, Double(state.calibrationSamples.count) / Double(requiredSamples))

        if state.calibrationSamples.count >= requiredSamples {
            state.baseline = computeBaseline()
            if let baseline = state.baseline {
                logger.info("""
                    Calibration complete — baseline: \
                    RMSSD=\(baseline.meanRMSSD, format: .fixed(precision: 1))±\(baseline.sdRMSSD, format: .fixed(precision: 1))ms, \
                    HR=\(baseline.meanHR, format: .fixed(precision: 1))bpm, \
                    LF/HF=\(baseline.meanLFHF, format: .fixed(precision: 2))
                    """)
            }
            return .calibrationComplete
        }

        return .calibrating(progress: progress)
    }

    private func computeBaseline() -> Baseline {
        let rmssdValues = state.calibrationSamples.map(\.rmssd)
        let hrValues = state.calibrationSamples.map(\.meanHR)
        let lfhfValues = state.calibrationSamples.map(\.lfHfRatio)

        return Baseline(
            meanRMSSD: Self.mean(rmssdValues),
            sdRMSSD: Self.standardDeviation(rmssdValues),
            meanHR: Self.mean(hrValues),
            sdHR: Self.standardDeviation(hrValues),
            meanLFHF: Self.mean(lfhfValues),
            sdLFHF: Self.standardDeviation(lfhfValues)
        )
    }

    // MARK: - Sleep Onset Evaluation

    private func evaluateSleepOnset(_ features: HRVFeatures) -> Result {
        guard let baseline = state.baseline else { return .awake }
        let config = state.config

        var criteriaMet = 0
        var totalCriteria = 0

        // Criterion 1: RMSSD increased above baseline + threshold SD
        // (Parasympathetic activation at sleep onset)
        totalCriteria += 1
        let rmssdThreshold = baseline.meanRMSSD + config.rmssdIncreaseSD * baseline.sdRMSSD
        if features.rmssd > rmssdThreshold {
            criteriaMet += 1
        }

        // Criterion 2: Mean HR dropped below baseline by specified percentage
        // (Heart rate deceleration at sleep onset)
        totalCriteria += 1
        let hrThreshold = baseline.meanHR * (1.0 - config.hrDropPercent)
        if features.meanHR < hrThreshold {
            criteriaMet += 1
        }

        // Criterion 3: LF/HF ratio decreased below baseline
        // (Sympathovagal shift toward parasympathetic dominance)
        if config.lfHfRatioDecrease {
            totalCriteria += 1
            if features.lfHfRatio < baseline.meanLFHF {
                criteriaMet += 1
            }
        }

        // All criteria must be met simultaneously
        if criteriaMet == totalCriteria {
            state.consecutiveSleepEpochs += 1
            let epochs = self.state.consecutiveSleepEpochs
            let required = config.requiredConsecutiveEpochs
            logger.debug("Sleep criteria met (\(epochs)/\(required) epochs)")
        } else {
            if state.consecutiveSleepEpochs > 0 {
                logger.debug("Sleep criteria reset (met \(criteriaMet)/\(totalCriteria))")
            }
            state.consecutiveSleepEpochs = 0
        }

        if state.consecutiveSleepEpochs >= config.requiredConsecutiveEpochs {
            logger.info("Sleep onset detected!")
            return .sleepOnsetDetected
        }

        return .awake
    }

    // MARK: - Statistics Helpers

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let avg = mean(values)
        let variance = values.map { pow($0 - avg, 2) }.reduce(0, +) / Double(values.count - 1)
        return sqrt(variance)
    }
}
