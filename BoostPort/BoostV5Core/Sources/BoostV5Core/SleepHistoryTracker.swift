import Foundation

/// SleepHistoryTracker — rolling 28-day record of sleep onset/wake times + per-session HR
/// percentiles, with circular-mean aggregation so the night window and resting HR can be
/// *learned* rather than purely configured. Faithful 1:1 port of AAPS `SleepHistoryTracker`
/// (openAPSBoost, Boost-V6-mealtime-alpha).
///
/// Two transitions drive the record:
///   AWAKE → SLEEPING   → `onSleepStart` records the open session start
///   SLEEPING → AWAKE   → `onWake` closes it (with sleep-period + prior-awake HR p10s), trims
///
/// `aggregate` returns learned night-onset/wake clock-minutes (circular mean) and resting/daytime
/// HR (median of per-session p10), but only once ≥ `minSessionsForLearned` (7) sessions exist;
/// below that the night-window fields are nil and the caller falls back to configured values.
public enum SleepHistoryTracker {
    static let windowDays = 28.0
    static let windowMs = windowDays * 24.0 * 60.0 * 60.0 * 1000.0
    static let minSessionsForLearned = 7

    /// A closed sleep session. `sleepHrP10`/`daytimeHrP10` are the p10 of HR over the sleep
    /// period / preceding awake period (nil when insufficient samples).
    public struct Session: Codable, Equatable, Sendable {
        public var sleepStartMs: Double
        public var wakeMs: Double
        public var sleepHrP10: Int?
        public var daytimeHrP10: Int?
        /// Why the session ended: "hr_steps"/"resume" = genuine wake (trains the learned wake);
        /// "boundary" = hard night-window exit (excluded); nil = legacy/unknown (also excluded, so
        /// pre-fix collapsed history is discarded, not re-learned). Optional → old JSON decodes nil.
        public var wakeReason: String?

        public init(
            sleepStartMs: Double, wakeMs: Double,
            sleepHrP10: Int? = nil, daytimeHrP10: Int? = nil, wakeReason: String? = nil
        ) {
            self.sleepStartMs = sleepStartMs
            self.wakeMs = wakeMs
            self.sleepHrP10 = sleepHrP10
            self.daytimeHrP10 = daytimeHrP10
            self.wakeReason = wakeReason
        }
    }

    /// Persisted carrier. `openSleepStartMs` is the in-progress session (SLEEPING, not yet woken).
    public struct History: Codable, Equatable, Sendable {
        public var sessions: [Session]
        public var openSleepStartMs: Double?

        public init(sessions: [Session] = [], openSleepStartMs: Double? = nil) {
            self.sessions = sessions
            self.openSleepStartMs = openSleepStartMs
        }
    }

    /// Learned aggregates over the rolling window. Night-window fields are nil below the
    /// session threshold; HR fields are nil below the threshold of *HR-bearing* sessions.
    public struct Aggregate: Equatable, Sendable {
        public var sleepStartMinAvg: Int?
        public var wakeMinAvg: Int?
        public var sleepDurationMinAvg: Int?
        public var sessionCount: Int
        public var restingHrBpm: Int?
        public var daytimeHrBpm: Int?
        public var restingHrSampleCount: Int
        public var daytimeHrSampleCount: Int
    }

    /// AWAKE → SLEEPING: open a session.
    public static func onSleepStart(_ h: History, sleepStartMs: Double) -> History {
        var copy = h
        copy.openSleepStartMs = sleepStartMs
        return copy
    }

    /// SLEEPING → AWAKE: close the open session (with HR p10s), append, trim the rolling window.
    public static func onWake(
        _ h: History,
        wakeMs: Double,
        sleepHrBpms: [Double] = [],
        daytimeHrBpms: [Double] = [],
        wakeReason: String? = nil
    ) -> History {
        guard let open = h.openSleepStartMs else { return h } // no open session
        var newSessions = h.sessions
        newSessions.append(Session(
            sleepStartMs: open,
            wakeMs: wakeMs,
            sleepHrP10: p10(sleepHrBpms),
            daytimeHrP10: p10(daytimeHrBpms),
            wakeReason: wakeReason
        ))
        let cutoff = wakeMs - windowMs
        newSessions.removeAll { $0.sleepStartMs < cutoff }
        return History(sessions: newSessions, openSleepStartMs: nil)
    }

