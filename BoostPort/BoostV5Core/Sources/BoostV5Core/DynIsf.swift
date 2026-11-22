import Foundation

public enum DynIsf {
    /// Magic numbers, matched exactly to AAPS Boost source.
    public enum Const {
        // ---- TDD blend (OpenAPSBoostPlugin.calculateBoostIsf) ----
        /// Weight applied to the last-4h TDD in the weighted-8h estimate. (1.4 * last4h)
        public static let weight4h: Double = 1.4
        /// Weight applied to the 8h..4h TDD in the weighted-8h estimate. (0.6 * last8to4h)
        public static let weight8to4h: Double = 0.6
        /// Scale-up factor turning the 8h window estimate into a daily-equivalent. (… ) * 3
        public static let weighted8hScale: Double = 3.0
        /// Pull-down trigger: weighted8h < 0.75 * tdd7d.
        public static let pullDownThreshold: Double = 0.75

        /// Blend weight on the weighted-8h component.
        public static let blendWeightWeighted8h: Double = 0.33
        /// Blend weight on the 7d component (or the pulled-down adjusted7d in the pull-down branch).
        public static let blendWeight7d: Double = 0.34
        /// Blend weight on the 1d component.
        public static let blendWeight1d: Double = 0.33

        /// Adjustment-factor clamp (percent), from IntKey.ApsBoostDynIsfAdjustmentFactor.coerceIn(1.0, 300.0).
        public static let adjustmentFactorMinPct: Double = 1.0
        public static let adjustmentFactorMaxPct: Double = 300.0

        /// Minimum believable blended TDD, as a fraction of the TDD the person's own profile ISF
        /// implies through the 1800 rule (AAPS `DYNISF_MIN_TDD_FRACTION`, 2026-07-30). Below this
        /// the insulin history is treated as incomplete and dynamic ISF is not derived.
        ///
        /// 0.35 is deliberately liberal. Falling back is safe-signed: `profileSens` is the value
        /// the person or their clinician configured, so a false positive costs one cycle of
        /// dynamic responsiveness, while a false negative paralyses dosing. The field case that
        /// motivated the guard sat at 0.22 of implied.
        public static let minTddFractionOfProfileImplied: Double = 0.35

        // ---- ISF target formula ----
        /// V1: ISF = 1800 / (TDD * ln(normalTarget/insulinDivisor + 1)).
        /// Boost uses V1 only; the V2 `2300/(…·TDD²·0.02)` formula is intentionally NOT ported
        /// (known issues, excluded from Boost).
        public static let isfNumeratorV1: Double = 1800.0

        // ---- Soft bg cap (getIsfByProfile / calculateBoostIsf) ----
        /// Above the cap: bgAdj = cap + (bg - cap) / 3.0.
        public static let softCapDivisor: Double = 3.0
    }

    // MARK: - TDD blend

    /// Blended TDD from the four TDD components, matching `calculateBoostIsf`.
    ///
    /// weighted8h = ((1.4 * last4h) + (0.6 * last8to4h)) * 3
    /// If weighted8h < 0.75 * tdd7d:
    ///   adjusted7d = weighted8h + (weighted8h / tdd7d) * (tdd7d - weighted8h)
    ///   blended    = adjusted7d * 0.34 + tdd1d * 0.33 + weighted8h * 0.33
    /// else:
    ///   blended    = weighted8h * 0.33 + tdd7d * 0.34 + tdd1d * 0.33
    /// final = blended * (clampedAdjustmentPct / 100)
    public static func blendedTdd(
        last4h: Double,
        last8to4h: Double,
        tdd7d: Double,
        tdd1d: Double,
        adjustmentFactorPct: Double
    ) -> Double {
        let weighted8h = ((Const.weight4h * last4h) + (Const.weight8to4h * last8to4h)) * Const.weighted8hScale

        let blended: Double
        if weighted8h < (Const.pullDownThreshold * tdd7d) {
            // Recent usage well below 7d average — pull the 7d average toward recent reality.
            let adjusted7d = weighted8h + ((weighted8h / tdd7d) * (tdd7d - weighted8h))
            blended = (adjusted7d * Const.blendWeight7d)
                + (tdd1d * Const.blendWeight1d)
                + (weighted8h * Const.blendWeightWeighted8h)
        } else {
            blended = (weighted8h * Const.blendWeightWeighted8h)
                + (tdd7d * Const.blendWeight7d)
                + (tdd1d * Const.blendWeight1d)
        }

        let clampedPct = min(max(adjustmentFactorPct, Const.adjustmentFactorMinPct), Const.adjustmentFactorMaxPct)
        return blended * (clampedPct / 100.0)
    }

