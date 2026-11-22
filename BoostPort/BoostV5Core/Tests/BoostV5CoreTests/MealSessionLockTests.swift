@testable import BoostV5Core
import XCTest

/// One confirm per meal (AAPS c237a4d081, audit item 7; port of MealSessionLockTest).
///
/// The single-confirm lock was cleared on the RECOVERING to IDLE exit, which fires on one negative
/// delta, the trough between two phases of a meal. The fast path then went IDLE to CONFIRMED without
/// the eventualBG-offset or dose-adequacy gates. The lock now holds for 90 minutes after the last
/// CONFIRMED or COMMITTED cycle unless 30 minutes of non-positive deltas ends the session first, and
/// inside it a rise can re-engage COMMITTED through the slow path only.
final class MealSessionLockTests: XCTestCase {
    private let t0: Double = 1_800_000_000_000
    private func at(_ m: Int) -> Double { t0 + Double(m) * 60000 }

    private func step(
        _ s: MealHypothesisState, score: Double, eventualBg: Double, delta: Double, deltaAccl: Double,
        deltaDeclining: Bool = false, fastConfirmEnabled: Bool = false, confirmDoseAdequate: Bool = true,
        nowMs: Double
    ) -> MealHypothesisState {
        MealHypothesisEngine.step(
            current: s, score: score, eventualBg: eventualBg, targetBg: 100, delta: delta,
            deltaAccl: deltaAccl, deltaDeclining: deltaDeclining, fastConfirmEnabled: fastConfirmEnabled,
            confirmDoseAdequate: confirmDoseAdequate, nowMs: nowMs
        )
    }

    /// A COMMITTED meal at t0, backed off to RECOVERING at +5 and out to IDLE on one negative delta at +10.
    private func troughAfterFirstPhase() -> MealHypothesisState {
        let committed = step(
            MealHypothesisState(state: .committed, committedInSession: true),
            score: 0.6, eventualBg: 200, delta: 6, deltaAccl: 5, nowMs: t0
        )
        XCTAssertEqual(committed.state, .committed)
        let recovering = step(
            committed,
            score: 0.5,
            eventualBg: 180,
            delta: 2,
            deltaAccl: -20,
            deltaDeclining: true,
            nowMs: at(5)
        )
        XCTAssertEqual(recovering.state, .recovering)
        let idle = step(
            recovering,
            score: 0.4,
            eventualBg: 170,
            delta: -1,
            deltaAccl: -5,
            deltaDeclining: true,
            nowMs: at(10)
        )
        XCTAssertEqual(idle.state, .idle)
        return idle
    }

    /// Fast-path signals: sharp, accelerating, corroborated.
    private func fastRise(_ s: MealHypothesisState, at time: Double, eventualBg: Double = 160) -> MealHypothesisState {
        step(s, score: 0.7, eventualBg: eventualBg, delta: 9, deltaAccl: 25, fastConfirmEnabled: true, nowMs: time)
    }

    func testASingleNegativeDeltaBetweenMealPhasesDoesNotReopenTheConfirm() {
        let idle = troughAfterFirstPhase()
        XCTAssertTrue(idle.committedInSession)
        XCTAssertNotEqual(fastRise(idle, at: at(15)).state, .confirmed)
    }

    func testTheFastPathCannotConfirmFromObservingInsideTheLockEither() {
        let idle = troughAfterFirstPhase()
        let observing = step(idle, score: 0.5, eventualBg: 120, delta: 2, deltaAccl: 0, nowMs: at(15))
        XCTAssertEqual(observing.state, .observing)
        // eventualBG offset 10 < 30, so the slow path is not eligible; only the fast path could fire.
        XCTAssertEqual(fastRise(observing, at: at(20), eventualBg: 110).state, .observing)
    }

    func testASecondPhaseThatPassesTheSlowPathGatesReEngagesCommittedNotConfirmed() {
        var s = troughAfterFirstPhase()
        var sawCommitted = false
        for m in [15, 20, 25, 30, 35] {
            s = step(s, score: 0.6, eventualBg: 190, delta: 4, deltaAccl: 5, nowMs: at(m))
            XCTAssertNotEqual(s.state, .confirmed)
            if s.state == .committed { sawCommitted = true }
        }
        XCTAssertTrue(sawCommitted)
        XCTAssertTrue(s.committedInSession)
    }

    func testInsideTheLockARiseThatFailsTheDoseAdequacyGateDoesNotReEngage() {
        var s = troughAfterFirstPhase()
        for m in [15, 20, 25, 30, 35] {
            s = step(s, score: 0.6, eventualBg: 190, delta: 4, deltaAccl: 5, confirmDoseAdequate: false, nowMs: at(m))
        }
        XCTAssertEqual(s.state, .observing)
    }

