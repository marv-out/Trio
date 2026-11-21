import Foundation
import HealthKit
import WatchKit

/// Keeps the Trio watch app running in the background with a workout session, so heart rate and
/// steps reach the phone within a few minutes.
///
/// watchOS gives an app continuous background time only while a workout session runs; background
/// refreshes are limited to a few per hour. During the session the heart rate sensor measures
/// every few seconds. The workout is never saved: it is discarded when the session ends.
///
/// Costs: noticeably higher battery use, the workout indicator shows on the watch face, and starting
/// a workout in another app ends this session.
final class WatchLiveSession: NSObject {
    static let shared = WatchLiveSession()

    private let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private let heartRateType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    /// Only accessed on the main thread.
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// True while a workout session is running. Main thread only.
    private(set) var isRunning = false

    static var configuration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        return configuration
    }

    override private init() {
        super.init()
    }

    // MARK: - Authorization

    /// Workout sessions need share access to workouts; heart rate needs read access.
    func requestAuthorization(completion: @escaping () -> Void) {
        guard let healthStore else {
            completion()
            return
        }
        healthStore.requestAuthorization(
            toShare: [HKObjectType.workoutType()],
            read: [heartRateType, HKQuantityType(.stepCount)]
        ) { success, error in
            if let error {
                WatchLogger.shared.warning(.data, "Health authorization request failed", error: error)
            } else if !success {
                WatchLogger.shared.warning(.data, "Health authorization request not completed")
            }
            completion()
        }
    }

    // MARK: - Lifecycle

    /// Starts a session unless one runs. watchOS only allows this while the app is in the foreground,
    /// when the phone launched the app with a workout configuration, or during recovery.
    func start() {
        DispatchQueue.main.async { [self] in
            guard WatchActivityMonitor.shared.isEnabled, WatchActivityMonitor.shared.isPreciseMode,
                  session == nil, let healthStore else { return }
            do {
                let session = try HKWorkoutSession(healthStore: healthStore, configuration: Self.configuration)
                attach(session)
                let startDate = Date()
                session.startActivity(with: startDate)
                builder?.beginCollection(withStart: startDate) { success, error in
                    if let error {
                        WatchLogger.shared.warning(.data, "Live session data collection did not start", error: error)
                        WatchActivityMonitor.shared.setLiveSessionError(
                            "Workout data collection: \(error.localizedDescription). Allow Workouts for Trio in Health."
                        )
                    } else {
                        WatchActivityMonitor.shared.setLiveSessionError(nil)
                        WatchLogger.shared.info(.data, "Live session data collection started: \(success)")
                    }
                }
            } catch {
                WatchLogger.shared.warning(.data, "Live session could not be created", error: error)
            }
        }
    }

    /// Ends the session and discards the workout, so nothing is saved to Health as a workout.
    func stop() {
        DispatchQueue.main.async { [self] in
            guard let session else { return }
            session.end()
            // Builder clean-up happens in the state change to `.ended`
        }
    }

    /// Called after the watch app crashed or was relaunched while a session was running.
    func recover() {
        guard let healthStore else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] session, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    WatchLogger.shared.warning(.data, "Live session recovery failed", error: error)
                    return
                }
                guard let session else { return }
                guard WatchActivityMonitor.shared.isEnabled, WatchActivityMonitor.shared.isPreciseMode else {
                    session.end()
                    return
                }
                WatchLogger.shared.info(.data, "Live session recovered")
                self.attach(session)
            }
        }
    }

    /// Main thread only.
    private func attach(_ session: HKWorkoutSession) {
        guard let healthStore else { return }
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: Self.configuration)
        dataSource.enableCollection(for: heartRateType, predicate: nil)
        builder.dataSource = dataSource
        builder.delegate = self
        session.delegate = self

        self.session = session
        self.builder = builder
        isRunning = true
        WatchActivityMonitor.shared.liveSessionDidStart()
    }

    /// Main thread only.
    private func detach() {
        guard let session else { return }
        let builder = self.builder
        self.session = nil
        self.builder = nil
        isRunning = false

        builder?.endCollection(withEnd: Date()) { _, _ in
            // Never save the workout
            builder?.discardWorkout()
        }
        session.delegate = nil
        WatchActivityMonitor.shared.liveSessionDidEnd()
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchLiveSession: HKWorkoutSessionDelegate {
    func workoutSession(
        _: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from _: HKWorkoutSessionState,
        date _: Date
    ) {
        DispatchQueue.main.async { [self] in
            WatchLogger.shared.debug(.data, "Live session state: \(toState.rawValue)")
            switch toState {
            case .ended,
                 .stopped:
                // Also happens when the user starts a workout in another app
                detach()
            default:
                break
            }
        }
    }

    func workoutSession(_: HKWorkoutSession, didFailWithError error: Error) {
        WatchLogger.shared.warning(.data, "Live session failed", error: error)
        WatchActivityMonitor.shared.setLiveSessionError("Workout session failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [self] in
            detach()
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchLiveSession: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else { return }

        let date = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        WatchActivityMonitor.shared.recordLiveHeartRate(bpm: quantity.doubleValue(for: bpmUnit), at: date)
    }

    func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}
}

// MARK: - Launch from the phone and session recovery

/// Receives the workout configuration when Trio on the iPhone starts the watch app with
/// `HKHealthStore.startWatchApp(with:)`, and recovers a session after a crash.
extension TrioWatchAppDelegate {
    func handle(_: HKWorkoutConfiguration) {
        WatchLogger.shared.info(.lifecycle, "Launched by the phone for a live session")
        // The phone only does this with both settings on; the watch state carrying them may still be on its way
        WatchActivityMonitor.shared.setPreciseMode(true)
        if WatchActivityMonitor.shared.isEnabled {
            WatchLiveSession.shared.start()
        } else {
            WatchActivityMonitor.shared.setEnabled(true)
        }
    }

    func handleActiveWorkoutRecovery() {
        WatchLiveSession.shared.recover()
    }
}
