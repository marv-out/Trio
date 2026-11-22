import Foundation

/// MealTimeLearner — Boost V6 (Swift port).
///
/// Faithful 1:1 port of `MealTimeLearner` from AAPS Boost
/// (`plugins/aps/.../openAPSBoost/MealTimeLearner.kt`), including the
/// `msToMinOfDay` / `circularMean` helpers it reuses from `SleepHistoryTracker`.
///
/// Learns a user's habitual meal times from CONFIRMED meal-commit timestamps
/// (UTC epoch-ms) over a rolling 60-day window, greedily clusters them into
/// trusted *meal modes* (densest ±45 min neighbourhood, requiring ≥6 events
/// over ≥4 distinct local days), and exposes a pre-meal query the loop uses to
/// fire an anticipatory low temp target 45–60 min before a learned meal.
///
/// All time-of-day maths is midnight-wrap-safe (circular minute math + circular
/// mean). The module is pure and Foundation-only: all timestamps are passed in
/// (no `Date.now`), so it is fully deterministic and testable.

/// Rolling history of meal-commit timestamps (UTC epoch-ms).
///
/// `events` are stored as `Double` to be JSON-friendly; they hold whole
/// epoch-millisecond values.
public struct MealTimeHistory: Codable, Equatable, Sendable {
    public var events: [Double]

    public init(events: [Double] = []) {
        self.events = events
    }
}

/// A learned habitual meal time.
public struct MealMode: Equatable, Sendable {
    /// Circular-mean clock minute-of-day `[0..1439]`.
    public let centreMin: Int
    /// Number of events in the cluster.
    public let eventCount: Int
    /// Number of distinct local days contributing (the trust signal).
    public let distinctDays: Int

    public init(centreMin: Int, eventCount: Int, distinctDays: Int) {
        self.centreMin = centreMin
        self.eventCount = eventCount
        self.distinctDays = distinctDays
    }
}

/// Result of a positive `preMealWindow` match.
public struct PreMealHit: Equatable, Sendable {
    public let mode: MealMode
    /// How many minutes before the meal centre we currently are.
    public let minutesBeforeMeal: Int

    public init(mode: MealMode, minutesBeforeMeal: Int) {
        self.mode = mode
        self.minutesBeforeMeal = minutesBeforeMeal
    }
}

public enum MealTimeLearner {
    /// Constants matched exactly to the Kotlin source.
    private enum Const {
        /// A cluster must have at least this many events to be a trusted meal mode.
        static let minSessions = 6
        /// …spread over at least this many distinct days (kills a single binge-day false mode).
        static let minDistinctDays = 4
        /// Circular half-width (min) for grouping events into one mode (~07:50 ± 45 → breakfast).
        static let clusterHalfWidthMin = 45
        /// The pre-meal window always CLOSES this many minutes before the learned meal.
        static let preMealLeadMinFloor = 45
        /// Guaranteed minimum window span (min), so a low leadMax can't yield a zero-width window.
        static let preMealMinSpanMin = 10

        static let minutesPerDay = 1440
        static let msPerDay: Double = 24.0 * 60.0 * 60.0 * 1000.0
    }

    // MARK: - Record

    /// Record a fresh meal-commit at `tsMs`. Appends and trims to the rolling
    /// window. Returns the updated history (caller persists).
    public static func record(_ h: MealTimeHistory, tsMs: Double, windowDays: Int = 60) -> MealTimeHistory {
        let windowMs = Double(windowDays) * Const.msPerDay
        var newEvents = h.events
        newEvents.append(tsMs)
        let cutoff = tsMs - windowMs
        newEvents.removeAll { $0 < cutoff }
        return MealTimeHistory(events: newEvents)
    }

    // MARK: - Night exclusion (AAPS a33752c9aa #8)

    /// True when local `minOfDay` lies in the night window `[startMin, endMin)`. A window that wraps
    /// midnight (start later than end, e.g. 22:00 to 07:00) is the union of `[start, 1440)` and
    /// `[0, end)`, so 23:30 and 03:00 are both inside and 07:00 is not. Equal times are an empty
    /// window, the same convention as `NightMode`, so a misconfigured window drops nothing.
    public static func inNightMinutes(_ minOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        NightMode.minuteInWindow(now: minOfDay, start: startMin, end: endMin)
    }

    /// `h` without the events whose local time falls inside the configured night window. Before the
    /// learner was gated on the night window and the sleep detector it recorded overnight sessions,
    /// which in the AAPS field record were rises with no logged carbs, mostly while the detector read
    /// SLEEPING or PRE_SLEEP; enough of them form a mode and move the lowered pre-meal target into
    /// the night. Returns `h` itself when nothing is dropped.
    public static func withoutNightEvents(
        _ h: MealTimeHistory,
        nightStartMin: Int,
        nightEndMin: Int,
        localOffsetMs: Double
    ) -> MealTimeHistory {
        let kept = h.events.filter {
            !inNightMinutes(msToMinOfDay($0, localOffsetMs: localOffsetMs), startMin: nightStartMin, endMin: nightEndMin)
        }
        return kept.count == h.events.count ? h : MealTimeHistory(events: kept)
    }

    /// The learner records a session only when it starts outside the configured night window with
    /// the detector AWAKE.
    public static func sessionRecordable(inNightWindow: Bool, sleepState: SleepState) -> Bool {
        !inNightWindow && sleepState == .awake
    }