    func testNinetyMinutesAfterTheLastCommitANewMealCanConfirmAgain() {
        var s = troughAfterFirstPhase()
        // Wobbling glucose so the non-positive run never reaches 30 minutes; only the time bound ends it.
        var m = 15
        while m < 95 {
            s = step(s, score: 0.2, eventualBg: 110, delta: m % 10 == 5 ? 1 : -1, deltaAccl: 0, nowMs: at(m))
            m += 5
        }
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.committedInSession)
        XCTAssertEqual(fastRise(s, at: at(95)).state, .confirmed)
    }

    func testThirtyMinutesOfNonPositiveDeltasEndsTheSessionEarly() {
        var s = troughAfterFirstPhase()
        for m in stride(from: 15, through: 45, by: 5) {
            s = step(s, score: 0.2, eventualBg: 100, delta: -2, deltaAccl: 0, nowMs: at(m))
        }
        XCTAssertFalse(s.committedInSession)
        XCTAssertEqual(fastRise(s, at: at(50)).state, .confirmed)
    }

    func testAResetKeepsTheLockSoAGapOrRestartAfterAConfirmCannotOpenASecondOne() {
        let locked = MealHypothesisState(state: .recovering, ageCycles: 2, committedInSession: true)
        let (reset, did) = MealHypothesisEngine.resetIfNeeded(current: locked, pumpDisconnected: true)
        XCTAssertTrue(did)
        XCTAssertEqual(reset.state, .idle)
        XCTAssertTrue(reset.committedInSession)
    }

    func testDecideAReEngagedCommittedIsNotANewMealSession() {
        let inputs = V5Inputs(
            delta: 4, shortAvgDelta: 4, deltaAccl: 0, bg: 170, eventualBg: 200, targetBg: 100,
            maxDelta: 4, minGuardBg: 150, minGuardThreshold: 80, deltaHistory: [4, 4, 4],
            iob: 1, maxIob: 10, baseInsulinReq: 2, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.9, recentLowBg: 120, cumulativeRise30min: 60, hour: 12,
            exerciseActive: false, inPostExerciseWindow: false, nowMs: at(30)
        )
        let locked = MealHypothesisState(
            state: .observing, ageCycles: 3, maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 90, committedInSession: true, lastAgeMs: at(25)
        )
        let out = BoostV5Engine.decide(inputs, persisted: V5PersistedState(mealHypothesis: locked))
        XCTAssertNotEqual(out.mealHypothesis, .confirmed)
        XCTAssertFalse(out.mealSessionStarted)
    }

    /// With no clock the RECOVERING to IDLE exit clears the lock as before (MealHypothesisFix7Test).
    func testWithNoClockTheExitClearsTheLockAsBefore() {
        let next = MealHypothesisEngine.step(
            current: MealHypothesisState(state: .recovering, ageCycles: 2, committedInSession: true),
            score: 0.5, eventualBg: 170, targetBg: 99, delta: -2, deltaAccl: 15, deltaDeclining: false
        )
        XCTAssertEqual(next.state, .idle)
        XCTAssertFalse(next.committedInSession)
    }

    /// With a clock the same exit keeps the lock (MealHypothesisFix7Test, revised 8 October 2026).
    func testWithAClockTheExitKeepsTheLock() {
        let next = MealHypothesisEngine.step(
            current: MealHypothesisState(state: .recovering, ageCycles: 2, committedInSession: true),
            score: 0.5, eventualBg: 170, targetBg: 99, delta: -2, deltaAccl: 15, deltaDeclining: false,
            nowMs: t0
        )
        XCTAssertEqual(next.state, .idle)
        XCTAssertTrue(next.committedInSession)
    }

    /// A state saved before the session-clock fields existed still decodes, keeping its lock.
    func testAStateWithoutTheNewFieldsDecodesAndKeepsItsLock() throws {
        let json = """
        {"state":"RECOVERING","ageCycles":1,"maxScoreInObserving":0,"maxEventualBgOffsetInObserving":0,
         "committedInSession":true,"lastAgeMs":1800000000000}
        """
        let s = try JSONDecoder().decode(MealHypothesisState.self, from: Data(json.utf8))
        XCTAssertTrue(s.committedInSession)
        XCTAssertEqual(s.lastCommitMs, 0)
        XCTAssertEqual(s.maxScoreAtMs, 0)
        let roundTrip = try JSONDecoder().decode(MealHypothesisState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTrip, s)
    }
}
