@testable import BoostV5Core
import XCTest

/// Stale meal-state evidence (AAPS c237a4d081, audit item 17; port of StaleMealStateTest and
/// ScoreStreakCadenceTest).
///
/// The OBSERVING peaks never expired, the persisted state was restored with no age check and the
/// confirm test ran before the fall-back test, so evidence from hours earlier could CONFIRM on a
/// cycle whose own glucose did not support it (the AAPS audit harness produced 1.4 U three hours
/// after a restore). Separately, the sustained-score streak counted invocations rather than time.
final class StaleMealStateTests: XCTestCase {
    private let t0: Double = 1_800_000_000_000
    private func at(_ m: Int) -> Double { t0 + Double(m) * 60000 }
    private func sec(_ s: Int) -> Double { t0 + Double(s) * 1000 }

    /// A moderate cycle: score between the fall-back and confirm bars, eventualBG only 10 over target.
    private func moderateCycle(_ now: Double) -> V5Inputs {
        V5Inputs(
            delta: 3, shortAvgDelta: 3, deltaAccl: 0, bg: 140, eventualBg: 110, targetBg: 100,
            maxDelta: 3, minGuardBg: 120, minGuardThreshold: 80, deltaHistory: [3, 3, 3],
            iob: 0.5, maxIob: 10, baseInsulinReq: 1.5, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.6, recentLowBg: 120, cumulativeRise30min: 18, hour: 12,
            exerciseActive: false, inPostExerciseWindow: false, nowMs: now
        )
    }

    /// OBSERVING past the age gate with high peaks, as it was saved at t0.
    private func savedAtT0() -> V5PersistedState {
        V5PersistedState(mealHypothesis: MealHypothesisState(
            state: .observing, ageCycles: 3, maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 80, committedInSession: false, lastAgeMs: at(0)
        ))
    }

    private func step(
        _ s: MealHypothesisState, score: Double, eventualBg: Double, delta: Double,
        confirmDoseAdequate: Bool = true, nowMs: Double = 0
    ) -> MealHypothesisState {
        MealHypothesisEngine.step(
            current: s, score: score, eventualBg: eventualBg, targetBg: 100, delta: delta,
            deltaAccl: delta == 6 ? 5 : 0, deltaDeclining: false, confirmDoseAdequate: confirmDoseAdequate,
            nowMs: nowMs
        )
    }

    func testAStateRestoredThreeHoursOldIsResetRatherThanConfirmedOnItsOldPeaks() {
        let d = BoostV5Engine.decide(moderateCycle(at(180)), persisted: savedAtT0())
        XCTAssertNotEqual(d.mealHypothesis, .confirmed)
        XCTAssertTrue(d.stateReset)
    }

    func testTheSameStateSavedFourMinutesAgoIsNotReset() {
        XCTAssertFalse(BoostV5Engine.decide(moderateCycle(at(4)), persisted: savedAtT0()).stateReset)
    }

    func testFallBackIsTestedBeforeConfirmSoACollapsedScoreCannotConfirmOnPeaks() {
        let observing = MealHypothesisState(
            state: .observing, ageCycles: 2, maxScoreInObserving: 0.7, maxEventualBgOffsetInObserving: 80
        )
        XCTAssertEqual(step(observing, score: 0.30, eventualBg: 105, delta: 0).state, .idle)
    }

    func testPeaksOlderThanTheWindowNoLongerCountTowardsTheConfirm() {
        // Strong entry at t0, then moderate cycles during which the dose-adequacy gate holds the
        // confirm back. When the gate opens 40 minutes later the entry peaks have expired.
        var s = step(MealHypothesisState(), score: 0.7, eventualBg: 180, delta: 6, nowMs: at(0))
        XCTAssertEqual(s.state, .observing)
        for m in stride(from: 5, through: 35, by: 5) {
            s = step(s, score: 0.45, eventualBg: 110, delta: 2, confirmDoseAdequate: false, nowMs: at(m))
            XCTAssertEqual(s.state, .observing)
        }
        XCTAssertEqual(step(s, score: 0.45, eventualBg: 110, delta: 2, nowMs: at(40)).state, .observing)
    }

