import Combine
import Foundation
import Swinject

/// One heart rate reading measured by the Apple Watch.
struct WatchHeartRateSample: JSON, Equatable, Hashable {
    /// Time the reading was taken (end of the HealthKit sample on the watch)
    let date: Date
    /// Beats per minute
    let bpm: Double
}

/// Steps counted by the Apple Watch in one interval (1 min buckets, aligned to the clock).
struct WatchStepSample: JSON, Equatable, Hashable {
    let start: Date
    let end: Date
    let steps: Int
}

/// Steps in the last 15, 30 and 60 minutes, only built from complete, current data.
struct WatchRecentSteps: Equatable {
    let last15Minutes: Int
    let last30Minutes: Int
    let last60Minutes: Int
    /// End of the newest step bucket; the windows end here, not exactly at "now"
    let until: Date
}

/// What the watch reports about its own collection, for troubleshooting.
struct WatchActivityStatus: Equatable {
    let receivedAt: Date
    let liveSessionRunning: Bool
    /// CMPedometer authorization on the watch: authorized, denied, restricted, notDetermined, unavailable
    let motionAuthorization: String
    /// Last step query error on the watch, nil after a successful query
    let stepError: String?
    /// "motion" (CoreMotion, live) or "healthKit" (the watch's HealthKit store, written in batches)
    var stepSource: String? = nil
    /// Why the workout session does not collect data, if it doesn't
    var liveSessionError: String? = nil
    /// Precise mode (workout session) is on, as the watch has it
    var preciseMode: Bool = false
    /// What started the last collection: sensorWake, backgroundRefresh, appActive, heartRate, live, settings
    var trigger: String? = nil
}

/// Stores heart rate and step data that the Trio watch app sends directly over WatchConnectivity.
///
/// The data never passes through the iPhone's HealthKit store, so it stays readable while the
/// iPhone is locked. It is kept for `retention` only. When Boost is on, `BoostActivityMonitor` reads steps and
/// heart rate from here instead of the iPhone's HealthKit store, so this data then steers dosing.
protocol WatchActivityStorage {
    func store(heartRates: [WatchHeartRateSample], steps: [WatchStepSample])
    func heartRates(since date: Date) -> [WatchHeartRateSample]
    func steps(since date: Date) -> [WatchStepSample]
    func latestHeartRate() -> WatchHeartRateSample?
    /// The latest heart rate, or nil when it is older than `maxAge`.
    func currentHeartRate(maxAge: TimeInterval) -> WatchHeartRateSample?
    /// End of the newest step bucket received.
    func lastStepUpdate() -> Date?
    /// True when steps were received within `maxAge`.
    func hasCurrentSteps(maxAge: TimeInterval) -> Bool
    func stepCount(since date: Date) -> Int
    /// Steps in the last `minutes`, or nil when the newest data is older than `maxAge` or a minute in the
    /// window is missing. Use this, not `stepCount(since:)`, wherever missing data must not read as 0 steps.
    func stepCount(lastMinutes minutes: Int, now: Date, maxAge: TimeInterval) -> Int?
    /// 15/30/60 minute step counts, or nil under the same conditions as `stepCount(lastMinutes:now:maxAge:)`.
    func recentSteps(now: Date, maxAge: TimeInterval) -> WatchRecentSteps?
    /// Steps in the `minutes` before the newest bucket received, not before "now". nil when the newest bucket
    /// is older than `maxAge` or a minute in the window is missing. For consumers (Boost) that must not read
    /// minutes still in transfer as 0 steps.
    func stepCount(minutesEndingAtNewest minutes: Int, now: Date, maxAge: TimeInterval) -> Int?
    /// Steps since local midnight, or nil when the newest bucket is older than `maxAge`.
    func stepsToday(now: Date, maxAge: TimeInterval) -> Int?
    /// Apple's resting heart rate as computed on the watch (about once a day)
    func storeRestingHeartRate(_ sample: WatchHeartRateSample)
    func latestRestingHeartRate() -> WatchHeartRateSample?
    func removeAll()
    /// Latest status sent by the watch; kept in memory only
    func updateStatus(_ status: WatchActivityStatus)
    func latestStatus() -> WatchActivityStatus?
    /// Emits after every change of the stored data.
    var updatePublisher: AnyPublisher<Void, Never> { get }
}

