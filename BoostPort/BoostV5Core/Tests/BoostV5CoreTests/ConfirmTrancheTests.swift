@testable import BoostV5Core
import XCTest

/// Confirm tranche (AAPS 2026-08-27): part of the commit shot now, the rest ten minutes later if
/// the rise continues.
final class ConfirmTrancheTests: XCTestCase {
    private let t0: Double = 1_700_000_000_000
    private func mins(_ m: Double) -> Double { t0 + m * 60000 }

    func testTheConfirmDeliversTheFractionAndHoldsTheRest() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0), 1.0, accuracy: 1E-12)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12)
    }

    func testAContinuingRiseReleasesTheRemainder() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        // Ten minutes on and still climbing hard.
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 185), 1.0, accuracy: 1E-12)
        XCTAssertEqual(c.heldU, 0)
    }

    func testAnExcursionThatGoesNowhereKeepsTheRemainderWithheld() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.9)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 151), 0)
        XCTAssertEqual(c.heldU, 0, "the hold is resolved on its cycle either way")
    }

    func testNothingIsReleasedBeforeTheHoldWindow() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(5), bg: 180), 0)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "still pending")
    }

    func testTheSlackAllowsACycleThatLandsJustShortOfTheBoundary() {
        // The reported case: a confirm at 14:52:11 followed by a cycle at 15:02:10, which is 9.991
        // minutes. An exact comparison deferred the decision by a whole cycle, and with five-minute
        // cycles that misses roughly half the time.
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertGreaterThan(c.onCycle(nowMs: mins(9.991), bg: 185), 0)
    }

    func testAnExpiredHoldIsDroppedRatherThanCarried() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(31), bg: 200), 0)
        XCTAssertEqual(c.heldU, 0)
    }

    func testANewConfirmReplacesAnOlderHold() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        _ = c.onConfirm(nowMs: mins(5), bg: 170, sizedDose: 1.0)
        XCTAssertEqual(c.heldU, 0.5, accuracy: 1E-12)
    }

    func testItCanOnlyEverDeliverLessThanTheEngineWould() {
        // The bounding property, across thresholds and outcomes: the sum of what is delivered at the
        // confirm and what is later released can never exceed the sized dose.
        for threshold in stride(from: 0.0, through: 1.0, by: 0.1) {
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                for endBg in [140.0, 150.0, 160.0, 200.0, 260.0] {
                    let c = ConfirmTranche(immediateFraction: fraction, releaseThreshold: threshold)
                    let sized = 2.0
                    let now = c.onConfirm(nowMs: t0, bg: 150, sizedDose: sized)
                    let later = c.onCycle(nowMs: mins(10), bg: endBg)
                    XCTAssertLessThanOrEqual(now + later, sized + 1E-9)
                    XCTAssertGreaterThanOrEqual(now + later, 0)
                }
            }
        }
    }

    func testAZeroOrNonFiniteDoseIsPassedThroughUntouched() {
        let c = ConfirmTranche()
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: 150, sizedDose: 0), 0)
        XCTAssertEqual(c.heldU, 0)
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: .nan, sizedDose: 1.5), 1.5, accuracy: 1E-12)
    }

    func testAMissingGlucoseReadingDoesNotReleaseOrDropTheHold() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: nil), 0)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "still pending, to be decided on a cycle with data")
    }

    func testResetDropsTheHold() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        c.reset()
        XCTAssertEqual(c.heldU, 0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 200), 0)
    }

    func testARaisedThresholdWithholdsMore() {
        func delivered(threshold: Double) -> Double {
            let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: threshold)
            let now = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
            return now + c.onCycle(nowMs: mins(10), bg: 168)
        }
        XCTAssertGreaterThanOrEqual(delivered(threshold: 0.30), delivered(threshold: 0.95))
    }

    func testProbeReportsWithoutActing() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        let p = c.probeProbability(bg: 185)
        XCTAssertNotNil(p)
        XCTAssertGreaterThan(p!, 0)
        XCTAssertLessThan(p!, 1)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "probing must not resolve the hold")
        XCTAssertNil(ConfirmTranche().probeProbability(bg: 185), "nothing pending")
    }

    // MARK: bounds at the seam (AAPS a33752c9aa, audit item 1)

    private func open(ceiling: Double = 10) -> ConfirmTranche.ReleaseBounds {
        ConfirmTranche.ReleaseBounds(inMealState: true, hardGateFired: false, postRescueWindow: false, ceilingU: ceiling)
    }

    /// A confirm at 110 followed by a rise the rule releases on.
    private func armed() -> ConfirmTranche {
        let c = ConfirmTranche(releaseThreshold: 0.48, holdMinutes: 10)
        _ = c.onConfirm(nowMs: t0, bg: 110, sizedDose: 2.0)
        _ = c.onCycleBounded(nowMs: mins(5), bg: 130, bounds: open())
        return c
    }

    func testBoundedAReleaseWithinEveryBoundIsDeliveredWhole() {
        let r = armed().onCycleBounded(nowMs: mins(10), bg: 160, bounds: open())
        XCTAssertEqual(r.units, 1.0, accuracy: 1E-9)
        XCTAssertTrue(r.note.isEmpty)
    }

    func testBoundedLeavingTheMealStatesDropsTheHoldAndReleasesNothing() {
        let c = armed()
        var b = open()
        b.inMealState = false
        let r = c.onCycleBounded(nowMs: mins(10), bg: 160, bounds: b)
        XCTAssertEqual(r.units, 0)
        XCTAssertTrue(r.note.hasPrefix("dropped:state"))
        XCTAssertEqual(c.heldU, 0)
        XCTAssertEqual(c.onCycleBounded(nowMs: mins(15), bg: 180, bounds: open()).units, 0)
    }

    func testBoundedAPhase3HardGateDropsTheHold() {
        let c = armed()
        var b = open()
        b.hardGateFired = true
        XCTAssertEqual(c.onCycleBounded(nowMs: mins(10), bg: 160, bounds: b).units, 0)
        XCTAssertEqual(c.heldU, 0)
    }

    func testBoundedThePostRescueWindowDropsTheHold() {
        let c = armed()
        var b = open()
        b.postRescueWindow = true
        XCTAssertEqual(c.onCycleBounded(nowMs: mins(10), bg: 160, bounds: b).units, 0)
        XCTAssertEqual(c.heldU, 0)
    }

    func testBoundedTheReleaseIsClampedToWhatIsLeftOfMaxIobAndTheConfirmCap() {
        let r = armed().onCycleBounded(nowMs: mins(10), bg: 160, bounds: open(ceiling: 0.4))
        XCTAssertEqual(r.units, 0.4, accuracy: 1E-9)
        XCTAssertEqual(r.note, "clamped:1.0->0.4")
    }

    func testCeilingIsTheTighterOfMaxIobHeadroomAndTheConfirmCapNeverNegative() {
        // Headroom 3.0 - 1.8 - 0.5 = 0.7 against cap 2.0 - 0.5 = 1.5.
        XCTAssertEqual(
            ConfirmTranche.releaseCeiling(cycleDoseU: 0.5, maxIobU: 3.0, iobU: 1.8, confirmedCapU: 2.0),
            0.7,
            accuracy: 1E-9
        )
        // Headroom 6.0 - 0.0 - 0.5 = 5.5 against cap 1.0 - 0.5 = 0.5.
        XCTAssertEqual(
            ConfirmTranche.releaseCeiling(cycleDoseU: 0.5, maxIobU: 6.0, iobU: 0.0, confirmedCapU: 1.0),
            0.5,
            accuracy: 1E-9
        )
        // IOB already above maxIOB.
        XCTAssertEqual(ConfirmTranche.releaseCeiling(cycleDoseU: 0.5, maxIobU: 2.0, iobU: 2.2, confirmedCapU: 2.0), 0)
    }

    func testOverAnEpisodeTheBoundedPathNeverDeliversMoreThanTheConfirmShot() {
        let c = ConfirmTranche(releaseThreshold: 0.0, holdMinutes: 10)
        var total = c.onConfirm(nowMs: t0, bg: 110, sizedDose: 2.0)
        for t in 1 ... 8 {
            total += c.onCycleBounded(nowMs: mins(Double(t * 5)), bg: 110 + 20 * Double(t), bounds: open()).units
        }
        XCTAssertLessThanOrEqual(total, 2.0 + 1E-9)
    }
}
