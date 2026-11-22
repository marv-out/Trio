import Foundation

/// Boost V5 auto-configuration — derive sensible initial V5 knobs from the user's own recent dosing
/// history (default: last 14 days) the first time they switch to Boost V5.
///
/// Faithful Swift port of the AAPS `BoostV5AutoConfig` (Kotlin). Algorithm-agnostic: it reads dosing
/// + glycaemia (TDD, bolus/SMB sizes, TBR, maxIOB/maxBolus), so it works equally for a Boost-V1 user
/// (AAPS) or a **standard oref** user (Trio) — the prior engine doesn't matter. PURE: the host
/// gathers the inputs and applies + logs the result. Suggestion-only — the caller writes a knob only
/// if the user hasn't already set it, and surfaces what it set.
///
/// Conservative by design: never auto-RAISE aggression above neutral; safety knobs (HypoCaution,
/// caps) bound rather than embolden; proven maxIOB/bolus carried over; aggression refines once shadow
/// data exists.
public enum BoostV5AutoConfig {
    /// The committed cap and primer settings' maxima (their slider and decode ranges). Auto-config
    /// uses the committed cap's whole range, at onboarding and in the weekly re-derivation, and holds
    /// the primer to its own (AAPS Boost 6.3.3 9bb6404df2, which removed COMMITTED_CAP_AUTO_MAX).
    public static let committedCapMaxU = 5.0
    public static let primerCapMaxU = 2.5
    public static let minDays = 7
    public static let minBgReadings = 1500 // ~7 days of 5-min CGM minus gaps
    private static let tbr70Target = 4.0 // % time <70 mg/dL
    private static let sev54Target = 1.0 // % time <54 mg/dL
    /// Hypo-prone history cut-points (drive both the Aggression ease-down and fastCarbConfirm).
    /// Named + shared per the AAPS d91a6a2617 quality pass (SEV54_HYPO_PRONE / TBR70_HYPO_PRONE).
    public static let sev54HypoProne = 1.5
    public static let tbr70HypoProne = 6.0

    /// Strict well-controlled cut-points that auto-enable the insulin-adding opt-in switches,
    /// being aggressive early confirm and the velocity-budget floor (AAPS 2026-07-17). Much tighter
    /// than the hypo-prone cut above, because these switches deliberately add a little insulin and
    /// may only auto-engage for someone whose trailing low-glucose exposure is clearly small. The
    /// pre-push cohort backtest set them: time below 70 under 1.5% and time below 54 under 0.3%
    /// enabled three of the eight users and excluded the rest. Either switch can still be turned on
    /// by hand; auto-config only picks a safe default, and the velocity-budget floor additionally
    /// has a live fail-closed 14-day gate downstream.
    public static let wellControlledMaxTbr70 = 1.5
    public static let wellControlledMaxSev54 = 0.3

    /// Minimum manual (NORMAL) boluses in the window before their p90 may drive the Confirmed cap.
    /// Backtest evidence (7-user migration cohort, 2026-07-06, AAPS fe9d8a1a13): one user's derived
    /// confirmedCap of 6.8 U rested on a p90 of just FOUR manual boluses — one of them an 8 U
    /// outlier. A percentile of n=4 is noise, not a dose habit. Below this floor the Confirmed cap
    /// falls back to the SMB p95 alone (still clamped to [1.5, 7.5]).
    public static let minManualBolusSamples = 10
    /// Every fraction of the committed cap the primer is sized with: hypo-prone, neither, and well
    /// controlled (AAPS PRIMER_FRACTIONS).
    public static let primerFractions = [0.375, 0.6, 0.75]

    /// Upper clamp of the derived rolling-60-min cumulative SMB cap — the preference range max of
    /// `boostCumulativeSmbCap60Min` (0…10). The cap formula is "one confirm shot + two holds"; the
    /// clamp only stops it exceeding what the preference can express. (AAPS fe9d8a1a13.)
    public static let cumulativeCapMaxU = 10.0

    /// What the host gathers from the user's last-N-day history (any prior engine).
    public struct PriorDosing: Sendable {
        public let daysWithData: Int
        public let bgReadingCount: Int
        public let tddMedianU: Double
        public let manualBolusesU: [Double] // NORMAL (meal/manual) boluses
        public let smbAmountsU: [Double] // SMB micro-boluses
        public let tbrBelow70Pct: Double
        public let timeBelow54Pct: Double
        public let meanGlucoseMgdl: Double
        public let currentMaxBolusU: Double

        public init(
            daysWithData: Int, bgReadingCount: Int, tddMedianU: Double,
            manualBolusesU: [Double], smbAmountsU: [Double],
            tbrBelow70Pct: Double, timeBelow54Pct: Double, meanGlucoseMgdl: Double,
            currentMaxBolusU: Double
        ) {
            self.daysWithData = daysWithData
            self.bgReadingCount = bgReadingCount
            self.tddMedianU = tddMedianU
            self.manualBolusesU = manualBolusesU
            self.smbAmountsU = smbAmountsU
            self.tbrBelow70Pct = tbrBelow70Pct
            self.timeBelow54Pct = timeBelow54Pct
            self.meanGlucoseMgdl = meanGlucoseMgdl
            self.currentMaxBolusU = currentMaxBolusU
        }
    }

