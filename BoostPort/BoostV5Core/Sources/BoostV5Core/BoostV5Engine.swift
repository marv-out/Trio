import Foundation

public struct V5Inputs {
    // Glucose status
    public var delta: Double
    public var shortAvgDelta: Double
    public var deltaAccl: Double
    public var bg: Double
    public var eventualBg: Double
    public var targetBg: Double
    public var maxDelta: Double
    public var minGuardBg: Double
    public var minGuardThreshold: Double
    public var deltaHistory: [Double]
    // IOB / dose context
    public var iob: Double
    public var maxIob: Double
    public var baseInsulinReq: Double
    public var roundSmbTo: Double
    public var enableSmbPreChecks: Bool
    // ML outputs
    public var mlHypoRisk: Double?
    public var mlMealLikely: Double?
    public var riskAtProjectedIob: ((Double) -> Double)?
    // Cycle context
    public var recentLowBg: Double
    public var cumulativeRise30min: Double
    public var hour: Int
    public var exerciseActive: Bool
    public var inPostExerciseWindow: Bool
    public var asleep: Bool
    public var fastCarbConfirmEnabled: Bool
    /// Aggressive early-confirm opt-in (AAPS `ApsBoostV5AggressiveEarlyConfirm`, auto-config
    /// managed). Shaves the sustained-score early-confirm path one more cycle. False keeps the
    /// audit-validated timing. See `MealHypothesisConstants.confirmMinObservingAgeScoreReadyAggressive`.
    public var aggressiveEarlyConfirmEnabled: Bool
    public var sensorQualityOk: Bool
    /// True when inside the post-rescue window (rolling 45-min CGM low < 75 mg/dL — same source and
    /// threshold as the override seam's post-rescue cap). Gates the composed floor off (both the
    /// would-add computation and, when `composedFloorActive`, the delivered floor). 2026-07-06, AAPS
    /// e0f18ddd0e / 730b3dcb2c.
    public var postRescueWindow: Bool
    /// V1's would-dose SMB this cycle (the base determination's `units`, BEFORE any V6 override), U.
    /// Used only by the composed floor: RECOVERING is a non-meal state capped at V1's would-dose at
    /// the override seam (2026-07-04 non-meal-state cap), so the floored dose is bounded the same
    /// way. Nil = bound unavailable (not applied).
    public var v1WouldDoseU: Double?
    /// Composed brake-floor ACTIVATION (`boostV5ComposedFloorActive` AND V6 is the active doser).
    /// False (default) = shadow: `floorWouldAdd` logs what the floor WOULD add, delivered dosing
    /// untouched. True = the delivered dose is floored at the composed-floor target on qualifying
    /// cycles (see decide()). Per-user activation only — TBR-gated by guidance. 2026-07, AAPS 730b3dcb2c.
    public var composedFloorActive: Bool
    /// Velocity-budget floor activation (AAPS `ApsBoostV5VelocityBudgetActive`, and V6 the active
    /// doser, and the fail-closed 14-day TBR gate). False is shadow: `velocityBudgetWouldAdd`
    /// records what the floor would add and the delivered dose is untouched. True floors the
    /// delivered dose on qualifying cycles and flags `velocityBudgetExempt`, which the override
    /// seam reads so the hold may out-dose the base engine. Per-user opt-in only.
    public var velocityBudgetActive: Bool
    /// Per-user fizzle-safe ceiling for the early primer, in units. 0 turns the primer off.
    public var primerCapU: Double
    /// True routes the primer as a retractable temp basal rather than folding it into the bolus.
    /// The host sets it from the fallback preference unless the user has overridden to bolus.
    public var primerUseTempBasal: Bool
    /// Wall-clock epoch-ms for this cycle, used by the primer-insulin accumulator's decay.
    /// 0 means unknown, in which case no decay is applied.
    public var nowMs: Double
    // Reset triggers
    public var profileSwitched: Bool
    public var pumpDisconnected: Bool
    public var loopSuspended: Bool
    public var timeJumpMinutes: Double
    // Knobs
    public var aggressionUserKnob: Double
    public var hypoCautionUserKnob: Double
    public var sensitivityUserKnob: Double
    public var confirmedCapU: Double
    public var committedCapU: Double
    /// Carbs on board or a manual or wizard bolus within `mealAnnouncedBolusWindowMs` (AAPS
    /// 82f47416c5). A confirm transition then enters COMMITTED rather than CONFIRMED, and the
    /// OBSERVING primer does not fire. Last in the list, since callers construct this positionally.
    public var mealAnnounced: Bool

    public init(
        delta: Double, shortAvgDelta: Double, deltaAccl: Double, bg: Double, eventualBg: Double,
        targetBg: Double, maxDelta: Double, minGuardBg: Double, minGuardThreshold: Double,
        deltaHistory: [Double], iob: Double, maxIob: Double, baseInsulinReq: Double, roundSmbTo: Double,
        enableSmbPreChecks: Bool, mlHypoRisk: Double? = nil, mlMealLikely: Double? = nil,
        riskAtProjectedIob: ((Double) -> Double)? = nil, recentLowBg: Double, cumulativeRise30min: Double,
        hour: Int, exerciseActive: Bool, inPostExerciseWindow: Bool, asleep: Bool = false,
        fastCarbConfirmEnabled: Bool = false, aggressiveEarlyConfirmEnabled: Bool = false,
        sensorQualityOk: Bool = true,
        postRescueWindow: Bool = false, v1WouldDoseU: Double? = nil, composedFloorActive: Bool = false,
        velocityBudgetActive: Bool = false,
        primerCapU: Double = 0, primerUseTempBasal: Bool = false, nowMs: Double = 0,
        profileSwitched: Bool = false,
        pumpDisconnected: Bool = false, loopSuspended: Bool = false, timeJumpMinutes: Double = 0.0,
        aggressionUserKnob: Double = 1.0, hypoCautionUserKnob: Double = 1.0, sensitivityUserKnob: Double = 1.0,
        confirmedCapU: Double = SafetyGateConstants.maxConfirmedCommitDoseU,
        committedCapU: Double = SafetyGateConstants.maxCommittedDoseU,
        mealAnnounced: Bool = false
    ) {
        self.delta = delta
        self.shortAvgDelta = shortAvgDelta
        self.deltaAccl = deltaAccl
        self.bg = bg
        self.eventualBg = eventualBg
        self.targetBg = targetBg
        self.maxDelta = maxDelta
        self.minGuardBg = minGuardBg
        self.minGuardThreshold = minGuardThreshold
        self.deltaHistory = deltaHistory
        self.iob = iob
        self.maxIob = maxIob
        self.baseInsulinReq = baseInsulinReq
        self.roundSmbTo = roundSmbTo
        self.enableSmbPreChecks = enableSmbPreChecks
        self.mlHypoRisk = mlHypoRisk
        self.mlMealLikely = mlMealLikely
        self.riskAtProjectedIob = riskAtProjectedIob
        self.recentLowBg = recentLowBg
        self.cumulativeRise30min = cumulativeRise30min
        self.hour = hour
        self.exerciseActive = exerciseActive
        self.inPostExerciseWindow = inPostExerciseWindow
        self.asleep = asleep
        self.fastCarbConfirmEnabled = fastCarbConfirmEnabled
        self.sensorQualityOk = sensorQualityOk
        self.postRescueWindow = postRescueWindow
        self.v1WouldDoseU = v1WouldDoseU
        self.composedFloorActive = composedFloorActive
        self.aggressiveEarlyConfirmEnabled = aggressiveEarlyConfirmEnabled
        self.velocityBudgetActive = velocityBudgetActive
        self.primerCapU = primerCapU
        self.primerUseTempBasal = primerUseTempBasal
        self.nowMs = nowMs
        self.profileSwitched = profileSwitched
        self.pumpDisconnected = pumpDisconnected
        self.loopSuspended = loopSuspended
        self.timeJumpMinutes = timeJumpMinutes
        self.aggressionUserKnob = aggressionUserKnob
        self.hypoCautionUserKnob = hypoCautionUserKnob
        self.sensitivityUserKnob = sensitivityUserKnob
        self.confirmedCapU = confirmedCapU
        self.committedCapU = committedCapU
        self.mealAnnounced = mealAnnounced
    }
}