final class BaseWatchActivityStorage: WatchActivityStorage, Injectable {
    static let retention: TimeInterval = 24 * 60 * 60
    /// Data older than this is not "live" and must not be presented as current.
    static let maxAge: TimeInterval = 5 * 60

    private enum Files {
        static let heartRate = "monitor/watch-heartrate.json"
        static let steps = "monitor/watch-steps.json"
        static let restingHeartRate = "monitor/watch-resting-heartrate.json"
    }

    @Injected() private var fileStorage: FileStorage!

    private let processQueue = DispatchQueue.markedQueue(label: "BaseWatchActivityStorage.processQueue")
    private let updateSubject = PassthroughSubject<Void, Never>()

    /// Only accessed on `processQueue`.
    private var cachedHeartRates: [WatchHeartRateSample]?
    private var cachedSteps: [WatchStepSample]?
    private var status: WatchActivityStatus?

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func store(heartRates: [WatchHeartRateSample], steps: [WatchStepSample]) {
        guard heartRates.isNotEmpty || steps.isNotEmpty else { return }

        processQueue.sync {
            let cutoff = Date().addingTimeInterval(-Self.retention)

            if heartRates.isNotEmpty {
                // Newer value wins for the same timestamp
                var byDate = Dictionary(loadHeartRates().map { ($0.date, $0) }, uniquingKeysWith: { _, new in new })
                heartRates.forEach { byDate[$0.date] = $0 }
                let merged = byDate.values
                    .filter { $0.date >= cutoff && $0.bpm > 0 }
                    .sorted { $0.date < $1.date }
                cachedHeartRates = merged
                fileStorage.save(merged, as: Files.heartRate)
            }

            if steps.isNotEmpty {
                // A re-sent bucket replaces the old one (the watch may count late steps)
                var byStart = Dictionary(loadSteps().map { ($0.start, $0) }, uniquingKeysWith: { _, new in new })
                steps.forEach { byStart[$0.start] = $0 }
                let merged = byStart.values
                    .filter { $0.end >= cutoff && $0.steps >= 0 }
                    .sorted { $0.start < $1.start }
                cachedSteps = merged
                fileStorage.save(merged, as: Files.steps)
            }
        }

        debug(
            .watch,
            "Stored \(heartRates.count) heart rate and \(steps.count) step samples from the watch"
        )
        updateSubject.send(())
    }

    func heartRates(since date: Date) -> [WatchHeartRateSample] {
        processQueue.sync { loadHeartRates().filter { $0.date >= date } }
    }

    func steps(since date: Date) -> [WatchStepSample] {
        processQueue.sync { loadSteps().filter { $0.end > date } }
    }

    func latestHeartRate() -> WatchHeartRateSample? {
        processQueue.sync { loadHeartRates().last }
    }

    func currentHeartRate(maxAge: TimeInterval = BaseWatchActivityStorage.maxAge) -> WatchHeartRateSample? {
        guard let latest = latestHeartRate(), Date().timeIntervalSince(latest.date) <= maxAge else { return nil }
        return latest
    }

    func lastStepUpdate() -> Date? {
        processQueue.sync { loadSteps().last?.end }
    }

    func hasCurrentSteps(maxAge: TimeInterval = BaseWatchActivityStorage.maxAge) -> Bool {
        guard let lastStepUpdate = lastStepUpdate() else { return false }
        return Date().timeIntervalSince(lastStepUpdate) <= maxAge
    }

    func stepCount(lastMinutes minutes: Int, now: Date, maxAge: TimeInterval) -> Int? {
        let buckets = processQueue.sync { loadSteps() }
        return Self.stepCount(in: buckets, lastMinutes: minutes, now: now, maxAge: maxAge)
    }

