@testable import BoostV5Core
import Foundation
import XCTest

final class DynIsfTests: XCTestCase {
    private let acc = 1E-6

    // MARK: - deltaAccl (AAPS guard + round)

    func testDeltaAcclGuardZeroShortAvg() {
        // |shortAvg| <= 0.001 → 0.0 (not 50·delta from the /max(|short|,2) floor).
        XCTAssertEqual(DynIsf.deltaAccl(delta: 6.0, shortAvgDelta: 0.0), 0.0, accuracy: acc)
        XCTAssertEqual(DynIsf.deltaAccl(delta: 6.0, shortAvgDelta: 0.0005), 0.0, accuracy: acc)
    }

    func testDeltaAcclNormalAndRound() {
        // shortAvg 4 → denom max(4,2)=4 → 100*(6-4)/4 = 50.0
        XCTAssertEqual(DynIsf.deltaAccl(delta: 6.0, shortAvgDelta: 4.0), 50.0, accuracy: acc)
        // small shortAvg uses the 2.0 floor: shortAvg 1 → denom 2 → 100*(2-1)/2 = 50.0
        XCTAssertEqual(DynIsf.deltaAccl(delta: 2.0, shortAvgDelta: 1.0), 50.0, accuracy: acc)
        // rounding to 2dp: shortAvg 3 → 100*(4-3)/3 = 33.333… → 33.33
        XCTAssertEqual(DynIsf.deltaAccl(delta: 4.0, shortAvgDelta: 3.0), 33.33, accuracy: acc)
    }

    // MARK: - futureSens (dosing ISF branch selection)

    private func fsArgs(
        currentBg: Double, eventualBg: Double, minPredBg: Double,
        delta: Double, shortAvg: Double, longAvg: Double, deltaAccl: Double, cob: Double
    ) -> Double {
        DynIsf.futureSens(
            currentBg: currentBg, eventualBg: eventualBg, minPredBg: minPredBg,
            delta: delta, shortAvgDelta: shortAvg, longAvgDelta: longAvg, deltaAccl: deltaAccl,
            cob: cob, sensNormalTarget: 50.0, normalTarget: 99.0, insulinDivisor: 55.0,
            velocity: 1.0, bgCap: 210.0
        )
    }

    private func isfAt(_ bg: Double) -> Double {
        let v = DynIsf.getIsfByProfile(
            bg: bg, normalTarget: 99.0, insulinDivisor: 55.0,
            sensNormalTarget: 50.0, velocity: 1.0, bgCap: 210.0, useCap: false
        )
        return (v * 10).rounded() / 10
    }

    func testFutureSensCobBranch() {
        // cob>0 && deltaAccl>0 → ISF at 0.75·fsensBg + 0.25·sensBg (no cap → fsensBg=eventual, sensBg=current)
        let result = fsArgs(
            currentBg: 120,
            eventualBg: 160,
            minPredBg: 110,
            delta: 3,
            shortAvg: 2,
            longAvg: 1,
            deltaAccl: 5,
            cob: 20
        )
        XCTAssertEqual(result, isfAt(160 * 0.75 + 120 * 0.25), accuracy: 0.05)
    }

    func testFutureSensRisingBranchUsesCurrent() {
        // no cob, not rapid, not flat-high, (delta>0 && accl>1) → ISF at sensBg (=current 120)
        let result = fsArgs(
            currentBg: 120,
            eventualBg: 110,
            minPredBg: 100,
            delta: 2,
            shortAvg: 2,
            longAvg: 1,
            deltaAccl: 2,
            cob: 0
        )
        XCTAssertEqual(result, isfAt(120), accuracy: 0.05)
    }

    func testFutureSensFallingBranchUsesMinPred() {
        // falling: not rising, eventual<=current → ISF at max(minPredBg,1) (=90)
        let result = fsArgs(
            currentBg: 120,
            eventualBg: 100,
            minPredBg: 90,
            delta: -2,
            shortAvg: -2,
            longAvg: -1,
            deltaAccl: -3,
            cob: 0
        )
        XCTAssertEqual(result, isfAt(90), accuracy: 0.05)
    }

    // MARK: - blendedTdd

