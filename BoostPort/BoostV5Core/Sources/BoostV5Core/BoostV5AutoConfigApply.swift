import Foundation

/// The knobs Boost auto-config manages, each with a per-knob resolution mark persisted by the host
/// (`Preferences.boostV5AutoConfigResolved`, raw values of this enum). Mirrors the AAPS managed-key
/// list (b2c0705e5e). The V1 engine's bolus cap (`boostBolus`) joined it in October 2026 with the port
/// of that engine: AAPS carries the user's max bolus into it. The engine's IOB limit, Boost max IOB,
/// left the list in November 2026 (agreed for both apps; AAPS's change is made separately): at its
/// 12 U default Boost uses max IOB on every cycle, and a written copy would read as the person's own
/// value and stop following.
public enum BoostAutoConfigKnob: String, CaseIterable, Sendable {
    case aggression
    case hypoCaution
    case confirmedCapU
    case committedCapU
    case cumulativeSmbCap60Min
    /// The V1 tier engine's per-SMB cap (AAPS ApsBoostBolus), carried from the user's max bolus.
    case boostBolus
    case fastCarbConfirm
    /// 2026-07-17 insulin-adding opt-in switches. Auto-config managed on the same once-only
    /// resolution as `fastCarbConfirm`, but derived from the strict well-controlled cut rather than
    /// the hypo-prone one.
    case aggressiveEarlyConfirm
    case velocityBudgetFloor
    /// 2026-07-20 early-primer ceiling, in units. Deliberately NOT in `doseCapKnobs`: the primer's
    /// safety differentiator is its delivery routing, which sends anyone not clearly
    /// well-controlled through a retractable temp basal, rather than a raise guard on the size.
    case primerCapU
    /// 2026-07-20 primer routing. Boolean, so the host applies it while the preference still sits
    /// at its factory default.
    case primerTbrFallback

    /// The double-valued knobs `applyAutoConfig` resolves (stable order). The boolean knobs are
    /// handled separately by the host, as in the AAPS plugin.
    public static let doubleKnobs: [BoostAutoConfigKnob] = [
        .aggression, .hypoCaution, .confirmedCapU, .committedCapU, .cumulativeSmbCap60Min, .boostBolus,
        .primerCapU
    ]

    /// The boolean knobs, which the host applies only while the preference still sits at its
    /// factory default, then marks resolved either way.
    public static let booleanKnobs: [BoostAutoConfigKnob] = [
        .fastCarbConfirm, .aggressiveEarlyConfirm, .velocityBudgetFloor, .primerTbrFallback
    ]
}

/// Pure helpers for applying a `BoostV5AutoConfig.Suggestion` to preferences while respecting any
/// value the user (or an imported preset) has ALREADY tuned. Mirrors AAPS `BoostV5AutoConfigApply`
/// (b2c0705e5e + the fe9d8a1a13 amendments + the 131923247e versioned re-migration).
///
/// ── Per-knob resolution (2026-07 fix, field evidence on AAPS) ─────────────────────────
/// The original design used one global "did run" flag (`boostV5AutoConfigDone` in Trio's
/// Preferences). Failure mode: once the flag was consumed (older build, or carried in via a
/// settings import), the whole run — including knobs ADDED to auto-config later — was suppressed
/// for good. The fix: each managed knob is tracked individually as RESOLVED once it has either
/// been applied once or been skipped because the user tuned it; both mark it resolved.
/// Insufficient data resolves nothing, so unresolved knobs genuinely retry on later cycles.
///
/// ── 2026-07-06 amendments (7-user migration-cohort backtest, AAPS fe9d8a1a13) ────────────────
///  - Historical factory defaults: the at-factory test must recognise the defaults of EVERY build
///    era, or a user whose prefs persisted an OLD factory value reads as "user-tuned" and is
///    frozen at the tightest-ever values. This problem EXISTS on Trio for the two per-shot caps
///    (defaults raised in 5cf1abb84, 2026-06-26) — see `historicalFactoryDefaults`.
///  - The cumulative 60-min cap is recomputed in `applyAutoConfig` from the FINAL operative
///    per-shot caps (kept-or-derived), not taken verbatim from the derivation.
///  - TBR raise-guard: a dose-cap RAISE is priced badly for a TBR-heavy user, and value==factory
///    cannot distinguish "never touched" from "deliberately reverted to factory". See
///    `tbrRaiseGuardPct`.
///  - Every knob's classification is returned as a `Resolution` with a human-readable reason, so
///    field diagnosis never needs inference.
///
/// Trio note vs AAPS: AAPS's presence-test defect never existed here — Trio's caps carry explicit
/// per-knob `…UserSet` flags (set only when the user moves the slider), which the host ORs into
/// the injected `isUserTuned` predicate ON TOP of the any-era value-vs-factory test.
public enum BoostV5AutoConfigApply {
    /// Tolerance for "still at factory default": preference values round-trip through
    /// Decimal/JSON, so exact Double equality would be fragile. Same epsilon as AAPS (1e-4).
    public static let defaultEps = 1E-4

    /// Max acceptable 14-day time-below-70 (%) for auto-APPLYING a dose-cap RAISE. At or below
    /// this, raises apply as normal; above it they are only *suggested* (surfaced to the user and
    /// the log) and the knob resolves without being written.
    ///
    /// Backtest evidence (7-user migration cohort, 2026-07-06, AAPS fe9d8a1a13 — cohort user B,
    /// TBR<70 4.26%): the insulin his raised caps would have added priced at 44.7% delivered
    /// within 3 h of a <70 mg/dL reading, vs 32.8% for his baseline dosing — a raise is exactly
    /// the wrong medicine for a TBR-heavy user. LOWERINGS and non-cap tightenings (HypoCaution,
    /// Aggression ≤ 1.0, FastCarbConfirm OFF, the cumulative cap when it tightens) always apply.
    /// 4.0% is the international consensus TBR<70 target the derivation already uses.
    public static let tbrRaiseGuardPct = 4.0

