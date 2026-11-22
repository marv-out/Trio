@testable import BoostV5Core
import XCTest

/// Announced-meal route (AAPS 82f47416c5, port of MealAnnouncedTest).
///
/// A meal announced by carbs on board or a recent manual or wizard bolus confirms into COMMITTED
/// rather than CONFIRMED, so oref's insulinReq, which already nets the pre-bolus and the carbs, is
/// not multiplied by the 1.8x catch-up. The AAPS field case: TDD about 20 U, 1.5 U pre-bolus, 24 g
/// entered, insulinReq 0.93 U, CONFIRMED delivered 1.25 U and glucose reached 74 within 45 minutes.
final class MealAnnouncedTests: XCTestCase {
    /// The reported cycle, approximately: rising after a covered meal, confirm-eligible.
    private func reportedCycle(announced: Bool) -> V5Inputs {
        V5Inputs(
            delta: 5, shortAvgDelta: 4, deltaAccl: 5, bg: 155, eventualBg: 190, targetBg: 100,
            maxDelta: 5, minGuardBg: 120, minGuardThreshold: 80, deltaHistory: [3, 4, 5],
            iob: 1.6, maxIob: 6, baseInsulinReq: 0.93, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.6, recentLowBg: 120,
            // Velocity factor 0.748, which reproduces the reported 1.25 U.
            cumulativeRise30min: 39.5, hour: 9, exerciseActive: false, inPostExerciseWindow: false,
            asleep: false, postRescueWindow: false,
            confirmedCapU: 2.5, committedCapU: 0.5, mealAnnounced: announced
        )
    }

    /// OBSERVING past the age gate with peak score and offset already over the confirm bar.
    private func readyToConfirm() -> V5PersistedState {
        V5PersistedState(mealHypothesis: MealHypothesisState(
            state: .observing, ageCycles: 2, maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 60, committedInSession: false
        ))
    }

    func testUnannouncedTheReportedCycleStillConfirmsWithTheCatchUpShot() {
        let d = BoostV5Engine.decide(reportedCycle(announced: false), persisted: readyToConfirm())
        XCTAssertEqual(d.mealHypothesis, .confirmed)
        XCTAssertEqual(d.insulinToDeliver, 0.93 * 1.8 * 0.748, accuracy: 0.01)
        XCTAssertTrue(d.mealSessionStarted)
    }

    func testAnnouncedTheSameCycleCommitsAtOrefsRequirementUnderTheCommittedCap() {
        let plain = BoostV5Engine.decide(reportedCycle(announced: false), persisted: readyToConfirm())
        let d = BoostV5Engine.decide(reportedCycle(announced: true), persisted: readyToConfirm())
        XCTAssertEqual(d.mealHypothesis, .committed)
        XCTAssertEqual(d.actionMultiplier, 1.0)
        XCTAssertLessThanOrEqual(d.insulinToDeliver, 0.5)
        XCTAssertLessThanOrEqual(d.insulinToDeliver, 0.93)
        XCTAssertLessThan(d.finalDose, plain.finalDose)
        // Still a session start, so the meal-time learner records it and the lock is set.
        XCTAssertTrue(d.mealSessionStarted)
        XCTAssertTrue(d.newPersistedState.mealHypothesis.committedInSession)
    }

    func testAnnouncedMealsTakeTheFastPathIntoCommittedAsWell() {
        let fromIdle = MealHypothesisEngine.step(
            current: MealHypothesisState(), score: 0.8, eventualBg: 200, targetBg: 100, delta: 9,
            deltaAccl: 20, deltaDeclining: false, fastConfirmEnabled: true, mealAnnounced: true
        )
        XCTAssertEqual(fromIdle.state, .committed)
        XCTAssertTrue(fromIdle.committedInSession)
        let unannounced = MealHypothesisEngine.step(
            current: MealHypothesisState(), score: 0.8, eventualBg: 200, targetBg: 100, delta: 9,
            deltaAccl: 20, deltaDeclining: false, fastConfirmEnabled: true
        )
        XCTAssertEqual(unannounced.state, .confirmed)
    }

    func testCarbsOnBoardAloneDoNotMoveIdle() {
        let s = MealHypothesisEngine.step(
            current: MealHypothesisState(), score: 0.1, eventualBg: 150, targetBg: 100, delta: 0,
            deltaAccl: 0, deltaDeclining: false, mealAnnounced: true
        )
        XCTAssertEqual(s.state, .idle)
    }

    func testAnAnnouncedMealCannotConfirmLaterInTheSameSession() {
        let committed = MealHypothesisEngine.step(
            current: readyToConfirm().mealHypothesis, score: 0.7, eventualBg: 190, targetBg: 100, delta: 5,
            deltaAccl: 5, deltaDeclining: false, mealAnnounced: true
        )
        // Re-entering OBSERVING with the lock still set (the Fix 6 persistence-race shape).
        var reEntered = committed
        reEntered.state = .observing
        reEntered.ageCycles = 3
        reEntered.maxScoreInObserving = 0.8
        reEntered.maxEventualBgOffsetInObserving = 80
        let next = MealHypothesisEngine.step(
            current: reEntered, score: 0.8, eventualBg: 200, targetBg: 100, delta: 6,
            deltaAccl: 8, deltaDeclining: false, mealAnnounced: false
        )
        XCTAssertNotEqual(next.state, .confirmed)
    }

    func testSessionStartExcludesContinuationsOfASession() {
        let idle = MealHypothesisState()
        let observing = MealHypothesisState(state: .observing)
        let confirmed = MealHypothesisState(state: .confirmed, committedInSession: true)
        let committed = MealHypothesisState(state: .committed, committedInSession: true)
        let recovering = MealHypothesisState(state: .recovering, committedInSession: true)
        let f = BoostV5Engine.sessionCommittedThisCycle
        XCTAssertTrue(f(observing, confirmed))
        XCTAssertTrue(f(idle, confirmed))
        XCTAssertTrue(f(observing, committed))
        XCTAssertTrue(f(idle, committed))
        XCTAssertFalse(f(confirmed, committed))
        XCTAssertFalse(f(recovering, committed))
        XCTAssertFalse(f(committed, committed))
        XCTAssertFalse(f(idle, observing))
    }

    func testNoPrimerOnAnAnnouncedMeal() {
        var rise = reportedCycle(announced: true)
        rise.delta = 6
        rise.deltaAccl = 15
        rise.bg = 140
        rise.iob = 1.0
        rise.maxIob = 8
        rise.primerCapU = 0.3
        let observing = V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 0))
        XCTAssertEqual(BoostV5Engine.decide(rise, persisted: observing).primerBolusU, 0)
        rise.mealAnnounced = false
        XCTAssertGreaterThan(BoostV5Engine.decide(rise, persisted: observing).primerBolusU, 0)
    }
}
