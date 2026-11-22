@testable import BoostV5Core
import XCTest

/// V1-acceleration early primer (AAPS 2026-07-20, sizing reworked 2026-07-30).
///
/// A small advance on the commit shot, delivered once per OBSERVING session on an accelerating
/// rise. Additive up to the ceiling; the excess is netted off the commit shot, so a confirmed meal
/// moves insulin earlier rather than adding it.
final class PrimerTests: XCTestCase {
    private let now: Double = 1_700_000_000_000

    /// A qualifying OBSERVING cycle: rise of 6 mg/dL per 5 min, accelerating, glucose in band,
    /// plenty of insulin headroom, awake, no recent low, outside the post-rescue window.
    private func inputs(
        delta: Double = 6, shortAvgDelta: Double? = nil, deltaAccl: Double = 20, bg: Double = 140, iob: Double = 0.5,
        maxIob: Double = 6, recentLowBg: Double = 120, asleep: Bool = false,
        exerciseActive: Bool = false, postRescueWindow: Bool = false,
        primerCapU: Double = 0.6, primerUseTempBasal: Bool = false
    ) -> V5Inputs {
        V5Inputs(
            delta: delta, shortAvgDelta: shortAvgDelta ?? delta - 1, deltaAccl: deltaAccl, bg: bg, eventualBg: bg + 40,
            targetBg: 100, maxDelta: delta, minGuardBg: bg, minGuardThreshold: 80,
            deltaHistory: [2, 4, delta], iob: iob, maxIob: maxIob, baseInsulinReq: 1.0,
            roundSmbTo: 0.05, enableSmbPreChecks: true, mlHypoRisk: nil, mlMealLikely: 0.6,
            recentLowBg: recentLowBg, cumulativeRise30min: 30, hour: 13,
            exerciseActive: exerciseActive, inPostExerciseWindow: false, asleep: asleep,
            postRescueWindow: postRescueWindow, v1WouldDoseU: 0.5,
            primerCapU: primerCapU, primerUseTempBasal: primerUseTempBasal, nowMs: now
        )
    }

