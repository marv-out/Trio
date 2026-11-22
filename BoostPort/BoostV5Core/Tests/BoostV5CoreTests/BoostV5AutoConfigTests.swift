@testable import BoostV5Core
import XCTest

/// Tests for the V5 auto-config calculator (Swift port) plus the apply layer
/// (`BoostV5AutoConfigApply`): conservative, transparent derivation of V5 knobs from a user's
/// last-N-day prior dosing history (oref or Boost-V1), per-knob resolution, the 2026-07-06
/// amendments (AAPS fe9d8a1a13: historical factories, cumulative clamp + operative recompute,
/// min-sample guard, TBR raise-guard) and the versioned re-migration (AAPS 131923247e).
/// Pure-function tests.
final class BoostV5AutoConfigTests: XCTestCase {
    // Default manual list has >= minManualBolusSamples entries so the meal-bolus p90 term
    // participates (p90 = 6.0); smaller fixtures exercise the min-sample fallback explicitly.
    private func prior(
        days: Int = 14, bg: Int = 3500, tdd: Double = 40,
        manual: [Double] = [3, 3.5, 4, 4, 4.5, 5, 5, 5.5, 6, 6],
        smb: [Double] = [0.2, 0.3, 0.4, 0.6, 0.8],
        tbr70: Double = 3, sev54: Double = 0.4, meanBg: Double = 130,
        maxBolus: Double = 10
    ) -> BoostV5AutoConfig.PriorDosing {
        BoostV5AutoConfig.PriorDosing(
            daysWithData: days, bgReadingCount: bg, tddMedianU: tdd,
            manualBolusesU: manual, smbAmountsU: smb,
            tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, meanGlucoseMgdl: meanBg,
            currentMaxBolusU: maxBolus
        )
    }

    func testInsufficientDaysReturnsNil() {
        XCTAssertNil(BoostV5AutoConfig.compute(prior(days: 5)))
    }

    func testInsufficientBgReturnsNil() {
        XCTAssertNil(BoostV5AutoConfig.compute(prior(bg: 800)))
    }