    /// Wake time of the latest closed session, or nil. Bounds the prior-awake HR window.
    public static func lastWakeMs(_ h: History) -> Double? {
        h.sessions.map(\.wakeMs).max()
    }

    /// Compute aggregates over the rolling window.
    /// Max minutes the learned sleep window may move from the configured night start or end.
    public static let learnedWindowBandMin = 90

    /// Clamp a learned minute-of-day to within the band around the configured minute-of-day, on the
    /// 24 h circle. Returns `configured` when `learned` is nil. This caps how far the learned window
    /// can drift from the configured times, which together with the genuine-wake-only training below
    /// is what stops the night window collapsing earlier every night.
    ///
    /// `allowEarlier: false` makes the nudge one-sided, so learning may only move the bound later
    /// than configured (AAPS 4b06282ba7). Used for the night end. The learned wake is a circular
    /// mean over roughly 40 sessions, and for someone whose real wake varies between 04:30 and 09:30
    /// that mean sits early: it dragged a configured 07:30 night end down to about 06:00, lifting
    /// sleep protection two hours before the person's own setting, which is the unsafe direction
    /// because it opens the dawn window. Real-time HR and step detection still catches a genuine
    /// early wake. The night start keeps the symmetric band, where later-to-bed drift is expected.
    public static func clampToConfiguredBand(
        learned: Int?,
        configured: Int,
        bandMin: Int = learnedWindowBandMin,
        allowEarlier: Bool = true
    ) -> Int {
        guard let learned else { return configured }
        // Signed circular delta in [-720, 719]; positive means the learned time is later.
        let delta = ((learned - configured + 1440 + 720) % 1440) - 720
        let loBand = allowEarlier ? -bandMin : 0
        let clamped = min(max(delta, loBand), bandMin)
        return ((configured + clamped) % 1440 + 1440) % 1440
    }

    /// Night start for the detector. Without an HR feed the learned start may not move it earlier:
    /// those sessions began on the clock fallback, not on observed sleep, so an early learned start
    /// would reopen sleep during the evening (AAPS Boost 6.3.3 `effectiveNightStartMin`).
    public static func effectiveNightStartMin(
        learned: Int?,
        configured: Int,
        bandMin: Int = learnedWindowBandMin,
        hrFeedPresent: Bool
    ) -> Int {
        clampToConfiguredBand(learned: learned, configured: configured, bandMin: bandMin, allowEarlier: hrFeedPresent)
    }

    public static func aggregate(_ h: History, localOffsetMs: Double) -> Aggregate {
        aggregate(h, offsetAt: { _ in localOffsetMs })
    }

