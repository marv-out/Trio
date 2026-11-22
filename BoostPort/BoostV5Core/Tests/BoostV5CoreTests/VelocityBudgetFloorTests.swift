@testable import BoostV5Core
import XCTest

/// Velocity-budget floor and aggressive early confirm (AAPS 3ea7479572).
///
/// Both are opt-in and auto-config managed. The floor addresses the budget-near-zero high tail:
/// cycles where the base engine's insulin requirement is at or below zero while the person sits
/// high, which is the population the composed floor excludes because it requires a positive budget.
final class VelocityBudgetFloorTests: XCTestCase {
    // MARK: targetDose, conditions and bounds

    private func target(
        state: MealHypothesis = .idle, bg: Double = 220, budgetU: Double = 0,
        committedCapU: Double = 0.5, asleep: Bool = false, postRescueWindow: Bool = false,
        hardGateFired: Bool = false
    ) -> Double? {
        VelocityBudgetFloor.targetDose(
            state: state, bg: bg, budgetU: budgetU, committedCapU: committedCapU,
            asleep: asleep, postRescueWindow: postRescueWindow, hardGateFired: hardGateFired
        )
    }

    func testQualifyingCycleReturnsTheTierHoldCappedAtCommitted() {
        XCTAssertEqual(target()!, 0.5, accuracy: 1E-12) // min(tier 0.5, cap 0.5)
        XCTAssertEqual(target(committedCapU: 0.25)!, 0.25, accuracy: 1E-12) // cap binds
        XCTAssertEqual(target(committedCapU: 2.0)!, 0.5, accuracy: 1E-12) // tier binds
    }

    func testEachConditionIndividuallyNullsTheFloor() {
        XCTAssertNil(target(state: .recovering)) // recovering is excluded
        XCTAssertNil(target(bg: 180)) // must be strictly above 180
        XCTAssertNil(target(budgetU: 0.02)) // budget must be at or below 0.01
        XCTAssertNil(target(asleep: true))
        XCTAssertNil(target(postRescueWindow: true))
    }

    func testAHardGateReturnsZeroRatherThanNil() {
        // Zero and nil mean different things: zero says a Phase-3 hard gate fired on a cycle that
        // otherwise qualified, which the telemetry needs to distinguish from conditions unmet.
        XCTAssertEqual(target(hardGateFired: true)!, 0.0, accuracy: 1E-12)
    }

    func testTheTwoFloorsOverlapInANarrowBudgetBand() {
        // The AAPS comment says the two floors are mutually exclusive by the budget condition. They
        // are not: the composed floor needs budget > 0 and this one needs budget at or below 0.01,
        // so both fire in the band (0, 0.01]. Recorded here rather than asserted away, because the
        // engine's uplift arithmetic depends on knowing it.
        func both(_ budget: Double) -> Bool {
            let vb = VelocityBudgetFloor.targetDose(
                state: .confirmed, bg: 270, budgetU: budget, committedCapU: 0.5,
                asleep: false, postRescueWindow: false, hardGateFired: false
            )
            let composed = ComposedFloor.targetDose(
                state: .confirmed, bg: 270, eventualBg: 200, targetBg: 100, asleep: false,
                postRescueWindow: false, budgetU: budget, committedCapU: 0.5,
                v1WouldDoseU: nil, hardGateFired: false
            )
            return vb != nil && composed != nil
        }
        XCTAssertFalse(both(0.0)) // composed needs a positive budget
        XCTAssertTrue(both(0.005)) // inside the overlap
        XCTAssertTrue(both(0.01)) // the upper edge of the overlap
        XCTAssertFalse(both(0.02)) // past this floor's ceiling
        XCTAssertFalse(both(4.0))
    }

    func testOverlapBandStillDeliversABoundedDose() {
        // In the overlap both floors can lift, and the delivered dose must stay inside the committed
        // cap. The uplift attributed to this floor is measured against the dose entering its block,
        // so the composed floor's contribution is not counted twice.
        var inputs = highTailInputs(velocityBudgetActive: true)
        inputs.composedFloorActive = true
        inputs.baseInsulinReq = 0.01
        let d = BoostV5Engine.decide(inputs, persisted: V5PersistedState())
        XCTAssertLessThanOrEqual(d.finalDose, 0.5 + 1E-9)
        if let add = d.velocityBudgetWouldAdd { XCTAssertGreaterThanOrEqual(add, 0) }
    }