    func recentSteps(now: Date, maxAge: TimeInterval) -> WatchRecentSteps? {
        let buckets = processQueue.sync { loadSteps() }
        guard let until = buckets.last?.end,
              let last15 = Self.stepCount(in: buckets, lastMinutes: 15, now: now, maxAge: maxAge),
              let last30 = Self.stepCount(in: buckets, lastMinutes: 30, now: now, maxAge: maxAge),
              let last60 = Self.stepCount(in: buckets, lastMinutes: 60, now: now, maxAge: maxAge)
        else { return nil }
        return WatchRecentSteps(last15Minutes: last15, last30Minutes: last30, last60Minutes: last60, until: until)
    }

    /// Counts the 1 min buckets that start inside the window [now - minutes, now].
    ///
    /// The newest bucket is usually 1–2 min old (only completed minutes are sent), so the counted span is
    /// that much shorter than `minutes`. A bucket that started before the window is left out, never counted
    /// in part. Returns nil when the newest bucket is older than `maxAge` or when any minute between the
    /// window start and the newest bucket is missing.
    static func stepCount(in buckets: [WatchStepSample], lastMinutes minutes: Int, now: Date, maxAge: TimeInterval) -> Int? {
        guard minutes > 0, let newestEnd = buckets.last?.end, now.timeIntervalSince(newestEnd) <= maxAge else {
            return nil
        }
        let windowStart = now.addingTimeInterval(-Double(minutes) * 60)
        let inWindow = buckets.filter { $0.start >= windowStart && $0.end <= now }

        // Every minute from the first full minute of the window to the newest bucket must be present
        let bucket: TimeInterval = 60
        let firstStart = ceil(windowStart.timeIntervalSince1970 / bucket) * bucket
        let lastStart = newestEnd.timeIntervalSince1970 - bucket
        let present = Set(inWindow.map { $0.start.timeIntervalSince1970 })
        var expected = firstStart
        while expected <= lastStart {
            guard present.contains(expected) else { return nil }
            expected += bucket
        }

        return inWindow.reduce(0) { $0 + $1.steps }
    }

    /// Sum of all buckets that end after `date`; a bucket that starts before `date` counts in full.
    func stepCount(since date: Date) -> Int {
        steps(since: date).reduce(0) { $0 + $1.steps }
    }

    func updateStatus(_ status: WatchActivityStatus) {
        processQueue.sync { self.status = status }
        updateSubject.send(())
    }

    func latestStatus() -> WatchActivityStatus? {
        processQueue.sync { status }
    }

    func stepCount(minutesEndingAtNewest minutes: Int, now: Date, maxAge: TimeInterval) -> Int? {
        let buckets = processQueue.sync { loadSteps() }
        guard let newestEnd = buckets.last?.end, now.timeIntervalSince(newestEnd) <= maxAge else { return nil }
        // The window ends at the newest bucket, so the freshness check above is the only age limit
        return Self.stepCount(in: buckets, lastMinutes: minutes, now: newestEnd, maxAge: .greatestFiniteMagnitude)
    }

    func stepsToday(now: Date, maxAge: TimeInterval) -> Int? {
        guard let newest = lastStepUpdate(), now.timeIntervalSince(newest) <= maxAge else { return nil }
        return stepCount(since: Calendar.current.startOfDay(for: now))
    }

    func storeRestingHeartRate(_ sample: WatchHeartRateSample) {
        processQueue.sync {
            fileStorage.save(sample, as: Files.restingHeartRate)
        }
    }

    func latestRestingHeartRate() -> WatchHeartRateSample? {
        processQueue.sync { fileStorage.retrieve(Files.restingHeartRate, as: WatchHeartRateSample.self) }
    }

    func removeAll() {
        processQueue.sync {
            status = nil
            cachedHeartRates = []
            cachedSteps = []
            fileStorage.remove(Files.heartRate)
            fileStorage.remove(Files.steps)
            fileStorage.remove(Files.restingHeartRate)
        }
        updateSubject.send(())
    }

