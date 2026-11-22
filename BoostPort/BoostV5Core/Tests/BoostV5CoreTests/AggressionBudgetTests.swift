@testable import BoostV5Core
import XCTest

final class AggressionBudgetTests: XCTestCase {
    typealias B = AggressionBudgetEngine

    func testNoRiskNoModifierIsBaseReq() {
        let r = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.1, inPostExerciseWindow: false)
        XCTAssertEqual(r.budget, 1.0, accuracy: 1E-9)
        XCTAssertEqual(r.mlHypoRiskScale, 1.0, accuracy: 1E-9)
    }

    func testFloorFallsWithHypoCaution() {
        // Boost 6.3.0 (AAPS 4a3c7a4341): the 30% floor is divided by Hypo Caution above 1.0. At risk
        // 1.0 and Hypo Caution 2.0 mlScale is 0.25, so the raw budget 0.25 x 2.0 now stands over
        // the 0.15 x 2.0 floor; the old fixed 0.30 floor overrode it.
        let r = B.aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: false, hypoCautionUserKnob: 2.0)
        XCTAssertEqual(r.floorBudget, 0.15 * 2.0, accuracy: 1E-9)
        XCTAssertEqual(r.budget, 0.25 * 2.0, accuracy: 1E-9)
    }

    func testFloorAt30PercentWithNeutralHypoCaution() {
        // At Hypo Caution 1.0 (and below) the floor is unchanged.
        let r = B.aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: false, hypoCautionUserKnob: 0.8)
        XCTAssertEqual(r.floorBudget, 0.30 * 2.0, accuracy: 1E-9)
    }

    func testMlScaleFloorsAtHalfWithDefaultKnob() {
        // risk 1.0, knob 1.0 → mlScale floors at 0.50 (not 0); raw 1.0 beats the 0.6 floor.
        let r = B.aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: false)
        XCTAssertEqual(r.mlHypoRiskScale, 0.50, accuracy: 1E-9)
        XCTAssertEqual(r.budget, 1.0, accuracy: 1E-9)
    }

    func testHypoCautionHigherKnobGivesLessInsulin() {
        // The 2026-06-15 direction fix: raising Hypo Caution must REDUCE the scale at a mid risk.
        let lo = B.mlHypoRiskScale(0.6, hypoCautionKnob: 1.0)
        let hi = B.mlHypoRiskScale(0.6, hypoCautionKnob: 2.0)
        XCTAssertLessThan(hi, lo)
    }

    func testPostExerciseHalvesBeforeFloor() {
        let r = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: true)
        // 1.0 * 1.0(ml) * 0.5(postEx) * 1.0(sens) = 0.5, above the 0.30 floor
        XCTAssertEqual(r.budget, 0.5, accuracy: 1E-9)
    }

    func testSensitivityKnobBounded() {
        let hi = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: false, sensitivityUserKnob: 5.0)
        XCTAssertEqual(hi.budget, 1.2, accuracy: 1E-9) // clamped to 1.2
        let lo = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: false, sensitivityUserKnob: 0.1)
        XCTAssertEqual(lo.budget, 0.8, accuracy: 1E-9) // clamped to 0.8
    }

    func testNilRiskIsNeutral() {
        XCTAssertEqual(B.mlHypoRiskScale(nil), 1.0, accuracy: 1E-9)
    }
}
