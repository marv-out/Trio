import CoreMotion
import Foundation
import HealthKit
import WatchConnectivity
import WatchKit

/// Reads heart rate and steps on the Apple Watch and sends them straight to Trio on the iPhone over
/// WatchConnectivity (`sendMessage` when the phone is reachable, otherwise `transferUserInfo`).
///
/// - Steps come from CoreMotion (`CMPedometer`) on the watch and do not use HealthKit at all.
/// - Heart rate has no API outside HealthKit on watchOS. It is read from the watch's own HealthKit
///   store, which is available while the watch is unlocked on the wrist, independent of whether the
///   iPhone is locked. The iPhone's HealthKit store is never touched.
///
/// When data is collected:
/// - **Sensor wake (default):** with G7 Direct-to-Watch, the sensor wakes the watch app over Bluetooth
///   about every 5 minutes. Each wake collects and sends, without a workout and with little extra battery.
/// - **Precise mode (opt-in):** `WatchLiveSession` runs a workout session and data is sent every
///   `liveSendInterval`. Costs battery and conflicts with the user's own workouts.
/// - Always: app activation, HealthKit background delivery for heart rate, and background refreshes,
///   which watchOS limits to a few per hour.
///
/// Without a workout, watchOS measures heart rate only now and then; a sensor wake sends the newest value
/// there is, which can be older than 5 minutes. The phone decides by its timestamp whether it is current.
final class WatchActivityMonitor {
    static let shared = WatchActivityMonitor()

    static let backgroundRefreshIdentifier = "org.nightscout.trio.watchActivityRefresh"

    /// Step bucket length; aligned to the clock so re-sent buckets replace older ones on the phone
    static let stepBucket: TimeInterval = 60
    /// How far back data is read on first use or after a long gap
    static let maxBackfill: TimeInterval = 60 * 60
    /// How often data is sent while the live session runs
    static let liveSendInterval: TimeInterval = 60
    /// Preferred interval between background refreshes
    static let refreshInterval: TimeInterval = 15 * 60

    /// Wakes closer together than this (a sensor reconnecting, several triggers at once) collect only once
    static let minimumWakeInterval: TimeInterval = 60

    /// What started a collection; reported to the phone for troubleshooting
    enum Trigger: String {
        case sensorWake
        case backgroundRefresh
        case appActive
        case heartRate
        case live
        case settings
    }

    private enum Keys {
        static let enabled = "watchActivity.enabled"
        static let preciseMode = "watchActivity.preciseMode"
        static let heartRateAnchor = "watchActivity.heartRateAnchor"
        static let stepsSentUntil = "watchActivity.stepsSentUntil"
    }

    private let defaults = UserDefaults.standard
    private let pedometer = CMPedometer()
    private let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private let heartRateType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    /// Serializes collection runs and access to the anchors below.
    private let queue = DispatchQueue(label: "WatchActivityMonitor.queue")
    private var isCollecting = false
    /// Identifies the running collection; a run that hangs is replaced after `collectionTimeout`. Only on `queue`.
    private var collectionRun = 0
    private var collectionStartedAt: Date?
    private static let collectionTimeout: TimeInterval = 120
    /// Last error from a step query, reported to the phone. Only on `queue`.
    private var lastStepError: String?
    /// Where the last steps came from: "motion" (CoreMotion) or "healthKit" (the watch's HealthKit store). Only on `queue`.
    private var stepSource = "none"
    /// Last error of the workout session, reported to the phone. Only on `queue`.
    private var liveSessionError: String?
    private let stepCountType = HKQuantityType(.stepCount)
    /// HealthKit gets the watch's steps in batches written minutes later, so recent minutes are re-read every run
    static let healthKitReReadWindow: TimeInterval = 15 * 60
    private var observerQuery: HKObserverQuery?
    /// Fires every `liveSendInterval` while the live session runs. Only on `queue`.
    private var liveTimer: DispatchSourceTimer?
    /// Latest heart rate per minute from the live session, not yet sent. Only on `queue`.
    private var liveHeartRates: [Int: (date: Date, bpm: Double)] = [:]
    /// Start of the last collection and what triggered it. Only on `queue`.
    private var lastCollectionAt: Date?
    private var lastTrigger: Trigger?

    private init() {}

    // MARK: - Enabled state (set by the phone)