    /// Severe-hypo co-guard on the same raise-guard (2026-07-07, AAPS 13c9bc4d53): a dose-cap RAISE
    /// is also held (suggested-not-applied) when 14-day time-below-54 is at or above this. 1.0% is
    /// the international consensus <54 target the derivation already uses (`sev54Target`). Catches
    /// the user-B pattern the <70-only guard missed: TBR<70 3.83% (under the 4.0% line) but <54
    /// 1.01% (over the severe line) — severe exposure is the stronger contraindication for a raise,
    /// and a user can sit under the <70 gate while over the <54 one. Same suggested-not-applied
    /// path as `tbrRaiseGuardPct`; lowerings and non-cap tightenings still always apply.
    public static let tbr54RaiseGuardPct = 1.0

    /// Every factory default each managed knob has EVER shipped with on Trio, beyond the current
    /// one. Verified from git history of Trio/Sources/Models/Preferences.swift (2026-07-06,
    /// `git log --all -p -G'var boost…'`):
    ///  - boostV5ConfirmedCapU: 1.0 (introduced 01f903a2f, 2026-06-23) → 2.5 (5cf1abb84, 2026-06-26)
    ///  - boostV5CommittedCapU: 0.25 (introduced 01f903a2f) → 0.5 (5cf1abb84)
    ///  - boostCumulativeSmbCap60Min: introduced at 10.0 (724d15cd5) and never changed — no eras.
    /// The other managed knobs (Aggression 1.0, HypoCaution 1.0, FastCarbConfirm true) have never
    /// changed default. A stored value matching ANY of these (±`defaultEps`) is at-factory, i.e.
    /// derivable — without this, a user whose old build persisted an old factory value reads as
    /// "user-tuned" and is frozen at the tightest-ever caps (AAPS cohort users C/D; the same
    /// 06-23→06-26 window exists on Trio). (AAPS fe9d8a1a13 amendment #1.)
    private static let historicalFactoryDefaults: [BoostAutoConfigKnob: [Double]] = [
        .confirmedCapU: [1.0],
        .committedCapU: [0.25]
    ]

    /// Current + historical factory defaults for `knob` (current first). The current default is
    /// injected by the host (it lives in Trio's `Preferences`, which this package cannot see).
    public static func factoryDefaults(_ knob: BoostAutoConfigKnob, currentDefault: Double) -> [Double] {
        [currentDefault] + (historicalFactoryDefaults[knob] ?? [])
    }

    /// "User (or preset) has tuned this knob" (value test): a stored value exists AND it differs
    /// from every factory default the knob has ever shipped with. A value persisted AT any-era
    /// factory default (settings import, settings-screen visit, an old build's default) does NOT
    /// count as tuned — nobody objected to a default, so a suggestion may still apply. The host
    /// ORs the caps' explicit `…UserSet` flags on top of this.
    public static func isUserTuned(storedValue: Double?, factoryDefaults: [Double]) -> Bool {
        guard let storedValue else { return false }
        return !factoryDefaults.contains { abs(storedValue - $0) <= defaultEps }
    }

    /// The dose-cap knobs subject to the `tbrRaiseGuardPct` raise-guard.
    public static let doseCapKnobs: Set<BoostAutoConfigKnob> = [
        .confirmedCapU, .committedCapU, .cumulativeSmbCap60Min
    ]

    /// How a knob was classified by `applyAutoConfig` this run.
    public enum Outcome: String, Equatable, Sendable {
        case applied
        case keptUserTuned
        case suggestedNotAppliedTbr
        // Periodic re-derivation outcomes (AAPS 2026-08-03).
        /// The knob was moved by a scheduled re-derivation.
        case redriven
        /// The move was smaller than the measurement error, so it accumulates instead.
        case insideDeadband
        /// A quantised knob: the new value must repeat once before it is written.
        case awaitingConfirmation
        /// First sight: where the derivation currently sits was recorded and nothing was written.
        case baselineRecorded
        /// An aggression raise stopped at `aggressionAutoCeiling`.
        case atNeutralCeiling
        /// The window had too few readings to judge; nothing changed.
        case insufficientEvidence
    }

    /// Per-knob classification record. `suggestedValue` is the final derived value for the knob
    /// (for the cumulative cap: recomputed from the operative per-shot caps); `operativeValue` is
    /// what governs dosing after this run; `reason` is the human-readable classification the host
    /// logs verbatim so field diagnosis never needs inference.
    public struct Resolution: Equatable, Sendable {
        public let knob: BoostAutoConfigKnob
        public let outcome: Outcome
        public let suggestedValue: Double
        public let operativeValue: Double
        public let reason: String
    }

