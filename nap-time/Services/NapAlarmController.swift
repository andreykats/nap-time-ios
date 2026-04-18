@preconcurrency import ActivityKit
import AlarmKit
import Foundation
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "Alarm")

/// Orchestrates the entire nap monitoring pipeline:
/// BLE streams → PPG processing → HRV computation → sleep detection → alarm.
@Observable
final class NapAlarmController {

    // MARK: - Dependencies

    let ringManager: ColmiRingManager
    var session: NapSession

    // MARK: - Private State

    private var hrvCalculator = HRVCalculator()
    private var sleepDetector = SleepOnsetDetector()
    private var config = SleepDetectionConfig()
    private var monitoringTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var napStartTime: Date?
    // An active Live Activity gets the app more generous background execution so BLE
    // packets keep flowing during brief screen locks instead of being queued by iOS.
    private var liveActivity: Activity<NapAlarmAttributes>?
    private var lastActivityUpdate: Date?
    private let alarmID = UUID()

    // MARK: - Init

    init(ringManager: ColmiRingManager) {
        self.ringManager = ringManager
        self.session = NapSession()
    }

    // MARK: - Public API

    func startNap() {
        guard ringManager.connectionState == .connected else {
            session.state = .error("Ring not connected")
            return
        }

        // Reset all processors
        hrvCalculator.reset()
        sleepDetector.reset()
        session.reset()

        // Pull live sensitivity from the same UserDefaults backing store that
        // SettingsView's @AppStorage("sensitivity") writes to. Default 1.0 if
        // the key was never written.
        let sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 1.0
        var newConfig = applyingSensitivity(sensitivity, to: SleepDetectionConfig())
        newConfig.napDurationMinutes = session.napDurationMinutes
        config = newConfig
        sleepDetector.updateConfig(newConfig)

        napStartTime = .now
        session.startTime = .now
        session.state = .calibrating(progress: 0)

        startLiveActivity()

        // Backstop alarm: if sleep is never detected, the alarm fires napDuration
        // after Start. Replaced by the post-sleep alarm in handleDetectionResultOnMain
        // on .sleepOnsetDetected (which reschedules napDuration after onset).
        scheduleAlarm(in: TimeInterval(config.napDurationMinutes * 60))

        // HRV was auto-started on connect; re-issue idempotently in case the stream stalled.
        // (We don't call startHeartRateMonitoring — 0x69 HR and 0x69 HRV share the same
        //  ring-side slot and starting HR would kill the IBI feed.)
        ringManager.startHRVMonitoring()

        // Capture streams on MainActor before launching background tasks
        let hrStream = ringManager.makeHeartRateStream()
        let ibiStream = ringManager.makeIBIStream()
        let calculator = hrvCalculator
        let detector = sleepDetector

        // Launch concurrent processing pipeline
        monitoringTask = Task { [weak self] in
            guard self != nil else { return }
            await withTaskGroup(of: Void.self) { group in
                // Task 1: Consume HR stream for display
                group.addTask { [weak self] in
                    for await reading in hrStream {
                        guard !Task.isCancelled else { break }
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.session.currentHR = reading.bpm
                            self.session.hrHistory.append(reading)
                            // Keep last 600 readings (~10 min at 1/s)
                            if self.session.hrHistory.count > 600 {
                                self.session.hrHistory.removeFirst()
                            }
                            self.refreshLiveActivityThrottled()
                        }
                    }
                }

                // Task 2: Consume native IBIs → HRV → sleep detection
                group.addTask { [weak self] in
                    for await ibi in ibiStream {
                        guard !Task.isCancelled else { break }
                        if let features = calculator.addIBIs([ibi]) {
                            let result = detector.addFeatures(features)
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.session.hrvHistory.append(features)
                                if self.session.hrvHistory.count > 60 {
                                    self.session.hrvHistory.removeFirst()
                                }
                                self.handleDetectionResultOnMain(result)
                            }
                        }
                    }
                }
            }
        }

        logger.info("Nap session started")
    }

    func stopNap() {
        monitoringTask?.cancel()
        monitoringTask = nil
        alarmTask?.cancel()
        alarmTask = nil

        // Tear down nap consumer tasks but leave the ring's HRV stream running so the UI
        // keeps showing a live BPM between naps. Full teardown happens on BLE disconnect.
        ringManager.finishStreams()
        cancelAlarm()
        endLiveActivity()

        let summary = NapSession.NapSummary(
            startTime: napStartTime ?? .now,
            sleepOnsetTime: sleepOnsetTime,
            endTime: .now,
            averageHR: session.hrHistory.isEmpty ? 0 :
                Double(session.hrHistory.map(\.bpm).reduce(0, +)) / Double(session.hrHistory.count),
            averageRMSSD: session.hrvHistory.isEmpty ? 0 :
                session.hrvHistory.map(\.rmssd).reduce(0, +) / Double(session.hrvHistory.count)
        )
        session.state = .completed(summary: summary)

        logger.info("Nap session stopped")
    }

    func updateConfig(_ newConfig: SleepDetectionConfig) {
        config = newConfig
    }

    /// Scale the two threshold criteria by the user's sensitivity multiplier.
    /// Higher s → smaller thresholds → easier to trip sleep detection (earlier
    /// onset, more false positives). 1.0 returns the published-research defaults.
    /// `requiredConsecutiveEpochs` is left untouched; dropping below 2 removes
    /// the cross-epoch confirmation that protects against single-window noise.
    private func applyingSensitivity(_ s: Double, to base: SleepDetectionConfig) -> SleepDetectionConfig {
        var c = base
        let clamped = max(0.5, min(2.0, s))
        c.rmssdIncreaseSD = base.rmssdIncreaseSD / clamped
        c.hrDropPercent   = base.hrDropPercent   / clamped
        return c
    }

    // MARK: - Detection Handling

    private var sleepOnsetTime: Date?

    private func handleDetectionResultOnMain(_ result: SleepOnsetDetector.Result) {
        switch result {
        case .calibrating(let progress):
            session.state = .calibrating(progress: progress)

        case .calibrationComplete:
            session.state = .monitoring
            logger.info("Calibration complete, now monitoring for sleep onset")

        case .awake:
            break

        case .sleepOnsetDetected:
            let now = Date.now
            sleepOnsetTime = now
            session.state = .sleepDetected(at: now)

            let duration = TimeInterval(config.napDurationMinutes * 60)
            cancelAlarm()  // kills the backstop alarm + task
            scheduleAlarm(in: duration)
            let napMins = config.napDurationMinutes
            logger.info("Sleep onset detected, alarm rescheduled \(napMins) min from onset")
            updateLiveActivity(
                sleepDetectedAt: now,
                wakeUpAt: now.addingTimeInterval(duration)
            )
        }
    }

    // MARK: - Alarm Management

    /// Schedule an AlarmKit alarm + in-process timer. Called once at session start
    /// (as a backstop) and again on sleep onset (replacing the backstop). AlarmKit
    /// breaks through silent mode, Focus, and DND the way the Clock app's alarm does —
    /// unlike local notifications, which the system silently suppresses in those modes.
    private func scheduleAlarm(in duration: TimeInterval) {
        alarmTask?.cancel()

        let onsetDate = sleepOnsetTime ?? napStartTime ?? .now
        let napMinutes = config.napDurationMinutes
        let fireDate = Date.now.addingTimeInterval(max(1, duration))
        let id = alarmID

        Task {
            let manager = AlarmManager.shared
            do {
                let state = try await manager.requestAuthorization()
                guard state == .authorized else {
                    logger.warning("AlarmKit authorization not granted: \(String(describing: state))")
                    return
                }
            } catch {
                logger.error("Failed to request AlarmKit authorization: \(error.localizedDescription)")
                return
            }

            // Re-scheduling replaces the previous fire time.
            try? manager.cancel(id: id)

            let stopButton = AlarmButton(
                text: "Stop",
                textColor: .white,
                systemImageName: "stop.circle.fill"
            )
            let alert = AlarmPresentation.Alert(
                title: "Nap's Over!",
                stopButton: stopButton
            )
            let metadata = NapAlarmMetadata(
                sleepDetectedAt: onsetDate,
                napDurationMinutes: napMinutes
            )
            let attributes = AlarmAttributes<NapAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert),
                metadata: metadata,
                tintColor: .blue
            )
            let configuration = AlarmManager.AlarmConfiguration<NapAlarmMetadata>.alarm(
                schedule: .fixed(fireDate),
                attributes: attributes
            )

            do {
                _ = try await manager.schedule(id: id, configuration: configuration)
                logger.info("AlarmKit alarm scheduled \(Int(duration))s from now")
            } catch {
                logger.error("Failed to schedule AlarmKit alarm: \(error.localizedDescription)")
            }
        }

        alarmTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.session.state = .alarming
                self.updateLiveActivity(isAlarming: true)
            }
        }
    }

    private func cancelAlarm() {
        try? AlarmManager.shared.cancel(id: alarmID)
        alarmTask?.cancel()
        alarmTask = nil
    }

    // MARK: - Live Activity

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.warning("Live Activities disabled by the user; background BLE may be throttled")
            return
        }
        let attributes = NapAlarmAttributes(napDurationMinutes: config.napDurationMinutes)
        let initialState = NapAlarmAttributes.ContentState(
            sleepDetectedAt: nil,
            wakeUpAt: nil,
            currentHeartRate: session.currentHR,
            isAlarming: false
        )
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil)
            )
            lastActivityUpdate = .now
            logger.info("Live Activity started")
        } catch {
            logger.error("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    /// Push a new HR into the Live Activity, but at most once every 5s. ActivityKit has
    /// a per-process update budget; unconditional HR updates at 2 Hz would exhaust it.
    private func refreshLiveActivityThrottled() {
        guard liveActivity != nil else { return }
        if let last = lastActivityUpdate, Date.now.timeIntervalSince(last) < 5.0 { return }
        lastActivityUpdate = .now
        updateLiveActivity()
    }

    /// Update the Live Activity. Omitted fields retain their current value.
    private func updateLiveActivity(
        sleepDetectedAt: Date? = nil,
        wakeUpAt: Date? = nil,
        isAlarming: Bool? = nil
    ) {
        guard let activity = liveActivity else { return }
        let current = activity.content.state
        let newState = NapAlarmAttributes.ContentState(
            sleepDetectedAt: sleepDetectedAt ?? current.sleepDetectedAt,
            wakeUpAt: wakeUpAt ?? current.wakeUpAt,
            currentHeartRate: session.currentHR,
            isAlarming: isAlarming ?? current.isAlarming
        )
        Task { @MainActor in
            await activity.update(.init(state: newState, staleDate: nil))
        }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        let finalState = activity.content.state
        liveActivity = nil
        lastActivityUpdate = nil
        Task { @MainActor in
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        }
        logger.info("Live Activity ended")
    }
}