    func testBlendedTddStandardBlend() {
        // Choose components so weighted8h >= 0.75 * tdd7d (standard branch).
        let last4h = 5.0
        let last8to4h = 4.0
        // weighted8h = ((1.4*5)+(0.6*4))*3 = (7 + 2.4)*3 = 28.2
        let weighted8h = ((1.4 * last4h) + (0.6 * last8to4h)) * 3.0
        XCTAssertEqual(weighted8h, 28.2, accuracy: acc)

        let tdd7d = 30.0 // 0.75*30 = 22.5 <= 28.2 -> standard branch
        let tdd1d = 32.0

        let expectedBlend = (weighted8h * 0.33) + (tdd7d * 0.34) + (tdd1d * 0.33)
        let result = DynIsf.blendedTdd(
            last4h: last4h, last8to4h: last8to4h, tdd7d: tdd7d, tdd1d: tdd1d,
            adjustmentFactorPct: 100.0
        )
        XCTAssertEqual(result, expectedBlend, accuracy: acc)
    }

    func testBlendedTddPullDownBranch() {
        // weighted8h < 0.75 * tdd7d -> pull-down branch.
        let last4h = 2.0
        let last8to4h = 1.0
        // weighted8h = ((1.4*2)+(0.6*1))*3 = (2.8+0.6)*3 = 10.2
        let weighted8h = ((1.4 * last4h) + (0.6 * last8to4h)) * 3.0
        XCTAssertEqual(weighted8h, 10.2, accuracy: acc)

        let tdd7d = 40.0 // 0.75*40 = 30 > 10.2 -> pull-down branch
        let tdd1d = 12.0

        let adjusted7d = weighted8h + ((weighted8h / tdd7d) * (tdd7d - weighted8h))
        let expectedBlend = (adjusted7d * 0.34) + (tdd1d * 0.33) + (weighted8h * 0.33)
        let result = DynIsf.blendedTdd(
            last4h: last4h, last8to4h: last8to4h, tdd7d: tdd7d, tdd1d: tdd1d,
            adjustmentFactorPct: 100.0
        )
        XCTAssertEqual(result, expectedBlend, accuracy: acc)
    }

    func testBlendedTddAdjustmentFactor() {
        let last4h = 5.0, last8to4h = 4.0, tdd7d = 30.0, tdd1d = 32.0
        let base = DynIsf.blendedTdd(
            last4h: last4h, last8to4h: last8to4h, tdd7d: tdd7d, tdd1d: tdd1d,
            adjustmentFactorPct: 100.0
        )
        let scaled = DynIsf.blendedTdd(
            last4h: last4h, last8to4h: last8to4h, tdd7d: tdd7d, tdd1d: tdd1d,
            adjustmentFactorPct: 80.0
        )
        XCTAssertEqual(scaled, base * 0.80, accuracy: acc)
    }

    func testBlendedTddAdjustmentFactorClamped() {
        let args = (last4h: 5.0, last8to4h: 4.0, tdd7d: 30.0, tdd1d: 32.0)
        let base = DynIsf.blendedTdd(
            last4h: args.last4h, last8to4h: args.last8to4h, tdd7d: args.tdd7d, tdd1d: args.tdd1d,
            adjustmentFactorPct: 100.0
        )
        // Below 1% clamps to 1%.
        let low = DynIsf.blendedTdd(
            last4h: args.last4h, last8to4h: args.last8to4h, tdd7d: args.tdd7d, tdd1d: args.tdd1d,
            adjustmentFactorPct: 0.0
        )
        XCTAssertEqual(low, base * 0.01, accuracy: acc)
        // Above 300% clamps to 300%.
        let high = DynIsf.blendedTdd(
            last4h: args.last4h, last8to4h: args.last8to4h, tdd7d: args.tdd7d, tdd1d: args.tdd1d,
            adjustmentFactorPct: 500.0
        )
        XCTAssertEqual(high, base * 3.0, accuracy: acc)
    }

    // MARK: - isfTargetV1 (Boost uses V1 only; V2 intentionally removed)

    func testIsfTargetV1() {
        let tdd = 40.0
        let normalTarget = 99.0
        let insulinDivisor = 75.0
        let expected = 1800.0 / (tdd * log((normalTarget / insulinDivisor) + 1.0))
        let result = DynIsf.isfTargetV1(tdd: tdd, normalTarget: normalTarget, insulinDivisor: insulinDivisor)
        XCTAssertEqual(result, expected, accuracy: acc)
    }

    // MARK: - getIsfByProfile (soft cap)