    /// Why the learned pre-meal target must not apply this cycle, or nil when it may. The target
    /// lowers glucose targets in the hour before a learned meal time, and in AAPS it was applying
    /// while asleep and under a user's own temp target. It applies only outside the configured night
    /// window, with the detector neither SLEEPING nor PRE_SLEEP, with no temp target and outside the
    /// post-rescue window. Each block can only remove insulin.
    public static func preMealTargetBlock(
        inNightWindow: Bool,
        sleepState: SleepState,
        tempTargetActive: Bool,
        postRescueWindow: Bool
    ) -> String? {
        if inNightWindow { return "night window" }
        if sleepState == .sleeping || sleepState == .preSleep { return "asleep" }
        if tempTargetActive { return "temp target" }
        if postRescueWindow { return "post-rescue" }
        return nil
    }

    // MARK: - Clustering

    /// Greedily cluster the history's events into trusted meal modes (descending
    /// by size). O(n²) over events, but n is tiny (≤ ~3 meals/day × 60 days).
    public static func modes(_ h: MealTimeHistory, localOffsetMs: Double) -> [MealMode] {
        if h.events.count < Const.minSessions { return [] }
        // (minuteOfDay, dayIndex) per event
        var pts: [(min: Int, day: Int)] = h.events.map { ms in
            (msToMinOfDay(ms, localOffsetMs: localOffsetMs), dayIndex(ms, localOffsetMs: localOffsetMs))
        }

        var result: [MealMode] = []
        while pts.count >= Const.minSessions {
            // pick the event whose ±half-width neighbourhood holds the most events
            guard let best = pts.max(by: { a, b in
                neighbourCount(of: a.min, in: pts) < neighbourCount(of: b.min, in: pts)
            }) else { break }

            let cluster = pts.filter { circularDistance($0.min, best.min) <= Const.clusterHalfWidthMin }
            let distinctDays = Set(cluster.map(\.day)).count
            if cluster.count >= Const.minSessions, distinctDays >= Const.minDistinctDays {
                if let centre = circularMean(cluster.map(\.min)) {
                    result.append(MealMode(centreMin: centre, eventCount: cluster.count, distinctDays: distinctDays))
                }
                // remove all members of this cluster
                pts.removeAll { circularDistance($0.min, best.min) <= Const.clusterHalfWidthMin }
            } else {
                // the densest remaining cluster isn't trustworthy → no further modes will be either
                break
            }
        }
        return result
    }

    // MARK: - Pre-meal query

    /// Is `nowMin` (local clock minute-of-day) inside the pre-meal lead window of
    /// any learned mode?
    ///
    /// The window for a mode centred at `c` is the arc
    /// `[c − open, c − PRE_MEAL_LEAD_MIN_FLOOR]` — it opens `open` min before the
    /// meal and closes `PRE_MEAL_LEAD_MIN_FLOOR` min before it. `open` is the
    /// user's lead-minutes setting, held at least `PRE_MEAL_MIN_SPAN_MIN` above
    /// the floor so a low setting can't collapse the window to nothing.
    public static func preMealWindow(
        _ h: MealTimeHistory,
        nowMin: Int,
        localOffsetMs: Double,
        leadMaxMin: Int
    ) -> PreMealHit? {
        let open = max(leadMaxMin, Const.preMealLeadMinFloor + Const.preMealMinSpanMin)
        for mode in modes(h, localOffsetMs: localOffsetMs) {
            // minutes from now forward to the meal centre, on the circle [0..1439]
            let ahead = ((mode.centreMin - nowMin) % Const.minutesPerDay + Const.minutesPerDay) % Const.minutesPerDay
            if ahead >= Const.preMealLeadMinFloor, ahead <= open {
                return PreMealHit(mode: mode, minutesBeforeMeal: ahead)
            }
        }
        return nil
    }

    // MARK: - Time-of-day helpers (ported from SleepHistoryTracker)

    /// Smaller of clockwise / anticlockwise distance between two minute-of-day values.
    private static func circularDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b)
        return min(d, Const.minutesPerDay - d)
    }

    private static func neighbourCount(of minute: Int, in pts: [(min: Int, day: Int)]) -> Int {
        pts.reduce(0) { acc, p in acc + (circularDistance(p.min, minute) <= Const.clusterHalfWidthMin ? 1 : 0) }
    }

    /// UTC ms → local minute-of-day `[0..1439]`, midnight-wrap-safe.
    static func msToMinOfDay(_ utcMs: Double, localOffsetMs: Double) -> Int {
        let localMs = utcMs + localOffsetMs
        let msPerDay = Const.msPerDay
        let msIntoDay = floorMod(localMs, msPerDay)
        return Int(msIntoDay / 60000.0)
    }

    /// Local day index — mirrors Kotlin `(ms + localOffsetMs) / msPerDay` (integer division).
    private static func dayIndex(_ utcMs: Double, localOffsetMs: Double) -> Int {
        let localMs = utcMs + localOffsetMs
        return Int((localMs / Const.msPerDay).rounded(.down))
    }

    /// Circular mean of a list of minute-of-day values, handling wrap-around.
    /// Returns the mean clock-minute `(0..1439)`, or nil for empty input.
    static func circularMean(_ minutes: [Int]) -> Int? {
        if minutes.isEmpty { return nil }
        var sx = 0.0
        var sy = 0.0
        for m in minutes {
            let angle = 2.0 * Double.pi * Double(m) / 1440.0
            sx += cos(angle)
            sy += sin(angle)
        }
        let mean = atan2(sy, sx)
        let normalized = floorMod(mean, 2.0 * Double.pi)
        return Int((normalized / (2.0 * Double.pi)) * 1440.0) % 1440
    }

    /// Non-negative floating modulo, matching Kotlin's `((x % m) + m) % m` idiom.
    private static func floorMod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return (r + m).truncatingRemainder(dividingBy: m)
    }
}