    /// Apply the suggestion with per-knob resolution. For each double knob, in order:
    ///  - already RESOLVED (applied or skipped in an earlier run) → untouched (no `Resolution`);
    ///  - user-tuned (injected predicate: UserSet flag OR off every-era factory) → kept, marked
    ///    resolved (never revisited);
    ///  - a dose-cap (`doseCapKnobs`) whose derived value would RAISE the operative value while
    ///    the 14-day TBR<70 exceeds `tbrRaiseGuardPct` OR the 14-day time-below-54 is ≥
    ///    `tbr54RaiseGuardPct` → NOT written, marked resolved, returned as
    ///    `.suggestedNotAppliedTbr` so the caller can surface the suggestion;
    ///  - otherwise → suggested value written, marked resolved.
    ///
    /// The cumulative 60-min cap is recomputed HERE from the FINAL operative per-shot caps
    /// (kept-or-derived-or-guard-held), via `BoostV5AutoConfig.cumulativeCap60Min` — never taken
    /// verbatim from the derivation, whose caps may not be the ones that apply.
    ///
    /// Per-knob and independent — presetting one never blocks the others. Pure: the closures
    /// inject the preference I/O so all skip/resolve behaviour is testable without the host.
    /// NOT called when there is insufficient history (the caller gets no suggestion), so
    /// unresolved knobs remain eligible and genuinely retry on a later cycle.
    public static func applyAutoConfig(
        suggestion: BoostV5AutoConfig.Suggestion,
        tbrBelow70Pct: Double,
        timeBelow54Pct: Double = 0.0,
        isResolved: (BoostAutoConfigKnob) -> Bool,
        storedValue: (BoostAutoConfigKnob) -> Double?,
        currentDefault: (BoostAutoConfigKnob) -> Double,
        isUserTuned: (BoostAutoConfigKnob) -> Bool,
        put: (BoostAutoConfigKnob, Double) -> Void,
        markResolved: (BoostAutoConfigKnob) -> Void,
        recordWritten: (BoostAutoConfigKnob, Double) -> Void = { _, _ in }
    ) -> [Resolution] {
        var resolutions: [Resolution] = []
        var operative: [BoostAutoConfigKnob: Double] = [:]
        // Raise-guard trigger: <70 over its line OR <54 at/over the consensus severe line (2026-07-07).
        let raiseGuardTripped = tbrBelow70Pct > Self.tbrRaiseGuardPct || timeBelow54Pct >= Self.tbr54RaiseGuardPct

        func resolve(_ knob: BoostAutoConfigKnob, _ derived: Double) {
            let current = storedValue(knob) ?? currentDefault(knob)
            if isResolved(knob) {
                operative[knob] = current // untouched; feeds the cumulative recompute
                return
            }
            if isUserTuned(knob) {
                markResolved(knob) // user value kept; never revisit
                operative[knob] = current
                resolutions.append(Resolution(
                    knob: knob, outcome: .keptUserTuned, suggestedValue: derived, operativeValue: current,
                    reason: "kept-user-tuned value=\(current) (suggested \(derived))"
                ))
                return
            }
            if doseCapKnobs.contains(knob), derived > current + Self.defaultEps, raiseGuardTripped {
                markResolved(knob) // suggestion surfaced, not written
                operative[knob] = current
                resolutions.append(Resolution(
                    knob: knob, outcome: .suggestedNotAppliedTbr, suggestedValue: derived, operativeValue: current,
                    reason: "suggested-not-applied (TBR): suggested=\(derived) current=\(current) " +
                        "TBR<70=\(tbrBelow70Pct)% (guard >\(Self.tbrRaiseGuardPct)%) " +
                        "<54=\(timeBelow54Pct)% (guard ≥\(Self.tbr54RaiseGuardPct)%)"
                ))
                return
            }
            put(knob, derived)
            recordWritten(knob, derived)
            markResolved(knob)
            operative[knob] = derived
            resolutions.append(Resolution(
                knob: knob, outcome: .applied, suggestedValue: derived, operativeValue: derived,
                reason: "applied \(derived)"
            ))
        }

        resolve(.aggression, suggestion.aggression)
        resolve(.hypoCaution, suggestion.hypoCaution)
        resolve(.confirmedCapU, suggestion.confirmedCapU)
        resolve(.committedCapU, suggestion.committedCapU)
        // Cumulative cap from the FINAL operative per-shot caps (kept-or-derived), never the
        // derivation's own caps (AAPS cohort user E: budget sized from a derived confirmedCap
        // 4.65 that never applied while his operative cap was 2.0).
        resolve(.cumulativeSmbCap60Min, BoostV5AutoConfig.cumulativeCap60Min(
            confirmedCapU: operative[.confirmedCapU]!,
            committedCapU: operative[.committedCapU]!
        ))
        resolve(.boostBolus, suggestion.bolusCapU)
        // Primer ceiling, resolved after the caps so it can be sized from the FINAL operative
        // committed cap rather than the derivation's own, for the same reason the cumulative cap is.
        // The primer is an advance on the commit shot, so a kept user cap must bound it too.
        if suggestion.committedCapU > 0 {
            let sized = (operative[.committedCapU]! * suggestion.primerFrac * 100).rounded() / 100
            resolve(.primerCapU, min(max(sized, 0), min(operative[.committedCapU]!, BoostV5AutoConfig.primerCapMaxU)))
        } else {
            resolve(.primerCapU, suggestion.primerCapU)
        }
        return resolutions
    }

    // MARK: - Periodic re-derivation

    /// Knobs whose movement is tracked as a RATIO, being unit quantities that scale with dose size.
    public static let redriveRatioKnobs: [BoostAutoConfigKnob] = [.committedCapU, .confirmedCapU]

    /// Knobs whose movement is tracked as an OFFSET, being bounded scales that step by a fixed
    /// quantum, for which a ratio is meaningless.
    public static let redriveOffsetKnobs: [BoostAutoConfigKnob] = [.aggression, .hypoCaution]

    /// Tracked knobs, in processing order: the caps before anything computed from them.
    public static let redriveKnobs: [BoostAutoConfigKnob] = redriveRatioKnobs + redriveOffsetKnobs

