import Foundation
// Note: BoostV5Core sources are compiled into the Trio app target (not a separate module), so
// `ComposedFloor` is used directly — no `import BoostV5Core` (which would fail to resolve).

/// Throttled trailing-14d hypo-gate for the composed brake-floor (2026-07-08, AAPS 9110ef2520 +
/// 8b492a08e7). The floor is insulin-ADDING, so it may engage only while the user's low exposure is
/// under the TING / two-test bars: **TBR<63 < 2.0% AND TBR<70 < 3.5%** (14 days).
///
/// A 14-day metric barely moves within an hour, so `APSManager` recomputes it at most hourly (the
/// expensive part is the 14d BG scan) and feeds the readings here; this store caches the fail-closed
/// gate the dosing path reads each cycle via `BoostV5Adapter`.
///
/// FAIL-CLOSED: the gate defaults to `false` and stays false until the first successful compute with
/// enough CGM history. It is an in-memory cache, so an app restart re-fails-closed — matching AAPS's
/// `@Volatile` fields. The 14d metric auto-re-engages/disengages as low exposure crosses the bars.
enum BoostComposedFloorGate {
    /// Recompute cadence — a 14d metric barely moves within an hour. (AAPS `TBR_GATE_REFRESH_MS`.)
    static let refreshInterval: TimeInterval = 3600
    /// Minimum 14d CGM readings before the fraction is trusted (~3.5 days of 5-min CGM). (AAPS 1000.)
    static let minReadings = ComposedFloor.gateMinReadings

    private static let lock = NSLock()
    private static var storedAllowed = false
    private static var lastComputeMs: Double = 0

    /// The fail-closed gate the dosing path (`BoostV5Adapter`) reads each cycle.
    static var allowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedAllowed
    }

    /// Whether the (expensive) 14d BG scan is due — never computed yet, or older than `refreshInterval`.
    static func shouldRecompute(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastComputeMs == 0 || now.timeIntervalSince1970 * 1000 - lastComputeMs >= refreshInterval * 1000
    }

    /// Recompute the gate from trailing-14d glucose (mg/dL, already sanity-filtered to 20…600 by the
    /// caller — Trio's convention, matching the auto-config TBR maths). Fail-closed on thin history.
    static func update(now: Date, glucoseValuesMgdl: [Int]) {
        // The safety-critical decision (min-readings fail-closed + TBR<63/<70 math) lives in the
        // unit-tested BoostV5Core; this store only caches it under a lock + throttle.
        let result = ComposedFloor.allowedFromGlucose(valuesMgdl: glucoseValuesMgdl, minReadings: minReadings)
        lock.lock()
        defer { lock.unlock() }
        storedAllowed = result
        lastComputeMs = now.timeIntervalSince1970 * 1000
    }

    /// Test/reset hook — clears the in-memory cache back to the fail-closed default.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        storedAllowed = false
        lastComputeMs = 0
    }
}