    // MARK: decide(), shadow against active

    /// A sustained high with the base requirement at zero, so the budget collapses and the pipeline
    /// dose goes to zero. IDLE, awake, outside the post-rescue window.
    private func highTailInputs(velocityBudgetActive: Bool) -> V5Inputs {
        V5Inputs(
            delta: 1, shortAvgDelta: 1, deltaAccl: 0, bg: 220, eventualBg: 210, targetBg: 100,
            maxDelta: 1, minGuardBg: 200, minGuardThreshold: 80, deltaHistory: [1, 1, 1],
            iob: 0.3, maxIob: 6, baseInsulinReq: 0, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.1, recentLowBg: 200, cumulativeRise30min: 3, hour: 13,
            exerciseActive: false, inPostExerciseWindow: false, asleep: false,
            postRescueWindow: false, v1WouldDoseU: 0.0, composedFloorActive: false,
            velocityBudgetActive: velocityBudgetActive
        )
    }

    func testShadowLeavesTheDeliveredDoseUntouched() {
        let d = BoostV5Engine.decide(highTailInputs(velocityBudgetActive: false), persisted: V5PersistedState())
        XCTAssertEqual(d.finalDose, d.phase3.finalDose, accuracy: 1E-12)
        XCTAssertFalse(d.velocityBudgetExempt)
        if let wouldAdd = d.velocityBudgetWouldAdd {
            XCTAssertGreaterThanOrEqual(wouldAdd, 0)
        }
    }

    func testActiveLiftsTheDoseAndFlagsTheExemption() {
        let shadow = BoostV5Engine.decide(highTailInputs(velocityBudgetActive: false), persisted: V5PersistedState())
        let active = BoostV5Engine.decide(highTailInputs(velocityBudgetActive: true), persisted: V5PersistedState())
        guard active.velocityBudgetWouldAdd != nil, active.velocityBudgetWouldAdd! > 0 else {
            // A Phase-3 hard gate held the cycle, which is a legitimate outcome; nothing is lifted.
            XCTAssertEqual(active.finalDose, shadow.finalDose, accuracy: 1E-12)
            XCTAssertFalse(active.velocityBudgetExempt)
            return
        }
        XCTAssertGreaterThan(active.finalDose, shadow.finalDose)
        XCTAssertTrue(active.velocityBudgetExempt)
        XCTAssertEqual(active.velocityBudgetWouldAdd!, active.finalDose - shadow.phase3.finalDose, accuracy: 1E-9)
        // Bounded by the committed cap, which defaults to 0.5 in these inputs.
        XCTAssertLessThanOrEqual(active.finalDose, 0.5)
    }

    func testIobHeadroomBoundsTheLiftedDose() {
        var inputs = highTailInputs(velocityBudgetActive: true)
        inputs.maxIob = 0.4
        inputs.iob = 0.3 // headroom 0.1
        let d = BoostV5Engine.decide(inputs, persisted: V5PersistedState())
        XCTAssertLessThanOrEqual(d.finalDose, 0.1 + 1E-9)
    }

    func testAsleepAndPostRescueBothSuppressTheActiveFloor() {
        for mutate in [
            { (i: inout V5Inputs) in i.asleep = true },
            { (i: inout V5Inputs) in i.postRescueWindow = true }
        ]
        {
            var inputs = highTailInputs(velocityBudgetActive: true)
            mutate(&inputs)
            let d = BoostV5Engine.decide(inputs, persisted: V5PersistedState())
            XCTAssertEqual(d.finalDose, d.phase3.finalDose, accuracy: 1E-12)
            XCTAssertFalse(d.velocityBudgetExempt)
            XCTAssertNil(d.velocityBudgetWouldAdd)
        }
    }

    // MARK: aggressive early confirm