    private func observing(age: Int = 1) -> V5PersistedState {
        V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: age))
    }

    // MARK: firing and sizing

    func testFiresInObservingOnAnAcceleratingRise() {
        let d = BoostV5Engine.decide(inputs(), persisted: observing())
        XCTAssertGreaterThan(d.primerBolusU, 0)
        XCTAssertFalse(d.primerScaleDebug.isEmpty)
        XCTAssertEqual(d.newPersistedState.primerAppliedU, d.primerBolusU, accuracy: 1E-12)
    }

    func testTheCapIsATrueCeiling() {
        // Full strength: rise at or above 8, glucose mid-band, almost no insulin on board.
        let d = BoostV5Engine.decide(
            inputs(delta: 12, bg: 150, iob: 0.0, primerCapU: 0.6), persisted: observing()
        )
        XCTAssertLessThanOrEqual(d.primerBolusU, 0.6 + 1E-9)
    }

    func testSizeRisesWithTheRiseAndNotWithAcceleration() {
        let small = BoostV5Engine.decide(inputs(delta: 3.5), persisted: observing()).primerBolusU
        let large = BoostV5Engine.decide(inputs(delta: 8), persisted: observing()).primerBolusU
        XCTAssertGreaterThan(large, small)
        // Acceleration is only a shape confirmer: at the same rise, a much larger deltaAccl must
        // not buy a larger dose. This is the inversion the 2026-07-30 rework removed, where a flat
        // trace scored higher than a genuine rise.
        let sameRiseHighAccl = BoostV5Engine.decide(
            inputs(delta: 6, deltaAccl: 60), persisted: observing()
        ).primerBolusU
        let sameRiseLowAccl = BoostV5Engine.decide(
            inputs(delta: 6, deltaAccl: 11), persisted: observing()
        ).primerBolusU
        XCTAssertEqual(sameRiseHighAccl, sameRiseLowAccl, accuracy: 1E-12)
    }

    func testGlucoseShouldersSuppressNearTargetAndNearTheCeiling() {
        // Below the lower shoulder nothing is delivered, guarding an observed fire at 92 on jitter.
        XCTAssertEqual(BoostV5Engine.decide(inputs(bg: 88), persisted: observing()).primerBolusU, 0)
        // At and above the upper ceiling it fades to nothing, so the primer cannot add into a
        // recovering high-insulin tail.
        XCTAssertEqual(BoostV5Engine.decide(inputs(bg: 225), persisted: observing()).primerBolusU, 0)
    }

    func testInsulinHeadroomScalesAndBoundsTheDose() {
        let roomy = BoostV5Engine.decide(inputs(iob: 0.2, maxIob: 6), persisted: observing()).primerBolusU
        let tight = BoostV5Engine.decide(inputs(iob: 5.5, maxIob: 6), persisted: observing()).primerBolusU
        XCTAssertGreaterThan(roomy, tight)
        // And the dose can never exceed the headroom itself.
        let d = BoostV5Engine.decide(inputs(iob: 5.95, maxIob: 6), persisted: observing())
        XCTAssertLessThanOrEqual(d.primerBolusU, 0.05 + 1E-9)
    }

    // MARK: gates

    func testEveryFloorIndividuallyBlocksThePrimer() {
        XCTAssertEqual(BoostV5Engine.decide(inputs(delta: 2.5), persisted: observing()).primerBolusU, 0)
        // Boost 6.3.0: a sustained rise (short average at least 3) opens it, not acceleration.
        XCTAssertEqual(BoostV5Engine.decide(inputs(shortAvgDelta: 2.9), persisted: observing()).primerBolusU, 0)
        XCTAssertEqual(BoostV5Engine.decide(inputs(recentLowBg: 75), persisted: observing()).primerBolusU, 0)
        XCTAssertEqual(BoostV5Engine.decide(inputs(asleep: true), persisted: observing()).primerBolusU, 0)
        XCTAssertEqual(BoostV5Engine.decide(inputs(exerciseActive: true), persisted: observing()).primerBolusU, 0)
        XCTAssertEqual(BoostV5Engine.decide(inputs(postRescueWindow: true), persisted: observing()).primerBolusU, 0)
        XCTAssertEqual(BoostV5Engine.decide(inputs(primerCapU: 0), persisted: observing()).primerBolusU, 0)
    }

    func testFiresOnASteadyRiseWithoutAcceleration() {
        // AAPS f1d0c93a8e: a steady 5 mg/dL per 5 min rise never met deltaAccl > 10.
        let d = BoostV5Engine.decide(inputs(delta: 5, shortAvgDelta: 5, deltaAccl: 0), persisted: observing())
        XCTAssertGreaterThan(d.primerBolusU, 0)
    }

    func testNoPrimerOnceTheSessionHasCommitted() {
        // AAPS f1d0c93a8e: no primer on a second rise once a meal has been committed.
        var s = observing()
        s.mealHypothesis = MealHypothesisState(state: .observing, ageCycles: 1, committedInSession: true)
        XCTAssertEqual(BoostV5Engine.decide(inputs(), persisted: s).primerBolusU, 0)
    }

    func testFiresOnlyOncePerObservingSession() {
        let first = BoostV5Engine.decide(inputs(), persisted: observing())
        XCTAssertGreaterThan(first.primerBolusU, 0)
        var carried = observing(age: 2)
        carried.primerAppliedU = first.primerBolusU
        XCTAssertEqual(BoostV5Engine.decide(inputs(), persisted: carried).primerBolusU, 0)
    }

    func testTheOnceOnlyGuardResetsOnIdleButTheAccumulatorDoesNot() {
        var carried = V5PersistedState(mealHypothesis: MealHypothesisState(state: .idle))
        carried.primerAppliedU = 0.4
        carried.primerIobU = 0.4
        carried.primerIobUpdatedMs = now
        // Flat, so the state stays IDLE and nothing fires; the guard clears, the estimate survives.
        let d = BoostV5Engine.decide(
            inputs(delta: 0, deltaAccl: 0), persisted: carried
        )
        XCTAssertEqual(d.newPersistedState.primerAppliedU, 0)
        XCTAssertGreaterThan(d.newPersistedState.primerIobU, 0)
    }

    // MARK: routing and netting

    func testBolusRouteFoldsThePrimerIntoTheDeliveredDose() {
        let withPrimer = BoostV5Engine.decide(inputs(primerUseTempBasal: false), persisted: observing())
        let without = BoostV5Engine.decide(inputs(primerCapU: 0), persisted: observing())
        XCTAssertGreaterThan(withPrimer.primerBolusU, 0)
        XCTAssertEqual(withPrimer.finalDose, without.finalDose + withPrimer.primerBolusU, accuracy: 1E-9)
        XCTAssertFalse(withPrimer.primerUseTempBasal)
    }

    func testTempBasalRouteLeavesTheDeliveredDoseAlone() {
        let tbr = BoostV5Engine.decide(inputs(primerUseTempBasal: true), persisted: observing())
        let without = BoostV5Engine.decide(inputs(primerCapU: 0), persisted: observing())
        XCTAssertGreaterThan(tbr.primerBolusU, 0)
        XCTAssertEqual(tbr.finalDose, without.finalDose, accuracy: 1E-12)
        XCTAssertTrue(tbr.primerUseTempBasal)
    }

    func testAccumulatedPrimerBeyondOneBaseIsNettedOffTheCommitShot() {
        // The residual is set at the CONFIRMED transition, so the session must confirm on this
        // cycle. Two fizzled sessions have left 1.0 U of primer insulin on board against a 0.6 U
        // ceiling, so 0.4 U is owed back and must come off the commit shot. `primerAppliedU` is
        // pre-set so the primer does not also fire this cycle and muddy the arithmetic.
        func confirming(primerIob: Double) -> V5PersistedState {
            var st = V5PersistedState(
                mealHypothesis: MealHypothesisState(
                    state: .observing, ageCycles: 3,
                    maxScoreInObserving: 1.0, maxEventualBgOffsetInObserving: 90
                )
            )
            st.primerIobU = primerIob
            st.primerIobUpdatedMs = now
            st.primerAppliedU = 0.4
            st.lastCycleScore = 1.0
            return st
        }
        let netted = BoostV5Engine.decide(inputs(primerCapU: 0.6), persisted: confirming(primerIob: 1.0))
        let clean = BoostV5Engine.decide(inputs(primerCapU: 0.6), persisted: confirming(primerIob: 0))
        XCTAssertEqual(netted.mealHypothesis, .confirmed, "precondition: the session confirms")
        XCTAssertEqual(clean.mealHypothesis, .confirmed)

        XCTAssertLessThan(netted.finalDose, clean.finalDose)
        XCTAssertEqual(clean.finalDose - netted.finalDose, 0.4, accuracy: 1E-9)
        // The credited excess is consumed, so a later meal cannot claim it again.
        XCTAssertEqual(netted.newPersistedState.primerIobU, 0.6, accuracy: 1E-9)
        XCTAssertEqual(netted.newPersistedState.primerNettingResidualU, 0, accuracy: 1E-9)
    }

    func testAResidualCarriedIntoCommittedIsSpentThere() {
        // Set at the confirm, spent down across the holds that follow.
        var carried = V5PersistedState(mealHypothesis: MealHypothesisState(state: .committed, ageCycles: 5))
        carried.primerNettingResidualU = 0.2
        let netted = BoostV5Engine.decide(inputs(), persisted: carried)

        let clean = BoostV5Engine.decide(
            inputs(), persisted: V5PersistedState(mealHypothesis: MealHypothesisState(state: .committed, ageCycles: 5))
        )
        XCTAssertEqual(clean.finalDose - netted.finalDose, 0.2, accuracy: 1E-9)
        XCTAssertEqual(netted.newPersistedState.primerNettingResidualU, 0, accuracy: 1E-9)
    }

    func testTheAccumulatorDecaysWithWallClock() {
        var carried = V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 1))
        carried.primerIobU = 1.0
        carried.primerIobUpdatedMs = now - 90 * 60000 // one time constant ago
        carried.primerAppliedU = 0.4 // already primed, so nothing is added this cycle
        let d = BoostV5Engine.decide(inputs(), persisted: carried)
        // exp(-1) of a unit, to within rounding.
        XCTAssertEqual(d.newPersistedState.primerIobU, 0.3679, accuracy: 0.001)
    }

    func testNettingNeverDrivesTheDoseNegative() {
        var carried = V5PersistedState(mealHypothesis: MealHypothesisState(state: .committed, ageCycles: 5))
        carried.primerNettingResidualU = 99
        let d = BoostV5Engine.decide(inputs(), persisted: carried)
        XCTAssertGreaterThanOrEqual(d.finalDose, 0)
        // The unspent remainder is carried forward rather than discarded.
        XCTAssertGreaterThan(d.newPersistedState.primerNettingResidualU, 0)
    }

    func testTelemetryIsEmittedEvenWhenTheDoseRoundsToNothing() {
        // The gate opens but the glucose factor sizes it to nearly zero, so it rounds away. A
        // reader must still be able to tell that the gate opened.
        let d = BoostV5Engine.decide(inputs(delta: 3.1, shortAvgDelta: 3.0, bg: 91), persisted: observing())
        XCTAssertEqual(d.primerBolusU, 0)
        XCTAssertFalse(d.primerScaleDebug.isEmpty)
    }
}
