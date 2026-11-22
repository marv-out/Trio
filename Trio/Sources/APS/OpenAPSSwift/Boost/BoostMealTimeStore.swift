import Foundation

/// Persists the V6 meal-time history (rolling window of CONFIRMED-commit timestamps) so the
/// MealTimeLearner can cluster habitual meal times and the determination can fire an
/// anticipatory pre-meal target. Recorded by the adapter on a fresh CONFIRMED; read by the
/// determination's V6 pre-meal check. UserDefaults-backed, thread-safe.
final class BoostMealTimeStore: @unchecked Sendable {
    static let shared = BoostMealTimeStore()

    private let key = "boost_mealtime_history"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var history: MealTimeHistory {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = defaults.data(forKey: key),
                  let h = try? JSONDecoder().decode(MealTimeHistory.self, from: data)
            else { return MealTimeHistory() }
            return h
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
        }
    }

    /// Record a fresh CONFIRMED commit at `clock` (trims to the learner's window).
    /// Uses the atomic mutate helper so the append-and-trim is a single locked read-modify-write —
    /// composing the locked getter and setter would leave a window where a concurrent recordConfirmed
    /// (scheduled loop vs post-bolus determineBasalSync) drops a committed meal-time event.
    func recordConfirmed(at clock: Date) {
        mutateHistory { $0 = MealTimeLearner.record($0, tsMs: clock.timeIntervalSince1970 * 1000.0) }
    }

    /// The history without learned sessions inside the configured night window, persisting the
    /// filtered copy only when something was dropped (AAPS a33752c9aa #8). Sessions recorded overnight
    /// before the learner was gated could otherwise form a mode and pull the lowered pre-meal target
    /// into the night. Returns the history to use this cycle.
    func historyWithoutNightEvents(nightStartMin: Int, nightEndMin: Int, localOffsetMs: Double) -> MealTimeHistory {
        var result = MealTimeHistory()
        var dropped = 0
        mutateHistory { h in
            let filtered = MealTimeLearner.withoutNightEvents(
                h, nightStartMin: nightStartMin, nightEndMin: nightEndMin, localOffsetMs: localOffsetMs
            )
            dropped = h.events.count - filtered.events.count
            h = filtered
            result = filtered
        }
        if dropped > 0 {
            debug(.algorithm, "V6 meal-time learner: dropped \(dropped) learned sessions inside the night window")
        }
        return result
    }

    /// Atomically load → mutate → save the meal-time history under a single critical section.
    /// Writes only when `body` changed the history, so a read-mostly caller does not rewrite it
    /// every cycle.
    private func mutateHistory(_ body: (inout MealTimeHistory) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var h: MealTimeHistory
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(MealTimeHistory.self, from: data)
        {
            h = decoded
        } else {
            h = MealTimeHistory()
        }
        let before = h
        body(&h)
        guard h != before else { return }
        if let data = try? JSONEncoder().encode(h) { defaults.set(data, forKey: key) }
    }
}