public struct V5PersistedState: Codable, Equatable, Sendable {
    public var mealHypothesis: MealHypothesisState
    public var mlMealLikelyNullStreak: Int
    /// Epoch-ms of the last decide() — the host uses it to detect a time jump / long gap
    /// (incl. app restart) and reset the meal hypothesis. Managed by the adapter, not decide().
    public var lastRunMs: Double?
    /// Previous cycle's meal_signal_score — input to the sustained-score early confirm
    /// (`confirmMinObservingAgeScoreReady`, 2026-07-03, AAPS 242a6e179d). Deliberately NOT
    /// serialized (excluded from CodingKeys, mirroring the AAPS in-memory-cache-only idiom):
    /// it survives across cycles only via BoostV5Store's in-memory cache, so a process restart
    /// loses it, which fails safe (streak=false → legacy confirm timing for one cycle).
    public var lastCycleScore: Double? = nil
    /// Units delivered as the early primer in this meal session, 0 meaning not yet primed. The
    /// once-per-session guard; reset on IDLE.
    public var primerAppliedU: Double = 0
    /// Remaining commit-shot reduction owed. Set at the CONFIRMED transition to the accumulated
    /// primer insulin beyond one base, then netted off the CONFIRMED shot and the COMMITTED holds.
    public var primerNettingResidualU: Double = 0
    /// Cross-session estimate of primer insulin still on board, in units, decayed by wall clock.
    /// It accumulates every primer across sessions and is deliberately NOT reset on IDLE, so a
    /// commit shot can credit the primer insulin from fizzled sessions that preceded it.
    public var primerIobU: Double = 0
    /// Epoch-ms the accumulator was last updated, for the decay. 0 means never.
    public var primerIobUpdatedMs: Double = 0
    /// Epoch-ms anchor for the ML null-streak tick (AAPS 2026-08-01). The renormalise threshold
    /// counts cycles and is meant to be about fifteen minutes of a missing model, which is three
    /// minutes on a one-minute feed unless the count is gated on elapsed time the way the
    /// meal-state ages are. Last in the list, since this type is constructed positionally.
    public var mlNullStreakLastMs: Double = 0
    /// Epoch-ms at which the current unbroken run of confirm-strength scores began, 0 when the last
    /// score was below `confirmScore` (AAPS c237a4d081, V6 review item 6). The sustained-score early
    /// confirm needs the run to have lasted `ageTickMs`, so a one-minute loop or a re-invoke seconds
    /// later cannot satisfy "two consecutive cycles". In memory only, like `lastCycleScore`: a restart
    /// loses it and the early path waits one more tick, which fails safe.
    public var scoreReadySinceMs: Double = 0

    enum CodingKeys: String, CodingKey {
        // lastCycleScore and scoreReadySinceMs intentionally omitted — in-memory only (see their
        // doc comments).
        case mealHypothesis
        case mlMealLikelyNullStreak
        case lastRunMs
        case primerAppliedU
        case primerNettingResidualU
        case primerIobU
        case primerIobUpdatedMs
        case mlNullStreakLastMs
    }

    public init(
        mealHypothesis: MealHypothesisState = MealHypothesisState(),
        mlMealLikelyNullStreak: Int = 0,
        lastRunMs: Double? = nil,
        lastCycleScore: Double? = nil,
        primerAppliedU: Double = 0,
        primerNettingResidualU: Double = 0,
        primerIobU: Double = 0,
        primerIobUpdatedMs: Double = 0,
        mlNullStreakLastMs: Double = 0,
        scoreReadySinceMs: Double = 0
    ) {
        self.mealHypothesis = mealHypothesis
        self.mlMealLikelyNullStreak = mlMealLikelyNullStreak
        self.lastRunMs = lastRunMs
        self.lastCycleScore = lastCycleScore
        self.primerAppliedU = primerAppliedU
        self.primerNettingResidualU = primerNettingResidualU
        self.primerIobU = primerIobU
        self.primerIobUpdatedMs = primerIobUpdatedMs
        self.mlNullStreakLastMs = mlNullStreakLastMs
        self.scoreReadySinceMs = scoreReadySinceMs
    }
}

