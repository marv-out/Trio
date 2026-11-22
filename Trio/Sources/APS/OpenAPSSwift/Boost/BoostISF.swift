import Foundation

/// Boost-flavoured Dynamic ISF (V1), the Trio-side glue over the pure `DynIsf` core
/// (BoostV5Core). Produces the single adjusted `sens` value that threads through the
/// determination — predictions, eventualBG, insulinReq — where stock oref uses
/// `sens / sensitivityRatio`. Faithful to AAPS `calculateBoostIsf` (V1 only; V2 excluded):
///   sensNormalTarget = useTdd ? 1800/(TDD·ln(normalTarget/divisor+1)) : profileSens
///   sensNormalTarget *= 100/profilePercent          (profile-% inverse ISF scaling)
///   variableSens = sensNormalTarget·(1 − (1−scaler)·velocity)  at current BG (soft cap)
///   × circadian (optional)
///
/// Sensitivity adaptation (AAPS 3d9d471dbb, f393d02e55, 1c6358ac6c, 24 September 2026). With TDD
/// on, the TDD model owns sensitivity and oref autosens is not applied. With TDD off, BG impact on ISF
/// is 0, so the profile ISF is used flat, and with `boostAutosensWhenNoTdd` on (the default) the oref
/// autosens ratio divides the ISF at target, as stock oref divides `profile.sens`. Folding it in at
/// target means predictions, the current BGI and `future_sens` all move with it. A temp target that
/// sets its own sensitivity ratio replaces autosens rather than stacking with it.
///
/// FLAGGED: the exact Boost weighted-8h TDD blend (1.4·4h + 0.6·8-4h …, pull-down) is NOT
/// reproduced — Trio exposes only a single blended TDD (weightedAverage/currentTDD), not the
/// 4h/8-4h/7d/1d splits. `tdd` here is Trio's blended TDD × the adjustment factor. Exact-blend
/// fidelity needs new TDD-window plumbing (see DynIsf.blendedTdd, currently unused).
enum BoostISF {
    /// `profilePercent` = the activity profile % (100 = none); applied as 100/profilePercent.
    static func adjustedSensitivity(
        profileSens: Decimal,
        currentGlucose: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        hourOfDay: Int,
        autosens: AutosensContext,
        profile: Profile,
        preferences: Preferences
    ) -> Decimal {
        let divisor = insulinDivisor(profile: profile, preferences: preferences)
        let normalTarget = dbl(preferences.boostDynIsfNormalTarget)
        let bgCap = dbl(preferences.boostDynIsfBgCap)
        let velocity = effectiveVelocity(preferences)
        let bg = dbl(currentGlucose)

        let sensNormalTarget = unroundedSensNormalTarget(
            profileSens: profileSens,
            tdd: tdd,
            profilePercent: profilePercent,
            autosens: autosens,
            profile: profile,
            preferences: preferences
        )

        var variableSens = DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: normalTarget,
            insulinDivisor: divisor,
            sensNormalTarget: sensNormalTarget,
            velocity: velocity,
            bgCap: bgCap,
            useCap: true
        )

        // Circadian ISF overlay (AAPS applies it to variable_sens when enabled).
        if preferences.boostEnableCircadianIsf {
            variableSens *= CircadianISF.sensitivity(hourOfDay: hourOfDay)
        }

