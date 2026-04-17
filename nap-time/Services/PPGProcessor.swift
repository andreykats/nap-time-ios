import Accelerate
import Foundation
import os

nonisolated(unsafe) private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "PPG")

/// Processes raw PPG samples into inter-beat intervals (IBIs).
///
/// Pipeline: raw PPG → bandpass filter (0.5–5 Hz) → adaptive peak detection → IBI extraction → artifact rejection.
/// Uses Accelerate framework (vDSP) for efficient signal processing.
nonisolated final class PPGProcessor: Sendable {

    // MARK: - Configuration

    private let minPeakDistanceSec: Float = 0.33    // 180 BPM max
    private let maxPeakDistanceSec: Float = 2.0     // 30 BPM min
    private let thresholdScale: Float = 0.6         // adaptive threshold multiplier
    private let movingAvgWindowSec: Float = 0.75    // window for adaptive threshold

    // MARK: - Mutable State (accessed single-threaded from processing task)

    private let state = ProcessorState()

    private final class ProcessorState: @unchecked Sendable {
        var sampleBuffer: [PPGSample] = []
        var measuredSampleRate: Float?
        var timestampBuffer: [Date] = []
        var filterDelays: [Float] = Array(repeating: 0, count: 10)  // 2 biquad sections × 5 delay elements
        var biquadSetup: vDSP.Biquad<Float>?
        var lastPeakTimestamp: Date?
        var previousIBI: Double?
        let bufferSize = 128
    }

    // MARK: - Public API

    /// Process a single PPG sample. Returns IBIs when enough data has been buffered.
    func process(sample: PPGSample) -> [InterBeatInterval] {
        state.sampleBuffer.append(sample)

        // Calibrate sample rate from first 100 samples
        if state.measuredSampleRate == nil && state.sampleBuffer.count >= 100 {
            calibrateSampleRate()
        }

        guard state.sampleBuffer.count >= state.bufferSize,
              state.measuredSampleRate != nil else {
            return []
        }

        let samplesToProcess = Array(state.sampleBuffer.prefix(state.bufferSize))

        // Keep 50% overlap for continuity
        state.sampleBuffer = Array(state.sampleBuffer.suffix(from: state.bufferSize / 2))

        return processBuffer(samplesToProcess)
    }

    /// Reset all internal state
    func reset() {
        state.sampleBuffer = []
        state.measuredSampleRate = nil
        state.timestampBuffer = []
        state.filterDelays = Array(repeating: 0, count: 10)
        state.biquadSetup = nil
        state.lastPeakTimestamp = nil
        state.previousIBI = nil
    }

    // MARK: - Sample Rate Calibration

    private func calibrateSampleRate() {
        let timestamps = state.sampleBuffer.map { $0.timestamp.timeIntervalSinceReferenceDate }
        guard timestamps.count >= 2 else { return }

        var diffs = [Double]()
        for i in 1..<timestamps.count {
            let d = timestamps[i] - timestamps[i - 1]
            if d > 0 { diffs.append(d) }
        }
        guard !diffs.isEmpty else { return }

        let sorted = diffs.sorted()
        let medianDiff = sorted[sorted.count / 2]
        let rate = Float(1.0 / medianDiff)

        // Sanity check: expect 10-50 Hz from a BLE wearable
        if rate >= 10 && rate <= 50 {
            state.measuredSampleRate = rate
            initializeFilter(sampleRate: rate)
            logger.info("PPG sample rate calibrated: \(rate, format: .fixed(precision: 1)) Hz")
        } else {
            // Fall back to 25 Hz
            state.measuredSampleRate = 25.0
            initializeFilter(sampleRate: 25.0)
            logger.warning("Unusual sample rate \(rate, format: .fixed(precision: 1)) Hz, defaulting to 25 Hz")
        }
    }

    // MARK: - Bandpass Filter (0.5–5 Hz Butterworth)

    private func initializeFilter(sampleRate fs: Float) {
        // Design a 4th-order Butterworth bandpass filter (0.5–5 Hz) as 2 cascaded biquad sections.
        // Using bilinear transform from analog prototype.
        let fLow: Float = 0.5
        let fHigh: Float = 5.0

        // Prewarp cutoff frequencies
        let wLow = 2.0 * fs * tan(.pi * fLow / fs)
        let wHigh = 2.0 * fs * tan(.pi * fHigh / fs)
        let bw = wHigh - wLow
        let w0 = sqrt(wLow * wHigh)

        // 2nd-order Butterworth poles at angles ±π/4 from negative real axis
        // For bandpass, each analog pole pair becomes two biquad sections
        let Q: Float = w0 / bw  // Quality factor

        // Direct form II transposed biquad coefficients for bandpass
        // Section 1 & 2: derived from bilinear transform of 2nd-order bandpass
        let w0d = 2.0 * Float.pi * sqrt(fLow * fHigh) / fs  // normalized digital center freq
        let alpha = sin(w0d) / (2.0 * Q)

        // Bandpass constant-0-dB-peak-gain coefficients
        let b0 = alpha
        let b1: Float = 0.0
        let b2 = -alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos(w0d)
        let a2 = 1.0 - alpha

        // Normalize
        let nb0 = b0 / a0
        let nb1 = b1 / a0
        let nb2 = b2 / a0
        let na1 = a1 / a0
        let na2 = a2 / a0

        // Use two identical biquad sections in cascade (4th-order total)
        // vDSP.Biquad expects coefficients as [Double] per section: [b0, b1, b2, a1, a2]
        let coefficients: [Double] = [
            Double(nb0), Double(nb1), Double(nb2), Double(na1), Double(na2),  // section 1
            Double(nb0), Double(nb1), Double(nb2), Double(na1), Double(na2)  // section 2
        ]
        state.biquadSetup = vDSP.Biquad(
            coefficients: coefficients,
            channelCount: 1,
            sectionCount: 2,
            ofType: Float.self
        )
    }

    private func applyBandpassFilter(_ input: [Float]) -> [Float] {
        guard var biquad = state.biquadSetup else { return input }
        let result = biquad.apply(input: input)
        state.biquadSetup = biquad
        return result
    }

    // MARK: - Peak Detection

    private func processBuffer(_ samples: [PPGSample]) -> [InterBeatInterval] {
        guard let fs = state.measuredSampleRate else { return [] }

        // Extract raw values
        let rawValues = samples.map { Float($0.rawValue) }
        let timestamps = samples.map { $0.timestamp }

        // Apply bandpass filter
        let filtered = applyBandpassFilter(rawValues)

        // Compute adaptive threshold using moving average of absolute values
        let windowSize = max(3, Int(movingAvgWindowSec * fs))
        let absValues = filtered.map { abs($0) }
        let threshold = computeMovingAverage(absValues, windowSize: windowSize)
            .map { $0 * thresholdScale }

        // Find peaks above threshold with minimum distance
        let minSampleDistance = Int(minPeakDistanceSec * fs)
        var peakIndices: [Int] = []

        for i in 1..<(filtered.count - 1) {
            // Local maximum above threshold
            guard filtered[i] > filtered[i - 1],
                  filtered[i] > filtered[i + 1],
                  filtered[i] > threshold[i] else {
                continue
            }

            // Enforce minimum distance from last peak
            if let lastPeak = peakIndices.last, i - lastPeak < minSampleDistance {
                // Keep the taller peak
                if filtered[i] > filtered[lastPeak] {
                    peakIndices[peakIndices.count - 1] = i
                }
                continue
            }

            peakIndices.append(i)
        }

        // Compute IBIs from peaks
        var ibis: [InterBeatInterval] = []

        for i in 0..<peakIndices.count {
            let peakTime = timestamps[peakIndices[i]]

            // Compute IBI from previous peak (either from last buffer or this buffer)
            let referenceTime: Date?
            if i == 0 {
                referenceTime = state.lastPeakTimestamp
            } else {
                referenceTime = timestamps[peakIndices[i - 1]]
            }

            if let ref = referenceTime {
                let ibiMs = peakTime.timeIntervalSince(ref) * 1000.0
                // Sanity check: IBI should be 333ms–2000ms (30–180 BPM)
                let isPhysiological = ibiMs >= 333.0 && ibiMs <= 2000.0
                let ibi = InterBeatInterval(
                    timestamp: peakTime,
                    intervalMs: ibiMs,
                    isValid: isPhysiological
                )
                ibis.append(ibi)
            }
        }

        // Update last peak for next buffer
        if let lastIdx = peakIndices.last {
            state.lastPeakTimestamp = timestamps[lastIdx]
        }

        // Apply artifact rejection
        return applyArtifactRejection(ibis)
    }

    // MARK: - Moving Average

    private func computeMovingAverage(_ input: [Float], windowSize: Int) -> [Float] {
        guard input.count >= windowSize else { return input }

        var result = [Float](repeating: 0, count: input.count)
        let halfWindow = windowSize / 2

        // Use vDSP sliding window sum for efficiency
        var windowSum: [Float] = [Float](repeating: 0, count: input.count - windowSize + 1)
        var divisor = Float(windowSize)

        vDSP_vswsum(input, 1, &windowSum, 1, vDSP_Length(windowSum.count), vDSP_Length(windowSize))
        vDSP_vsdiv(windowSum, 1, &divisor, &windowSum, 1, vDSP_Length(windowSum.count))

        // Center the output
        for i in 0..<input.count {
            let j = i - halfWindow
            if j >= 0 && j < windowSum.count {
                result[i] = windowSum[j]
            } else if j < 0 {
                result[i] = windowSum[0]
            } else {
                result[i] = windowSum[windowSum.count - 1]
            }
        }

        return result
    }

    // MARK: - Artifact Rejection

    /// Apply artifact rejection per Sheridan et al., 2020:
    /// 1. Successive difference > 75% → reject
    /// 2. IQR outlier → reject
    /// 3. >36% rejected in window → discard entire window
    private func applyArtifactRejection(_ ibis: [InterBeatInterval]) -> [InterBeatInterval] {
        guard !ibis.isEmpty else { return [] }

        var results = ibis.map { ibi -> InterBeatInterval in
            guard ibi.isValid else { return ibi }

            // Rule 1: Successive difference filter
            if let prev = state.previousIBI {
                let diff = abs(ibi.intervalMs - prev)
                if diff > 0.75 * prev {
                    return InterBeatInterval(
                        timestamp: ibi.timestamp,
                        intervalMs: ibi.intervalMs,
                        isValid: false
                    )
                }
            }
            state.previousIBI = ibi.intervalMs
            return ibi
        }

        // Rule 2: IQR outlier filter on valid IBIs
        let validMs = results.filter(\.isValid).map(\.intervalMs).sorted()
        if validMs.count >= 4 {
            let q1 = validMs[validMs.count / 4]
            let q3 = validMs[3 * validMs.count / 4]
            let iqr = q3 - q1
            let lower = q1 - 1.5 * iqr
            let upper = q3 + 1.5 * iqr

            results = results.map { ibi in
                guard ibi.isValid else { return ibi }
                if ibi.intervalMs < lower || ibi.intervalMs > upper {
                    return InterBeatInterval(
                        timestamp: ibi.timestamp,
                        intervalMs: ibi.intervalMs,
                        isValid: false
                    )
                }
                return ibi
            }
        }

        // Rule 3: If >36% rejected, discard entire window
        let totalCount = results.count
        let rejectedCount = results.filter { !$0.isValid }.count
        if totalCount > 0 && Double(rejectedCount) / Double(totalCount) > 0.36 {
            logger.debug("Discarding window: \(rejectedCount)/\(totalCount) IBIs rejected (>\u{200B}36%)")
            return results.map {
                InterBeatInterval(timestamp: $0.timestamp, intervalMs: $0.intervalMs, isValid: false)
            }
        }

        return results
    }
}
