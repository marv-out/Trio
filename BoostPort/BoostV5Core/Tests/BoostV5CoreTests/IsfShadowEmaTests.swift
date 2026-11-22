@testable import BoostV5Core
import XCTest

final class IsfShadowEmaTests: XCTestCase {
    private let dayMs = 24.0 * 60.0 * 60.0 * 1000.0
    private let tau = IsfShadowEma.tauMs // 3h in ms

    // MARK: - Constants match source

    func testConstantsMatchSource() {
        XCTAssertEqual(IsfShadowEma.tauMs, 3.0 * 60.0 * 60.0 * 1000.0, accuracy: 1E-6)
        XCTAssertEqual(IsfShadowEma.coldStartDays, 5.0, accuracy: 1E-6)
    }

    // MARK: - Guard: tdd7d <= 0 (and other invalid inputs)

    func testReturnsNilWhenTdd7dNonPositive() {
        XCTAssertNil(IsfShadowEma.computeShadow(
            tdd24h: 40, tdd7d: 0, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 0, state: IsfShadowState()
        ))
        XCTAssertNil(IsfShadowEma.computeShadow(
            tdd24h: 40, tdd7d: -5, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 0, state: IsfShadowState()
        ))
    }

    func testReturnsNilWhenTdd24hNonPositiveOrMissing() {
        XCTAssertNil(IsfShadowEma.computeShadow(
            tdd24h: 0, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 0, state: IsfShadowState()
        ))
        XCTAssertNil(IsfShadowEma.computeShadow(
            tdd24h: nil, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 0, state: IsfShadowState()
        ))
        XCTAssertNil(IsfShadowEma.computeShadow(
            tdd24h: 40, tdd7d: nil, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 0, state: IsfShadowState()
        ))
    }

    // MARK: - Raw ratio clamp

    func testRawRatioClampedToBounds() {
        // ratio = 60/30 = 2.0, clamp to max 1.3
        let high = IsfShadowEma.computeShadow(
            tdd24h: 60, tdd7d: 30, autosensMin: 0.7, autosensMax: 1.3,
            nowMs: 0, state: IsfShadowState()
        )
        XCTAssertEqual(high?.raw ?? .nan, 1.3, accuracy: 1E-6)

        // ratio = 10/40 = 0.25, clamp to min 0.7
        let low = IsfShadowEma.computeShadow(
            tdd24h: 10, tdd7d: 40, autosensMin: 0.7, autosensMax: 1.3,
            nowMs: 0, state: IsfShadowState()
        )
        XCTAssertEqual(low?.raw ?? .nan, 0.7, accuracy: 1E-6)

        // within bounds: 36/30 = 1.2
        let mid = IsfShadowEma.computeShadow(
            tdd24h: 36, tdd7d: 30, autosensMin: 0.7, autosensMax: 1.3,
            nowMs: 0, state: IsfShadowState()
        )
        XCTAssertEqual(mid?.raw ?? .nan, 1.2, accuracy: 1E-6)
    }

    // MARK: - First call seeds firstSeenMs and EMA

    func testFirstCallSeedsFirstSeenAndEma() {
        let now = 1_000_000.0
        let r = IsfShadowEma.computeShadow(
            tdd24h: 36, tdd7d: 30, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: now, state: IsfShadowState()
        )
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.newState.firstSeenMs ?? .nan, now, accuracy: 1E-6)
        XCTAssertEqual(r?.newState.lastUpdateMs ?? .nan, now, accuracy: 1E-6)