    // MARK: - ISF target

    /// Whether `tdd` is too low to be believed against what `profileSens` implies, so dynamic ISF
    /// must not be derived from it (AAPS `tddImplausibleForProfile`, 2026-07-30).
    ///
    /// The old condition was `tdd > 0`, which does not ensure a sane ISF: 0.1 U/day passes it and
    /// 1800/(tdd x logTerm) then explodes. Observed in the field on a cross-fork migration, where a
    /// fresh database reported 3.1 to 4.1 U/day against a true 20, dynamic ISF reached 5550 to 8944
    /// mg/dL/U against a profile ISF of 100, insulin requirement computed at or below zero, and the
    /// loop delivered nothing for 3.5 h while glucose climbed to 276 mg/dL.
    ///
    /// The floor is anchored on the profile's own implied TDD rather than a rolling self-reference,
    /// because a rolling baseline is contaminated by the very failure it has to catch: the field
    /// case's own median TDD was the broken value. Anchoring on the profile also makes it
    /// self-scaling, so a person on U200 insulin, a child and a high-TDD adult need no separate
    /// threshold. A non-positive `profileSens` gives no reference to judge against and returns
    /// false, leaving the existing `tdd > 0` test to act.
    public static func tddImplausibleForProfile(tdd: Double, profileSens: Double) -> Bool {
        guard profileSens > 0 else { return false }
        let impliedTdd = Const.isfNumeratorV1 / profileSens
        return tdd < impliedTdd * Const.minTddFractionOfProfileImplied
    }

    /// V1 ISF at normal target: 1800 / (TDD * ln(normalTarget/insulinDivisor + 1)).
    public static func isfTargetV1(
        tdd: Double,
        normalTarget: Double,
        insulinDivisor: Double
    ) -> Double {
        let logTerm = log((normalTarget / insulinDivisor) + 1.0)
        return Const.isfNumeratorV1 / (tdd * logTerm)
    }

    // MARK: - Variable sensitivity