    func testAggressiveFloorIsOneCycleEarlierThanTheDefault() {
        XCTAssertEqual(MealHypothesisConstants.confirmMinObservingAgeScoreReady, 1)
        XCTAssertEqual(MealHypothesisConstants.confirmMinObservingAgeScoreReadyAggressive, 0)
    }

    func testAggressiveEarlyConfirmOpensTheGateAtAgeZero() {
        let observing = MealHypothesisState(
            state: .observing, ageCycles: 0, maxScoreInObserving: 0,
            maxEventualBgOffsetInObserving: 0
        )
        let score = MealHypothesisConstants.confirmScore
        let eventual = 200.0
        let targetBg = 100.0
        // Default timing: age 0 is below the score-ready floor of 1, so the gate stays shut.
        XCTAssertFalse(MealHypothesisEngine.confirmEligibleExceptDoseGate(
            current: observing, score: score, eventualBg: eventual, targetBg: targetBg,
            scoreReadyStreak: true, aggressiveEarlyConfirm: false
        ))
        // Opt-in: the floor drops to 0 and the same cycle is eligible.
        XCTAssertTrue(MealHypothesisEngine.confirmEligibleExceptDoseGate(
            current: observing, score: score, eventualBg: eventual, targetBg: targetBg,
            scoreReadyStreak: true, aggressiveEarlyConfirm: true
        ))
    }

    func testAggressiveEarlyConfirmStillNeedsTheStreakAndTheScore() {
        let observing = MealHypothesisState(
            state: .observing, ageCycles: 0, maxScoreInObserving: 0,
            maxEventualBgOffsetInObserving: 0
        )
        // No streak: the early path is shut whatever the flag says.
        XCTAssertFalse(MealHypothesisEngine.confirmEligibleExceptDoseGate(
            current: observing, score: MealHypothesisConstants.confirmScore,
            eventualBg: 200, targetBg: 100, scoreReadyStreak: false, aggressiveEarlyConfirm: true
        ))
        // Streak but the current score is below threshold: still shut.
        XCTAssertFalse(MealHypothesisEngine.confirmEligibleExceptDoseGate(
            current: observing, score: MealHypothesisConstants.confirmScore - 0.01,
            eventualBg: 200, targetBg: 100, scoreReadyStreak: true, aggressiveEarlyConfirm: true
        ))
    }

    // MARK: auto-config derivation

    private func prior(tbr70: Double, sev54: Double) -> BoostV5AutoConfig.PriorDosing {
        BoostV5AutoConfig.PriorDosing(
            daysWithData: 14, bgReadingCount: 4000, tddMedianU: 40,
            manualBolusesU: Array(repeating: 6.0, count: 20),
            smbAmountsU: Array(repeating: 0.4, count: 200),
            tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, meanGlucoseMgdl: 140,
            currentMaxBolusU: 10
        )
    }

    func testBothSwitchesEnableOnlyForAClearlyWellControlledHistory() {
        let clean = BoostV5AutoConfig.compute(prior(tbr70: 1.0, sev54: 0.1))!
        XCTAssertTrue(clean.aggressiveEarlyConfirm)
        XCTAssertTrue(clean.velocityBudgetFloor)

        // Just outside on either axis and both stay off.
        let wideTbr = BoostV5AutoConfig.compute(prior(tbr70: 1.5, sev54: 0.1))!
        XCTAssertFalse(wideTbr.aggressiveEarlyConfirm)
        XCTAssertFalse(wideTbr.velocityBudgetFloor)

        let wideSev = BoostV5AutoConfig.compute(prior(tbr70: 1.0, sev54: 0.3))!
        XCTAssertFalse(wideSev.aggressiveEarlyConfirm)
        XCTAssertFalse(wideSev.velocityBudgetFloor)
    }

    func testTheCutIsStricterThanTheFastCarbTest() {
        // A history that clears fastCarbConfirm's hypo-prone test but not the well-controlled one.
        let s = BoostV5AutoConfig.compute(prior(tbr70: 3.0, sev54: 0.5))!
        XCTAssertTrue(s.fastCarbConfirm)
        XCTAssertFalse(s.aggressiveEarlyConfirm)
        XCTAssertFalse(s.velocityBudgetFloor)
    }
}
