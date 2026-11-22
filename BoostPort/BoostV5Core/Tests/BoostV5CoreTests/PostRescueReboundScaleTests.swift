@testable import BoostV5Core
import XCTest

/// Graduated post-rescue rebound scale (AAPS `PostRescueReboundScaleTest`, 2026-07-23).
///
/// The curve is 0.3 below 120 mg/dL, linear to 1.0 at 170, and 1.0 above. AAPS applies it to the
/// final microbolus of its V1 tier engine whenever the 45-minute post-rescue window is active,
/// carbs on board are zero and glucose is below 170. Trio has no V1 tier engine, so the curve is
/// defined here and not yet consumed.
final class PostRescueReboundScaleTests: XCTestCase {
    private func scale(_ bg: Double) -> Double {
        SafetyGateConstants.postRescueReboundScale(bg: bg)
    }

    func testFloorBelow120() {
        XCTAssertEqual(scale(80), 0.3, accuracy: 1E-12)
        XCTAssertEqual(scale(97), 0.3, accuracy: 1E-12) // the reported incident's glucose
        XCTAssertEqual(scale(119.99), 0.3, accuracy: 1E-12)
    }

    func testLinearBetween120And170() {
        XCTAssertEqual(scale(120), 0.3, accuracy: 1E-12)
        XCTAssertEqual(scale(145), 0.65, accuracy: 1E-12) // midpoint
        XCTAssertEqual(scale(169.99), 1.0, accuracy: 0.001)
    }

    func testNoSuppressionAtOrAbove170() {
        XCTAssertEqual(scale(170), 1.0, accuracy: 1E-12)
        XCTAssertEqual(scale(250), 1.0, accuracy: 1E-12)
    }

    func testCurveIsMonotonicAndBounded() {
        var previous = 0.0
        for bg in stride(from: 40.0, through: 400.0, by: 1.0) {
            let s = scale(bg)
            XCTAssertGreaterThanOrEqual(s, previous - 1E-12)
            XCTAssertGreaterThanOrEqual(s, 0.3)
            XCTAssertLessThanOrEqual(s, 1.0)
            previous = s
        }
    }

    // MARK: - The guard, and the tight-ramp trial arm (AAPS 2378baf367)

    func testTheShippedGuardStopsAtTheCeiling() {
        XCTAssertEqual(SafetyGateConstants.postRescueScale(bg: 150, tightRamp: false)!, 0.72, accuracy: 0.001)
        XCTAssertNil(SafetyGateConstants.postRescueScale(bg: 170, tightRamp: false))
        XCTAssertNil(SafetyGateConstants.postRescueScale(bg: 250, tightRamp: false))
    }

    func testTheTreatmentArmRunsAcrossTheWholeWindowWithACappedScale() {
        XCTAssertEqual(SafetyGateConstants.postRescueScale(bg: 250, tightRamp: true)!, 0.60, accuracy: 1E-12)
        XCTAssertEqual(SafetyGateConstants.postRescueScale(bg: 150, tightRamp: true)!, 0.60, accuracy: 1E-12)
        // Below the cap the curve still governs, since the arm is a cap rather than a replacement.
        XCTAssertEqual(SafetyGateConstants.postRescueScale(bg: 100, tightRamp: true)!, 0.30, accuracy: 1E-12)
    }

    func testATreatmentCycleCanNeverDeliverMoreThanAControlCycle() {
        // The safety property, over the whole range: the arm is a cap, so at any glucose value the
        // treatment scale is at most the control scale, where the control applies at all.
        for bg in stride(from: 40.0, through: 400.0, by: 1.0) {
            let treatment = SafetyGateConstants.postRescueScale(bg: bg, tightRamp: true)!
            let control = SafetyGateConstants.postRescueScale(bg: bg, tightRamp: false) ?? 1.0
            XCTAssertLessThanOrEqual(treatment, control + 1E-12, "at bg \(bg)")
        }
    }

    func testArmAssignmentIsBalancedAndDeterministic() {
        let seed = "a-fixed-install-seed"
        // Deterministic: the same day gives the same arm.
        for day in 0 ..< 40 {
            XCTAssertEqual(
                PostRescueTrial.tightRampArm(seed: seed, dayIndex: day),
                PostRescueTrial.tightRampArm(seed: seed, dayIndex: day)
            )
        }
        // Balanced in 7-day blocks: four treatment days in even blocks, three in odd.
        for block in 0 ..< 8 {
            let treated = (0 ..< 7).filter { PostRescueTrial.tightRampArm(seed: seed, dayIndex: block * 7 + $0) }
            XCTAssertEqual(treated.count, block % 2 == 0 ? 4 : 3, "block \(block)")
        }
    }

    func testArmIsNotConfoundedWithTheWeekday() {
        // Positions are shuffled per block, so no weekday is always treated or always control.
        let seed = "another-install-seed"
        for weekday in 0 ..< 7 {
            let treated = (0 ..< 20).filter { PostRescueTrial.tightRampArm(seed: seed, dayIndex: $0 * 7 + weekday) }
            XCTAssertGreaterThan(treated.count, 0, "weekday \(weekday) never treated")
            XCTAssertLessThan(treated.count, 20, "weekday \(weekday) always treated")
        }
    }

    func testAnEmptySeedNeverTreats() {
        for day in 0 ..< 30 {
            XCTAssertFalse(PostRescueTrial.tightRampArm(seed: "", dayIndex: day))
        }
    }

    func testNegativeDayIndicesAreHandled() {
        // Days before the epoch must not crash or skew, since the index is signed.
        for day in -21 ..< 0 {
            _ = PostRescueTrial.tightRampArm(seed: "seed", dayIndex: day)
        }
        let treated = (-14 ..< 0).filter { PostRescueTrial.tightRampArm(seed: "seed", dayIndex: $0) }
        XCTAssertEqual(treated.count, 7, "two blocks either side of the epoch give 4 + 3")
    }

    func testHashIsTheDocumentedFnv1a() {
        // A fixed vector, so the offline analysis can check it reimplemented the same hash.
        XCTAssertEqual(PostRescueTrial.fnv1a64(""), -3_750_763_034_362_895_579)
        XCTAssertNotEqual(PostRescueTrial.fnv1a64("a"), PostRescueTrial.fnv1a64("b"))
    }

    func testIncidentMagnitude() {
        // The reported incident delivered 3.55 U at 97 mg/dL, 25 minutes after a low of 67.
        // At that glucose the scale is the floor, so the dose would have been about a third.
        XCTAssertEqual(3.55 * scale(97), 1.065, accuracy: 0.001)
    }
}