    /// variable_sens = sensNormalTarget * (1 - (1 - scaler) * velocity)
    /// where scaler = ln(normalTarget/insulinDivisor + 1) / ln(bgCapped/insulinDivisor + 1).
    ///
    /// `bgCapped` is the (already soft-capped) BG used in the log; pass the raw BG if no cap applies.
    public static func variableSens(
        sensNormalTarget: Double,
        normalTarget: Double,
        bgCapped: Double,
        insulinDivisor: Double,
        velocity: Double
    ) -> Double {
        let sbg = log((bgCapped / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sbg
        return sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
    }

    /// Soft-cap variant matching `DetermineBasalBoost.getIsfByProfile(bg, profile, useCap)`.
    ///
    /// If useCap and bg > bgCap: bgAdj = bgCap + (bg - bgCap) / 3.0.
    /// sensBG = ln(bgAdj/insulinDivisor + 1)
    /// scaler = ln(normalTarget/insulinDivisor + 1) / sensBG
    /// return sensNormalTarget * (1 - (1 - scaler) * velocity)
    public static func getIsfByProfile(
        bg: Double,
        normalTarget: Double,
        insulinDivisor: Double,
        sensNormalTarget: Double,
        velocity: Double,
        bgCap: Double,
        useCap: Bool
    ) -> Double {
        var bgAdj = bg
        if useCap, bgAdj > bgCap {
            bgAdj = bgCap + (bgAdj - bgCap) / Const.softCapDivisor
        }
        let sensBG = log((bgAdj / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sensBG
        return sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
    }

    // MARK: - delta acceleration

    /// `delta_accl` exactly as AAPS DetermineBasalBoost (~269): guarded so a near-zero shortAvgDelta
    /// yields 0 (not a spurious 50·delta from the /max(|short|,2) floor), then rounded to 2 dp.
    public static func deltaAccl(delta: Double, shortAvgDelta: Double) -> Double {
        guard abs(shortAvgDelta) > 0.001 else { return 0.0 }
        let raw = 100.0 * (delta - shortAvgDelta) / max(abs(shortAvgDelta), 2.0)
        return (raw * 100.0).rounded() / 100.0
    }

    // MARK: - Dosing sensitivity (future_sens)

    /// Boost `future_sens` (DetermineBasalBoost ~750-787): the BG-context-weighted dosing ISF.
    /// `sensBg` = current BG soft-capped /3, `fsensBg` = eventual BG soft-capped /2; the blend BG is
    /// chosen by condition, then ISF = getIsfByProfile(blend, useCap:false), rounded to 0.1.
    public static func futureSens(
        currentBg: Double,
        eventualBg: Double,
        minPredBg: Double,
        delta: Double,
        shortAvgDelta: Double,
        longAvgDelta: Double,
        deltaAccl: Double,
        cob: Double,
        sensNormalTarget: Double,
        normalTarget: Double,
        insulinDivisor: Double,
        velocity: Double,
        bgCap: Double
    ) -> Double {
        let sensBg = currentBg > bgCap ? bgCap + (currentBg - bgCap) / 3.0 : currentBg
        let fsensBg = eventualBg > bgCap ? bgCap + (eventualBg - bgCap) / 2.0 : eventualBg

        func isf(_ bg: Double) -> Double {
            getIsfByProfile(
                bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
                sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: false
            )
        }

        let value: Double
        if cob > 0, deltaAccl > 0 {
            value = isf(fsensBg * 0.75 + sensBg * 0.25)
        } else if delta > 4, deltaAccl > 10, currentBg < 180, eventualBg > currentBg {
            value = isf(fsensBg * 0.5 + sensBg * 0.5)
        } else if currentBg > 180, abs(delta) < 2, abs(shortAvgDelta) < 2, abs(longAvgDelta) < 2 {
            value = isf(minPredBg * 0.25 + sensBg * 0.75)
        } else if (delta > 0 && deltaAccl > 1) || eventualBg > currentBg {
            value = isf(sensBg)
        } else {
            value = isf(max(minPredBg, 1.0))
        }
        return (value * 10.0).rounded() / 10.0
    }

    // MARK: - Sensitivity ratio selection

    /// Which sensitivity-ratio path `calculateBoostIsf` takes.
    /// - tdd:      useTdd && adjustSens — ratio = clamp(tdd24h / tdd7d, autosensMin, autosensMax).
    /// - autosens: !useTdd — fall back to the oref autosens ratio passed in (no clamp here; oref already clamps).
    /// - legacy:   ratio = 1.0.
    public enum SensitivityRatioMode {
        case tdd
        case autosens
        case legacy
    }

    public static func sensitivityRatio(
        mode: SensitivityRatioMode,
        tdd24h: Double,
        tdd7d: Double,
        autosensRatio: Double,
        autosensMin: Double,
        autosensMax: Double
    ) -> Double {
        switch mode {
        case .tdd:
            // ratio = max(min(tddLast24H / tdd7D, autosensMax), autosensMin)
            return max(min(tdd24h / tdd7d, autosensMax), autosensMin)
        case .autosens:
            return autosensRatio
        case .legacy:
            return 1.0
        }
    }

    // MARK: - Sensitivity with TDD-based ISF off (AAPS 3d9d471dbb, f393d02e55, 1c6358ac6c)

    /// BG impact on ISF as a fraction, as the engine uses it. With TDD-based ISF off it is 0 whatever
    /// is stored, so the profile ISF is used flat (AAPS 3d9d471dbb read-time guard in
    /// `calculateBoostIsf`). Without a TDD there is nothing for the BG curve to adapt, and with the curve
    /// on, BG entered the dose through ISF and again through the target.
    public static func effectiveVelocity(useTdd: Bool, velocityPct: Double) -> Double {
        useTdd ? velocityPct / 100.0 : 0.0
    }

    /// ISF at target after autosens, for a static profile ISF (AAPS `autosensAdjustedIsf`, 1c6358ac6c).
    /// Stock oref divides the profile ISF by the autosens ratio and uses the result for predictions and
    /// for the dose. Boost builds every sensitivity from the ISF at target, so the ratio is applied
    /// there. Not applied with TDD-based ISF (TDD owns sensitivity), with the no-TDD autosens switch
    /// off, when a temp target has set its own ratio (stock lets that replace autosens rather than
    /// stack), or for a ratio that is not positive.
    public static func autosensAdjustedIsf(
        sensNormalTarget: Double,
        useTdd: Bool,
        autosensWhenNoTdd: Bool,
        tempTargetRatio: Double,
        orefAutosensRatio: Double
    ) -> Double {
        if useTdd || !autosensWhenNoTdd || tempTargetRatio != 1.0 || orefAutosensRatio <= 0.0 {
            return sensNormalTarget
        }
        return sensNormalTarget / orefAutosensRatio
    }

    /// The ratio that drives basal, the autosens target shift and carbohydrate absorption time under
    /// Boost (AAPS `selectSensitivityRatio`). TDD-based ISF and oref autosens are alternative
    /// adaptation mechanisms, never both: with TDD on the TDD model's ratio applies, with TDD off and
    /// the no-TDD autosens switch on the oref ratio applies, and otherwise the ISF result's ratio, which
    /// is 1.0 unless a temp target set one.
    public static func selectSensitivityRatio(
        useTdd: Bool,
        autosensWhenNoTdd: Bool,
        isfResultRatio: Double,
        orefAutosensRatio: Double
    ) -> Double {
        if useTdd { return isfResultRatio }
        if autosensWhenNoTdd { return orefAutosensRatio }
        return isfResultRatio
    }

    /// The temp-target sensitivity ratio `calculateBoostIsf` derives, or 1.0 when no temp target sets
    /// one. A high temp target raises sensitivity and a low one lowers it, each behind its own switch,
    /// on the half-basal-target curve and clamped to the autosens limits. Used here to decide whether
    /// a temp target replaces autosens.
    public static func tempTargetRatio(
        isTempTarget: Bool,
        targetBg: Double,
        normalTarget: Double,
        halfBasalTarget: Double,
        highTtRaisesSens: Bool,
        lowTtLowersSens: Bool,
        autosensMin: Double,
        autosensMax: Double
    ) -> Double {
        guard isTempTarget,
              (highTtRaisesSens && targetBg > normalTarget) || (lowTtLowersSens && targetBg < normalTarget)
        else { return 1.0 }
        let c = halfBasalTarget - normalTarget
        guard c * (c + targetBg - normalTarget) > 0.0 else { return 1.0 }
        return max(min(c / (c + targetBg - normalTarget), autosensMax), autosensMin)
    }

    /// BG impact on ISF after `reconcileSensitivitySettings`, with what was changed.
    public struct SensitivitySettings: Equatable, Sendable {
        public let velocityPct: Double
        public let zeroedVelocity: Bool
        public let restoredVelocity: Bool
        public var changed: Bool { zeroedVelocity || restoredVelocity }
    }

    /// Settings that must not be on together (AAPS `reconcileSensitivitySettings`, 3d9d471dbb and
    /// f393d02e55). With TDD-based ISF off, BG impact on ISF is set to 0, so the stored value matches
    /// what `effectiveVelocity` already enforces. When TDD-based ISF is switched on it is set back to
    /// `velocityOnPct` once, on that transition only, so a value chosen afterwards with TDD on is kept.
    /// The AAPS half that clears "TDD sensitivity adjustment" has no Trio counterpart: the port never
    /// had the 24 h / 7 d adjustment or its curve-ratio fallback.
    public static func reconcileSensitivitySettings(
        useTdd: Bool,
        velocityPct: Double,
        tddJustEnabled: Bool = false,
        velocityOnPct: Double = 100.0
    ) -> SensitivitySettings {
        let zero = !useTdd && velocityPct != 0.0
        let restore = useTdd && tddJustEnabled && velocityPct != velocityOnPct
        return SensitivitySettings(
            velocityPct: zero ? 0.0 : (restore ? velocityOnPct : velocityPct),
            zeroedVelocity: zero,
            restoredVelocity: restore
        )
    }

    /// True when TDD-based ISF is on now and was recorded off. No record (nil) is not a transition, so
    /// an upgrade leaves a TDD user's BG impact as it is and only records the state.
    public static func isTddJustEnabled(lastUseTdd: Bool?, useTdd: Bool) -> Bool {
        useTdd && lastUseTdd == false
    }
}
