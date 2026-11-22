import Foundation
// Note: BoostV5Core sources are compiled into the Trio app target (not a separate module), so
// `BoostAutoConfigKnob` is used directly — no `import BoostV5Core` (which would fail to resolve).

/// Persistence and scheduling for the periodic auto-config re-derivation (AAPS 2026-08-03).
///
/// The pure decision lives in `BoostV5AutoConfigApply.redrive`. This holds the three pieces of state
/// it needs across runs and answers whether an evaluation is due.
///
/// - the BASELINE per knob: the derived value at the last write, advanced only on a write, so
///   movement suppressed by the deadband or held by the raise guard accumulates rather than
///   being lost.
/// - the PENDING value per knob: a quantised knob's proposed value awaiting its second consecutive
///   derivation, which is what stops it flapping across a threshold.
/// - the WRITTEN value per knob: what auto-config last wrote, so a computed knob the user has
///   since edited is recognised and kept (AAPS Boost 6.3.0 written ledger).
/// - the last evaluation time, for the cadence.
///
/// UserDefaults rather than Preferences, matching `BoostActivityStore` and `BoostMealTimeStore`:
/// this is bookkeeping about the derivation rather than a setting anyone edits, and it should not
/// travel with an exported settings file. An import carrying someone else's baselines would make
/// the first re-derivation track a movement that never happened on this device.
enum BoostRedriveStore {
    /// Evaluation cadence. Evaluating often is cheap once the filter, rather than the schedule,
    /// decides whether to write.
    static let interval: TimeInterval = 7 * 86400
    /// History window. Fourteen days is noise-dominated: two independent 14-day derivations of the
    /// same fortnight differ by 0.69 U [0.30, 1.17] on the confirmed cap.
    static let windowDays = 28

    private static let baselineKey = "boost.redrive.baseline"
    private static let pendingKey = "boost.redrive.pending"
    /// Votes cast by a run whose raise guard the person overrode. Kept apart so a scheduled run never
    /// counts one towards its two-run confirmation; only another overridden run can.
    private static let overridePendingKey = "boost.redrive.pending.override"
    private static let lastRunKey = "boost.redrive.lastRunMs"
    private static let writtenKey = "boost.redrive.written"

    private static let lock = NSLock()
    private static var running = false

    /// One evaluation at a time, scheduled or run by hand. A second started while one is in flight
    /// would read the same pending votes and step the same caps twice.
    static func tryBeginRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    static func endRun() {
        lock.lock()
        defer { lock.unlock() }
        running = false
    }

    /// Whether an evaluation is due. The first call on a fresh install returns true, which records
    /// the baselines and writes no tracked knob.
    static func isDue(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    /// Hours since the last evaluation, scheduled or run by hand; nil before the first.
    static func hoursSinceLastRun(now: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        return last > 0 ? (now.timeIntervalSince1970 - last) / 3600 : nil
    }

    static func markRun(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRunKey)
    }

    static func baseline(_ knob: BoostAutoConfigKnob) -> Double? {
        map(baselineKey)[knob.rawValue]
    }

    static func setBaseline(_ knob: BoostAutoConfigKnob, _ value: Double) {
        update(baselineKey) { $0[knob.rawValue] = value }
    }

    static func pending(_ knob: BoostAutoConfigKnob, overridden: Bool = false) -> Double? {
        map(overridden ? overridePendingKey : pendingKey)[knob.rawValue]
    }

    static func setPending(_ knob: BoostAutoConfigKnob, _ value: Double?, overridden: Bool = false) {
        update(overridden ? overridePendingKey : pendingKey) { $0[knob.rawValue] = value }
    }

    static func lastWritten(_ knob: BoostAutoConfigKnob) -> Double? {
        map(writtenKey)[knob.rawValue]
    }

    static func recordWritten(_ knob: BoostAutoConfigKnob, _ value: Double) {
        update(writtenKey) { $0[knob.rawValue] = value }
    }

    /// A boolean knob's last write, read as AAPS reads it: a value of 0 or more (the user-set mark
    /// is negative) as true at 0.5 and above.
    static func lastWrittenBool(_ knob: BoostAutoConfigKnob) -> Bool? {
        lastWritten(knob).flatMap { $0 >= 0 ? $0 >= 0.5 : nil }
    }

    static func recordWrittenBool(_ knob: BoostAutoConfigKnob, _ value: Bool) {
        recordWritten(knob, value ? 1.0 : 0.0)
    }

    /// Chooses the ledger a run votes in, once per run: the override ledger when the person's override
    /// lifts a guard that would otherwise hold. Any other run clears that ledger, so an overridden vote
    /// can be confirmed only by the very next run, as an ordinary vote is.
    static func voteLedger(overrideLiftsGuard: Bool) -> Bool {
        if !overrideLiftsGuard {
            lock.lock()
            defer { lock.unlock() }
            UserDefaults.standard.removeObject(forKey: overridePendingKey)
        }
        return overrideLiftsGuard
    }

    /// Pending entries not tied to a knob, such as a window's previous verdict.
    static func pendingFlag(_ key: String, overridden: Bool = false) -> Bool? {
        map(overridden ? overridePendingKey : pendingKey)[key].map { $0 >= 0.5 }
    }

    static func setPendingFlag(_ key: String, _ value: Bool?, overridden: Bool = false) {
        update(overridden ? overridePendingKey : pendingKey) { $0[key] = value.map { $0 ? 1.0 : 0.0 } }
    }

    /// Clear everything. Used by tests for isolation.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: baselineKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: overridePendingKey)
        UserDefaults.standard.removeObject(forKey: lastRunKey)
        UserDefaults.standard.removeObject(forKey: writtenKey)
    }

    private static func map(_ key: String) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private static func update(_ key: String, _ mutate: (inout [String: Double]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var m = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        mutate(&m)
        UserDefaults.standard.set(m, forKey: key)
    }
}