    func testGetIsfByProfileBelowCapEqualsUncapped() {
        let bg = 120.0
        let normalTarget = 99.0
        let insulinDivisor = 75.0
        let sensNormalTarget = 45.0
        let velocity = 0.5
        let bgCap = 180.0

        let capped = DynIsf.getIsfByProfile(
            bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
            sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: true
        )
        let uncapped = DynIsf.getIsfByProfile(
            bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
            sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: false
        )
        // Below the cap, useCap makes no difference.
        XCTAssertEqual(capped, uncapped, accuracy: acc)

        // And it equals the hand-computed formula.
        let sensBG = log((bg / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sensBG
        let expected = sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
        XCTAssertEqual(capped, expected, accuracy: acc)
    }

    func testGetIsfByProfileSoftCapKicksIn() {
        let bg = 300.0
        let normalTarget = 99.0
        let insulinDivisor = 75.0
        let sensNormalTarget = 45.0
        let velocity = 0.5
        let bgCap = 180.0

        let capped = DynIsf.getIsfByProfile(
            bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
            sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: true
        )
        let uncapped = DynIsf.getIsfByProfile(
            bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
            sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: false
        )
        // Above the cap the result must differ.
        XCTAssertNotEqual(capped, uncapped, accuracy: acc)

        // Hand-compute the soft-capped value: bgAdj = 180 + (300-180)/3 = 220.
        let bgAdj = bgCap + (bg - bgCap) / 3.0
        XCTAssertEqual(bgAdj, 220.0, accuracy: acc)
        let sensBG = log((bgAdj / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sensBG
        let expected = sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
        XCTAssertEqual(capped, expected, accuracy: acc)
    }

    // MARK: - variableSens

    func testVariableSensVelocityZeroEqualsSensNormalTarget() {
        let sensNormalTarget = 45.0
        let result = DynIsf.variableSens(
            sensNormalTarget: sensNormalTarget, normalTarget: 99.0,
            bgCapped: 200.0, insulinDivisor: 75.0, velocity: 0.0
        )
        // velocity 0 -> multiplier is exactly 1.
        XCTAssertEqual(result, sensNormalTarget, accuracy: acc)
    }

    func testVariableSensVelocityOneFullScaler() {
        let sensNormalTarget = 45.0
        let normalTarget = 99.0
        let bgCapped = 200.0
        let insulinDivisor = 75.0
        let result = DynIsf.variableSens(
            sensNormalTarget: sensNormalTarget, normalTarget: normalTarget,
            bgCapped: bgCapped, insulinDivisor: insulinDivisor, velocity: 1.0
        )
        // velocity 1 -> sensNormalTarget * scaler.
        let sbg = log((bgCapped / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sbg
        XCTAssertEqual(result, sensNormalTarget * scaler, accuracy: acc)
    }

    // MARK: - sensitivityRatio

    func testSensitivityRatioTddMode() {
        // 24/16 = 1.5, within [0.7, 2.0].
        let r = DynIsf.sensitivityRatio(
            mode: .tdd, tdd24h: 24.0, tdd7d: 16.0,
            autosensRatio: 1.0, autosensMin: 0.7, autosensMax: 2.0
        )
        XCTAssertEqual(r, 1.5, accuracy: acc)
    }

    func testSensitivityRatioTddModeClampMax() {
        // 24/8 = 3.0 -> clamped to autosensMax 2.0.
        let r = DynIsf.sensitivityRatio(
            mode: .tdd, tdd24h: 24.0, tdd7d: 8.0,
            autosensRatio: 1.0, autosensMin: 0.7, autosensMax: 2.0
        )
        XCTAssertEqual(r, 2.0, accuracy: acc)
    }

    func testSensitivityRatioTddModeClampMin() {
        // 8/24 = 0.333 -> clamped to autosensMin 0.7.
        let r = DynIsf.sensitivityRatio(
            mode: .tdd, tdd24h: 8.0, tdd7d: 24.0,
            autosensRatio: 1.0, autosensMin: 0.7, autosensMax: 2.0
        )
        XCTAssertEqual(r, 0.7, accuracy: acc)
    }

    func testSensitivityRatioAutosensMode() {
        let r = DynIsf.sensitivityRatio(
            mode: .autosens, tdd24h: 24.0, tdd7d: 8.0,
            autosensRatio: 1.23, autosensMin: 0.7, autosensMax: 2.0
        )
        XCTAssertEqual(r, 1.23, accuracy: acc)
    }

    func testSensitivityRatioLegacyMode() {
        let r = DynIsf.sensitivityRatio(
            mode: .legacy, tdd24h: 24.0, tdd7d: 8.0,
            autosensRatio: 1.23, autosensMin: 0.7, autosensMax: 2.0
        )
        XCTAssertEqual(r, 1.0, accuracy: acc)
    }
}