    /// Largest single-step change as a ratio of the current value. It bounds one evaluation's move
    /// when a driver jumps, since a site change or a fortnight of illness can shift median total
    /// daily dose sharply and a 28-day window carries that in as a step. Clipped movement is not
    /// lost: on a write the baseline advances only by the movement actually applied, so the
    /// remainder arrives over later evaluations.
    public static let redriveMaxStepRatio = 0.25

    /// Minimum move worth writing, per knob: that knob's day-block bootstrap half-width over a
    /// 28-day window. Below it the move is inside the noise of measuring it. The offset knobs are
    /// absent deliberately, because their own rounding is already the filter and a band wider than
    /// the quantum, as hypo caution's 0.16 is against its 0.1, would freeze them below a double step.
    public static let redriveDeadband: [BoostAutoConfigKnob: Double] = [
        .committedCapU: 0.07,
        .confirmedCapU: 0.47
    ]

    /// Offset knobs get hysteresis instead of a deadband: a new value must be derived twice in a
    /// row before it is written, so a knob cannot flap across a threshold. One cohort user flipped
    /// aggression between 1.0 and 0.92 across the 4% line depending on the window.
    public static let redriveConfirmTwice: Set<BoostAutoConfigKnob> = Set(redriveOffsetKnobs)

    /// Deadband on the recomputed primer ceiling, its own measured half-width.
    public static let redrivePrimerDeadband = 0.056

    /// The highest value re-derivation raises aggression to. Onboarding never derives above
    /// neutral, and movement tracking could otherwise carry a user's offset past it. A value above
    /// 1.0 set by hand is kept and may still be lowered (AAPS Boost 6.3.0 AGGRESSION_AUTO_CEILING).
    public static let aggressionAutoCeiling = 1.0

    /// Boost's starting values for the two "max minutes of basal to limit SMB" settings, 15 for the
    /// standard one and 20 for UAM (AAPS Boost 6.3.2 `smbBasalMinutesSeeds`). They size every
    /// microbolus V6 does not size itself. Written once, when Boost first runs, and then left to the
    /// person; 6.3.0 and 6.3.1 held them at or below these values on every cycle instead.
    public static let smbBasalMinutesSeeds = (smb: 15.0, uam: 20.0)

    /// The values to write on Boost's first run, nil for a setting to leave alone: the seed for any
    /// value above it. AAPS writes a seed only where nothing is stored, but its 6.3.0 ceiling had
    /// already lowered every stored value above the seeds, so an AAPS install reaches 6.3.2 at or
    /// below them. Trio's 6.3.0 clamp acted at read time and left the stored values as they were,
    /// so lowering them once reproduces that state and doses no more than the clamp did. Trio's
    /// default of 30 is above both seeds, so a setting never changed by hand is seeded as in AAPS.
    public static func seedSmbBasalMinutes(
        smb: Double, uam: Double, alreadySeeded: Bool
    ) -> (smb: Double?, uam: Double?) {
        guard !alreadySeeded else { return (nil, nil) }
        func seed(_ v: Double, _ to: Double) -> Double? { v > to + defaultEps ? to : nil }
        return (seed(smb, smbBasalMinutesSeeds.smb), seed(uam, smbBasalMinutesSeeds.uam))
    }

    /// Whether a computed knob (the cumulative cap, the primer cap) is still auto-config's to
    /// recompute (AAPS computedKnobOwned, Boost 6.3.0). A value at a factory default is
    /// auto-config's, as is the value auto-config last wrote. Installs with no record of a write
    /// take a stored value as auto-config's only when it is within `tolerance` of one of
    /// `autoValues`, the recomputations from the caps as they stood when the run began.
    public static func computedKnobOwned(
        userTuned: Bool, stored: Double, lastWritten: Double?, autoValues: [Double], tolerance: Double
    ) -> Bool {
        if !userTuned { return true }
        if let lastWritten { return abs(stored - lastWritten) <= defaultEps }
        return autoValues.contains { abs(stored - $0) <= tolerance + defaultEps }
    }

    /// The re-derivation's raise guard, for the dose caps and the insulin-adding switches: time below
    /// 70 mg/dL over `tbrRaiseGuardPct`, or time below 54 mg/dL at or over `tbr54RaiseGuardPct`.
    /// `overridden` is the person's choice in the run-now dialog and lifts both for that run only;
    /// the scheduled runs never pass it.
    public static func raiseGuardTripped(tbrBelow70Pct: Double, timeBelow54Pct: Double, overridden: Bool = false) -> Bool {
        !overridden && (tbrBelow70Pct > tbrRaiseGuardPct || timeBelow54Pct >= tbr54RaiseGuardPct)
    }

