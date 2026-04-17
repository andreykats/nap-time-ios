import Foundation
import Observation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.andreykats.nap-time", category: "Alarm")

// TODO: Replace UserNotifications with AlarmKit once the iOS 26 SDK is available.
// AlarmKit provides system-level alarms that break through silent mode and Focus settings,
// appear on Lock Screen, Dynamic Island, StandBy, and Apple Watch.
// The current implementation uses local notifications as a fallback.

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

        config.napDurationMinutes = session.napDurationMinutes
        napStartTime = .now
        session.startTime = .now
        session.state = .calibrating(progress: 0)

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
            sleepOnsetTime = .now
            session.state = .sleepDetected(at: .now)
            scheduleAlarm()
            let mins = config.napDurationMinutes
            logger.info("Sleep onset detected, alarm scheduled for \(mins) minutes")
        }
    }

    // MARK: - Alarm Management

    private func scheduleAlarm() {
        let napDuration = TimeInterval(config.napDurationMinutes * 60)

        // Schedule a local notification as the alarm
        // TODO: Replace with AlarmKit when iOS 26 SDK is available
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    logger.warning("Notification permission not granted")
                    return
                }
            } catch {
                logger.error("Failed to request notification permission: \(error.localizedDescription)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Nap's Over!"
            content.body = "Time to wake up. You've been napping for \(config.napDurationMinutes) minutes."
            content.sound = .defaultCritical
            content.interruptionLevel = .critical

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: napDuration,
                repeats: false
            )

            let request = UNNotificationRequest(
                identifier: "nap-alarm",
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                logger.info("Alarm notification scheduled for \(napDuration)s from now")
            } catch {
                logger.error("Failed to schedule alarm: \(error.localizedDescription)")
            }
        }

        // Also run a timer to update UI state when alarm fires
        alarmTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(napDuration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.session.state = .alarming
            }
        }
    }

    private func cancelAlarm() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["nap-alarm"]
        )
        alarmTask?.cancel()
        alarmTask = nil
    }
}