public struct V5Decision {
    public let finalDose: Double
    public let score: Double
    public let scoreComponents: ScoreComponents
    public let mlWeightsRenormalized: Bool
    public let mealHypothesis: MealHypothesis
    public let mealHypothesisAge: Int
    public let stateReset: Bool
    public let aggressionBudget: AggressionBudgetResult
    public let actionMultiplier: Double
    public let insulinToDeliver: Double
    public let phase3: Phase3Result
    /// Composed Phase-3 floor (F = `ComposedFloor.fraction`) telemetry — dual semantics keyed on
    /// `V5Inputs.composedFloorActive`; nil when the floor conditions are unmet either way:
    ///  - toggle OFF (shadow): extra U the floor WOULD have added this cycle vs the pipeline output;
    ///    never affects `finalDose`.
    ///  - toggle ON (activation): the uplift actually APPLIED to `finalDose` (delivered-with-floor −
    ///    what-unfloored-would-have-delivered); 0.0 when no uplift.
    /// See `ComposedFloor.targetDose`. 2026-07-06/07, AAPS e0f18ddd0e + 730b3dcb2c.
    public let floorWouldAdd: Double?
    /// Velocity-budget floor telemetry, with the same dual semantics as `floorWouldAdd` and keyed
    /// on `V5Inputs.velocityBudgetActive`. Nil when the floor's conditions are unmet either way.
    /// Shadow records the extra units the floor would add; active records the uplift applied.
    public let velocityBudgetWouldAdd: Double?
    /// True only when the active velocity-budget floor lifted the delivered dose. The override seam
    /// reads it to exempt the cycle from the non-meal cap, because this floor doses precisely when
    /// the base engine doses about zero. The exempt dose is bounded by the committed cap and the
    /// remaining IOB headroom.
    public let velocityBudgetExempt: Bool
    /// Units to deliver as the early primer this cycle, expressed as a bolus equivalent. In bolus
    /// mode it is already folded into `finalDose`; in temp-basal mode it is not, and the seam
    /// converts it to a retractable temp basal. 0 means no primer this cycle.
    public let primerBolusU: Double
    /// Delivery routing, passed through for the seam. True means temp basal.
    public let primerUseTempBasal: Bool
    /// Sizing telemetry, of the form "d=<delta>,fR=,fB=,fI=,tgt=". Non-empty whenever the primer
    /// gate opened, including when the state factors sized it to nothing, so a shadow can tell
    /// "the gate never opened" from "the gate opened and correctly sized to zero".
    public let primerScaleDebug: String
    /// True on the cycle a meal session commits, whether by CONFIRMED or, for an announced meal,
    /// straight to COMMITTED (AAPS 82f47416c5). The meal-time learner and the primer netting key on it.
    public let mealSessionStarted: Bool
    public let newPersistedState: V5PersistedState
}