    /// Apply the derivation's MOVEMENT to each tracked knob's current value, rather than
    /// overwriting it with a fresh absolute derivation.
    ///
    /// Someone who raised the committed cap from a derived 1.24 to 1.8 was expressing a judgement
    /// the formula does not capture. Overwriting discards it; freezing means the knob never tracks
    /// anything again. Applying the movement keeps both: if total daily dose then rises by a fifth,
    /// they go to 2.16 and their own offset survives. The load-bearing property is that the knob is
    /// scaled by exactly the ratio the derivation moved, so current over derived is invariant across
    /// a re-derivation and the offset neither decays nor compounds.
    ///
    /// That is also why this needs no notion of who owns a knob, and so no ownership ledger: nothing
    /// is ever overwritten, so it never matters who set the current value. The AAPS first revision
    /// used such a ledger and was inert on every existing install, because only the onboarding path
    /// could populate it and onboarding had already run. This ports the second revision.
    ///
    /// The baseline is the derived value at the last write and advances only on a write, so movement
    /// suppressed by the deadband or held by the raise guard accumulates rather than being lost. On
    /// the first evaluation there is no baseline, so no tracked knob is written: the run records
    /// where the derivation sits and tracking begins from the next one. The computed knobs are the
    /// exception and can be written on that first run, because they are not tracked but recomputed
    /// from the operative caps every time, so a cumulative cap that has drifted out of step with the
    /// caps it bounds is corrected immediately.
    public static func redrive(
        suggestion: BoostV5AutoConfig.Suggestion,
        tbrBelow70Pct: Double,
        timeBelow54Pct: Double,
        overrideHypoProtections: Bool = false,
        storedValue: (BoostAutoConfigKnob) -> Double?,
        currentDefault: (BoostAutoConfigKnob) -> Double,
        baselineValue: (BoostAutoConfigKnob) -> Double?,
        pendingValue: (BoostAutoConfigKnob) -> Double?,
        put: (BoostAutoConfigKnob, Double) -> Void,
        setBaseline: (BoostAutoConfigKnob, Double) -> Void,
        setPending: (BoostAutoConfigKnob, Double?) -> Void,
        isUserTuned: (BoostAutoConfigKnob) -> Bool = { _ in false },
        lastWritten: (BoostAutoConfigKnob) -> Double? = { _ in nil },
        recordWritten: (BoostAutoConfigKnob, Double) -> Void = { _, _ in }
    ) -> [Resolution] {
        var out: [Resolution] = []
        let raiseGuard = Self.raiseGuardTripped(
            tbrBelow70Pct: tbrBelow70Pct, timeBelow54Pct: timeBelow54Pct, overridden: overrideHypoProtections
        )
        let derivedFor: [BoostAutoConfigKnob: Double] = [
            .aggression: suggestion.aggression,
            .hypoCaution: suggestion.hypoCaution,
            .confirmedCapU: suggestion.confirmedCapU,
            .committedCapU: suggestion.committedCapU,
            .cumulativeSmbCap60Min: suggestion.cumulativeSmbCap60MinU,
            .primerCapU: suggestion.primerCapU
        ]
        var operative: [BoostAutoConfigKnob: Double] = [:]
        for k in BoostAutoConfigKnob.doubleKnobs { operative[k] = storedValue(k) ?? currentDefault(k) }
        let start = operative // as stored before this run moved anything

        for knob in redriveKnobs {
            let current = operative[knob]!
            let derivedNow = derivedFor[knob]!
            guard let baseline = baselineValue(knob), baseline > 0 else {
                // First sight: record where the derivation sits and change nothing, since movement
                // is what is tracked and none has been observed yet.
                setBaseline(knob, derivedNow)
                out.append(Resolution(
                    knob: knob, outcome: .baselineRecorded, suggestedValue: derivedNow,
                    operativeValue: current,
                    reason: "baseline recorded at \(derivedNow); tracking starts next run"
                ))
                continue
            }

            let rawProposed = redriveRatioKnobs.contains(knob)
                ? current * (derivedNow / baseline)
                : current + (derivedNow - baseline)
            let stepCap = abs(current) * redriveMaxStepRatio
            let bounded = min(max(rawProposed, current - stepCap), current + stepCap)
            var proposed = (bounded * 100).rounded() / 100
            // The committed cap stays inside its setting's range, as the Kotlin's coerceIn(key.min, key.max)
            // keeps every knob. Trio's other knobs rely on the decode clamp (REVIEW.md, pre-existing).
            if knob == .committedCapU { proposed = min(max(proposed, 0), BoostV5AutoConfig.committedCapMaxU) }
            // Aggression is never auto-raised above neutral. A raise stops at 1.0, and from a value
            // already at or above 1.0, which only the user can have set, it does not move. The
            // baseline is not advanced, so the withheld movement stays available.
            if knob == .aggression, proposed > current + Self.defaultEps {
                let ceiling = max(current, Self.aggressionAutoCeiling)
                if proposed > ceiling + Self.defaultEps {
                    if abs(ceiling - current) <= Self.defaultEps {
                        setPending(knob, nil)
                        out.append(Resolution(
                            knob: knob, outcome: .atNeutralCeiling, suggestedValue: proposed,
                            operativeValue: current,
                            reason: "held:neutral-ceiling raise \(current) → \(proposed) not written; " +
                                "aggression is auto-raised no higher than \(Self.aggressionAutoCeiling)"
                        ))
                        continue
                    }
                    proposed = ceiling
                }
            }
            let delta = proposed - current

            if abs(delta) <= Self.defaultEps {
                // Clear any pending confirmation. "Twice in a row" has to mean consecutively, or a
                // knob alternating either side of a threshold accumulates a match across the gap and
                // eventually writes the flap the hysteresis exists to prevent.
                setPending(knob, nil)
                out.append(Resolution(
                    knob: knob, outcome: .insideDeadband, suggestedValue: proposed,
                    operativeValue: current,
                    reason: "no movement: derivation \(baseline) → \(derivedNow) leaves \(current) unchanged"
                ))
                continue
            }

            // Any insulin-adding move is held while the TBR guard is tripped: a cap or aggression
            // rising, or hypo caution falling. Checked before the confirmation and noise filters so
            // a held move is reported as held, and the baseline is not advanced, so the movement
            // accumulates until the guard clears (AAPS Boost 6.3.0, audit 22).
            let loosening = knob == .hypoCaution ? delta < 0 : delta > 0
            if loosening, raiseGuard {
                setPending(knob, nil)
                out.append(Resolution(
                    knob: knob, outcome: .suggestedNotAppliedTbr, suggestedValue: proposed,
                    operativeValue: current,
                    reason: "raise held: \(current) → \(proposed); TBR<70=\(tbrBelow70Pct)% <54=\(timeBelow54Pct)%"
                ))
                continue
            }

            if redriveConfirmTwice.contains(knob) {
                let pending = pendingValue(knob)
                if pending == nil || abs(pending! - proposed) > Self.defaultEps {
                    setPending(knob, proposed)
                    out.append(Resolution(
                        knob: knob, outcome: .awaitingConfirmation, suggestedValue: proposed,
                        operativeValue: current,
                        reason: "held for confirmation: \(current) → \(proposed) must repeat next run"
                    ))
                    continue
                }
            } else {
                let band = redriveDeadband[knob] ?? 0
                if abs(delta) <= band {
                    // The baseline is deliberately not advanced, so the movement accumulates.
                    out.append(Resolution(
                        knob: knob, outcome: .insideDeadband, suggestedValue: proposed,
                        operativeValue: current,
                        reason: "no change: move \((delta * 100).rounded() / 100) within the ±\(band) noise band (accumulating)"
                    ))
                    continue
                }
            }

            put(knob, proposed)
            recordWritten(knob, proposed)
            // Advance the baseline by the movement ACTUALLY APPLIED, not by the movement derived.
            // When the step cap clips a large move, advancing to the newly derived value would
            // discard the remainder and strand the knob short of its target: an insulin
            // concentration change that doubles the dose in units would move a cap by a quarter once
            // and then stop, about 40% below where it belongs. Advancing proportionally leaves the
            // residual in place. Unclipped moves are unaffected, since proposed over current then
            // equals derivedNow over baseline and this reduces to derivedNow exactly.
            let appliedBaseline: Double = redriveRatioKnobs.contains(knob)
                ? (abs(current) > Self.defaultEps ? baseline * (proposed / current) : derivedNow)
                : baseline + (proposed - current)
            setBaseline(knob, appliedBaseline)
            setPending(knob, nil)
            operative[knob] = proposed
            out.append(Resolution(
                knob: knob, outcome: .redriven, suggestedValue: proposed, operativeValue: proposed,
                reason: "tracked \(current) → \(proposed) (derivation moved \(baseline) → \(derivedNow))"
            ))
        }

        // The computed knobs follow the operative caps, exactly as the derivation computes them, but
        // only while auto-config still owns them (computedKnobOwned). A value the user set is kept.
        let cum = BoostAutoConfigKnob.cumulativeSmbCap60Min
        let currentCum = operative[cum]!
        let newCum = BoostV5AutoConfig.cumulativeCap60Min(
            confirmedCapU: operative[.confirmedCapU]!,
            committedCapU: operative[.committedCapU]!
        )
        let cumAtStart = BoostV5AutoConfig.cumulativeCap60Min(
            confirmedCapU: start[.confirmedCapU]!, committedCapU: start[.committedCapU]!
        )
        let cumStored = storedValue(cum)
        if let cumStored, !computedKnobOwned(
            userTuned: isUserTuned(cum), stored: cumStored, lastWritten: lastWritten(cum),
            autoValues: [cumAtStart], tolerance: Self.defaultEps
        ) {
            out.append(Resolution(
                knob: cum, outcome: .keptUserTuned, suggestedValue: newCum, operativeValue: currentCum,
                reason: "kept:user-set \(currentCum) (recomputed \(newCum) not written)"
            ))
        } else if abs(newCum - currentCum) > Self.defaultEps {
            if newCum > currentCum, raiseGuard {
                out.append(Resolution(
                    knob: cum, outcome: .suggestedNotAppliedTbr,
                    suggestedValue: newCum, operativeValue: currentCum,
                    reason: "raise held: \(currentCum) → \(newCum); TBR<70=\(tbrBelow70Pct)% <54=\(timeBelow54Pct)%"
                ))
            } else {
                put(cum, newCum)
                recordWritten(cum, newCum)
                out.append(Resolution(
                    knob: cum, outcome: .redriven, suggestedValue: newCum,
                    operativeValue: newCum,
                    reason: "recomputed \(currentCum) → \(newCum) from the operative caps"
                ))
            }
        } else if let cumStored, lastWritten(cum) == nil {
            // Owned, unchanged and no record of a write yet: record it, so a later edit by the user
            // is recognised exactly rather than by the tolerance test.
            recordWritten(cum, cumStored)
        }
        // The primer ceiling is a fraction of the committed cap, the fraction taken from the
        // derivation so the hypo-prone and well-controlled policy is not duplicated here.
        if suggestion.committedCapU > 0 {
            let primer = BoostAutoConfigKnob.primerCapU
            let currentPrimer = operative[primer]!
            let raw = operative[.committedCapU]! * suggestion.primerFrac
            let newPrimer = (min(max(raw, 0), min(operative[.committedCapU]!, BoostV5AutoConfig.primerCapMaxU)) * 100)
                .rounded() / 100
            let primerStored = storedValue(primer)
            let primerAtStart = BoostV5AutoConfig.primerFractions.map { (start[.committedCapU]! * $0 * 100).rounded() / 100 }
            let changes = abs(newPrimer - currentPrimer) > redrivePrimerDeadband
            if let primerStored, abs(primerStored) <= Self.defaultEps {
                // A stored 0 is the primer's only off switch, and auto-config never writes 0.
                out.append(Resolution(
                    knob: primer, outcome: .keptUserTuned, suggestedValue: newPrimer, operativeValue: 0,
                    reason: "kept:user-set 0 (primer off; recomputed \(newPrimer) not written)"
                ))
            } else if let primerStored, !computedKnobOwned(
                userTuned: isUserTuned(primer), stored: primerStored, lastWritten: lastWritten(primer),
                autoValues: primerAtStart, tolerance: redrivePrimerDeadband
            ) {
                out.append(Resolution(
                    knob: primer, outcome: .keptUserTuned, suggestedValue: newPrimer, operativeValue: currentPrimer,
                    reason: "kept:user-set \(currentPrimer) (recomputed \(newPrimer) not written)"
                ))
            } else if changes, newPrimer > currentPrimer, raiseGuard {
                // Onboarding does not guard the primer, so a hypo-prone person is still provisioned
                // one for the temp-basal route; once provisioned, a larger primer waits for the guard.
                out.append(Resolution(
                    knob: primer, outcome: .suggestedNotAppliedTbr, suggestedValue: newPrimer,
                    operativeValue: currentPrimer,
                    reason: "raise held: \(currentPrimer) → \(newPrimer); TBR<70=\(tbrBelow70Pct)% <54=\(timeBelow54Pct)%"
                ))
            } else if changes {
                put(primer, newPrimer)
                recordWritten(primer, newPrimer)
                out.append(Resolution(
                    knob: primer, outcome: .redriven, suggestedValue: newPrimer,
                    operativeValue: newPrimer,
                    reason: "recomputed \(currentPrimer) → \(newPrimer) from the committed cap"
                ))
            } else if let primerStored, lastWritten(primer) == nil {
                recordWritten(primer, primerStored)
            }
        }
        return out
    }