        // Autosens, where it applies, is already in sensNormalTarget.
        return Decimal(variableSens).jsRounded(scale: 1)
    }

    /// Per-BG ISF for the prediction loops, faithful to AAPS `getIsfByProfile(bg, profile, true)`.
    /// Recomputes the velocity-blended ISF at the given predicted BG (with the soft cap).
    static func isfByProfile(
        bg: Double,
        sensNormalTarget: Double,
        profile: Profile,
        preferences: Preferences,
        useCap: Bool
    ) -> Double {
        DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: dbl(preferences.boostDynIsfNormalTarget),
            insulinDivisor: insulinDivisor(profile: profile, preferences: preferences),
            sensNormalTarget: sensNormalTarget,
            velocity: effectiveVelocity(preferences),
            bgCap: dbl(preferences.boostDynIsfBgCap),
            useCap: useCap
        )
    }

    /// `sensNormalTarget` (ISF at normal target) for a given context — needed by the prediction
    /// loops so they can recompute per-BG ISF without re-deriving it each tick.
    static func sensNormalTarget(
        profileSens: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        autosens: AutosensContext,
        profile: Profile,
        preferences: Preferences
    ) -> Double {
        let sens = unroundedSensNormalTarget(
            profileSens: profileSens,
            tdd: tdd,
            profilePercent: profilePercent,
            autosens: autosens,
            profile: profile,
            preferences: preferences
        )
        // AAPS stores sensNormalTarget rounded to 0.1 before getIsfByProfile/future_sens consume it.
        return (sens * 10.0).rounded() / 10.0
    }

    /// The ISF at normal target before rounding, shared by `adjustedSensitivity` and
    /// `sensNormalTarget` so the two cannot disagree: the prediction loops must never run a derived
    /// ISF, or an autosens adjustment, that the dosing path did not.
    private static func unroundedSensNormalTarget(
        profileSens: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        autosens: AutosensContext,
        profile: Profile,
        preferences: Preferences
    ) -> Double {
        let divisor = insulinDivisor(profile: profile, preferences: preferences)
        let globalScale = profilePercent > 0 ? 100.0 / profilePercent : 1.0
        let tddValue = dbl(tdd)
        var sens: Double
        // Implausible-TDD guard (AAPS 5fc7951452): applied to the ADJUSTED TDD, matching the
        // Kotlin, which applies the adjustment factor before the guard. Below the floor the
        // derivation is skipped entirely and the profile ISF stands for this cycle.
        let tddAdjusted = tddValue * dbl(preferences.boostDynIsfAdjustmentFactor) / 100.0
        let tddImplausible = DynIsf.tddImplausibleForProfile(
            tdd: tddAdjusted, profileSens: dbl(profileSens)
        )
        if preferences.boostUseTdd, tddValue > 0, !tddImplausible {
            sens = DynIsf.isfTargetV1(
                tdd: tddAdjusted,
                normalTarget: dbl(preferences.boostDynIsfNormalTarget),
                insulinDivisor: divisor
            )
        } else {
            sens = dbl(profileSens)
        }
        // Profile-% inverse scaling (AAPS globalScale): active 80% → ISF ×1.25 (more sensitive).
        sens *= globalScale
        // Autosens on a static profile ISF (AAPS 1c6358ac6c), after the scaling, as in the Kotlin.
        return DynIsf.autosensAdjustedIsf(
            sensNormalTarget: sens,
            useTdd: preferences.boostUseTdd,
            autosensWhenNoTdd: preferences.boostAutosensWhenNoTdd,
            tempTargetRatio: autosens.tempTargetRatio,
            orefAutosensRatio: autosens.orefRatio
        )
    }

    /// The ISF fields AAPS calculateBoostIsf hands the V1 engine: sensNormalTarget and variableSens
    /// rounded to 0.1 (variableSens from the unrounded ISF at target, at the soft-capped current BG,
    /// without the circadian factor, which the engine applies itself), the soft-capped BG, and the
    /// TDD the ISF came from (0 when the TDD model is off or its value was rejected).
    static func v1Inputs(
        profileSens: Decimal,
        currentGlucose: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        autosens: AutosensContext,
        profile: Profile,
        preferences: Preferences
    ) -> (sensNormalTarget: Double, variableSens: Double, bgCapped: Double, tdd: Double) {
        let sensNT = unroundedSensNormalTarget(
            profileSens: profileSens,
            tdd: tdd,
            profilePercent: profilePercent,
            autosens: autosens,
            profile: profile,
            preferences: preferences
        )
        let bg = dbl(currentGlucose)
        let bgCap = dbl(preferences.boostDynIsfBgCap)
        let bgCapped = bg > bgCap ? bgCap + (bg - bgCap) / 3.0 : bg
        let variable = DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: dbl(preferences.boostDynIsfNormalTarget),
            insulinDivisor: insulinDivisor(profile: profile, preferences: preferences),
            sensNormalTarget: sensNT,
            velocity: effectiveVelocity(preferences),
            bgCap: bgCap,
            useCap: true
        )
        let tddValue = dbl(tdd)
        let tddAdjusted = tddValue * dbl(preferences.boostDynIsfAdjustmentFactor) / 100.0
        let usedTdd = preferences.boostUseTdd && tddValue > 0
            && !DynIsf.tddImplausibleForProfile(tdd: tddAdjusted, profileSens: dbl(profileSens))
        return (
            (sensNT * 10.0).rounded() / 10.0,
            (variable * 10.0).rounded() / 10.0,
            bgCapped,
            usedTdd ? tddAdjusted : 0
        )
    }

    /// BG impact on ISF as the engine uses it: 0 with TDD-based ISF off (AAPS 3d9d471dbb).
    static func effectiveVelocity(_ preferences: Preferences) -> Double {
        DynIsf.effectiveVelocity(useTdd: preferences.boostUseTdd, velocityPct: dbl(preferences.boostDynIsfVelocity))
    }

    /// What the autosens fold-in needs from the cycle: the oref autosens ratio, taken before Trio's
    /// own dynamic ISF or a temp target replaces it, and the temp-target ratio Boost's ISF derivation
    /// would set, which replaces autosens when it is not 1.
    struct AutosensContext {
        let orefRatio: Double
        let tempTargetRatio: Double

        static let neutral = AutosensContext(orefRatio: 1.0, tempTargetRatio: 1.0)

        static func make(
            orefRatio: Decimal,
            isTempTarget: Bool,
            targetBg: Decimal,
            profile: Profile,
            preferences: Preferences
        ) -> AutosensContext {
            AutosensContext(
                orefRatio: dbl(orefRatio),
                tempTargetRatio: DynIsf.tempTargetRatio(
                    isTempTarget: isTempTarget,
                    targetBg: dbl(targetBg),
                    normalTarget: dbl(preferences.boostDynIsfNormalTarget),
                    halfBasalTarget: dbl(profile.halfBasalExerciseTarget),
                    highTtRaisesSens: profile.highTemptargetRaisesSensitivity,
                    lowTtLowersSens: profile.lowTemptargetLowersSensitivity,
                    autosensMin: dbl(profile.autosensMin),
                    autosensMax: dbl(profile.autosensMax)
                )
            )
        }
    }

    /// The ratio that drives basal, the autosens target shift and carbohydrate absorption time under
    /// Boost (AAPS `selectSensitivityRatio`). The ISF result's own ratio is 1.0 here, because the TDD
    /// 24 h / 7 d adjustment and Boost's temp-target ISF ratio are not ported (see BOOST.md).
    static func sensitivityRatio(autosens: AutosensContext, preferences: Preferences) -> Decimal {
        Decimal(DynIsf.selectSensitivityRatio(
            useTdd: preferences.boostUseTdd,
            autosensWhenNoTdd: preferences.boostAutosensWhenNoTdd,
            isfResultRatio: 1.0,
            orefAutosensRatio: autosens.orefRatio
        ))
    }

    /// Boost dosing sensitivity (`future_sens`), faithful to AAPS DetermineBasalBoost (~750-787).
    /// A BG-context-weighted ISF used ONLY for the insulinReq math (not predictions): it evaluates
    /// getIsfByProfile (uncapped) at a blend of the current BG (`sensBg`, soft-capped /3) and the
    /// eventual BG (`fsensBg`, soft-capped /2) — or minPredBG when falling — per the same conditions
    /// AAPS uses. Returns ISF rounded to 0.1.
    static func futureSens(
        currentBg: Double,
        eventualBg: Double,
        minPredBg: Double,
        delta: Double,
        shortAvgDelta: Double,
        longAvgDelta: Double,
        deltaAccl: Double,
        cob: Double,
        sensNormalTarget: Double,
        profile: Profile,
        preferences: Preferences
    ) -> Decimal {
        let value = DynIsf.futureSens(
            currentBg: currentBg,
            eventualBg: eventualBg,
            minPredBg: minPredBg,
            delta: delta,
            shortAvgDelta: shortAvgDelta,
            longAvgDelta: longAvgDelta,
            deltaAccl: deltaAccl,
            cob: cob,
            sensNormalTarget: sensNormalTarget,
            normalTarget: dbl(preferences.boostDynIsfNormalTarget),
            insulinDivisor: insulinDivisor(profile: profile, preferences: preferences),
            velocity: effectiveVelocity(preferences),
            bgCap: dbl(preferences.boostDynIsfBgCap)
        )
        return Decimal(value)
    }

    /// AAPS Boost insulin divisor: peak (coerced 30–75) → (90−peak)+30 if peak<60 else +40.
    static func insulinDivisor(profile: Profile, preferences: Preferences) -> Double {
        let peakRaw = preferences.useCustomPeakTime ? dbl(profile.insulinPeakTime) : curveDefaultPeak(profile.curve)
        let peak = min(max(peakRaw, 30.0), 75.0)
        return peak < 60.0 ? (90.0 - peak) + 30.0 : (90.0 - peak) + 40.0
    }

    private static func curveDefaultPeak(_ curve: InsulinCurve) -> Double {
        switch curve {
        case .ultraRapid: return 55.0
        case .rapidActing: return 75.0
        default: return 75.0 // bilinear
        }
    }

    private static func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
}