    func testInTargetUserNeutral() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 2.5, sev54: 0.2))!
        XCTAssertEqual(s.aggression, 1.0)
        XCTAssertEqual(s.hypoCaution, 1.0)
        XCTAssertTrue(s.fastCarbConfirm)
    }

    func testHypoProneGetsGentlerAndCautious() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 8, sev54: 2.5))!
        XCTAssertEqual(s.aggression, 0.85)
        XCTAssertGreaterThan(s.hypoCaution, 1.0)
        XCTAssertFalse(s.fastCarbConfirm)
    }

    func testAggressionNeverRaisedAboveNeutral() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 0.5, sev54: 0.0))!
        XCTAssertLessThanOrEqual(s.aggression, 1.0)
    }

    func testCapsClampToRanges() {
        let s = BoostV5AutoConfig.compute(prior(
            manual: [2, 2.5, 3, 3, 3.5, 4, 4, 4.5, 5, 5],
            smb: [0.3, 0.5, 0.7]
        ))!
        XCTAssertGreaterThanOrEqual(s.confirmedCapU, 1.5)
        XCTAssertLessThanOrEqual(s.confirmedCapU, 7.5)
        XCTAssertGreaterThanOrEqual(s.committedCapU, 0.25)
        XCTAssertLessThanOrEqual(s.committedCapU, 2.5)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, 1.0)
        XCTAssertLessThanOrEqual(s.cumulativeSmbCap60MinU, BoostV5AutoConfig.cumulativeCapMaxU)
        // cumulative cap is never below a single confirm shot (it must allow ≥1 confirm)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, s.confirmedCapU - 1E-9)
    }

    func testConfirmedCapCoversBigMealUser() {
        let big = BoostV5AutoConfig.compute(prior(manual: [5, 5, 6, 6, 7, 7, 8, 9, 10, 11]))!
        let small = BoostV5AutoConfig.compute(prior(manual: [1, 1, 1.5, 1.5, 1.5, 2, 2, 2, 2, 2]))!
        XCTAssertGreaterThan(big.confirmedCapU, small.confirmedCapU)
    }

    func testCumulativeCapNeverBelowConfirmedForBigMealUser() {
        // Big eater: confirmedCap clamps to its 7.5 ceiling. The hourly cumulative budget must not
        // saturate below that (was clamped to 5.0 before the 2026-06-26 fix).
        let s = BoostV5AutoConfig.compute(prior(manual: [5, 6, 7, 7, 8, 9, 9, 10, 11, 11]))!
        XCTAssertEqual(s.confirmedCapU, 7.5)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, s.confirmedCapU - 1E-9)
    }

    func testCumulativeBudgetKeepsTwoHoldsForBigConfirmUser() {
        // 2026-07-06 amendment (AAPS fe9d8a1a13 #2): the old max(5.0, confirmedCap) ceiling
        // collapsed "one confirm + two holds" to "confirm + ~0 holds" for big-confirm users
        // (cohort: 6 of one user's 8 projected suppressions; another landed cumulative ==
        // confirmedCap exactly). New clamp is the pref range max (10.0):
        // conf 6.0 + 2×1.26 = 8.52 → 8.5, NOT 6.0.
        let s = BoostV5AutoConfig.compute(prior(
            tdd: 50.4, // 50.4/40 = 1.26 committed
            manual: [4, 4, 5, 5, 5, 6, 6, 6, 6, 6] // p90 = 6.0
        ))!
        XCTAssertEqual(s.confirmedCapU, 6.0)
        XCTAssertEqual(s.committedCapU, 1.26)
        XCTAssertEqual(s.cumulativeSmbCap60MinU, 8.5)
    }

    func testConfirmedCapIgnoresManualP90WhenSampleTooSmall() {
        // 2026-07-06 amendment (AAPS fe9d8a1a13 #4, min-sample guard): one cohort user's derived
        // confirmedCap 6.8 rested on a p90 of FOUR manual boluses, one an 8U outlier. With
        // n < minManualBolusSamples the cap must come from the SMB p95 alone.
        let fourWithOutlier: [Double] = [2, 3, 4, 8]
        let smbs: [Double] = [0.3, 0.4, 0.5, 0.5, 0.6]
        let s = BoostV5AutoConfig.compute(prior(manual: fourWithOutlier, smb: smbs))!
        // SMB p95 ≈ 0.58 → clamped to the 1.5 floor; the 8U outlier must NOT reach the cap.
        XCTAssertEqual(s.confirmedCapU, 1.5)
        // Same doses with an honest sample size DO drive the cap.
        let tenManual: [Double] = [2, 2, 3, 3, 3, 4, 4, 4, 8, 8]
        let s10 = BoostV5AutoConfig.compute(prior(manual: tenManual, smb: smbs))!
        XCTAssertGreaterThan(s10.confirmedCapU, 1.5)
    }

    func testBolusCarriedAndClamped() {
        let s = BoostV5AutoConfig.compute(prior(maxBolus: 12))!
        XCTAssertEqual(s.bolusCapU, 10.0)
    }

    func testPercentileInterpolates() {
        let v = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 0), 1.0)
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 100), 4.0)
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 50), 2.5, accuracy: 1E-9)
        XCTAssertEqual(BoostV5AutoConfig.percentile([], 90), 0.0)
    }

    func testRationaleExplainsSettings() {
        let s = BoostV5AutoConfig.compute(prior())!
        XCTAssertFalse(s.rationale.isEmpty)
        XCTAssertTrue(s.rationale.contains { $0.contains("HypoCaution") })
        XCTAssertTrue(s.rationale.contains { $0.contains("Aggression") })
        // Amendment (AAPS fe9d8a1a13 #6): the committedCap rationale is honest about BOTH terms —
        // the TDD/40 floor binds for most cohort users, not just "routine SMB size".
        XCTAssertTrue(s.rationale.contains { $0.contains("Committed cap") && $0.contains("TDD/40") })
    }

    // MARK: - Application of the suggestion (BoostV5AutoConfigApply): per-knob resolution

    //
    // Mirrors AAPS b2c0705e5e + fe9d8a1a13 / BoostV5AutoConfigTest: tuning one knob must not block
    // the others; each knob resolves (applied once, or skipped-because-user-tuned, or held as a
    // TBR suggestion) exactly once; insufficient data leaves knobs unresolved; the cumulative cap
    // is recomputed from the OPERATIVE per-shot caps; the legacy global done-flag migrates to
    // per-knob marks (tuned resolved, at-stock re-derivable).

    typealias Apply = BoostV5AutoConfigApply
    typealias Knob = BoostAutoConfigKnob

    private let safeTbr = 2.0 // below the raise-guard threshold: raises apply normally

    /// Trio factory defaults per knob (the host injects these from `Preferences()`).
    private static func stockDefault(_ knob: Knob) -> Double {
        switch knob {
        case .aggression: return 1.0
        case .hypoCaution: return 1.0
        case .confirmedCapU: return 2.5
        case .committedCapU: return 0.5
        case .cumulativeSmbCap60Min: return 10.0
        case .boostBolus: return 2.5
        case .primerCapU: return 0.0 // derived from the committed cap; no separate factory value
        case .aggressiveEarlyConfirm,
             .fastCarbConfirm,
             .primerTbrFallback,
             .velocityBudgetFloor: return 0 // boolean knobs, handled by the host
        }
    }

    /// Minimal in-memory stand-in for the host's preference + resolution-mark I/O. `userSetFlags`
    /// models Trio's explicit per-knob "user moved the slider" flags on the caps.
    private final class FakeStore {
        var store: [Knob: Double]
        var resolved = Set<Knob>()
        var userSetFlags = Set<Knob>()
        init(_ preset: [Knob: Double] = [:]) { store = preset }

        func isUserTuned(_ knob: Knob) -> Bool {
            userSetFlags.contains(knob) || Apply.isUserTuned(
                storedValue: store[knob],
                factoryDefaults: Apply.factoryDefaults(
                    knob, currentDefault: BoostV5AutoConfigTests.stockDefault(knob)
                )
            )
        }

        func apply(_ s: BoostV5AutoConfig.Suggestion, tbr: Double, sev54: Double = 0.0) -> [Apply.Resolution] {
            Apply.applyAutoConfig(
                suggestion: s,
                tbrBelow70Pct: tbr,
                timeBelow54Pct: sev54,
                isResolved: { self.resolved.contains($0) },
                storedValue: { self.store[$0] },
                currentDefault: { BoostV5AutoConfigTests.stockDefault($0) },
                isUserTuned: { self.isUserTuned($0) },
                put: { k, v in self.store[k] = v },
                markResolved: { self.resolved.insert($0) }
            )
        }
    }

    private func appliedKnobs(_ res: [Apply.Resolution]) -> [Knob] {
        res.filter { $0.outcome == .applied }.map(\.knob)
    }

    func testNothingPresetEverythingConfiguredAndResolvedIncludingCumulativeCap() {
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore()
        let res = f.apply(s, tbr: safeTbr)
        XCTAssertEqual(appliedKnobs(res), Knob.doubleKnobs)
        XCTAssertEqual(f.resolved, Set(Knob.doubleKnobs))
        // With both per-shot caps applied, the cumulative recompute equals the derivation's value.
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], s.cumulativeSmbCap60MinU)
    }

    func testTuningOneKnobKeepsItAndStillConfiguresTheOthers() {
        let s = BoostV5AutoConfig.compute(prior())!
        // user tuned the SMB cap: 2.5 differs from its only factory (10.0)
        let f = FakeStore([.cumulativeSmbCap60Min: 2.5])
        let res = f.apply(s, tbr: safeTbr)
        let others = Knob.doubleKnobs.filter { $0 != .cumulativeSmbCap60Min }
        XCTAssertEqual(appliedKnobs(res), others)
        XCTAssertTrue(f.resolved.contains(.cumulativeSmbCap60Min)) // tuned → resolved, never revisited
        let kept = res.first { $0.knob == .cumulativeSmbCap60Min }!
        XCTAssertEqual(kept.outcome, .keptUserTuned)
        XCTAssertTrue(kept.reason.contains("kept-user-tuned value=2.5"))
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], 2.5) // tuned value untouched
        XCTAssertEqual(f.store[.confirmedCapU], s.confirmedCapU)
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
    }

    func testKnobPersistedAtFactoryDefaultDoesNotBlockSuggestion() {
        // The field failure mode with a presence-style test: committedCap existed in storage at the
        // stock 0.5 and was skipped forever. Value == default means nobody objected — the
        // suggestion must still be applied.
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore([.committedCapU: Self.stockDefault(.committedCapU)])
        let res = f.apply(s, tbr: safeTbr)
        XCTAssertTrue(appliedKnobs(res).contains(.committedCapU))
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
    }

    // MARK: historical factory defaults (AAPS fe9d8a1a13 amendment #1; Trio eras git-verified)

    // Trio's factories changed in 5cf1abb84 (2026-06-26): confirmedCap 1.0→2.5, committedCap
    // 0.25→0.5. The cumulative cap was introduced at 10.0 and never changed — so on Trio 6.0 IS a
    // tuned value (unlike AAPS, whose cumulative shipped eras 1.5/6.0/10.0).

    func testEveryHistoricalFactoryValueRecognisedAsAtFactory() {
        func tuned(_ knob: Knob, _ value: Double?) -> Bool {
            Apply.isUserTuned(
                storedValue: value,
                factoryDefaults: Apply.factoryDefaults(knob, currentDefault: Self.stockDefault(knob))
            )
        }
        // every value each knob ever shipped as its Trio default → NOT user-tuned
        for v in [0.25, 0.5] { XCTAssertFalse(tuned(.committedCapU, v)) }
        for v in [1.0, 2.5] { XCTAssertFalse(tuned(.confirmedCapU, v)) }
        XCTAssertFalse(tuned(.cumulativeSmbCap60Min, 10.0))
        // genuinely tuned values still detected — incl. 6.0 for the cumulative cap, which was an
        // AAPS factory era but NEVER a Trio one
        XCTAssertTrue(tuned(.committedCapU, 1.24))
        XCTAssertTrue(tuned(.confirmedCapU, 4.0))
        XCTAssertTrue(tuned(.cumulativeSmbCap60Min, 6.0))
        XCTAssertTrue(tuned(.cumulativeSmbCap60Min, 2.5))
        // absent value is never "tuned"
        XCTAssertFalse(tuned(.committedCapU, nil))
    }

    func testKnobStrandedAtOldEraFactoryStillDerivable() {
        // Old-build user (pre-5cf1abb84 Preferences JSON): committedCap persisted at the ORIGINAL
        // factory 0.25, confirmedCap at 1.0, no UserSet flags. All must be treated as
        // never-touched and re-derived.
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore([.committedCapU: 0.25, .confirmedCapU: 1.0])
        let res = f.apply(s, tbr: safeTbr)
        XCTAssertEqual(appliedKnobs(res), Knob.doubleKnobs)
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
        XCTAssertEqual(f.store[.confirmedCapU], s.confirmedCapU)
    }

    func testUserSetFlagBlocksEvenAtFactoryValue() {
        // Trio's explicit UserSet flag must win even when the stored value EQUALS a factory
        // default (the user deliberately set it there) — stronger than the AAPS value-only test.
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore([.confirmedCapU: Self.stockDefault(.confirmedCapU)])
        f.userSetFlags.insert(.confirmedCapU)
        let res = f.apply(s, tbr: safeTbr)
        let kept = res.first { $0.knob == .confirmedCapU }!
        XCTAssertEqual(kept.outcome, .keptUserTuned)
        XCTAssertEqual(f.store[.confirmedCapU], Self.stockDefault(.confirmedCapU))
        XCTAssertTrue(f.resolved.contains(.confirmedCapU))
        XCTAssertEqual(Set(appliedKnobs(res)), Set(Knob.doubleKnobs).subtracting([.confirmedCapU]))
    }

    // MARK: cumulative cap from RESOLVED values (AAPS fe9d8a1a13 amendment #3)

    func testCumulativeCapComputedFromOperativeCapsNotDerivation() {
        // AAPS cohort user E: derivation suggested confirmedCap 4.65 but his operative
        // (user-tuned) cap was 2.0 — the cumulative budget must be sized from what applies.
        let s = BoostV5AutoConfig.compute(prior(tdd: 49.6, smb: [0.5, 0.5, 0.5, 0.5, 0.5]))!
        XCTAssertEqual(s.committedCapU, 1.24) // derived, will apply
        let keptConfirmed = 2.0 // user-tuned (≠ Trio factories 2.5/1.0)
        let f = FakeStore([.confirmedCapU: keptConfirmed])
        _ = f.apply(s, tbr: safeTbr)
        // cumulative = clamp(2.0 + 2×1.24, 1, 10) = 4.48 → 4.5 — from the KEPT 2.0, not derived 6.0
        XCTAssertEqual(f.store[.confirmedCapU], keptConfirmed)
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], 4.5)
        XCTAssertNotEqual(f.store[.cumulativeSmbCap60Min], s.cumulativeSmbCap60MinU)
    }

    // MARK: TBR raise-guard on dose caps (AAPS fe9d8a1a13 amendment #5, cohort user B)

    func testDoseCapRaiseWithElevatedTbrIsHeldAsSuggestion() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 4.3))!
        XCTAssertGreaterThan(s.committedCapU, Self.stockDefault(.committedCapU))
        let f = FakeStore()
        let res = f.apply(s, tbr: 4.3)
        let held = res.first { $0.knob == .committedCapU }!
        XCTAssertEqual(held.outcome, .suggestedNotAppliedTbr)
        XCTAssertEqual(held.suggestedValue, s.committedCapU) // suggestion recorded for the notification
        XCTAssertTrue(held.reason.contains("suggested-not-applied (TBR)"))
        XCTAssertNil(f.store[.committedCapU])
        XCTAssertTrue(f.resolved.contains(.committedCapU)) // resolved: not retried forever
        // The confirmed cap (also a raise: 6.0 > factory 2.5) is held too...
        XCTAssertEqual(res.first { $0.knob == .confirmedCapU }!.outcome, .suggestedNotAppliedTbr)
        // ...while non-cap knobs still apply (hypo-protective tightenings must never be blocked).
        XCTAssertTrue(appliedKnobs(res).contains(.aggression))
        XCTAssertTrue(appliedKnobs(res).contains(.hypoCaution))
        // The cumulative cap TIGHTENS (from factory 10.0 down to the operative-cap budget) → applied.
        XCTAssertTrue(appliedKnobs(res).contains(.cumulativeSmbCap60Min))
        XCTAssertLessThan(f.store[.cumulativeSmbCap60Min]!, 10.0)
    }

    func testDoseCapLoweringAppliesEvenWithElevatedTbr() {
        // Tightenings are exactly what a TBR-heavy user needs — the guard must never block them.
        // Small-dose user: confirmedCap derives to the 1.5 floor, below the factory 2.5.
        let s = BoostV5AutoConfig.compute(prior(
            manual: [0.5, 0.5, 0.5, 0.5], smb: [0.2, 0.2, 0.3], tbr70: 4.3
        ))!
        XCTAssertEqual(s.confirmedCapU, 1.5)
        let f = FakeStore()
        let res = f.apply(s, tbr: 4.3)
        XCTAssertTrue(appliedKnobs(res).contains(.confirmedCapU))
        XCTAssertEqual(f.store[.confirmedCapU], 1.5)
    }

    func testDoseCapRaiseAppliesNormallyWhenTbrAtTarget() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 2.0))!
        XCTAssertGreaterThan(s.committedCapU, Self.stockDefault(.committedCapU))
        let f = FakeStore()
        let res = f.apply(s, tbr: 2.0)
        XCTAssertTrue(appliedKnobs(res).contains(.committedCapU))
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
    }

    // MARK: <54 severe co-guard on the raise-guard (AAPS 13c9bc4d53, cohort user B)

    func testDoseCapRaiseHeldByServe54GuardEvenWhenTbr70UnderLine() {
        // user-B pattern: <70 3.83% (UNDER the 4.0% line) but <54 1.01% (OVER the 1.0% severe line).
        // The <70-only guard would let the raise through; the <54 co-guard must hold it.
        let s = BoostV5AutoConfig.compute(prior(tbr70: 3.83))!
        XCTAssertGreaterThan(s.committedCapU, Self.stockDefault(.committedCapU))
        let f = FakeStore()
        let res = f.apply(s, tbr: 3.83, sev54: 1.01)
        let held = res.first { $0.knob == .committedCapU }!
        XCTAssertEqual(held.outcome, .suggestedNotAppliedTbr)
        XCTAssertTrue(held.reason.contains("<54=1.01%"))
        XCTAssertNil(f.store[.committedCapU])
    }

    func testServe54GuardBoundaryAtExactlyOnePercentHolds() {
        // The <54 guard is inclusive (>= 1.0), so exactly 1.0% holds the raise.
        let s = BoostV5AutoConfig.compute(prior(tbr70: 2.0))!
        XCTAssertGreaterThan(s.committedCapU, Self.stockDefault(.committedCapU))
        let f = FakeStore()
        let res = f.apply(s, tbr: 2.0, sev54: 1.0)
        XCTAssertEqual(res.first { $0.knob == .committedCapU }!.outcome, .suggestedNotAppliedTbr)
    }

    func testRaiseAppliesWhenBothGuardsUnderTheirLines() {
        // <70 under 4.0% AND <54 under 1.0% → the raise applies normally.
        let s = BoostV5AutoConfig.compute(prior(tbr70: 2.0))!
        XCTAssertGreaterThan(s.committedCapU, Self.stockDefault(.committedCapU))
        let f = FakeStore()
        let res = f.apply(s, tbr: 2.0, sev54: 0.9)
        XCTAssertTrue(appliedKnobs(res).contains(.committedCapU))
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
    }

    func testDoseCapLoweringAppliesEvenWithSevere54Exposure() {
        // Tightenings must never be blocked, even at <54 2.0% — a lowering is protective.
        let s = BoostV5AutoConfig.compute(prior(
            manual: [0.5, 0.5, 0.5, 0.5], smb: [0.2, 0.2, 0.3], tbr70: 2.0
        ))!
        XCTAssertEqual(s.confirmedCapU, 1.5)
        let f = FakeStore()
        let res = f.apply(s, tbr: 2.0, sev54: 2.0)
        XCTAssertTrue(appliedKnobs(res).contains(.confirmedCapU))
        XCTAssertEqual(f.store[.confirmedCapU], 1.5)
    }

    // AAPS 9bb6404df2: onboarding sizes Trio's primer from the kept committed cap at the policy
    // fraction. primerCapU / committedCapU stops being that fraction once the primer is held to 2.5 U.
    func testOnboardingSizesThePrimerFromAKeptCapAtThePolicyFraction() {
        let s = BoostV5AutoConfig.compute(prior(tdd: 200, smb: [0.3], tbr70: 1.0, sev54: 0.2))!
        XCTAssertEqual(s.committedCapU, 5.0)
        XCTAssertEqual(s.primerCapU, 2.5) // held: 5.0 x 0.75 would be 3.75
        let f = FakeStore([.committedCapU: 2.5])
        f.userSetFlags = [.committedCapU] // the person's cap is kept
        _ = f.apply(s, tbr: 1.0)
        XCTAssertEqual(f.store[.committedCapU], 2.5)
        XCTAssertEqual(f.store[.primerCapU]!, (2.5 * s.primerFrac * 100).rounded() / 100, accuracy: 1E-9)
    }

    func testOnceAppliedKnobIsResolvedAndNeverReapplied() {
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore()
        _ = f.apply(s, tbr: safeTbr)
        // User later sets a knob back to something — a second (re-derived) run must not touch it.
        f.store[.committedCapU] = 0.33
        let rederived = BoostV5AutoConfig.Suggestion(
            aggression: s.aggression, hypoCaution: s.hypoCaution,
            confirmedCapU: 7.0, committedCapU: 2.0,
            cumulativeSmbCap60MinU: s.cumulativeSmbCap60MinU,
            bolusCapU: s.bolusCapU,
            fastCarbConfirm: s.fastCarbConfirm,
            aggressiveEarlyConfirm: s.aggressiveEarlyConfirm,
            velocityBudgetFloor: s.velocityBudgetFloor,
            primerCapU: s.primerCapU,
            primerFrac: s.primerFrac,
            primerTbrFallback: s.primerTbrFallback,
            rationale: s.rationale
        )
        let resAgain = f.apply(rederived, tbr: safeTbr)
        XCTAssertTrue(resAgain.isEmpty)
        XCTAssertEqual(f.store[.committedCapU], 0.33)
    }

    func testInsufficientDataResolvesNothingSoKnobsGenuinelyRetry() {
        // The caller gets no suggestion → applyAutoConfig is never invoked → no knob resolves.
        XCTAssertNil(BoostV5AutoConfig.compute(prior(days: 5)))
        let f = FakeStore()
        XCTAssertTrue(f.resolved.isEmpty) // still all eligible
        // Once data accrues, the SAME store applies everything.
        let res = f.apply(BoostV5AutoConfig.compute(prior())!, tbr: safeTbr)
        XCTAssertEqual(appliedKnobs(res), Knob.doubleKnobs)
    }

    // MARK: versioned re-migration (AAPS 131923247e — schema v2)

    // On Trio no RELEASED build ever persisted era-blind resolved marks (the per-knob resolution
    // and historical-factory awareness land together), so v2 is a scaffold + a rescue for anyone
    // who built from source in the brief window between the two.

    /// Runs the schema migration against a `FakeStore` with an explicit persisted version.
    private final class VersionedStore {
        let f: FakeStore
        var version = 0 // pre-versioning installs have no stamp
        init(_ preset: [Knob: Double] = [:]) { f = FakeStore(preset) }
        func migrate() -> [Knob] {
            BoostV5AutoConfigApply.runSchemaMigrations(
                storedVersion: version,
                knobs: Knob.doubleKnobs,
                isResolved: { self.f.resolved.contains($0) },
                isUserTuned: { self.f.isUserTuned($0) },
                clearResolved: { self.f.resolved.remove($0) },
                setVersion: { self.version = $0 }
            )
        }
    }

    func testReMigrationV2ReopensKnobStrandedAtOldFactoryValue() {
        // Stranded path: an era-blind build saw committedCap 0.25 (old-era factory), judged it
        // user-tuned, and persisted the resolved mark. The v2 audit must clear the mark so the
        // normal derivation applies the formula value on the next cycle.
        let v = VersionedStore([.committedCapU: 0.25])
        v.f.resolved.insert(.committedCapU) // as persisted by the era-blind build
        let cleared = v.migrate()
        XCTAssertEqual(cleared, [.committedCapU])
        XCTAssertFalse(v.f.resolved.contains(.committedCapU))
        XCTAssertEqual(v.version, Apply.autoConfigSchemaVersion)
        // Next cycle: the ordinary per-knob path now derives and applies the formula value.
        let s = BoostV5AutoConfig.compute(prior())!
        let res = v.f.apply(s, tbr: safeTbr)
        XCTAssertTrue(appliedKnobs(res).contains(.committedCapU))
        XCTAssertEqual(v.f.store[.committedCapU], s.committedCapU)
    }

    func testReMigrationV2KeepsGenuinelyTunedKnobResolved() {
        let v = VersionedStore([.committedCapU: 0.8]) // 0.8 ∉ {0.25, 0.5} — really tuned
        v.f.resolved.insert(.committedCapU)
        let cleared = v.migrate()
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(v.f.resolved.contains(.committedCapU))
        XCTAssertEqual(v.version, Apply.autoConfigSchemaVersion)
        // And the kept value survives the next cycle untouched.
        _ = v.f.apply(BoostV5AutoConfig.compute(prior())!, tbr: safeTbr)
        XCTAssertEqual(v.f.store[.committedCapU], 0.8)
    }

    func testReMigrationV2NoOpOnFreshInstallStillStampsVersion() {
        let v = VersionedStore() // nothing stored, nothing resolved
        let cleared = v.migrate()
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(v.f.resolved.isEmpty)
        XCTAssertTrue(v.f.store.isEmpty)
        XCTAssertEqual(v.version, Apply.autoConfigSchemaVersion)
    }

    func testReMigrationRunsOnceStampedVersionNeverReaudited() {
        let v = VersionedStore([.committedCapU: 0.25])
        v.f.resolved.insert(.committedCapU)
        XCTAssertEqual(v.migrate(), [.committedCapU]) // first startup: cleared + stamped
        // The knob resolves again at a factory-coincident value (e.g. auto-applied, later reset).
        v.f.resolved.insert(.committedCapU)
        XCTAssertTrue(v.migrate().isEmpty) // second startup: version current → no re-clear
        XCTAssertTrue(v.f.resolved.contains(.committedCapU))
    }

    // MARK: migration from the legacy global done-flag

    func testLegacyFlagMigrationResolvesOnlyTunedKnobs() {
        // tuned: confirmedCap 4.0 (∉ factories 2.5/1.0) → resolved, left alone forever.
        // stock: committedCap AT current default (the field case) → stays eligible.
        // oldEra: confirmedCap-era value on committedCap? — use committedCap 0.25 via a second
        //         store entry is impossible per knob; instead verify the old-era case on
        //         confirmedCap in testKnobStrandedAtOldEraFactoryStillDerivable. Here: absent
        //         knobs also stay eligible.
        let f = FakeStore([.confirmedCapU: 4.0, .committedCapU: Self.stockDefault(.committedCapU)])
        let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
            knobs: Knob.doubleKnobs,
            isUserTuned: { f.isUserTuned($0) },
            markResolved: { f.resolved.insert($0) }
        )
        XCTAssertEqual(migrated, [.confirmedCapU]) // off-every-factory → left alone forever
        XCTAssertEqual(f.resolved, [.confirmedCapU])
        XCTAssertFalse(f.resolved.contains(.committedCapU)) // at-stock stays eligible
    }

    func testLegacyFlagMigrationLeavesOldEraFactoryValuesEligible() {
        // A legacy install whose caps rode over from the pre-5cf1abb84 era: values at the OLD
        // factories must stay unresolved so the next cycle derives them.
        let f = FakeStore([.confirmedCapU: 1.0, .committedCapU: 0.25])
        let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
            knobs: Knob.doubleKnobs,
            isUserTuned: { f.isUserTuned($0) },
            markResolved: { f.resolved.insert($0) }
        )
        XCTAssertTrue(migrated.isEmpty)
        XCTAssertTrue(f.resolved.isEmpty)
    }

    func testFieldCaseRegressionFlagConsumedKeysAtDefaultsCapsGetApplied() {
        // AAPS field case: V6-active, months of history, TDD ~50U; committedCap stuck at
        // factory 0.5 although his derived value is 1.24. After migration (nothing resolved
        // because everything is at stock), the next cycle must apply BOTH the committed cap and
        // the cumulative cap.
        let roman = prior(
            tdd: 49.6, // 49.6/40 = 1.24 committed
            manual: [4, 4, 5, 5, 5, 6, 6, 6, 6, 6], // p90 = 6.0 → confirmedCap 6.0
            smb: [0.5, 0.5, 0.5, 0.5, 0.5] // p75 clipped at the old 0.5 cap
        )
        let s = BoostV5AutoConfig.compute(roman)!
        XCTAssertEqual(s.confirmedCapU, 6.0)
        XCTAssertEqual(s.committedCapU, 1.24)
        // cumulative = clamp(6.0 + 2×1.24, 1.0, 10.0) = 8.48 → 8.5. (fe9d8a1a13 #2: previously
        // the max(5.0, conf) ceiling collapsed this to 6.0 — confirm + ~0 holds.)
        XCTAssertEqual(s.cumulativeSmbCap60MinU, 8.5)

        // Storage as found in the field: managed knobs present at stock after the old run.
        let f = FakeStore([
            .committedCapU: Self.stockDefault(.committedCapU),
            .cumulativeSmbCap60Min: Self.stockDefault(.cumulativeSmbCap60Min)
        ])
        let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
            knobs: Knob.doubleKnobs,
            isUserTuned: { f.isUserTuned($0) },
            markResolved: { f.resolved.insert($0) }
        )
        XCTAssertTrue(migrated.isEmpty) // nothing off-default → all eligible
        let res = f.apply(s, tbr: 3.0) // the field case's TBR<70 3.0% < guard 4.0%
        XCTAssertTrue(appliedKnobs(res).contains(.committedCapU))
        XCTAssertTrue(appliedKnobs(res).contains(.cumulativeSmbCap60Min))
        XCTAssertEqual(f.store[.committedCapU], 1.24)
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], 8.5)
        // Invariant: the suggestion never auto-raises Aggression above neutral.
        XCTAssertLessThanOrEqual(s.aggression, 1.0)
    }
}