    // MARK: - Weekly re-evaluation of the on/off settings (AAPS Boost 6.3.0)

    /// Pending-ledger entry holding the previous window's well-controlled verdict (1.0 or 0.0).
    public static let primerRoutePrevWcKey = "primer_route_prev_well_controlled"
    /// Written-ledger value recording that onboarding found a switch set by the user; such a switch
    /// is never changed by re-derivation. 1.0 and 0.0 record auto-config's own true and false.
    public static let switchUserSetMark = -1.0
    /// Pending-ledger entry holding a switch's previous window verdict.
    public static func switchPreviousVerdictKey(_ knob: BoostAutoConfigKnob) -> String {
        "switch_prev_allows_\(knob.rawValue)"
    }

    public struct SwitchResolution: Equatable, Sendable {
        public let outcome: Outcome
        public let value: Bool
        public let reason: String
    }

    /// The primer delivery route (true = temp basal). Not well controlled while on the bolus moves to
    /// the temp basal at once, a tightening; well controlled while on the temp basal moves back to
    /// the bolus, which adds insulin, only after two consecutive well-controlled windows. A stored
    /// value that differs from auto-config's last write was set by someone else and is kept.
    /// Trio-specific: the move back to the bolus also needs a record that auto-config wrote the
    /// temp basal. AAPS takes an unrecorded value as its own because it has no screen entry for the
    /// route; Trio's settings have one, so an unrecorded temp basal may be the person's choice.
    public static func resolvePrimerRoute(
        wellControlled: Bool,
        bgReadings: Int,
        previousWellControlled: Bool?,
        stored: Bool,
        lastWritten: Bool?,
        put: (Bool) -> Void,
        recordWritten: (Bool) -> Void,
        recordWellControlled: (Bool?) -> Void
    ) -> SwitchResolution {
        let current = stored
        if bgReadings < BoostV5AutoConfig.minBgReadings {
            recordWellControlled(nil)
            return SwitchResolution(outcome: .insufficientEvidence, value: current, reason: "held:evidence bg=\(bgReadings)")
        }
        recordWellControlled(wellControlled)
        if let lastWritten, stored != lastWritten {
            return SwitchResolution(outcome: .keptUserTuned, value: current, reason: "kept:user-set tbrFallback=\(current)")
        }
        if !wellControlled, !current {
            put(true)
            recordWritten(true)
            return SwitchResolution(outcome: .redriven, value: true, reason: "bolus to temp basal: window not well controlled")
        }
        if wellControlled, current, lastWritten != true {
            return SwitchResolution(outcome: .keptUserTuned, value: true, reason: "kept:unrecorded tbrFallback=true")
        }
        if wellControlled, current, previousWellControlled == true {
            put(false)
            recordWritten(false)
            return SwitchResolution(
                outcome: .redriven, value: false, reason: "temp basal to bolus: two consecutive well-controlled windows"
            )
        }
        if wellControlled, current {
            return SwitchResolution(
                outcome: .awaitingConfirmation, value: true,
                reason: "held:one-window temp basal kept until a second well-controlled window"
            )
        }
        return SwitchResolution(outcome: .insideDeadband, value: current, reason: "unchanged tbrFallback=\(current)")
    }