    /// Suggested V5 knobs (each clamped to its preference range) + human-readable reasons.
    public struct Suggestion: Sendable, Equatable {
        public let aggression: Double
        public let hypoCaution: Double
        public let confirmedCapU: Double
        public let committedCapU: Double
        public let cumulativeSmbCap60MinU: Double
        public let bolusCapU: Double
        public let fastCarbConfirm: Bool
        /// Insulin-adding opt-in switches, enabled only for a clearly well-controlled history.
        public let aggressiveEarlyConfirm: Bool
        public let velocityBudgetFloor: Bool
        /// Early-primer ceiling in units, 0 meaning off, and the delivery routing.
        public let primerCapU: Double
        /// The policy fraction of the committed cap. primerCapU / committedCapU differs from it once the
        /// primer is held to its own maximum, so sizing from a committed cap takes this instead.
        public let primerFrac: Double
        public let primerTbrFallback: Bool
        public let rationale: [String]
    }

    /// Returns nil when there isn't enough data to responsibly auto-configure.
    public static func compute(_ p: PriorDosing) -> Suggestion? {
        guard p.daysWithData >= minDays, p.bgReadingCount >= minBgReadings else { return nil }

        var reasons: [String] = []
        let hypoProne = p.timeBelow54Pct > sev54HypoProne || p.tbrBelow70Pct > tbr70HypoProne

        // HypoCaution [1.0..2.0]
        let cautionRaw = 1.0
            + max(0.0, p.tbrBelow70Pct - tbr70Target) / 4.0
            + max(0.0, p.timeBelow54Pct - sev54Target) * 0.5
        let hypoCaution = round1(min(max(cautionRaw, 1.0), 2.0))
        reasons
            .append("HypoCaution \(hypoCaution) (TBR<70 \(pct(p.tbrBelow70Pct)), <54 \(pct(p.timeBelow54Pct)) vs targets 4%/1%)")

        // Aggression [0.7..1.6] — never auto-raised above 1.0
        let aggression = round2(
            hypoProne ? 0.85
                : (p.tbrBelow70Pct > tbr70Target) ? 0.92
                : 1.0
        )
        reasons
            .append(
                "Aggression \(aggression) (\(aggression < 1.0 ? "gentle — hypo history" : "neutral"); refines after shadow period)"
            )

        // Confirmed cap [1.5..7.5]: cover their biggest typical single dose (meal bolus p90 or SMB
        // p95). The manual-bolus p90 participates only with a statistically honest sample
        // (>= minManualBolusSamples in the window) — see the constant's doc for the n=4 case.
        let manualP90 = p.manualBolusesU.count >= minManualBolusSamples ? percentile(p.manualBolusesU, 90) : 0.0
        let confirmedCapU = round2(min(max(max(manualP90, percentile(p.smbAmountsU, 95)), 1.5), 7.5))
        reasons.append("Confirmed cap \(confirmedCapU)U (≈ your biggest typical single dose)")

        // Committed cap [0.25..committedCapMaxU]: routine per-cycle hold = max(typical SMB p75, TDD/40), floored.
        // It passes 2.5 U only above a median TDD of 100 U or an SMB 75th percentile above 2.5 U.
        let committedCapU = round2(min(max(max(percentile(p.smbAmountsU, 75), p.tddMedianU / 40.0), 0.25), committedCapMaxU))
        reasons.append("Committed cap \(committedCapU)U (max of your routine SMB size and TDD/40)")

        let cumulativeSmbCap60MinU = cumulativeCap60Min(confirmedCapU: confirmedCapU, committedCapU: committedCapU)
        reasons.append("Cumulative SMB cap/60min \(cumulativeSmbCap60MinU)U (limits dose frequency)")

        let bolusCapU = round1(min(max(p.currentMaxBolusU, 0.1), 10.0))
        reasons.append("Bolus cap \(bolusCapU)U carried from your settings")

        let fastCarbConfirm = !hypoProne
        if hypoProne { reasons.append("Fast-carb confirm OFF (cautious start — notable hypo history)") }

        // The two insulin-adding switches auto-enable only on the strict cut above, which is tighter
        // than fastCarbConfirm's test because they add insulin rather than merely reshaping when it
        // is given. Either can still be set by hand.
        let wellControlled = p.tbrBelow70Pct < wellControlledMaxTbr70 && p.timeBelow54Pct < wellControlledMaxSev54
        let aggressiveEarlyConfirm = wellControlled
        let velocityBudgetFloor = wellControlled
        reasons.append(
            wellControlled
                ? "Confirm sooner + velocity-budget floor ON (low-glucose exposure well within target: "
                + "<70 \(pct(p.tbrBelow70Pct)), <54 \(pct(p.timeBelow54Pct)))"
                : "Confirm sooner + velocity-budget floor OFF (enabled only for very low low-glucose exposure)"
        )

        // Early primer. Everyone with enough data gets one, but the size scales with control and
        // the delivery routes anyone not clearly well-controlled through the retractable temp
        // basal, which unwinds, rather than a bolus, which does not.
        //
        // The fractions were re-levelled for the 2026-07-30 sizing rework. The cap used to be a
        // base that an acceleration scale multiplied by up to two, and because that scale saturated
        // the doubled peak was paid on five of six observed live fires, flat traces included. The
        // scale is gone and the cap is now a true ceiling reached only at a confirm-strength rise
        // with glucose in band and insulin headroom to spare. Keeping the old fractions would have
        // halved the peak and left the sized dose rounding to nothing at most real onsets, so they
        // are raised by half. The new ceiling lands at three quarters of the old effective peak: a
        // deliberate quarter cut at full strength, on top of the much larger cut everywhere below
        // it, measured at about 85% less primer insulin overall and concentrated on genuine rises.
        let primerFrac: Double = hypoProne ? primerFractions[0] : (wellControlled ? primerFractions[2] : primerFractions[1])
        // The bound is one commit shot. The primer is an advance on the CONFIRMED shot, so it
        // should never exceed the shot it advances. Since the fraction is at most 0.75 this is an
        // invariant rather than a cutoff, and it scales in the person's own units because the
        // committed cap is derived from their own dose distribution. A committed cap above 3.33 U would
        // derive a primer past the primer setting's maximum, so the primer is held to that as well.
        let primerCapU = round2(min(max(committedCapU * primerFrac, 0), min(committedCapU, primerCapMaxU)))
        // Only a clearly well-controlled history routes to the bolus. That makes the bolus route
        // inherently safe on time-below-range, which is why the primer cap is not raise-guarded:
        // the routing is the safety differentiator rather than a cap. A user can force the bolus.
        let primerTbrFallback = !wellControlled
        reasons.append(
            "Primer ceiling \(primerCapU)U "
                + (
                    primerTbrFallback
                        ? "via retractable temp basal (recommended, can be overridden to bolus)"
                        : "as bolus (well-controlled)"
                )
                + " — reclaims the earlier acceleration response. It is a ceiling paid only on a "
                + "confirm-strength rise, from \(Int(Primer.deltaMin)) mg/dL per 5 min to fire and "
                + "full at \(Int(Primer.deltaFull)), scaled down by glucose room and insulin headroom."
        )

        return Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmedCapU, committedCapU: committedCapU,
            cumulativeSmbCap60MinU: cumulativeSmbCap60MinU,
            bolusCapU: bolusCapU,
            fastCarbConfirm: fastCarbConfirm,
            aggressiveEarlyConfirm: aggressiveEarlyConfirm,
            velocityBudgetFloor: velocityBudgetFloor,
            primerCapU: primerCapU,
            primerFrac: primerFrac,
            primerTbrFallback: primerTbrFallback,
            rationale: reasons
        )
    }

    /// Rolling-60-min cumulative SMB cap: bounds dose *frequency* (the per-shot caps only bound
    /// magnitude). Budget = one confirm shot plus two holds per hour, clamped only to the
    /// preference's expressible range [1.0, `cumulativeCapMaxU`].
    ///
    /// History (AAPS fe9d8a1a13): the previous ceiling was `max(5.0, confirmedCap)`, which
    /// collapsed "one confirm + 2 holds" to "confirm + ~0 holds" for any big-confirm user (the
    /// 2026-07-06 7-user migration backtest attributed 6 of one user's 8 projected suppressions to
    /// exactly this, and left another user's cumulative == confirmedCap so a single confirm
    /// exhausted the hour). The clamp is now the pref range max: the formula is the policy, the
    /// clamp is only a bound.
    ///
    /// Exposed separately from `compute` because the apply layer must recompute it from the FINAL
    /// operative per-shot caps (kept-user-tuned or derived), not from the derivation's own caps —
    /// a cumulative budget sized from a derived confirmedCap that never applies is incoherent
    /// (cohort user E: cumulative sized from derived 4.65 while his operative cap was 2.0).
    public static func cumulativeCap60Min(confirmedCapU: Double, committedCapU: Double) -> Double {
        round1(min(max(confirmedCapU + 2.0 * committedCapU, 1.0), cumulativeCapMaxU))
    }

    /// Linear-interpolated percentile (0..100) of positive values; 0.0 if empty.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        let v = values.filter { $0.isFinite && $0 > 0 }.sorted()
        if v.isEmpty { return 0.0 }
        if v.count == 1 { return v[0] }
        let rank = (p / 100.0) * Double(v.count - 1)
        let lo = Int(rank)
        let hi = min(lo + 1, v.count - 1)
        return v[lo] + (v[hi] - v[lo]) * (rank - Double(lo))
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    private static func pct(_ x: Double) -> String { "\((x * 10).rounded() / 10)%" }
}