    func testPeaksInsideTheWindowStillConfirmAsFix1AndFix5Intend() {
        var s = step(MealHypothesisState(), score: 0.7, eventualBg: 180, delta: 6, nowMs: at(0))
        for m in [5, 10] {
            s = step(s, score: 0.45, eventualBg: 110, delta: 2, nowMs: at(m))
        }
        XCTAssertEqual(step(s, score: 0.45, eventualBg: 110, delta: 2, nowMs: at(15)).state, .confirmed)
    }

    // MARK: score streak counted in time (V6 review item 6)

    /// A cycle whose own score is confirm-strength and whose eventualBG is well over target.
    private func strong(_ now: Double) -> V5Inputs {
        V5Inputs(
            delta: 8, shortAvgDelta: 7, deltaAccl: 5, bg: 160, eventualBg: 220, targetBg: 100,
            maxDelta: 8, minGuardBg: 150, minGuardThreshold: 80, deltaHistory: [6, 7, 8],
            iob: 0.5, maxIob: 10, baseInsulinReq: 2, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.95, recentLowBg: 120, cumulativeRise30min: 60, hour: 12,
            exerciseActive: false, inPostExerciseWindow: false, nowMs: now
        )
    }

    /// OBSERVING at age 1, one tick short of the standard gate, so only the early path can confirm.
    private func observingAge1(lastAgeMs: Double) -> V5PersistedState {
        V5PersistedState(mealHypothesis: MealHypothesisState(
            state: .observing, ageCycles: 1, maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 100, lastAgeMs: lastAgeMs
        ))
    }

    func testPreconditionTheStrongCycleScoresAtConfirmStrength() {
        let d = BoostV5Engine.decide(strong(sec(0)), persisted: observingAge1(lastAgeMs: sec(0)))
        XCTAssertGreaterThanOrEqual(d.score, MealHypothesisConstants.confirmScore)
    }

    func testAReInvokeThirtySecondsLaterDoesNotCountAsASecondCycle() {
        let first = BoostV5Engine.decide(strong(sec(0)), persisted: observingAge1(lastAgeMs: sec(-60)))
        XCTAssertEqual(first.mealHypothesis, .observing)
        let second = BoostV5Engine.decide(strong(sec(30)), persisted: first.newPersistedState)
        XCTAssertEqual(second.mealHypothesis, .observing)
    }

    func testOnAOneMinuteLoopTheEarlyPathWaitsForFourMinutesOfConfirmStrengthScores() {
        var p = observingAge1(lastAgeMs: sec(-60))
        var states: [MealHypothesis] = []
        for m in 0 ... 4 {
            let d = BoostV5Engine.decide(strong(sec(m * 60)), persisted: p)
            states.append(d.mealHypothesis)
            p = d.newPersistedState
            if d.mealHypothesis == .confirmed { break }
        }
        // Minutes 0 to 3 are under four minutes of run; the age tick (also four minutes) and the
        // streak open together at minute 4.
        XCTAssertFalse(states.prefix(4).contains(.confirmed))
        XCTAssertEqual(states.last, .confirmed)
    }

    func testOnAFiveMinuteLoopThePreviousCycleStillCountsAsBefore() {
        // Start from age 0 so that the standard age gate cannot be what confirms.
        let fresh = V5PersistedState(mealHypothesis: MealHypothesisState(
            state: .observing, ageCycles: 0, maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 100, lastAgeMs: sec(-300)
        ))
        let a = BoostV5Engine.decide(strong(sec(0)), persisted: fresh)
        XCTAssertEqual(a.mealHypothesis, .observing)
        let b = BoostV5Engine.decide(strong(sec(300)), persisted: a.newPersistedState)
        // Age 1 with a streak from the previous five-minute cycle: the early path confirms.
        XCTAssertEqual(b.mealHypothesis, .confirmed)
    }
}