    /// Aggregates with each session time converted at the UTC offset in force at that instant
    /// (AAPS Boost 6.3.0, f4d7f1a0d4). With today's offset for all of them, sessions that began at
    /// 23:00 BST read as 22:00 after the clocks went back, and the learned onset moved an hour early
    /// until the window refilled.
    public static func aggregate(_ h: History, offsetAt: (Double) -> Double) -> Aggregate {
        let restingHrSamples = h.sessions.compactMap(\.sleepHrP10)
        let daytimeHrSamples = h.sessions.compactMap(\.daytimeHrP10)
        let restingHr = restingHrSamples.count >= minSessionsForLearned ? median(restingHrSamples) : nil
        let daytimeHr = daytimeHrSamples.count >= minSessionsForLearned ? median(daytimeHrSamples) : nil

        // Learned WAKE time trains ONLY on genuine wakes ("hr_steps"/"resume"/"steps"); "boundary"
        // hard-exit and legacy-nil wakes are excluded, with its own session-count gate. Breaks the
        // hard-exit→learned-wake feedback loop: with no genuine wake signal (sparse-HR night) this
        // stays nil and the host falls back to the configured wake. Onset still learns from all
        // sessions. "steps" (2026-07-08, AAPS dea9d300ff): steps-only wake when HR is unreliable — a
        // genuine getting-up signal, so it trains too.
        let genuineWakeMins = h.sessions
            .filter { $0.wakeReason == "hr_steps" || $0.wakeReason == "resume" || $0.wakeReason == "steps" }
            .map { msToMinOfDay($0.wakeMs, localOffsetMs: offsetAt($0.wakeMs)) }
        let wakeAvg = genuineWakeMins.count >= minSessionsForLearned ? circularMean(genuineWakeMins) : nil

        if h.sessions.count < minSessionsForLearned {
            return Aggregate(
                sleepStartMinAvg: nil, wakeMinAvg: wakeAvg, sleepDurationMinAvg: nil,
                sessionCount: h.sessions.count, restingHrBpm: restingHr, daytimeHrBpm: daytimeHr,
                restingHrSampleCount: restingHrSamples.count, daytimeHrSampleCount: daytimeHrSamples.count
            )
        }
        let sleepStartMin = h.sessions.map { msToMinOfDay($0.sleepStartMs, localOffsetMs: offsetAt($0.sleepStartMs)) }
        let durations = h.sessions.map { Int(($0.wakeMs - $0.sleepStartMs) / 60000.0) }
        return Aggregate(
            sleepStartMinAvg: circularMean(sleepStartMin),
            wakeMinAvg: wakeAvg,
            sleepDurationMinAvg: durations.isEmpty ? nil : durations.reduce(0, +) / durations.count,
            sessionCount: h.sessions.count,
            restingHrBpm: restingHr,
            daytimeHrBpm: daytimeHr,
            restingHrSampleCount: restingHrSamples.count,
            daytimeHrSampleCount: daytimeHrSamples.count
        )
    }

    /// p10 of HR values (BPM); nil when fewer than `minSamples` valid samples.
    public static func p10(_ values: [Double], minSamples: Int = 30) -> Int? {
        let valid = values.filter { $0.isFinite && $0 > 0 }
        if valid.count < minSamples { return nil }
        let sorted = valid.sorted()
        let idx = min(max(Int(Double(sorted.count - 1) * 0.10), 0), sorted.count - 1)
        return Int(sorted[idx])
    }

    /// Integer median (upper-middle for even count, matching Kotlin `sorted[size/2]`).
    static func median(_ values: [Int]) -> Int? {
        if values.isEmpty { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// UTC ms → local clock minute-of-day [0..1439].
    static func msToMinOfDay(_ utcMs: Double, localOffsetMs: Double) -> Int {
        let localMs = utcMs + localOffsetMs
        let msPerDay = 24.0 * 60.0 * 60.0 * 1000.0
        let msIntoDay = (localMs.truncatingRemainder(dividingBy: msPerDay) + msPerDay).truncatingRemainder(dividingBy: msPerDay)
        return Int(msIntoDay / 60000.0)
    }

    /// Circular mean of minute-of-day values (handles midnight wrap). nil if empty.
    static func circularMean(_ minutes: [Int]) -> Int? {
        if minutes.isEmpty { return nil }
        var sx = 0.0, sy = 0.0
        for m in minutes {
            let angle = 2.0 * Double.pi * Double(m) / 1440.0
            sx += cos(angle)
            sy += sin(angle)
        }
        let mean = atan2(sy, sx)
        let normalized = (mean + 2.0 * Double.pi).truncatingRemainder(dividingBy: 2.0 * Double.pi)
        return Int((normalized / (2.0 * Double.pi)) * 1440.0) % 1440
    }

    // MARK: - Persistence (JSON string, matching the AAPS storage shape's intent)

    public static func serialize(_ h: History) -> String {
        guard let data = try? JSONEncoder().encode(h), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    public static func deserialize(_ raw: String) -> History {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let h = try? JSONDecoder().decode(History.self, from: data)
        else { return History() }
        return h
    }
}
