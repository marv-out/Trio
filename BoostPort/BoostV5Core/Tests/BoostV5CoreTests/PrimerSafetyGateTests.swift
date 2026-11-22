@testable import BoostV5Core
import XCTest

/// Primer safety gates (AAPS c237a4d081, audit item 10, engine part; port of PrimerSafetyGateTest).
///
/// The primer was sized before Phase 3 and ignored its hard gates, so it dosed on cycles where both
/// floors and the pipeline dose were zero because the 30-minute minGuardBG was under the low
/// threshold. It also ignored mlHypoRisk, which damps the aggression budget, and in bolus mode it
/// made the whole final dose of an OBSERVING cycle exempt from the override seam's V1 bound.
final class PrimerSafetyGateTests: XCTestCase {
    /// The primer base cycle: OBSERVING age 0, a real rise, every floor clear.
    private func base() -> V5Inputs {
        V5Inputs(
            delta: 6, shortAvgDelta: 5, deltaAccl: 15, bg: 140, eventualBg: 150, targetBg: 100,
            maxDelta: 6, minGuardBg: 135, minGuardThreshold: 80, deltaHistory: [4, 5, 6],
            iob: 0, maxIob: 8, baseInsulinReq: 1, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.5, recentLowBg: 120, cumulativeRise30min: 30, hour: 12,
            exerciseActive: false, inPostExerciseWindow: false, asleep: false, postRescueWindow: false,
            primerCapU: 0.5, primerUseTempBasal: false,
            confirmedCapU: 4.0, committedCapU: 1.5
        )
    }

    private func observing() -> V5PersistedState {
        V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 0))
    }

    func testPreconditionTheBaseCyclePrimes() {
        XCTAssertGreaterThan(BoostV5Engine.decide(base(), persisted: observing()).primerBolusU, 0)
    }

    func testNoPrimerWhenTheMinGuardBgHardGateFired() {
        var i = base()
        i.minGuardBg = 70
        let d = BoostV5Engine.decide(i, persisted: observing())
        XCTAssertEqual(d.phase3.reductions.hardGateFired, "min_guard_bg")
        XCTAssertEqual(d.primerBolusU, 0)
        XCTAssertEqual(d.finalDose, 0)
    }

    func testNoPrimerWhenSmbPreChecksFail() {
        var i = base()
        i.enableSmbPreChecks = false
        let d = BoostV5Engine.decide(i, persisted: observing())
        XCTAssertEqual(d.primerBolusU, 0)
        XCTAssertEqual(d.finalDose, 0)
    }

    func testNoTempBasalPrimerEitherWhenAHardGateFired() {
        var i = base()
        i.minGuardBg = 70
        i.primerUseTempBasal = true
        XCTAssertEqual(BoostV5Engine.decide(i, persisted: observing()).primerBolusU, 0)
    }

    func testTheOncePerSessionGuardIsNotSpentByAGatedCycle() {
        var i = base()
        i.minGuardBg = 70
        let d = BoostV5Engine.decide(i, persisted: observing())
        XCTAssertEqual(d.newPersistedState.primerAppliedU, 0)
        XCTAssertEqual(d.newPersistedState.primerIobU, 0)
    }

    func testElevatedMlHypoRiskScalesThePrimerDownAsItDoesTheBudget() {
        let clear = BoostV5Engine.decide(base(), persisted: observing()).primerBolusU
        var i = base()
        i.mlHypoRisk = 0.8
        let risky = BoostV5Engine.decide(i, persisted: observing()).primerBolusU
        XCTAssertLessThan(risky, clear)
        XCTAssertLessThanOrEqual(risky, clear * AggressionBudgetEngine.mlHypoRiskScale(0.8) + 1E-9)
    }

    func testLowMlHypoRiskLeavesThePrimerUnchanged() {
        let clear = BoostV5Engine.decide(base(), persisted: observing()).primerBolusU
        var i = base()
        i.mlHypoRisk = 0.2
        XCTAssertEqual(BoostV5Engine.decide(i, persisted: observing()).primerBolusU, clear)
    }

    func testBolusModeOnlyThePrimerEscapesTheV1BoundAndTheObservingDoseDoesNot() {
        // V1 would dose nothing this cycle; the OBSERVING pipeline dose on its own would be capped to
        // 0 at the seam, but the seam exempts the whole final dose once a bolus primer is present.
        var withV1Zero = base()
        withV1Zero.v1WouldDoseU = 0
        withV1Zero.baseInsulinReq = 2
        var noPrimerInputs = withV1Zero
        noPrimerInputs.primerCapU = 0
        XCTAssertGreaterThan(BoostV5Engine.decide(noPrimerInputs, persisted: observing()).finalDose, 0)
        let d = BoostV5Engine.decide(withV1Zero, persisted: observing())
        XCTAssertGreaterThan(d.primerBolusU, 0)
        XCTAssertEqual(d.finalDose, d.primerBolusU, accuracy: 1E-9)
    }

    func testBolusModeAV1DoseAboveThePipelineDoseLeavesItUnbounded() {
        var generousV1 = base()
        generousV1.v1WouldDoseU = 5
        generousV1.baseInsulinReq = 2
        var noPrimerInputs = generousV1
        noPrimerInputs.primerCapU = 0
        let noPrimer = BoostV5Engine.decide(noPrimerInputs, persisted: observing())
        let d = BoostV5Engine.decide(generousV1, persisted: observing())
        XCTAssertEqual(d.finalDose, noPrimer.finalDose + d.primerBolusU, accuracy: 1E-9)
    }
}