        // At day 0, warmup = 0 => warmedRatio = 1.0; EMA seeds to warmedRatio.
        XCTAssertEqual(r?.warmupFraction ?? .nan, 0.0, accuracy: 1E-6)
        XCTAssertEqual(r?.ema ?? .nan, 1.0, accuracy: 1E-6)
        XCTAssertEqual(r?.newState.emaState ?? .nan, 1.0, accuracy: 1E-6)
        // raw remains the clamped raw ratio (1.2), unaffected by warmup.
        XCTAssertEqual(r?.raw ?? .nan, 1.2, accuracy: 1E-6)
    }

    // MARK: - Cold-start warmup fraction rises 0 -> 1 over the window

    func testWarmupFractionRisesOverColdStartWindow() {
        let start = 5_000_000.0
        let seeded = IsfShadowState(emaState: nil, lastUpdateMs: nil, firstSeenMs: start)

        func warmup(atDays days: Double) -> Double {
            let r = IsfShadowEma.computeShadow(
                tdd24h: 36, tdd7d: 30, autosensMin: 0.5, autosensMax: 2.0,
                nowMs: start + days * dayMs, state: seeded
            )
            return r?.warmupFraction ?? .nan
        }

        XCTAssertEqual(warmup(atDays: 0), 0.0, accuracy: 1E-6)
        XCTAssertEqual(warmup(atDays: 2.5), 0.5, accuracy: 1E-6)
        XCTAssertEqual(warmup(atDays: 5), 1.0, accuracy: 1E-6)
        // Beyond the window stays clamped at 1.0.
        XCTAssertEqual(warmup(atDays: 10), 1.0, accuracy: 1E-6)
    }

    func testWarmedRatioBlendsTowardOneEarlyInWindow() {
        // At day 1 (warmup = 0.2), raw = 1.5 => warmed = 1.0 + 0.5*0.2 = 1.1.
        // First call seeds EMA directly to warmedRatio, so ema == 1.1.
        let start = 0.0
        let r = IsfShadowEma.computeShadow(
            tdd24h: 60, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: start + 1.0 * dayMs,
            state: IsfShadowState(emaState: nil, lastUpdateMs: nil, firstSeenMs: start)
        )
        XCTAssertEqual(r?.warmupFraction ?? .nan, 0.2, accuracy: 1E-6)
        XCTAssertEqual(r?.raw ?? .nan, 1.5, accuracy: 1E-6)
        XCTAssertEqual(r?.ema ?? .nan, 1.1, accuracy: 1E-6)
    }

    // MARK: - EMA converges toward raw at tau spacing (alpha ~= 0.63 at dt = tau)

    func testAlphaApproxPointSixThreeAtDeltaTEqualsTau() {
        // Fully warmed (past cold-start) so warmedRatio == rawRatio.
        // Prior EMA = 1.0, raw target = 1.5, dt = tau => alpha = 1 - e^-1.
        let firstSeen = 0.0
        let now = 10.0 * dayMs // well past 5-day window
        let last = now - tau // exactly one tau ago
        let prior = IsfShadowState(emaState: 1.0, lastUpdateMs: last, firstSeenMs: firstSeen)

        let r = IsfShadowEma.computeShadow(
            tdd24h: 60, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: now, state: prior
        )
        let alpha = 1.0 - exp(-1.0) // ~0.632
        XCTAssertEqual(alpha, 0.6321205588, accuracy: 1E-6)

        // warmed == raw == 1.5; expected = 1.0 + alpha*(1.5 - 1.0)
        let expected = 1.0 + alpha * (1.5 - 1.0)
        XCTAssertEqual(r?.ema ?? .nan, expected, accuracy: 1E-6)
        XCTAssertEqual(r?.warmupFraction ?? .nan, 1.0, accuracy: 1E-6)
    }

    func testEmaConvergesTowardRawOverRepeatedTauCalls() {
        // Start fully warmed, EMA below the raw target; step at tau spacing.
        var state = IsfShadowState(emaState: 1.0, lastUpdateMs: 100.0 * dayMs, firstSeenMs: 0.0)
        let target = 1.5
        var last: Double = .nan
        var t = 100.0 * dayMs
        for _ in 0 ..< 20 {
            t += tau
            let r = IsfShadowEma.computeShadow(
                tdd24h: 60, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
                nowMs: t, state: state
            )!
            // Monotonically increasing toward target, never overshooting.
            if !last.isNaN { XCTAssertGreaterThan(r.ema, last) }
            XCTAssertLessThan(r.ema, target)
            last = r.ema
            state = r.newState
        }
        // After 20 taus it is very close to the raw target.
        XCTAssertEqual(last, target, accuracy: 1E-6)
    }

    func testZeroDeltaTLeavesEmaUnchanged() {
        // dt == 0 => alpha == 0 => EMA unchanged from prior.
        let state = IsfShadowState(emaState: 1.23, lastUpdateMs: 7.0 * dayMs, firstSeenMs: 0.0)
        let r = IsfShadowEma.computeShadow(
            tdd24h: 60, tdd7d: 40, autosensMin: 0.5, autosensMax: 2.0,
            nowMs: 7.0 * dayMs, state: state
        )
        XCTAssertEqual(r?.ema ?? .nan, 1.23, accuracy: 1E-6)
    }

    // MARK: - Final clamp to [min, max]

    func testFinalRatioClampedToBounds() {
        // Push EMA above max: prior EMA already high, raw clamp high, tight max.
        let high = IsfShadowEma.computeShadow(
            tdd24h: 60, tdd7d: 30, autosensMin: 0.9, autosensMax: 1.1,
            nowMs: 10.0 * dayMs,
            state: IsfShadowState(emaState: 5.0, lastUpdateMs: 9.0 * dayMs, firstSeenMs: 0.0)
        )
        XCTAssertNotNil(high)
        XCTAssertLessThanOrEqual(high!.ratio, 1.1 + 1E-9)
        XCTAssertEqual(high!.ratio, 1.1, accuracy: 1E-6)

        // Push EMA below min.
        let low = IsfShadowEma.computeShadow(
            tdd24h: 10, tdd7d: 40, autosensMin: 0.9, autosensMax: 1.1,
            nowMs: 10.0 * dayMs,
            state: IsfShadowState(emaState: 0.1, lastUpdateMs: 9.0 * dayMs, firstSeenMs: 0.0)
        )
        XCTAssertNotNil(low)
        XCTAssertGreaterThanOrEqual(low!.ratio, 0.9 - 1E-9)
        XCTAssertEqual(low!.ratio, 0.9, accuracy: 1E-6)
    }

    // MARK: - Codable round-trip

    func testStateCodableRoundTrip() throws {
        let original = IsfShadowState(emaState: 1.234, lastUpdateMs: 1_700_000_000_000.0, firstSeenMs: 1_699_000_000_000.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IsfShadowState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStateCodableRoundTripWithNils() throws {
        let original = IsfShadowState()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IsfShadowState.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.emaState)
        XCTAssertNil(decoded.lastUpdateMs)
        XCTAssertNil(decoded.firstSeenMs)
    }

    func testStateSerializedFieldNames() throws {
        let s = IsfShadowState(emaState: 1.0, lastUpdateMs: 2.0, firstSeenMs: 3.0)
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("emaState"))
        XCTAssertTrue(json.contains("lastUpdateMs"))
        XCTAssertTrue(json.contains("firstSeenMs"))
    }
}