public enum BoostV5Engine {
    /// One full V5 cycle. Pure over inputs + prior state.
    public static func decide(_ inputs: V5Inputs, persisted: V5PersistedState) -> V5Decision {
        // 2026-10-08 (AAPS c237a4d081, audit item 17): a state whose wall-clock anchor is more than
        // timeJumpResetMinutes from now, whether restored from storage after a restart or held in
        // memory across a loop gap, is treated as a time jump and reset to IDLE. The session lock
        // survives the reset.
        let (resetState, didReset) = MealHypothesisEngine.resetIfNeeded(
            current: persisted.mealHypothesis,
            profileSwitched: inputs.profileSwitched, pumpDisconnected: inputs.pumpDisconnected,
            loopSuspended: inputs.loopSuspended,
            timeJumpMinutes: max(
                inputs.timeJumpMinutes,
                MealHypothesisEngine.staleStateMinutes(persisted.mealHypothesis, nowMs: inputs.nowMs)
            )
        )
        // The session lock after its release rules, as step() will see it (step applies the same
        // idempotent function), for the session-start test below.
        let lockState = MealHypothesisEngine.releaseEndedSessionLock(resetState, nowMs: inputs.nowMs, delta: inputs.delta)

        // Count elapsed time rather than invocations, as the meal-state ages do.
        let nullStreakTick = inputs.nowMs <= 0 || persisted.mlNullStreakLastMs <= 0
            || (inputs.nowMs - persisted.mlNullStreakLastMs) >= MealHypothesisConstants.ageTickMs
        let nextNullStreak = inputs.mlMealLikely == nil
            ? (nullStreakTick ? persisted.mlMealLikelyNullStreak + 1 : persisted.mlMealLikelyNullStreak)
            : 0
        let nextNullStreakMs: Double = (inputs.mlMealLikely == nil && inputs.nowMs > 0 && nullStreakTick)
            ? inputs.nowMs : persisted.mlNullStreakLastMs
        let scoreResult = MealSignalScoreEngine.mealSignalScore(
            delta: inputs.delta, deltaAccl: inputs.deltaAccl, mlMealLikely: inputs.mlMealLikely,
            recentLowBg: inputs.recentLowBg, hour: inputs.hour, exerciseActive: inputs.exerciseActive,
            cumulativeRise30min: inputs.cumulativeRise30min, mlMealLikelyNullStreak: nextNullStreak
        )

        // AggressionBudget is HOISTED above the state step — it is state-independent (takes no
        // meal-state input), so computing it first lets the OBSERVING→CONFIRMED dose-adequacy gate
        // size the prospective commit-shot. Pure reorder, no behaviour change. (2026-07-02, mirrors
        // AAPS 4bfd7bea32.)
        let budget = AggressionBudgetEngine.aggressionBudget(
            baseInsulinReq: inputs.baseInsulinReq, mlHypoRisk: inputs.mlHypoRisk,
            inPostExerciseWindow: inputs.inPostExerciseWindow,
            hypoCautionUserKnob: inputs.hypoCautionUserKnob, sensitivityUserKnob: inputs.sensitivityUserKnob
        )

        // Dose-adequacy gate for OBSERVING→CONFIRMED (2026-07-02): the single per-session commit-shot
        // must beat one routine COMMITTED hold cycle (committedCapU) to be worth spending — else a
        // trivial pre-meal upswing burns the token and the committedInSession lock starves the meal on
        // holds alone. Uses the mlHypoRisk-DAMPED budget, so confirm is also held back when hypo risk
        // is elevated. Clamped strictly below confirmedCapU so a manual committedCap ≥ confirmedCap
        // can't make the gate unsatisfiable (which would silently disable V6 meal response). Fast-carb
        // fast-path is exempt (handled inside step()).
        // 2026-07-02 (9545323fb1): size the shot as it would actually DELIVER — including velocity
        // scaling — not the pre-velocity raw. Backtest: 35.8% of raw-gate passes delivered BELOW the
        // floor after velocity scaling, re-creating the starvation the gate exists to prevent. The
        // velocityFactor is hoisted here (pure fn of inputs) and reused for the delivered dose below.
        let velocityFactor = SafetyGates.velocityScaledDoseFactor(inputs.cumulativeRise30min)
        let prospectiveConfirmShot = budget.budget *
            MealActionMultiplier.value(for: .confirmed, aggressionUserKnob: inputs.aggressionUserKnob) * velocityFactor
        // 2026-07-06 (AAPS 311703ddf5): the committedCap term of the floor is PINNED at the factory
        // default (0.5 U) so a user-raised committedCap can't silently tighten the confirm gate —
        // see MealHypothesisConstants.confirmDoseFloorU.
        let confirmDoseFloor = MealHypothesisConstants.confirmDoseFloorU(
            committedCapU: inputs.committedCapU,
            confirmedCapU: inputs.confirmedCapU
        )
        let confirmDoseAdequate = prospectiveConfirmShot > confirmDoseFloor

        // 2026-07-03 sustained-score early confirm input (AAPS 242a6e179d): was LAST cycle's
        // score already confirm-ready? Sourced from the in-memory persisted state (nil on cold
        // start → false → legacy timing). 2026-10-08 (AAPS c237a4d081): with a clock, "the previous
        // cycle" means a confirm-strength run that began at least ageTickMs ago, not the previous
        // invocation (see scoreReadySinceMs).
        let scoreReadyStreak = Self.confirmScoreReadyStreak(persisted, nowMs: inputs.nowMs, didReset: didReset)
        let scoreReadySinceMs = Self.nextScoreReadySinceMs(
            persisted, nowMs: inputs.nowMs, didReset: didReset, score: scoreResult.score
        )

        let newHypothesisState = MealHypothesisEngine.step(
            current: resetState, score: scoreResult.score, eventualBg: inputs.eventualBg,
            targetBg: inputs.targetBg, delta: inputs.delta, deltaAccl: inputs.deltaAccl,
            deltaDeclining: MealHypothesisEngine.deltaDeclining(inputs.deltaHistory, windowCycles: 2),
            asleep: inputs.asleep, exerciseActive: inputs.exerciseActive,
            // 2026-07-02 (1245d33a9a): post-hypo rescue-carb guard — the fast-carb fast-path is
            // suppressed when the 60-min low is below the rescue threshold, since a rescue-carb rebound
            // routinely satisfies the fast-path signals yet is exempt from the confirmDoseAdequate gate.
            fastConfirmEnabled: MealHypothesisEngine.fastConfirmAllowed(
                inputs.fastCarbConfirmEnabled, recentLowBg: inputs.recentLowBg
            ),
            confirmDoseAdequate: confirmDoseAdequate,
            scoreReadyStreak: scoreReadyStreak, // 2026-07-03 sustained-score early confirm (hoisted above)
            aggressiveEarlyConfirm: inputs.aggressiveEarlyConfirmEnabled, // 2026-07-17 opt-in, one cycle earlier
            nowMs: inputs.nowMs, // 2026-07-30 wall-clock age tick
            mealAnnounced: inputs.mealAnnounced // 2026-10-05 announced meal confirms into COMMITTED
        )
        let mealSessionStarted = Self.sessionCommittedThisCycle(prior: lockState, next: newHypothesisState)

        // Early primer (AAPS 2026-07-20). The session accumulators are carried here; the primer
        // itself is sized after Phase 3 (see primerSizing), where the hard gates are known (AAPS
        // c237a4d081, audit item 10). The once-per-session guard resets on IDLE; the primer-insulin
        // accumulator deliberately does not, so a commit shot can credit the primer insulin from
        // fizzled sessions that preceded it.
        let primerState = newHypothesisState.state
        var primerAppliedU = primerState == .idle ? 0.0 : persisted.primerAppliedU
        var primerIobU = persisted.primerIobU
        if inputs.nowMs > 0, persisted.primerIobUpdatedMs > 0, inputs.nowMs > persisted.primerIobUpdatedMs {
            let dtMin = (inputs.nowMs - persisted.primerIobUpdatedMs) / 60000.0
            primerIobU *= exp(-dtMin / Primer.iobTauMin)
        }
        let primerIobUpdatedMs = inputs.nowMs > 0 ? inputs.nowMs : persisted.primerIobUpdatedMs
        // Netting residual: reset on IDLE, and set when a meal session commits to the accumulated
        // primer insulin beyond one base, so the first primer's bonus stays additive while later
        // fizzles are credited against the commit shot. The credited excess is then consumed from
        // the accumulator so a second meal cannot re-credit it. Spent down against CONFIRMED and
        // then the COMMITTED holds below. Since 2026-10-05 (AAPS 82f47416c5) it keys on the session
        // start rather than on CONFIRMED, which is the same cycle for an unannounced meal and also
        // covers an announced meal's direct commit; a re-engaged COMMITTED is not a session start.
        var primerNettingResidualU = primerState == .idle ? 0.0 : persisted.primerNettingResidualU
        if mealSessionStarted {
            primerNettingResidualU = max(0.0, primerIobU - inputs.primerCapU)
            primerIobU = min(primerIobU, inputs.primerCapU)
        }

        let actionMult = MealActionMultiplier.value(for: newHypothesisState.state, aggressionUserKnob: inputs.aggressionUserKnob)
        let rawInsulinToDeliver = budget.budget * actionMult
        // velocityFactor hoisted above the confirm dose gate (reused here). (2026-07-02, 9545323fb1)
        let velocityScaled = rawInsulinToDeliver * velocityFactor
        let insulinToDeliver = SafetyGates.applyStateDoseCap(
            newHypothesisState.state,
            velocityScaled,
            confirmedCapU: inputs.confirmedCapU,
            committedCapU: inputs.committedCapU
        )

        let phase3 = SafetyGates.applyPhase3(Phase3Inputs(
            insulinToDeliver: insulinToDeliver, enableSmbPreChecks: inputs.enableSmbPreChecks,
            minGuardBg: inputs.minGuardBg, minGuardThreshold: inputs.minGuardThreshold,
            maxDelta: inputs.maxDelta, bg: inputs.bg, iob: inputs.iob, maxIob: inputs.maxIob,
            deltaAccl: inputs.deltaAccl, delta: inputs.delta, baseInsulinReq: inputs.baseInsulinReq,
            roundSmbTo: inputs.roundSmbTo, sensorQualityOk: inputs.sensorQualityOk,
            riskAtProjectedIob: inputs.riskAtProjectedIob, mlHypoRisk: inputs.mlHypoRisk
        ))

        // 2026-07-06/07 composed Phase-3 floor (AAPS e0f18ddd0e + 730b3dcb2c). Computed here because
        // this is the one place the whole composed multiplier stack (state mult × velocityFactor ×
        // iobHeadroomBrake × decelerationBrake) has already been applied (phase3.finalDose). Target
        // semantics: nil = floor conditions unmet; 0.0 = a Phase-3 HARD gate fired; else the bounded
        // floored dose min(budget × F, committedCapU) (v1-bounded in RECOVERING). See ComposedFloor.
        let floorTarget = ComposedFloor.targetDose(
            state: newHypothesisState.state,
            bg: inputs.bg,
            eventualBg: inputs.eventualBg,
            targetBg: inputs.targetBg,
            asleep: inputs.asleep,
            postRescueWindow: inputs.postRescueWindow,
            budgetU: budget.budget,
            committedCapU: inputs.committedCapU,
            v1WouldDoseU: inputs.v1WouldDoseU,
            hardGateFired: phase3.reductions.hardGateFired != nil
        )
        var finalDose: Double
        let floorWouldAdd: Double?
        if !inputs.composedFloorActive {
            // SHADOW (toggle OFF, or V6 not the active doser) — zero dosing-path effect; the field
            // records what the floor WOULD have added.
            finalDose = phase3.finalDose
            floorWouldAdd = floorTarget.map { max(0.0, $0 - phase3.finalDose) }
        } else {
            // ACTIVE (per-user activation): deliver max(pipeline dose, floored dose). The floored
            // dose passes through the SAME downstream clamps the pipeline dose already received after
            // the soft-brake product, so no hard gate or cap is bypassed (see ComposedFloor). The
            // override-seam caps (non-meal v1-bound, post-rescue cap, cumulative cap, sleep/boost-
            // active gates) all still run downstream on finalDose; RECOVERING is v1-bounded inside
            // the target so the logged uplift matches what the seam delivers.
            let deliverableFloor: Double = floorTarget.map { target in
                var f = min(target, max(0.0, inputs.maxIob - inputs.iob))
                f = min(f, SafetyGates.dynamicSpikeCap(inputs.baseInsulinReq))
                if inputs.roundSmbTo > 0.0 { f = floor(f / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
                return max(0.0, f)
            } ?? 0.0
            finalDose = max(phase3.finalDose, deliverableFloor)
            floorWouldAdd = floorTarget.map { _ in finalDose - phase3.finalDose }
        }

        // Velocity-budget floor (AAPS 3ea7479572), for the budget-near-zero high tail: cycles where
        // the base engine's insulin requirement is at or below zero, so the model says covered, while
        // the person sits high. That is broadly the population the composed floor leaves out, since
        // it requires a positive budget.
        //
        // The AAPS comment states the two floors are mutually exclusive by the budget condition.
        // They are not, quite: the composed floor needs budget > 0 and this one needs budget <= 0.01,
        // so both fire in the band (0, 0.01]. The delivered dose is unaffected, being the larger of
        // the two and bounded by the committed cap either way, which is what AAPS delivers too. The
        // uplift below is therefore measured against the dose entering this block rather than
        // against phase3.finalDose, so a cycle where both fired does not report the composed floor's
        // contribution as this floor's. AAPS measures against phase3.finalDose and over-reports in
        // that band; the field is internal here, so the difference is telemetry only.
        let vbTarget = VelocityBudgetFloor.targetDose(
            state: newHypothesisState.state,
            bg: inputs.bg,
            budgetU: budget.budget,
            committedCapU: inputs.committedCapU,
            asleep: inputs.asleep,
            postRescueWindow: inputs.postRescueWindow,
            hardGateFired: phase3.reductions.hardGateFired != nil
        )
        let doseBeforeVelocityBudget = finalDose
        let velocityBudgetWouldAdd: Double?
        var velocityBudgetExempt = false
        if !inputs.velocityBudgetActive {
            // Shadow: record what the floor would add, deliver nothing extra.
            velocityBudgetWouldAdd = vbTarget.map { max(0.0, $0 - doseBeforeVelocityBudget) }
        } else {
            // The dynamic spike cap is deliberately not applied here. It is 2.5 times the base
            // insulin requirement, which is about zero on this tail, so applying it would zero the
            // floor. Exposure is bounded instead by the committed cap inside the target and by the
            // remaining IOB headroom here.
            let deliverable: Double = vbTarget.map { target in
                var f = min(target, max(0.0, inputs.maxIob - inputs.iob))
                if inputs.roundSmbTo > 0.0 { f = floor(f / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
                return max(0.0, f)
            } ?? 0.0
            let lifted = max(finalDose, deliverable)
            velocityBudgetExempt = vbTarget != nil && lifted > finalDose
            finalDose = lifted
            velocityBudgetWouldAdd = vbTarget.map { _ in finalDose - doseBeforeVelocityBudget }
        }

        // Primer sizing and application (AAPS 2026-07-20; moved after Phase 3 on 2026-10-08, AAPS
        // c237a4d081 audit item 10). Sized here so it can see the Phase-3 hard gates, which it must
        // respect exactly as both floors do. See primerSizing for the rules.
        let primer = Self.primerSizing(
            inputs, state: primerState, alreadyPrimedU: primerAppliedU,
            mlScale: budget.mlHypoRiskScale, hardGateFired: phase3.reductions.hardGateFired != nil,
            sessionLocked: newHypothesisState.committedInSession
        )
        let primerBolusU = primer.bolusU
        if primerBolusU > 0 {
            primerAppliedU = primerBolusU
            primerIobU += primerBolusU
        }
        // Bolus routing folds the primer into the final dose, and the seam exempts such a cycle
        // from the non-meal cap. Temp-basal routing leaves the dose alone and the seam delivers the
        // primer as a retractable raise above scheduled basal. Since 2026-10-08 the seam's exemption
        // covers the whole final dose, so the non-primer part is bounded at V1's would-dose here,
        // leaving only the primer itself free of the V1 bound.
        if primerBolusU > 0, !inputs.primerUseTempBasal {
            let nonPrimer = Self.primerNonMealBound(
                finalDose, state: newHypothesisState.state,
                velocityBudgetExempt: velocityBudgetExempt, v1WouldDoseU: inputs.v1WouldDoseU
            )
            finalDose = min(nonPrimer + primerBolusU, max(0.0, inputs.maxIob - inputs.iob))
        }
        // Net the accumulated primer excess off the commit shot and then the holds: move, not add.
        if primerState == .confirmed || primerState == .committed, primerNettingResidualU > 0 {
            let net = min(primerNettingResidualU, finalDose)
            finalDose = max(0.0, finalDose - net)
            primerNettingResidualU -= net
        }

        return V5Decision(
            finalDose: finalDose, score: scoreResult.score, scoreComponents: scoreResult.components,
            mlWeightsRenormalized: scoreResult.mlWeightsRenormalized, mealHypothesis: newHypothesisState.state,
            mealHypothesisAge: newHypothesisState.ageCycles, stateReset: didReset, aggressionBudget: budget,
            actionMultiplier: actionMult, insulinToDeliver: insulinToDeliver, phase3: phase3,
            floorWouldAdd: floorWouldAdd,
            velocityBudgetWouldAdd: velocityBudgetWouldAdd,
            velocityBudgetExempt: velocityBudgetExempt,
            primerBolusU: primerBolusU,
            primerUseTempBasal: inputs.primerUseTempBasal,
            primerScaleDebug: primer.debug,
            mealSessionStarted: mealSessionStarted,
            newPersistedState: V5PersistedState(
                mealHypothesis: newHypothesisState,
                mlMealLikelyNullStreak: nextNullStreak,
                lastCycleScore: scoreResult.score, // 2026-07-03: next cycle's scoreReadyStreak input
                primerAppliedU: primerAppliedU,
                primerNettingResidualU: primerNettingResidualU,
                primerIobU: primerIobU,
                primerIobUpdatedMs: primerIobUpdatedMs,
                mlNullStreakLastMs: nextNullStreakMs,
                scoreReadySinceMs: scoreReadySinceMs
            )
        )
    }

    /// True when this cycle's step began a meal session's commitment: entry into CONFIRMED, or into
    /// COMMITTED from IDLE or OBSERVING, the announced-meal route (AAPS 82f47416c5). CONFIRMED to
    /// COMMITTED and RECOVERING re-engaging COMMITTED continue a session and are excluded, as is a
    /// COMMITTED re-engaged from OBSERVING inside a held session lock.
    static func sessionCommittedThisCycle(prior: MealHypothesisState, next: MealHypothesisState) -> Bool {
        (next.state == .confirmed && prior.state != .confirmed) ||
            (next.state == .committed && !prior.committedInSession && (prior.state == .idle || prior.state == .observing))
    }

    /// Sustained-score early-confirm input (AAPS c237a4d081, V6 review item 6). The streak was
    /// counted per invocation, so a one-minute loop, or a re-invoke seconds after the last one,
    /// satisfied "two consecutive cycles" almost at once. With a clock it now needs a confirm-strength
    /// run that began at least `ageTickMs` ago: on a five-minute loop that is the previous cycle, as
    /// before, and on a one-minute loop it is four minutes of readings. A reset this cycle breaks the
    /// run. With no clock the previous invocation's score decides, as before.
    static func confirmScoreReadyStreak(_ persisted: V5PersistedState, nowMs: Double, didReset: Bool) -> Bool {
        if nowMs <= 0 { return (persisted.lastCycleScore ?? 0.0) >= MealHypothesisConstants.confirmScore }
        return !didReset && persisted.scoreReadySinceMs > 0
            && nowMs - persisted.scoreReadySinceMs >= MealHypothesisConstants.ageTickMs
    }

    /// The run start carried to the next cycle: kept while the score stays confirm-strength, 0 otherwise.
    static func nextScoreReadySinceMs(_ persisted: V5PersistedState, nowMs: Double, didReset: Bool, score: Double) -> Double {
        if nowMs <= 0 || score < MealHypothesisConstants.confirmScore { return 0 }
        if !didReset, persisted.scoreReadySinceMs > 0 { return persisted.scoreReadySinceMs }
        return nowMs
    }

    /// The early primer's amount this cycle and its sizing telemetry (empty when the gate did not open).
    ///
    /// Once per OBSERVING session, on an accelerating rise, with every floor clear (recent low at or
    /// above 80, awake, not exercising, not post-rescue) and maxIOB headroom. AAPS added three
    /// conditions in October 2026:
    ///  - no primer on an announced meal (82f47416c5). It reclaims early insulin for a meal nobody
    ///    dosed for, and after a pre-bolus that insulin has already been given.
    ///  - no primer when a Phase-3 hard gate fired (c237a4d081, audit item 10: SMB pre-checks,
    ///    minGuardBG below threshold, maxDelta). Both floors return 0 on those cycles and the pipeline
    ///    dose is already 0; the primer was the one route past them. Temp-basal routing is blocked as
    ///    well, since a gate that says no insulin should be added applies to a raised temp too.
    ///  - the ceiling is scaled by the same mlHypoRisk damper the aggression budget applies, so the
    ///    primer stays proportional to the meal response the budget would give at the same risk. The
    ///    damper floors at 0.50 (0.25 at maximum Hypo Caution).
    static func primerSizing(
        _ inputs: V5Inputs,
        state: MealHypothesis,
        alreadyPrimedU: Double,
        mlScale: Double,
        hardGateFired: Bool,
        sessionLocked: Bool = false
    ) -> (bolusU: Double, debug: String) {
        let open = inputs.primerCapU > 0 && state == .observing && alreadyPrimedU <= 0
            && inputs.delta >= Primer.deltaMin && inputs.shortAvgDelta >= Primer.riseShortAvgMin
            && inputs.recentLowBg >= Primer.minRecentLowMgdl && !inputs.asleep
            && !inputs.exerciseActive && !inputs.postRescueWindow
            && !inputs.mealAnnounced
            && !hardGateFired
            // No second primer once the session has committed (AAPS f1d0c93a8e).
            && !sessionLocked
        guard open else { return (0, "") }
        // The cap is a true ceiling and the factors in [0, 1] scale it down. The rise factor
        // discriminates, carrying the magnitude of the actual rise. The glucose and insulin factors
        // suppress: neither can tell a real onset from jitter, because at onset both look flat and
        // benign, and they exist only to bound the cost of being wrong. `deltaAccl` deliberately does
        // not scale, since it peaks on flat traces and any monotonic function of it would re-import
        // the inversion the 2026-07-30 rework removed.
        let fRise = min(max((inputs.delta - Primer.deltaRampLo) / (Primer.deltaFull - Primer.deltaRampLo), 0), 1)
        let fBg = min(max((inputs.bg - Primer.bgLo) / Primer.bgLoSpan, 0), 1)
            * min(max((Primer.bgCeil - inputs.bg) / Primer.bgFade, 0), 1)
        let fIob = inputs.maxIob > 0 ? min(max(1.0 - inputs.iob / inputs.maxIob, 0), 1) : 0
        let fMl = min(max(mlScale, 0), 1)
        let target = inputs.primerCapU * fRise * fBg * fIob * fMl
        var amt = min(target, max(0.0, inputs.maxIob - inputs.iob))
        if inputs.roundSmbTo > 0 { amt = floor(amt / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
        // Re-clamp after rounding. floor(x/step)*step can land a hair above the target in binary
        // floating point, which would break the ceiling invariant; rounding must only ever go down.
        amt = min(amt, target)
        // fM is appended after tgt so that parsers keyed on the earlier fields are unaffected.
        let debug = "d=\(rnd(inputs.delta, 1)),fR=\(rnd(fRise, 2)),fB=\(rnd(fBg, 2)),"
            + "fI=\(rnd(fIob, 2)),tgt=\(rnd(target, 3)),fM=\(rnd(fMl, 2))"
        return (amt > 0 ? amt : 0, debug)
    }

    /// The non-primer part of a bolus-mode primer cycle, bounded at V1's would-dose (AAPS c237a4d081,
    /// audit item 10). The override seam treats any cycle with a bolus primer as a meal state and
    /// lets the whole final dose past its non-meal V1 bound; the primer is meant to out-dose V1, but
    /// the OBSERVING dose it was folded into is not. Meal states and a velocity-budget lift keep
    /// their own exemption, as does a cycle with no V1 dose to bound against.
    static func primerNonMealBound(
        _ dose: Double, state: MealHypothesis, velocityBudgetExempt: Bool, v1WouldDoseU: Double?
    ) -> Double {
        if state == .confirmed || state == .committed || velocityBudgetExempt { return dose }
        guard let v1 = v1WouldDoseU else { return dose }
        return min(dose, max(0.0, v1))
    }
}

// MARK: - Composed Phase-3 floor (F = 0.25) — shadow first, per-user activatable

/// 2026-07-06/07 composed Phase-3 floor (AAPS e0f18ddd0e + 730b3dcb2c).
///
/// Forensic + 40,180-cycle cohort backtest: on meal-session high cycles (CONFIRMED/COMMITTED/
/// RECOVERING ∧ BG > 160 ∧ eventualBG > target+20 ∧ awake ∧ budget > 0) the composed post-budget
/// multiplier — stateMult × velocityFactor × iobHeadroomBrake × decelerationBrake — has MEDIAN
/// 0.037. Individually-sane brakes multiply into a product that drives the dose below one pump
/// step, so it floor-rounds to ZERO for 30+ minutes mid-meal (Episode B: BG 268–277, six
/// consecutive zero-dose cycles, ended 297 + a manual bolus). A pipeline defect (independent
/// brakes multiplying), not a calibration issue.
///
/// F = 0.25 backtests at +0.76 U/user-day with 16.6% pre-low incidence — the base rate, i.e. no
/// added hypo exposure. SHADOW first: with the toggle OFF, `targetDose` only feeds the
/// `floorWouldAdd` telemetry (what the floor WOULD have added) and delivered dosing is untouched.
/// Activation (`boostV5ComposedFloorActive`, Advanced, default OFF) applies the floor to the
/// delivered dose — PER-USER, and the per-user TBR gate is now ENFORCED in code (2026-07-08, AAPS
/// 9110ef2520 + 8b492a08e7): the floor may only engage while trailing-14d TBR<63 < 2.0% AND
/// TBR<70 < 3.5% (`allowedByTbr`, fail-closed). The host computes those from a throttled 14d BG
/// scan and ANDs the result into `V5Inputs.composedFloorActive`.
/// V1-acceleration early primer (AAPS 2026-07-20, reworked 2026-07-30).
///
/// The base Boost engine responded to acceleration about 15 minutes before V6 reached CONFIRMED,
/// at 98% recall. The primer restores that lead as a small advance on the commit shot, delivered
/// once per OBSERVING session. It is additive up to the fizzle-safe ceiling and the excess is
/// netted off the commit shot, so a confirmed meal moves insulin earlier rather than adding it.
///
/// The 2026-07-30 rework replaced the original trigger and sizing. `deltaAccl` is a percentage
/// whose denominator floors at 2.0, so on a flat trace the old gate reduced to a rise of 0.2
/// mg/dL, a fifth of one sensor quantisation step. Measured over 90 days and 25,766 points it was
/// the worst of ten candidate detectors, and its magnitude scaling ran backwards: a flat trace
/// scored 33.5 while a genuine 11 mg/dL per 5 min rise scored 12.5, so noise was paid about twice
/// and real meals about 1.1 times. It also saturated at its ceiling on five of six observed live
/// fires, making it a constant dressed as a response curve. One incident delivered 1.35 U on a
/// flat 120 and reached a nadir of 68.
///
/// Now the absolute rise carries the magnitude, `deltaAccl` remains only as a cheap shape
/// confirmer, and the cap is a true ceiling scaled down by three factors in [0, 1].
/// Fixed-decimal rounding for the primer telemetry string, kept local so the core stays free of
/// formatting dependencies.
private func rnd(_ x: Double, _ dp: Int) -> Double {
    var f = 1.0
    for _ in 0 ..< dp { f *= 10 }
    return (x * f).rounded() / f
}

enum Primer {
    /// Sustained-rise trigger, short average in mg/dL per 5 min. It replaced the acceleration
    /// trigger (deltaAccl > 10), which a steady rise never meets (AAPS Boost 6.3.0, f1d0c93a8e).
    static let riseShortAvgMin = 3.0
    /// Suppressed unless the 60-minute low is at or above this, guarding a rescue-carb rebound.
    static let minRecentLowMgdl = 80.0
    /// Absolute-rise floor, mg/dL per 5 min. A rise of 3 strictly dominates the old ratio gate:
    /// the same firing frequency, 25.75 against 26.70 per 100 cycles, at 52.7% against 43.8%
    /// probability of a real rise, while keeping 25 minutes of median lead over the confirm point.
    /// A floor of 5, the base engine's own, collapses that lead to 5 minutes and would make the
    /// primer redundant with CONFIRMED.
    static let deltaMin = 3.0
    /// Rise at which the scale reaches 1.0, so the full ceiling is only paid on a confirm-strength
    /// rise. It is the rise at which V6 reached CONFIRMED in the reference meal.
    static let deltaFull = 8.0
    /// Ramp origin, kept below `deltaMin` so the gate decides whether to fire and the ramp only
    /// decides how much.
    static let deltaRampLo = 1.5
    /// Lower glucose shoulder: suppressed below this, full scale by lo + span. It guards the
    /// near-target case, after an observed fire at 92 mg/dL on jitter. It does not discriminate,
    /// because at onset a real meal and a flat trace look alike in glucose; it bounds the cost of
    /// being wrong.
    static let bgLo = 90.0
    static let bgLoSpan = 20.0
    /// Upper glucose shoulder: fades to zero from ceiling minus fade, so the primer can never add
    /// into a recovering high-insulin tail, which was the repeated source of lows.
    static let bgCeil = 220.0
    static let bgFade = 40.0
    /// Decay time constant in minutes for the cross-session primer-insulin accumulator, which
    /// decays as exp(-dt / tau). About 90 minutes approximates rapid insulin clearance well enough
    /// for the confirm-time netting, which only ever removes insulin and is therefore safe-signed.
    static let iobTauMin = 90.0
}

/// Velocity-budget floor (AAPS 2026-07-17), for the budget-near-zero high tail.
///
/// It addresses cycles where the base engine's insulin requirement is at or below zero, meaning the
/// model says the person is covered, while they sit high. The composed floor deliberately excludes
/// that population because it requires a positive budget.
///
/// This floor is unique in that a delivered dose must out-dose the base engine in a non-meal state,
/// since the base engine also doses about zero when its requirement is at or below zero. The caller
/// therefore flags the cycle exempt from the override seam's non-meal cap. The exemption is bounded
/// by construction: the target is capped at the committed cap, the floor requires the person to be
/// awake and outside the post-rescue window, and the cumulative 60-minute, boost-active and sleep
/// gates at the seam all still run.
enum VelocityBudgetFloor {
    /// Glucose must exceed this, mg/dL. Higher than the composed floor's 160, because this floor
    /// doses when the base requirement is about zero, so it is confined to a genuinely high value.
    static let minBgMgdl = 180.0
    /// A budget at or below this, in units, means the base engine considers the person covered.
    /// The composed floor requires a positive budget, so the two floors cannot both fire.
    static let maxBudgetU = 0.01
    /// The tier-equivalent hold, in units, before the committed-cap and IOB-headroom bounds. It is
    /// about the per-cycle velocity-tier addition the base engine drops to zero on this tail.
    static let tierU = 0.5

    /// Target dose in units, or nil when the conditions are unmet. A returned 0.0 means a Phase-3
    /// hard gate fired, which is distinct from nil and keeps the telemetry honest about why.
    /// RECOVERING is excluded, matching the rejected pattern of dosing during recovery, and the
    /// floor keys on a sustained high rather than a sharp rise: in the sizing work the rising
    /// sub-cell ran at 10.7% pre-low against 4.3% for the sustained one.
    static func targetDose(
        state: MealHypothesis,
        bg: Double,
        budgetU: Double,
        committedCapU: Double,
        asleep: Bool,
        postRescueWindow: Bool,
        hardGateFired: Bool
    ) -> Double? {
        let conditionsMet = state != .recovering
            && bg > minBgMgdl
            && budgetU <= maxBudgetU
            && !asleep
            && !postRescueWindow
        guard conditionsMet else { return nil }
        if hardGateFired { return 0.0 }
        return min(tierU, committedCapU)
    }
}

enum ComposedFloor {
    /// Floor fraction of the (mlHypoRisk-damped) AggressionBudget the composed multiplier stack may
    /// not push the dose below on a meal-session high cycle.
    static let fraction = 0.25
    /// BG must exceed this (mg/dL) — the "high cycle" condition.
    static let minBgMgdl = 160.0
    /// eventualBG must exceed target by more than this (mg/dL).
    static let minEventualOffsetMgdl = 20.0

    /// Max trailing-14-day time-below-63 mg/dL (3.5 mmol/L — the TING lower bound) for the composed
    /// brake-floor to be ALLOWED to engage. The floor is insulin-ADDING, so it may only alter the
    /// delivered dose for users with low severe-hypo exposure. (2026-07-08, AAPS 9110ef2520.)
    static let maxTbr63Pct = 2.0
    /// Max trailing-14-day time-below-70 mg/dL — the two-test-bar primary gate (added 2026-07-08,
    /// AAPS 8b492a08e7: a <63-only gate wrongly engaged user C, whose <63 was 1.56% but <70 3.95%).
    static let maxTbr70Pct = 3.5

    /// Whether the composed brake-floor may engage, given the user's trailing-14d time-below-63 AND
    /// time-below-70 mg/dL. FAIL-CLOSED: a nil in EITHER (not yet computed, or insufficient CGM
    /// history to trust the fraction) means NOT allowed — an insulin-adding feature never engages
    /// without evidence the user is not hypo-prone. Thresholds are strict (<), so a user exactly at
    /// either limit is blocked. (2026-07-08, AAPS 9110ef2520 + 8b492a08e7.)
    static func allowedByTbr(
        tbr63Pct: Double?,
        tbr70Pct: Double?,
        max63: Double = maxTbr63Pct,
        max70: Double = maxTbr70Pct
    ) -> Bool {
        guard let t63 = tbr63Pct, let t70 = tbr70Pct else { return false }
        return t63 < max63 && t70 < max70
    }

    /// Minimum trailing-14d CGM readings before the TBR fractions are trusted (~3.5 days of 5-min
    /// CGM). Below this the gate fails closed. (AAPS `TBR_GATE_MIN_READINGS` = 1000.)
    static let gateMinReadings = 1000

    /// The complete fail-closed hypo-gate decision from trailing-14d glucose values (mg/dL, already
    /// sanity-filtered by the caller). Fewer than `minReadings` readings → NOT allowed (thin history
    /// can't be trusted for an insulin-adding feature); otherwise computes TBR<63 / TBR<70 over the
    /// SAME window and applies `allowedByTbr`. The host (`BoostComposedFloorGate`) wraps this in a
    /// throttled, thread-safe cache; keeping the decision here puts the safety branches under test.
    static func allowedFromGlucose(valuesMgdl: [Int], minReadings: Int = gateMinReadings) -> Bool {
        let n = valuesMgdl.count
        guard n >= minReadings else { return false }
        let tbr63 = 100.0 * Double(valuesMgdl.filter { $0 < 63 }.count) / Double(n)
        let tbr70 = 100.0 * Double(valuesMgdl.filter { $0 < 70 }.count) / Double(n)
        return allowedByTbr(tbr63Pct: tbr63, tbr70Pct: tbr70)
    }

    /// The composed Phase-3 floor's target dose (U) for this cycle — the single source of truth for
    /// BOTH the shadow field (toggle OFF: `wouldAdd = max(0, target − actualFinalDose)`) and the
    /// delivered floor (toggle ON: `finalDose = max(pipeline, clamped-and-rounded target)`), so the
    /// two can never diverge.
    ///
    /// Returns:
    ///  - **nil** when the floor conditions are unmet. Conditions (ALL required): meal session
    ///    (CONFIRMED/COMMITTED/RECOVERING) ∧ bg > 160 ∧ eventualBg > targetBg + 20 ∧ !asleep ∧
    ///    !postRescueWindow ∧ budget > 0. The budget > 0 condition makes the Episode-A guard hold
    ///    BY CONSTRUCTION: a zero budget can never produce a floored dose.
    ///  - **0.0** when a Phase-3 HARD gate fired (enableSMB pre-checks, minGuardBG, maxDelta): those
    ///    zero the dose regardless of any multiplier floor, so the floor may add nothing.
    ///  - Otherwise the bounded floored dose = min(budget × F, committedCapU) — one routine hold is
    ///    the ceiling — additionally bounded at `v1WouldDoseU` in RECOVERING, a NON-meal state at
    ///    the override seam (capped at V1's would-dose since the 2026-07-04 non-meal-state cap).
    static func targetDose(
        state: MealHypothesis,
        bg: Double,
        eventualBg: Double,
        targetBg: Double,
        asleep: Bool,
        postRescueWindow: Bool,
        budgetU: Double,
        committedCapU: Double,
        v1WouldDoseU: Double?,
        hardGateFired: Bool
    ) -> Double? {
        let mealSession = state == .confirmed || state == .committed || state == .recovering
        let conditionsMet = mealSession &&
            bg > minBgMgdl &&
            eventualBg > targetBg + minEventualOffsetMgdl &&
            !asleep &&
            !postRescueWindow &&
            budgetU > 0.0
        if !conditionsMet { return nil }
        // Hard gates (enableSMB pre-checks, minGuardBG, maxDelta) zero the dose regardless of any
        // multiplier floor — the floored pipeline would deliver 0 too, so the floor adds nothing.
        if hardGateFired { return 0.0 }
        let flooredDose = min(budgetU * fraction, committedCapU)
        // RECOVERING: v1-bound where applicable (non-meal-state cap at the override seam).
        if state == .recovering, let v1 = v1WouldDoseU {
            return min(flooredDose, v1)
        }
        return flooredDose
    }
}
