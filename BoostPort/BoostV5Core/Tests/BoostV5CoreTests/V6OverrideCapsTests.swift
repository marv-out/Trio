@testable import BoostV5Core
import XCTest

/// 2026-07-04 post-rescue meal-state cap — pure-function tests of the V6-override dose caps
/// (`SafetyGates.applyV6OverrideCaps`, port of AAPS `OpenAPSBoostPlugin.applyV6OverrideCaps`,
/// commits 5b5026e10b + c306241a35).
///
/// Incident 2026-07-03 19:47 BST (AAPS): severe hypo (nadir 40) → unannounced rescue carbs →
/// rebound. V6 CONFIRMED at BG 119 delivered 2.7U while V1's 45-min post-rescue tier guard had
/// restrained the base engine to 1.05U; the meal-state exemption discarded that restraint. Inside
/// the post-rescue window (45-min low < 75) the exemption is now suppressed, so
/// CONFIRMED/COMMITTED inherit the base engine's hypo-restrained dose. DB backtest 2026-07-04:
/// 27% of removed insulin sits ahead of a second low <70 (vs 14-19% for other levers); cost 10%
/// genuine post-hypo meals at 0.15U median under-delivery.
final class V6OverrideCapsTests: XCTestCase {
    // The 2026-07-03 incident numbers: V6 wanted 2.7U, hypo-restrained base would give 1.05U.
    private let v5Dose = 2.7
    private let orefDose = 1.05

    func testMealStateInsideWindowCappedAtBaseDose() {
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: true, inPostRescueWindow: true, v5FinalDose: v5Dose, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, orefDose)
        XCTAssertEqual(r.cap, .postRescue)
    }

    func testMealStateInsideWindowButV5AlreadyBelowBaseKeepsV5Dose() {
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: true, inPostRescueWindow: true, v5FinalDose: 0.4, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, 0.4)
        XCTAssertEqual(r.cap, .none)
    }

    func testMealStateOutsideWindowExemptionIntact() {
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: true, inPostRescueWindow: false, v5FinalDose: v5Dose, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, v5Dose)
        XCTAssertEqual(r.cap, .none)
    }

    func testNonMealStateOutsideWindowNonMealCapUnchanged() {
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: false, inPostRescueWindow: false, v5FinalDose: v5Dose, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, orefDose)
        XCTAssertEqual(r.cap, .nonMeal)
    }

    func testNonMealStateInsideWindowStillTheNonMealCap() {
        // The window adds nothing new for non-meal states — they were already capped.
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: false, inPostRescueWindow: true, v5FinalDose: v5Dose, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, orefDose)
        XCTAssertEqual(r.cap, .nonMeal)
    }

    func testNonMealStateWithV5BelowBaseKeepsV5Dose() {
        let r = SafetyGates.applyV6OverrideCaps(
            inMealState: false, inPostRescueWindow: false, v5FinalDose: 0.3, orefWouldDose: orefDose
        )
        XCTAssertEqual(r.dose, 0.3)
        XCTAssertEqual(r.cap, .none)
    }

    func testSharedThresholdStaysAlignedWithAAPSTierGuardAt75() {
        // Alignment is load-bearing on the AAPS side (V1's Fix A v2 tier guard reads the same
        // constant); the Trio value must stay in lock-step so both platforms define
        // "post-rescue" identically.
        XCTAssertEqual(SafetyGateConstants.postRescueLowThresholdMgdl, 75.0)
    }
}