    // MARK: - Only on processQueue

    private func loadHeartRates() -> [WatchHeartRateSample] {
        if let cachedHeartRates { return cachedHeartRates }
        let loaded = fileStorage.retrieve(Files.heartRate, as: [WatchHeartRateSample].self) ?? []
        cachedHeartRates = loaded
        return loaded
    }

    private func loadSteps() -> [WatchStepSample] {
        if let cachedSteps { return cachedSteps }
        let loaded = fileStorage.retrieve(Files.steps, as: [WatchStepSample].self) ?? []
        cachedSteps = loaded
        return loaded
    }
}

// MARK: - WatchConnectivity payload

enum WatchActivityPayload {
    /// Parses the dictionary the watch sends under `WatchMessageKeys.watchActivity`.
    static func status(from payload: [String: Any], receivedAt: Date = Date()) -> WatchActivityStatus? {
        guard let status = payload[WatchMessageKeys.watchStatus] as? [String: Any] else { return nil }
        return WatchActivityStatus(
            receivedAt: receivedAt,
            liveSessionRunning: status[WatchMessageKeys.liveSession] as? Bool ?? false,
            motionAuthorization: status[WatchMessageKeys.motionAuthorization] as? String ?? "unknown",
            stepError: status[WatchMessageKeys.stepError] as? String,
            stepSource: status[WatchMessageKeys.stepSource] as? String,
            liveSessionError: status[WatchMessageKeys.liveSessionError] as? String,
            preciseMode: status[WatchMessageKeys.preciseMode] as? Bool ?? false,
            trigger: status[WatchMessageKeys.trigger] as? String
        )
    }

    /// Resting heart rate (30–150 bpm, not in the future)
    static func restingHeartRate(from payload: [String: Any], now: Date = Date()) -> WatchHeartRateSample? {
        guard let sample = payload[WatchMessageKeys.restingHeartRate] as? [String: Any],
              let timestamp = sample[WatchMessageKeys.date] as? TimeInterval,
              let bpm = sample[WatchMessageKeys.value] as? Double,
              bpm >= 30, bpm <= 150
        else { return nil }
        let date = Date(timeIntervalSince1970: timestamp.rounded())
        guard date <= now.addingTimeInterval(5 * 60) else { return nil }
        return WatchHeartRateSample(date: date, bpm: bpm)
    }

    static func parse(payload: [String: Any]) -> (heartRates: [WatchHeartRateSample], steps: [WatchStepSample]) {
        let now = Date()
        // Reject readings from the future (clock skew of more than 5 min) and physiologically impossible values
        let latestAllowed = now.addingTimeInterval(5 * 60)

        let heartRates = (payload[WatchMessageKeys.heartRateSamples] as? [[String: Any]] ?? []).compactMap {
            sample -> WatchHeartRateSample? in
            guard let timestamp = sample[WatchMessageKeys.date] as? TimeInterval,
                  let bpm = sample[WatchMessageKeys.value] as? Double,
                  bpm >= 20, bpm <= 250
            else { return nil }
            // Whole seconds, so the de-duplication still matches after a round trip through the JSON file
            let date = Date(timeIntervalSince1970: timestamp.rounded())
            guard date <= latestAllowed else { return nil }
            return WatchHeartRateSample(date: date, bpm: bpm)
        }

        let steps = (payload[WatchMessageKeys.stepSamples] as? [[String: Any]] ?? []).compactMap {
            sample -> WatchStepSample? in
            guard let start = sample[WatchMessageKeys.start] as? TimeInterval,
                  let end = sample[WatchMessageKeys.end] as? TimeInterval,
                  let value = sample[WatchMessageKeys.value] as? Int,
                  end > start, value >= 0
            else { return nil }
            let endDate = Date(timeIntervalSince1970: end)
            guard endDate <= latestAllowed else { return nil }
            return WatchStepSample(start: Date(timeIntervalSince1970: start), end: endDate, steps: value)
        }

        return (heartRates, steps)
    }
}