    var isEnabled: Bool {
        defaults.bool(forKey: Keys.enabled)
    }

    /// Called with the setting from every watch state the phone sends.
    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        defaults.set(enabled, forKey: Keys.enabled)

        if enabled, !wasEnabled {
            WatchLogger.shared.info(.data, "Watch activity sharing turned on")
            WatchLiveSession.shared.requestAuthorization { [weak self] in
                guard let self else { return }
                self.startObservingHeartRate()
                self.collectAndSend(trigger: .settings)
                self.scheduleBackgroundRefresh()
                // Works only while the app is in the foreground; otherwise it starts on the next app open
                if self.isPreciseMode { WatchLiveSession.shared.start() }
            }
        } else if !enabled, wasEnabled {
            WatchLogger.shared.info(.data, "Watch activity sharing turned off")
            WatchLiveSession.shared.stop()
            stopObservingHeartRate()
            // Start fresh when turned on again
            queue.async { [defaults] in
                defaults.removeObject(forKey: Keys.heartRateAnchor)
                defaults.removeObject(forKey: Keys.stepsSentUntil)
            }
        }
    }

    /// Precise mode runs a workout session for minute-by-minute data. Off by default.
    var isPreciseMode: Bool {
        defaults.bool(forKey: Keys.preciseMode)
    }

    /// Called with the setting from every watch state the phone sends.
    func setPreciseMode(_ precise: Bool) {
        let wasPrecise = isPreciseMode
        defaults.set(precise, forKey: Keys.preciseMode)
        guard precise != wasPrecise else { return }
        WatchLogger.shared.info(.data, "Precise mode turned \(precise ? "on" : "off")")
        if precise {
            // Only possible in the foreground; the phone also starts it with startWatchApp
            if isEnabled { WatchLiveSession.shared.start() }
        } else {
            WatchLiveSession.shared.stop()
        }
    }

    /// Called by the app delegate for every Bluetooth wake from the CGM (G7 Direct-to-Watch), about every
    /// 5 minutes. The delegate holds the wake about 25 s, enough for one collection.
    func sensorDidWake() {
        collectAndSend(trigger: .sensorWake, minimumInterval: Self.minimumWakeInterval)
    }

    /// Call at app launch.
    func start() {
        guard isEnabled else { return }
        startObservingHeartRate()
        scheduleBackgroundRefresh()
    }

    /// Call when the app comes to the foreground: the only time watchOS lets the app start a workout session.
    func appDidBecomeActive() {
        guard isEnabled else { return }
        // Asks only for types not decided yet (e.g. step count after an update); prompts need the foreground
        WatchLiveSession.shared.requestAuthorization {
            if self.isPreciseMode { WatchLiveSession.shared.start() }
            self.collectAndSend(trigger: .appActive)
        }
    }

    func setLiveSessionError(_ message: String?) {
        queue.async { [self] in liveSessionError = message }
    }

    // MARK: - Live session

    func liveSessionDidStart() {
        queue.async { [self] in
            guard liveTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.liveSendInterval, repeating: Self.liveSendInterval, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                self?.collectAndSend(trigger: .live)
            }
            timer.resume()
            liveTimer = timer
            WatchLogger.shared.info(.data, "Live sending every \(Int(Self.liveSendInterval)) s started")
        }
    }

    func liveSessionDidEnd() {
        queue.async { [self] in
            liveTimer?.cancel()
            liveTimer = nil
            WatchLogger.shared.info(.data, "Live sending stopped")
        }
        // Send what the session collected last
        collectAndSend(trigger: .live)
    }

    /// Heart rate from the running workout session (every few seconds); kept as one value per minute.
    func recordLiveHeartRate(bpm: Double, at date: Date) {
        queue.async { [self] in
            liveHeartRates[Int(date.timeIntervalSince1970 / 60)] = (date, bpm)
        }
    }

    // MARK: - Heart rate background delivery

    private func startObservingHeartRate() {
        guard let healthStore, observerQuery == nil else { return }

        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                WatchLogger.shared.warning(.data, "Heart rate observer failed", error: error)
                completionHandler()
                return
            }
            self?.collectFromObserver(completion: completionHandler)
        }
        observerQuery = query
        healthStore.execute(query)

        healthStore.enableBackgroundDelivery(for: heartRateType, frequency: .immediate) { success, error in
            if let error {
                WatchLogger.shared.warning(.data, "Heart rate background delivery not enabled", error: error)
            } else {
                WatchLogger.shared.debug(.data, "Heart rate background delivery enabled: \(success)")
            }
        }
    }

    /// During a workout a new heart rate value arrives every few seconds. While the live timer runs it sends
    /// once a minute, so the observer must not trigger a transfer for every value. Without it, the observer
    /// is one more wake, limited to one collection per `minimumWakeInterval`.
    private func collectFromObserver(completion: @escaping () -> Void) {
        queue.async { [self] in
            if liveTimer != nil {
                completion()
                return
            }
            collectAndSend(trigger: .heartRate, minimumInterval: Self.minimumWakeInterval, completion: completion)
        }
    }

    private func stopObservingHeartRate() {
        guard let healthStore else { return }
        if let observerQuery {
            healthStore.stop(observerQuery)
            self.observerQuery = nil
        }
        healthStore.disableBackgroundDelivery(for: heartRateType) { _, _ in }
    }

    // MARK: - Background refresh

    func scheduleBackgroundRefresh() {
        Task { @MainActor in
            self.scheduleBackgroundRefreshOnMain()
        }
    }

    @MainActor private func scheduleBackgroundRefreshOnMain() {
        guard isEnabled else { return }
        // While the watch reads the CGM, its Bluetooth wakes come every 5 min and the CGM host schedules its own
        // refreshes as an acquisition backstop. A refresh scheduled here could replace that one, so none is.
        guard WatchCGMHost.shared.cgmManager == nil else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(Self.refreshInterval),
            userInfo: Self.backgroundRefreshIdentifier as NSString
        ) { error in
            if let error {
                WatchLogger.shared.warning(.data, "Scheduling watch activity refresh failed", error: error)
            }
        }
    }

    /// Runs one collection for a background refresh, schedules the next one, then calls `completion`
    /// so the app delegate can complete the task.
    func handleBackgroundRefresh(completion: @escaping () -> Void) {
        guard isEnabled else {
            completion()
            return
        }
        collectAndSend(trigger: .backgroundRefresh, minimumInterval: Self.minimumWakeInterval) {
            // Schedule before the task completes; the app may be suspended right after
            Task { @MainActor in
                self.scheduleBackgroundRefreshOnMain()
                completion()
            }
        }
    }

    // MARK: - Collection

    /// Reads new heart rate samples and completed step buckets and queues them for the phone.
    /// - Parameter minimumInterval: skips the run when the last one started less than this ago
    func collectAndSend(
        trigger: Trigger,
        minimumInterval: TimeInterval = 0,
        completion: (() -> Void)? = nil
    ) {
        queue.async { [self] in
            guard isEnabled else {
                completion?()
                return
            }
            if minimumInterval > 0, let last = lastCollectionAt, Date().timeIntervalSince(last) < minimumInterval {
                completion?()
                return
            }
            if isCollecting {
                // A CMPedometer or HealthKit callback that never arrives must not block all later runs
                guard let started = collectionStartedAt, Date().timeIntervalSince(started) > Self.collectionTimeout else {
                    completion?()
                    return
                }
                WatchLogger.shared.warning(.data, "Previous collection did not finish within \(Int(Self.collectionTimeout)) s, starting a new one")
            }
            isCollecting = true
            collectionRun += 1
            let run = collectionRun
            collectionStartedAt = Date()
            lastCollectionAt = collectionStartedAt
            lastTrigger = trigger

            let group = DispatchGroup()
            var heartRates: [[String: Any]] = []
            var newAnchor: HKQueryAnchor?
            var steps: [[String: Any]] = []
            var stepsUntil: Date?

            group.enter()
            readHeartRates { samples, anchor in
                heartRates = samples
                newAnchor = anchor
                group.leave()
            }

            group.enter()
            readSteps { buckets, until in
                steps = buckets
                stepsUntil = until
                group.leave()
            }

            var restingHeartRate: [String: Any]?
            group.enter()
            readRestingHeartRate { sample in
                restingHeartRate = sample
                group.leave()
            }

            group.notify(queue: queue) { [self] in
                // A run that was replaced after a timeout sends nothing
                guard run == collectionRun else {
                    completion?()
                    return
                }
                defer {
                    isCollecting = false
                    collectionStartedAt = nil
                    completion?()
                }

                let live = liveHeartRates
                heartRates = Self.latestPerMinute(
                    heartRates + live.values.map {
                        [WatchMessageKeys.date: $0.date.timeIntervalSince1970, WatchMessageKeys.value: $0.bpm]
                    }
                )

                // Sent even without new samples, so the phone always has the current status
                guard send(heartRates: heartRates, steps: steps, restingHeartRate: restingHeartRate) else { return }
                // Drop the live values that went out; newer ones that arrived meanwhile stay
                for (minute, sent) in live where liveHeartRates[minute]?.date == sent.date {
                    liveHeartRates[minute] = nil
                }
                // Advance only after the transfer is queued; WatchConnectivity delivers it later.
                commit(anchor: newAnchor, stepsUntil: stepsUntil)
            }
        }
    }

    /// During a workout the sensor stores a value every few seconds; one per minute is enough for Trio.
    private static func latestPerMinute(_ samples: [[String: Any]]) -> [[String: Any]] {
        var byMinute: [Int: [String: Any]] = [:]
        for sample in samples {
            guard let timestamp = sample[WatchMessageKeys.date] as? TimeInterval else { continue }
            let minute = Int(timestamp / 60)
            if let existing = byMinute[minute]?[WatchMessageKeys.date] as? TimeInterval, existing >= timestamp {
                continue
            }
            byMinute[minute] = sample
        }
        return byMinute.values.sorted {
            ($0[WatchMessageKeys.date] as? TimeInterval ?? 0) < ($1[WatchMessageKeys.date] as? TimeInterval ?? 0)
        }
    }

    /// Only on `queue`.
    private func commit(anchor: HKQueryAnchor?, stepsUntil: Date?) {
        if let anchor,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        {
            defaults.set(data, forKey: Keys.heartRateAnchor)
        }
        if let stepsUntil {
            defaults.set(stepsUntil.timeIntervalSince1970, forKey: Keys.stepsSentUntil)
        }
    }

    /// Only on `queue`.
    private func send(heartRates: [[String: Any]], steps: [[String: Any]], restingHeartRate: [String: Any]?) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLogger.shared.debug(.connectivity, "Session not active, watch activity kept for the next run")
            return false
        }

        var status: [String: Any] = [
            WatchMessageKeys.liveSession: liveTimer != nil,
            WatchMessageKeys.motionAuthorization: Self.motionAuthorizationDescription()
        ]
        status[WatchMessageKeys.stepSource] = stepSource
        status[WatchMessageKeys.preciseMode] = isPreciseMode
        if let lastTrigger {
            status[WatchMessageKeys.trigger] = lastTrigger.rawValue
        }
        if let lastStepError {
            status[WatchMessageKeys.stepError] = lastStepError
        }
        if let liveSessionError {
            status[WatchMessageKeys.liveSessionError] = liveSessionError
        }
        var activity: [String: Any] = [
            WatchMessageKeys.date: Date().timeIntervalSince1970,
            WatchMessageKeys.heartRateSamples: heartRates,
            WatchMessageKeys.stepSamples: steps,
            WatchMessageKeys.watchStatus: status
        ]
        if let restingHeartRate {
            activity[WatchMessageKeys.restingHeartRate] = restingHeartRate
        }
        let payload: [String: Any] = [WatchMessageKeys.watchActivity: activity]
        let summary = "\(heartRates.count) heart rate and \(steps.count) step samples"
        if session.isReachable {
            // Immediate; wakes Trio on the iPhone in the background, also when the iPhone is locked
            session.sendMessage(payload, replyHandler: nil) { error in
                WatchLogger.shared.debug(.connectivity, "Live send failed, queued instead: \(error.localizedDescription)")
                session.transferUserInfo(payload)
            }
            WatchLogger.shared.debug(.data, "Sent \(summary) to the phone")
        } else {
            // Queued by the system and delivered when the phone is in reach again
            session.transferUserInfo(payload)
            WatchLogger.shared.debug(.data, "Queued \(summary) for the phone")
        }
        return true
    }

    private static func motionAuthorizationDescription() -> String {
        guard CMPedometer.isStepCountingAvailable() else { return "unavailable" }
        switch CMPedometer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // MARK: Heart rate

    /// Apple's resting heart rate, computed by the watch about once a day; the newest of the last 7 days.
    private func readRestingHeartRate(completion: @escaping ([String: Any]?) -> Void) {
        guard let healthStore else {
            completion(nil)
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-7 * 86400), end: nil)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.restingHeartRate),
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sort]
        ) { [bpmUnit] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            completion([
                WatchMessageKeys.date: sample.endDate.timeIntervalSince1970,
                WatchMessageKeys.value: sample.quantity.doubleValue(for: bpmUnit)
            ])
        }
        healthStore.execute(query)
    }

    private func storedAnchor() -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: Keys.heartRateAnchor) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func readHeartRates(completion: @escaping ([[String: Any]], HKQueryAnchor?) -> Void) {
        guard let healthStore else {
            completion([], nil)
            return
        }

        let since = Date().addingTimeInterval(-Self.maxBackfill)
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictEndDate)

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: storedAnchor(),
            limit: HKObjectQueryNoLimit
        ) { [bpmUnit] _, samples, _, newAnchor, error in
            if let error {
                // Typically: watch locked (data protected) or no authorization
                WatchLogger.shared.debug(.data, "Heart rate query failed: \(error.localizedDescription)")
                completion([], nil)
                return
            }
            let result: [[String: Any]] = (samples as? [HKQuantitySample] ?? []).map { sample in
                [
                    WatchMessageKeys.date: sample.endDate.timeIntervalSince1970,
                    WatchMessageKeys.value: sample.quantity.doubleValue(for: bpmUnit)
                ]
            }
            completion(result, newAnchor)
        }
        healthStore.execute(query)
    }

    // MARK: Steps

    private func readSteps(completion: @escaping ([[String: Any]], Date?) -> Void) {
        let motionUsable: Bool
        if !CMPedometer.isStepCountingAvailable() {
            motionUsable = false
        } else {
            switch CMPedometer.authorizationStatus() {
            case .denied,
                 .restricted: motionUsable = false
            default: motionUsable = true
            }
        }
        guard motionUsable else {
            // CoreMotion blocked: the watch's own HealthKit store has the same steps, written in batches
            readStepsFromHealthKit(completion: completion)
            return
        }
        stepSource = "motion"

        let bucket = Self.stepBucket
        let now = Date()
        // Only complete buckets; the current one is sent on a later run
        let lastBucketEnd = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / bucket) * bucket)
        let earliest = Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - Self.maxBackfill) / bucket) * bucket)

        var start = earliest
        let sentUntil = defaults.double(forKey: Keys.stepsSentUntil)
        if sentUntil > 0 {
            // Re-read the last sent bucket: the pedometer can attribute steps late
            start = max(earliest, Date(timeIntervalSince1970: sentUntil - bucket))
        }

        var intervals: [(Date, Date)] = []

        // Older than `maxBackfill` but today and not yet sent: one coarse bucket, so the day total is right
        // without hundreds of 1 min queries. It starts before every 15/30/60 min window and never counts there.
        let startOfDay = Calendar.current.startOfDay(for: now)
        let coarseStart = max(startOfDay, sentUntil > 0 ? Date(timeIntervalSince1970: sentUntil) : startOfDay)
        if coarseStart < earliest {
            intervals.append((coarseStart, earliest))
        }

        var cursor = start
        while cursor.addingTimeInterval(bucket) <= lastBucketEnd {
            intervals.append((cursor, cursor.addingTimeInterval(bucket)))
            cursor = cursor.addingTimeInterval(bucket)
        }

        guard !intervals.isEmpty else {
            completion([], nil)
            return
        }

        queryBuckets(intervals, index: 0, collected: []) { buckets in
            // Advance only as far as buckets were actually read, so a failed query is retried
            let readUntil = (buckets.last?[WatchMessageKeys.end] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            completion(buckets, readUntil)
        }
    }

    /// Steps recorded by an Apple Watch, from the watch's HealthKit store, in 1 min buckets. Only on `queue`.
    ///
    /// The watch writes steps to HealthKit in batches, often several minutes late. Minutes without samples
    /// read as 0 and are corrected on later runs, because the last `healthKitReReadWindow` is read again
    /// every time and the phone replaces buckets with the same start.
    private func readStepsFromHealthKit(completion: @escaping ([[String: Any]], Date?) -> Void) {
        stepSource = "healthKit"
        guard let healthStore else {
            lastStepError = "Health data not available on this watch"
            completion([], nil)
            return
        }

        let bucket = Self.stepBucket
        let now = Date()
        let lastBucketEnd = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / bucket) * bucket)
        let earliest = Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - Self.maxBackfill) / bucket) * bucket)
        let sentUntil = defaults.double(forKey: Keys.stepsSentUntil)

        var start = earliest
        if sentUntil > 0 {
            let reRead = floor((sentUntil - Self.healthKitReReadWindow) / bucket) * bucket
            start = max(earliest, Date(timeIntervalSince1970: reRead))
        }
        let startOfDay = Calendar.current.startOfDay(for: now)
        let coarseStart = max(startOfDay, sentUntil > 0 ? Date(timeIntervalSince1970: sentUntil) : startOfDay)

        guard start < lastBucketEnd else {
            completion([], nil)
            return
        }

        // Only steps an Apple Watch recorded, not the iPhone's
        let watchOnly = HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: ["Watch"])
        let unit = HKUnit.count()
        let group = DispatchGroup()
        var coarse: [String: Any]?
        var fine: [[String: Any]] = []
        var failure: String?

        if coarseStart < earliest {
            group.enter()
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: coarseStart, end: earliest, options: []),
                watchOnly
            ])
            let query = HKStatisticsQuery(
                quantityType: stepCountType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error, (error as? HKError)?.code != .errorNoData {
                    failure = "HealthKit steps: \(error.localizedDescription)"
                } else {
                    coarse = [
                        WatchMessageKeys.start: coarseStart.timeIntervalSince1970,
                        WatchMessageKeys.end: earliest.timeIntervalSince1970,
                        WatchMessageKeys.value: Int(statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0)
                    ]
                }
                group.leave()
            }
            healthStore.execute(query)
        }

        group.enter()
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: lastBucketEnd, options: []),
            watchOnly
        ])
        let query = HKStatisticsCollectionQuery(
            quantityType: stepCountType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: start,
            intervalComponents: DateComponents(minute: 1)
        )
        query.initialResultsHandler = { _, collection, error in
            if let error {
                failure = "HealthKit steps: \(error.localizedDescription)"
            } else if let collection {
                // Includes minutes without samples as 0
                collection.enumerateStatistics(from: start, to: lastBucketEnd) { statistics, _ in
                    guard statistics.endDate <= lastBucketEnd else { return }
                    fine.append([
                        WatchMessageKeys.start: statistics.startDate.timeIntervalSince1970,
                        WatchMessageKeys.end: statistics.endDate.timeIntervalSince1970,
                        WatchMessageKeys.value: Int(statistics.sumQuantity()?.doubleValue(for: unit) ?? 0)
                    ])
                }
            }
            group.leave()
        }
        healthStore.execute(query)

        group.notify(queue: queue) { [self] in
            if let failure {
                WatchLogger.shared.warning(.data, failure)
                lastStepError = failure
                completion([], nil)
                return
            }
            lastStepError = nil
            let buckets = (coarse.map { [$0] } ?? []) + fine
            completion(buckets, buckets.isEmpty ? nil : lastBucketEnd)
        }
    }

    /// Queries buckets one after the other; CMPedometer handlers arrive on an arbitrary queue.
    private func queryBuckets(
        _ intervals: [(Date, Date)],
        index: Int,
        collected: [[String: Any]],
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        guard index < intervals.count else {
            completion(collected)
            return
        }
        let (from, to) = intervals[index]
        pedometer.queryPedometerData(from: from, to: to) { [weak self] data, error in
            guard let self else {
                completion(collected)
                return
            }
            var collected = collected
            if let error {
                let nsError = error as NSError
                let message = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
                WatchLogger.shared.warning(.data, "Step query failed: \(message)")
                self.queue.async { self.lastStepError = message }
                // Authorization or availability errors hit every bucket; stop early
                completion(collected)
                return
            }
            if index == intervals.count - 1 {
                self.queue.async { self.lastStepError = nil }
            }
            if let steps = data?.numberOfSteps.intValue {
                collected.append([
                    WatchMessageKeys.start: from.timeIntervalSince1970,
                    WatchMessageKeys.end: to.timeIntervalSince1970,
                    WatchMessageKeys.value: steps
                ])
            }
            self.queryBuckets(intervals, index: index + 1, collected: collected, completion: completion)
        }
    }
}