    /// An insulin-adding on/off switch (aggressive early confirm, fast-carb confirm), by the rules of
    /// the primer route: off on the first window that does not allow it, on only after two
    /// consecutive windows that do and never under the TBR raise guard, never over a value the user
    /// set. Trio's preferences always hold a value, so `stored` is never absent: with no record of a
    /// write, a value at the factory default is auto-config's and one off it is not switched on.
    public static func resolveInsulinAddingSwitch(
        allowsOn: Bool,
        raiseGuard: Bool,
        bgReadings: Int,
        previousAllowsOn: Bool?,
        stored: Bool,
        defaultValue: Bool,
        lastWritten: Bool?,
        userMarked: Bool,
        put: (Bool) -> Void,
        recordWritten: (Bool) -> Void,
        recordVerdict: (Bool?) -> Void
    ) -> SwitchResolution {
        let current = stored
        if bgReadings < BoostV5AutoConfig.minBgReadings {
            recordVerdict(nil)
            return SwitchResolution(outcome: .insufficientEvidence, value: current, reason: "held:evidence bg=\(bgReadings)")
        }
        let countsTowardOn = allowsOn && !raiseGuard
        recordVerdict(countsTowardOn)
        if userMarked || (lastWritten != nil && stored != lastWritten) {
            return SwitchResolution(outcome: .keptUserTuned, value: current, reason: "kept:user-set \(current)")
        }
        let unrecordedNonDefault = lastWritten == nil && stored != defaultValue
        if !allowsOn, current {
            put(false)
            recordWritten(false)
            return SwitchResolution(outcome: .redriven, value: false, reason: "on to off: window does not allow it")
        }
        if allowsOn, !current, raiseGuard {
            return SwitchResolution(
                outcome: .suggestedNotAppliedTbr, value: false,
                reason: "held:tbr-guard off kept while time below range trips the guard"
            )
        }
        if countsTowardOn, !current, previousAllowsOn == true {
            if unrecordedNonDefault {
                return SwitchResolution(
                    outcome: .keptUserTuned, value: false,
                    reason: "kept:unrecorded off is not switched on without a record that auto-config set it"
                )
            }
            put(true)
            recordWritten(true)
            return SwitchResolution(outcome: .redriven, value: true, reason: "off to on: two consecutive windows allow it")
        }
        if countsTowardOn, !current {
            return SwitchResolution(
                outcome: .awaitingConfirmation, value: false, reason: "held:one-window off kept until a second window allows it"
            )
        }
        return SwitchResolution(outcome: .insideDeadband, value: current, reason: "unchanged \(current)")
    }

