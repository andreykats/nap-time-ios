import Accelerate
import Foundation
import os

nonisolated(unsafe) private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "HRV")

/// Computes time-domain and frequency-domain HRV features from inter-beat intervals.
///
/// Maintains a 5-minute sliding window of validated IBIs, updated every 30 seconds.
/// Frequency domain uses Welch's method (FFT on overlapping windowed segments)
/// via Accelerate's vDSP functions.
nonisolated final class HRVCalculator: Sendable {

    private let state = CalculatorState()

    private final class CalculatorState: @unchecked Sendable {
        var ibiWindow: [InterBeatInterval] = []
        var windowDuration: TimeInterval = 300  // 5 minutes
        var lastComputeTime: Date?
        let computeInterval: TimeInterval = 30  // compute every 30 seconds
    }

    // MARK: - Public API

    /// Add new IBIs and return computed HRV features if enough time has elapsed.
    func addIBIs(_ newIBIs: [InterBeatInterval]) -> HRVFeatures? {
        state.ibiWindow.append(contentsOf: newIBIs)

        // Trim to sliding window
        let cutoff = Date.now.addingTimeInterval(-state.windowDuration)
        state.ibiWindow.removeAll { $0.timestamp < cutoff }

        // Only compute every 30 seconds
        if let last = state.lastComputeTime,
           Date.now.timeIntervalSince(last) < state.computeInterval {
            return nil
        }

        // Need minimum valid IBIs for reliable HRV
        let validIBIs = state.ibiWindow.filter(\.isValid)
        guard validIBIs.count >= 30 else { return nil }

        state.lastComputeTime = .now
        return computeFeatures(from: validIBIs)
    }

    func reset() {
        state.ibiWindow = []
        state.lastComputeTime = nil
    }

    // MARK: - Feature Computation

    private func computeFeatures(from ibis: [InterBeatInterval]) -> HRVFeatures {
        let intervals = ibis.map(\.intervalMs)

        // Time domain
        let (rmssd, sdnn, pnn50, meanHR) = computeTimeDomain(intervals)

        // Frequency domain
        let (lfPower, hfPower) = computeFrequencyDomain(ibis: ibis)
        let lfHfRatio = hfPower > 0 ? lfPower / hfPower : 0

        return HRVFeatures(
            timestamp: .now,
            rmssd: rmssd,
            sdnn: sdnn,
            pnn50: pnn50,
            meanHR: meanHR,
            lfPower: lfPower,
            hfPower: hfPower,
            lfHfRatio: lfHfRatio
        )
    }

    // MARK: - Time Domain

    private func computeTimeDomain(_ intervals: [Double]) -> (rmssd: Double, sdnn: Double, pnn50: Double, meanHR: Double) {
        guard intervals.count >= 2 else {
            return (0, 0, 0, 0)
        }

        // Mean NN
        let sum = intervals.reduce(0, +)
        let meanNN = sum / Double(intervals.count)

        // SDNN: standard deviation of all NN intervals
        let variance = intervals.map { pow($0 - meanNN, 2) }.reduce(0, +) / Double(intervals.count - 1)
        let sdnn = sqrt(variance)

        // Successive differences
        var sumSquaredDiffs = 0.0
        var countAbove50 = 0

        for i in 1..<intervals.count {
            let diff = intervals[i] - intervals[i - 1]
            sumSquaredDiffs += diff * diff
            if abs(diff) > 50.0 {
                countAbove50 += 1
            }
        }

        // RMSSD
        let rmssd = sqrt(sumSquaredDiffs / Double(intervals.count - 1))

        // pNN50
        let pnn50 = Double(countAbove50) / Double(intervals.count - 1) * 100.0

        // Mean HR
        let meanHR = meanNN > 0 ? 60000.0 / meanNN : 0

        return (rmssd, sdnn, pnn50, meanHR)
    }

    // MARK: - Frequency Domain (Welch's Method)

    private func computeFrequencyDomain(ibis: [InterBeatInterval]) -> (lf: Double, hf: Double) {
        // Step 1: Interpolate irregular IBI series to uniform 4 Hz sampling
        let uniformSignal = interpolateToUniform(ibis: ibis, targetRate: 4.0)
        guard uniformSignal.count >= 64 else { return (0, 0) }

        // Step 2: Welch's method PSD estimation
        let sampleRate: Float = 4.0
        let (frequencies, psd) = welchPSD(signal: uniformSignal, sampleRate: sampleRate)

        // Step 3: Integrate LF and HF bands
        return extractBandPowers(frequencies: frequencies, psd: psd)
    }

    /// Interpolate irregular IBI series to a uniform time grid using linear interpolation.
    private func interpolateToUniform(ibis: [InterBeatInterval], targetRate: Double) -> [Float] {
        guard ibis.count >= 2 else { return [] }

        // Build cumulative time axis (seconds)
        let baseTime = ibis[0].timestamp.timeIntervalSinceReferenceDate
        var cumulativeTime = [Double]()
        var ibiValues = [Double]()

        var t = 0.0
        for ibi in ibis {
            t = ibi.timestamp.timeIntervalSinceReferenceDate - baseTime
            cumulativeTime.append(t)
            ibiValues.append(ibi.intervalMs)
        }

        guard let tMax = cumulativeTime.last, tMax > 0 else { return [] }

        // Create uniform time grid
        let dt = 1.0 / targetRate
        let n = Int(tMax / dt)
        guard n >= 2 else { return [] }

        var output = [Float](repeating: 0, count: n)

        // Linear interpolation
        var j = 0
        for i in 0..<n {
            let tTarget = Double(i) * dt

            // Advance j to bracket tTarget
            while j < cumulativeTime.count - 2 && cumulativeTime[j + 1] < tTarget {
                j += 1
            }

            if j >= cumulativeTime.count - 1 {
                output[i] = Float(ibiValues.last ?? 0)
            } else {
                let t0 = cumulativeTime[j]
                let t1 = cumulativeTime[j + 1]
                let v0 = ibiValues[j]
                let v1 = ibiValues[j + 1]

                if t1 > t0 {
                    let frac = (tTarget - t0) / (t1 - t0)
                    output[i] = Float(v0 + frac * (v1 - v0))
                } else {
                    output[i] = Float(v0)
                }
            }
        }

        // Remove mean (detrend) to focus on variability
        var mean: Float = 0
        vDSP_meanv(output, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(output, 1, &negMean, &output, 1, vDSP_Length(n))

        return output
    }

    /// Welch's method: segment signal, window, FFT, average periodograms.
    private func welchPSD(signal: [Float], sampleRate: Float) -> (frequencies: [Float], psd: [Float]) {
        let segmentLength = min(256, signal.count)  // ~64s at 4 Hz
        let overlap = segmentLength / 2
        let nfft = segmentLength

        guard segmentLength >= 16 else { return ([], []) }

        // Hann window
        var window = [Float](repeating: 0, count: segmentLength)
        vDSP_hann_window(&window, vDSP_Length(segmentLength), Int32(vDSP_HANN_NORM))

        // Window power for normalization
        var windowPower: Float = 0
        vDSP_dotpr(window, 1, window, 1, &windowPower, vDSP_Length(segmentLength))

        // FFT setup
        let log2n = vDSP_Length(log2(Float(nfft)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([], [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Process segments
        var avgPSD = [Float](repeating: 0, count: nfft / 2)
        var segmentCount = 0
        var start = 0

        while start + segmentLength <= signal.count {
            var segment = Array(signal[start..<(start + segmentLength)])

            // Apply window
            vDSP_vmul(segment, 1, window, 1, &segment, 1, vDSP_Length(segmentLength))

            // Compute power spectrum for this segment
            let power = computePowerSpectrum(segment: segment, fftSetup: fftSetup, log2n: log2n, nfft: nfft)
            if power.count == nfft / 2 {
                vDSP_vadd(avgPSD, 1, power, 1, &avgPSD, 1, vDSP_Length(nfft / 2))
                segmentCount += 1
            }

            start += (segmentLength - overlap)
        }

        guard segmentCount > 0 else { return ([], []) }

        // Average and normalize
        var count = Float(segmentCount)
        vDSP_vsdiv(avgPSD, 1, &count, &avgPSD, 1, vDSP_Length(nfft / 2))

        var normFactor = sampleRate * windowPower
        vDSP_vsdiv(avgPSD, 1, &normFactor, &avgPSD, 1, vDSP_Length(nfft / 2))

        // Frequency axis
        var frequencies = [Float](repeating: 0, count: nfft / 2)
        for i in 0..<nfft / 2 {
            frequencies[i] = Float(i) * sampleRate / Float(nfft)
        }

        return (frequencies, avgPSD)
    }

    private func computePowerSpectrum(segment: [Float], fftSetup: FFTSetup, log2n: vDSP_Length, nfft: Int) -> [Float] {
        let halfN = nfft / 2

        // Pack real data into split complex format
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        // Convert interleaved real to split complex
        segment.withUnsafeBufferPointer { bufPtr in
            bufPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                realp.withUnsafeMutableBufferPointer { rBuf in
                    imagp.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Forward FFT and power spectrum computation
        var power = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zaspec(&splitComplex, &power, vDSP_Length(halfN))
            }
        }

        return power
    }

    /// Extract LF (0.04–0.15 Hz) and HF (0.15–0.40 Hz) band powers by integrating the PSD.
    private func extractBandPowers(frequencies: [Float], psd: [Float]) -> (lf: Double, hf: Double) {
        guard frequencies.count >= 2 else { return (0, 0) }

        let freqResolution = Double(frequencies[1] - frequencies[0])
        var lfPower: Double = 0
        var hfPower: Double = 0

        for i in 0..<frequencies.count {
            let f = Double(frequencies[i])
            let p = Double(psd[i])

            if f >= 0.04 && f < 0.15 {
                lfPower += p * freqResolution
            } else if f >= 0.15 && f <= 0.40 {
                hfPower += p * freqResolution
            }
        }

        return (lfPower, hfPower)
    }
}
