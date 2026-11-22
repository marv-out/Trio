@testable import BoostV5Core
import XCTest

/// Sensitivity with TDD-based ISF off (AAPS 3d9d471dbb, f393d02e55, 1c6358ac6c; tests mirror
/// `BoostAutosensIsfTest` and `BoostSensitivitySettingsReconcileTest`).
///
/// On a static profile ISF the autosens ratio is folded into the ISF at target, the value every
/// sensitivity in the engine is built from, so it reaches the dosing sensitivity as in stock oref.
/// Field case: ratio 1.30 on an ISF of 68.4 must give 52.6 for the dose. And with TDD off, BG impact on
/// ISF is 0, since the curve otherwise entered the dose through ISF and again through the target.
final class BoostAutosensIsfTests: XCTestCase {
    private func isf(useTdd: Bool = false, autosensWhenNoTdd: Bool = true, tt: Double = 1.0, ratio: Double) -> Double {
        DynIsf.autosensAdjustedIsf(
            sensNormalTarget: 68.4, useTdd: useTdd, autosensWhenNoTdd: autosensWhenNoTdd,
            tempTargetRatio: tt, orefAutosensRatio: ratio
        )
    }

    func testResistantRatioStrengthensIsfAtTarget() { XCTAssertEqual(isf(ratio: 1.3), 52.6, accuracy: 0.05) }
    func testSensitiveRatioWeakensIsfAtTarget() { XCTAssertEqual(isf(ratio: 0.8), 85.5, accuracy: 0.05) }
    func testNeutralRatioChangesNothing() { XCTAssertEqual(isf(ratio: 1.0), 68.4) }
    func testTddBasedIsfOwnsSensitivity() { XCTAssertEqual(isf(useTdd: true, ratio: 1.3), 68.4) }
    func testNoTddAutosensSwitchOff() { XCTAssertEqual(isf(autosensWhenNoTdd: false, ratio: 1.3), 68.4) }
    func testTempTargetRatioIsNotStackedWithAutosens() { XCTAssertEqual(isf(tt: 0.7, ratio: 1.3), 68.4) }

    func testNonPositiveRatioFallsBackRatherThanDividing() {
        XCTAssertEqual(isf(ratio: 0.0), 68.4)
        XCTAssertEqual(isf(ratio: -1.0), 68.4)
    }

    func testVelocityIsZeroWithoutTdd() {
        XCTAssertEqual(DynIsf.effectiveVelocity(useTdd: false, velocityPct: 100), 0)
        XCTAssertEqual(DynIsf.effectiveVelocity(useTdd: true, velocityPct: 60), 0.6, accuracy: 1E-12)
    }

    func testSelectedRatioFollowsTheOwningMechanism() {
        XCTAssertEqual(
            DynIsf.selectSensitivityRatio(useTdd: true, autosensWhenNoTdd: true, isfResultRatio: 1.0, orefAutosensRatio: 1.3),
            1.0
        )
        XCTAssertEqual(
            DynIsf.selectSensitivityRatio(useTdd: false, autosensWhenNoTdd: true, isfResultRatio: 1.0, orefAutosensRatio: 1.3),
            1.3
        )
        XCTAssertEqual(
            DynIsf.selectSensitivityRatio(useTdd: false, autosensWhenNoTdd: false, isfResultRatio: 1.0, orefAutosensRatio: 1.3),
            1.0
        )
    }

    func testTempTargetRatio() {
        func r(_ tt: Bool, _ target: Double, high: Bool = true, low: Bool = true) -> Double {
            DynIsf.tempTargetRatio(
                isTempTarget: tt, targetBg: target, normalTarget: 99, halfBasalTarget: 160,
                highTtRaisesSens: high, lowTtLowersSens: low, autosensMin: 0.7, autosensMax: 1.2
            )
        }
        XCTAssertEqual(r(false, 140), 1.0)
        // c = 61: 61 / (61 + 41) = 0.598, clamped to the autosens minimum.
        XCTAssertEqual(r(true, 140), 0.7)
        XCTAssertEqual(r(true, 140, high: false), 1.0)
        // 61 / (61 - 9) = 1.173, inside the limits.
        XCTAssertEqual(r(true, 90), 61.0 / 52.0, accuracy: 1E-12)
        XCTAssertEqual(r(true, 90, low: false), 1.0)
        XCTAssertEqual(r(true, 99), 1.0)
    }
}

final class BoostSensitivitySettingsReconcileTests: XCTestCase {
    func testTddOffZeroesBgImpact() {
        let r = DynIsf.reconcileSensitivitySettings(useTdd: false, velocityPct: 100)
        XCTAssertEqual(r.velocityPct, 0)
        XCTAssertTrue(r.zeroedVelocity)
        XCTAssertTrue(r.changed)
    }

    func testTddOffAlreadySafeChangesNothing() {
        let r = DynIsf.reconcileSensitivitySettings(useTdd: false, velocityPct: 0)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.velocityPct, 0)
    }

    func testTddOnLeavesBgImpactAsSet() {
        let r = DynIsf.reconcileSensitivitySettings(useTdd: true, velocityPct: 60)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.velocityPct, 60)
    }

    func testSwitchingTddOnRestoresBgImpact() {
        let r = DynIsf.reconcileSensitivitySettings(useTdd: true, velocityPct: 0, tddJustEnabled: true, velocityOnPct: 100)
        XCTAssertEqual(r.velocityPct, 100)
        XCTAssertTrue(r.restoredVelocity)
        XCTAssertFalse(r.zeroedVelocity)
        XCTAssertTrue(r.changed)
    }

    func testBgImpactChosenAfterSwitchOnIsKept() {
        let r = DynIsf.reconcileSensitivitySettings(useTdd: true, velocityPct: 40, tddJustEnabled: false, velocityOnPct: 100)
        XCTAssertEqual(r.velocityPct, 40)
        XCTAssertFalse(r.changed)
    }

    func testTddSwitchOnIsDetectedOnlyFromARecordedOff() {
        XCTAssertTrue(DynIsf.isTddJustEnabled(lastUseTdd: false, useTdd: true))
        XCTAssertFalse(DynIsf.isTddJustEnabled(lastUseTdd: true, useTdd: true))
        XCTAssertFalse(DynIsf.isTddJustEnabled(lastUseTdd: nil, useTdd: true))
        XCTAssertFalse(DynIsf.isTddJustEnabled(lastUseTdd: false, useTdd: false))
    }

    func testWithoutASwitchOnTheReconcileCanOnlyTurnBgImpactDown() {
        for useTdd in [true, false] {
            for v in [0.0, 50.0, 100.0] {
                XCTAssertLessThanOrEqual(DynIsf.reconcileSensitivitySettings(useTdd: useTdd, velocityPct: v).velocityPct, v)
            }
        }
    }
}