    /// Auto-config persistence schema version — THE single hook future re-migrations plug into
    /// (extend the `if storedVersion < N` chain in `runSchemaMigrations` and bump this).
    ///
    /// Mirrors AAPS 131923247e (AUTO_CONFIG_SCHEMA_VERSION = 2; version 1 is skipped there so the
    /// number mirrors the amendment generation — Trio keeps the SAME numbering so the platforms'
    /// schema versions stay comparable). Trio judgement (2026-07-06): strictly, no released Trio
    /// build ever persisted era-blind resolved marks — the per-knob resolution and the
    /// historical-factory awareness land together here, so devices upgrading from the released
    /// one-shot-flag era are fully handled by the legacy-flag migration and start at version 2.
    /// The v2 re-audit branch is still implemented because it is free, idempotent, and rescues
    /// anyone who built from source in the brief window where the per-knob resolution existed
    /// WITHOUT historical-factory awareness.
    public static let autoConfigSchemaVersion = 2

    /// Versioned re-migration of persisted per-knob resolution state (see
    /// `autoConfigSchemaVersion`). The pre-amendment persistence shape stores ONLY a resolved mark
    /// per knob with no outcome detail, so applied and kept-user-tuned are indistinguishable — the
    /// audit therefore re-runs the (now historical-factory-aware, UserSet-flag-respecting)
    /// injected `isUserTuned` on every resolved knob and clears the mark when the value is at ANY
    /// era's factory. A knob auto-APPLIED at a factory-coincident value (e.g. Aggression 1.0) gets
    /// re-opened too, which is harmless: re-derivation is suggestion-only and still respects tuned
    /// values.
    ///
    /// Runs at most once per schema bump: no-op (empty result, no version write) when the stored
    /// version is current; otherwise clears + stamps `autoConfigSchemaVersion`. Returns the
    /// re-opened knobs for logging. Pure — the closures inject preference I/O.
    public static func runSchemaMigrations(
        storedVersion: Int,
        knobs: [BoostAutoConfigKnob],
        isResolved: (BoostAutoConfigKnob) -> Bool,
        isUserTuned: (BoostAutoConfigKnob) -> Bool,
        clearResolved: (BoostAutoConfigKnob) -> Void,
        setVersion: (Int) -> Void
    ) -> [BoostAutoConfigKnob] {
        if storedVersion >= autoConfigSchemaVersion { return [] }
        var cleared: [BoostAutoConfigKnob] = []
        if storedVersion < 2 {
            // v2: re-open knobs an era-blind isUserTuned could have mis-resolved at an old
            // factory value.
            let reopened = knobs.filter { isResolved($0) && !isUserTuned($0) }
            reopened.forEach(clearResolved)
            cleared += reopened
        }
        // Future re-migrations: add `if storedVersion < 3 { ... }` here and bump the constant.
        setVersion(autoConfigSchemaVersion)
        return cleared
    }

    /// One-time migration from the legacy global "auto-config done" flag to per-knob resolution.
    /// Called when the legacy flag is found set: marks as resolved ONLY the knobs the host deems
    /// user-tuned (UserSet flag, or off EVERY factory default the knob ever shipped with — they
    /// were plausibly applied by the old run, or user-set; either way they must not be rewritten).
    /// Knobs still AT a factory default (current or any historical era) stay UNRESOLVED and become
    /// eligible for derivation again — this rescues installs where a consumed/imported flag
    /// wrongly suppressed them; suggestion-only still holds because value == default means nobody
    /// objected. Returns the knobs marked resolved. The caller clears the legacy flag afterwards
    /// (migration is one-shot).
    public static func migrateLegacyDoneFlag<Knob>(
        knobs: [Knob],
        isUserTuned: (Knob) -> Bool,
        markResolved: (Knob) -> Void
    ) -> [Knob] {
        let tuned = knobs.filter(isUserTuned)
        tuned.forEach(markResolved)
        return tuned
    }
}
