import Foundation

enum BoostV5Adapter {
    private static func dbl(_ d: Decimal?) -> Double? { d.map { ($0 as NSDecimalNumber).doubleValue } }

    /// Minimum sgv over the last 60 min (mg/dL); high default when no recent data (≈ no recent low).
    private static func recentLowBg(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = glucose.filter { $0.dateString >= cutoff }.compactMap(\.sgv)
        return Double(recent.min() ?? 120)
    }

    /// Minimum sgv over the last 45 min (mg/dL) — the post-rescue-window source value
    /// (2026-07-04, AAPS c306241a35). Defaults to 999 when no recent data, matching AAPS
    /// `recentLowBG45Min` (no data ⇒ no recent low ⇒ no post-rescue window).
    static func recentLowBg45Min(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-45 * 60)
        let recent = glucose.filter { $0.dateString >= cutoff }.compactMap(\.sgv)
        return Double(recent.min() ?? 999)
    }

    /// Run the V5 engine for this cycle against the stock determination + glucose status.
    /// Returns the decision; the caller decides whether to act on it (mode-gated).
    /// ML `direction_num` feature, EXACTLY matching AAPS DetermineBasalBoost (bucketing of
    /// `shortAvgDelta` at ±5/±10/±15 mg/dL per 5-min — the training-time NS-arrow encoding).
    private static func directionNum(shortAvgDelta: Double) -> Double {
        switch shortAvgDelta {
        case let d where d > 15: return 2.0
        case let d where d > 10: return 1.5
        case let d where d > 5: return 1.0
        case let d where d > -5: return 0.0
        case let d where d > -10: return -1.0
        case let d where d > -15: return -1.5
        default: return -2.0
        }
    }

    /// Short-horizon (first 6 prediction points ≈ 30 min) min across the IOB/COB/UAM/ZT series,
    /// matching AAPS `shortHorizonMinGuard`. The full-horizon `minGuardBG` over-fires the
    /// min_guard_bg hard gate (~50% of cycles in AAPS testing). Returns nil if no predictions.
    private static func shortHorizonMinGuard(_ predictions: Predictions?) -> Double? {
        guard let predictions else { return nil }
        let series = [predictions.iob, predictions.cob, predictions.uam, predictions.zt]
        let firstSix = series.compactMap { $0 }.flatMap { $0.prefix(6) }
        guard let minValue = firstSix.min() else { return nil }
        return Double(minValue)
    }

    /// User-tunable V5 knobs (from Preferences). Ranges match AAPS.
    struct V5Knobs {
        var aggression: Double = 1.0
        var hypoCaution: Double = 1.0
        var sensitivity: Double = 1.0
        var confirmedCapU: Double = 2.5 // fallback; host normally passes preferences.boostV5ConfirmedCapU
        var committedCapU: Double = 0.5 // fallback; host normally passes preferences.boostV5CommittedCapU
        var fastCarbConfirm: Bool = true
        // 2026-07 composed brake-floor toggle (boostV5ComposedFloorActive). Per-user activation,
        // default OFF — see ComposedFloor. Only takes effect when mode == .active (V6 the doser).
        var composedFloorActive: Bool = false
        /// 2026-07-17 aggressive early confirm (boostV5AggressiveEarlyConfirm). Opt-in, default OFF.
        var aggressiveEarlyConfirm: Bool = false
        /// 2026-07-17 velocity-budget floor (boostV5VelocityBudgetActive). Opt-in, default OFF; only
        /// takes effect when mode == .active, under the same fail-closed 14-day TBR gate as the
        /// composed floor.
        var velocityBudgetActive: Bool = false
        /// 2026-07-20 early-primer ceiling (boostV5PrimerCapU), in units. 0 turns the primer off.
        var primerCapU: Double = 0
        /// Delivery routing: true routes through a retractable temp basal. The host resolves the
        /// recommended fallback against the user's bolus override before passing it.
        var primerUseTempBasal: Bool = true
        /// The configured night window in minutes of the day, read whatever the night-mode toggle
        /// says (AAPS a33752c9aa #8: the meal-time learner records no session inside it). Defaults
        /// are AAPS's 22:00 to 07:00; the host passes `nightWindowMinutes(preferences)`.
        var nightStartMinute: Int = 1320
        var nightEndMinute: Int = 420
    }

    static func run(
        determination: Determination,
        glucoseStatus: GlucoseStatus,
        glucose: [BloodGlucose],
        iobData _: [IobResult],
        maxIob: Double,
        roundSmbTo: Double,
        microBolusAllowed: Bool,
        mode: BoostMode,
        knobs: V5Knobs,
        clock: Date,
        // Cumulative SMB volume in the last 60 min and minutes since the last SMB — v12 ML
        // features (AAPS recentSmbVolume60Min / timeSinceLastSmbMin). Defaults match AAPS
        // (0 U / 720 min) for the legacy 8-feature model where they are unused.
        recentSmbUnits60m _: Double = 0.0,
        timeSinceLastSmbMin _: Double = 720.0,
        // 2026-10-05 announced meal (AAPS 82f47416c5): a manual or external bolus within
        // mealAnnouncedBolusWindowMs. Carbs on board are read from the determination below.
        manualBolusWithinWindow: Bool = false,
        // 2026-10-08 meal-state reset triggers (AAPS 6ab6cf9e3d). The pump's own suspend state, and
        // the identity of the insulin-scaling override in force (nil when it could not be read).
        pumpSuspended: Bool = false,
        profileSwitchKey: String? = nil,
        // What the V1 engine computed this cycle (nil when the determination did not come from it).
        v1: BoostV1Telemetry? = nil,
        store: BoostV5Store = .shared
    ) -> Result {
        let delta = (glucoseStatus.delta as NSDecimalNumber).doubleValue
        let shortAvg = (glucoseStatus.shortAvgDelta as NSDecimalNumber).doubleValue
        let longAvg = (glucoseStatus.longAvgDelta as NSDecimalNumber).doubleValue
        let bg = (glucoseStatus.glucose as NSDecimalNumber).doubleValue
        // AAPS v5MaxDelta (Boost 6.3.0, 3c3a9c8520): the largest of the latest change and the two
        // averages, as V1 measures it, where it used to be abs(delta) alone.
        let maxDelta = max(abs(delta), shortAvg, longAvg)
        let deltaAccl = DynIsf.deltaAccl(delta: delta, shortAvgDelta: shortAvg)

        let eventualBg = determination.eventualBG.map(Double.init) ?? bg
        let targetBg = dbl(determination.current_target) ?? 100
        // Budget base is floored at 0 (AAPS coerceAtLeast(0)); the ML feature stays SIGNED.
        let signedInsulinReq = dbl(determination.insulinReq) ?? 0.0
        let baseInsulinReq = max(0.0, signedInsulinReq)
        let iob = dbl(determination.iob) ?? 0.0
        // 30-min short-horizon min (AAPS shortHorizonMinGuard); fall back to full-horizon, then bg.
        let minGuardBg = shortHorizonMinGuard(determination.predictions)
            ?? dbl(determination.minGuardBG) ?? bg
        let minGuardThreshold = dbl(determination.threshold) ?? 80.0
        let hour = Calendar.current.component(.hour, from: clock)

        // ML scores come from the V1 engine, which ran the models at its dosing section with its own
        // insulinReq and target (AAPS V5 reads rT.mlHypoRisk / rT.mlMealLikely). A cycle on which V1
        // returned before that section has no scores, as in AAPS, and V6 renormalises without them.
        let mlHypoRisk = v1?.mlHypoRisk
        let mlMealLikely = v1?.mlMealLikely
        // Phase-3 postActionRiskCheck is now WIRED (2026-07-02, AAPS 921a56ea27) — see the
        // riskAtProjectedIob closure passed into V5Inputs below.

        // ── HealthKit activity (steps + HR) → V5 exercise modifiers. Snapshot is kept fresh
        // by BoostActivityMonitor; flags() guards on staleness. Inert until Health read is granted. ──
        let activity = BoostActivityStore.shared.flags(now: clock)

        // V6's own target, IOB ceiling, hypo threshold and recent low are V1's inputs (AAPS opb.target_bg,
        // min(opb.boost_maxIOB, opb.max_iob), opb.lgsThreshold ?: 80, opb.recentLowBG), not V1's
        // adjusted outputs.
        let v6TargetBg = v1?.inputTargetBg ?? targetBg
        let v6MaxIob = v1?.v6MaxIob ?? maxIob
        let v6Threshold = v1.map { $0.lgsThreshold ?? 80.0 } ?? minGuardThreshold
        let v6RecentLow = v1?.recentLowBg ?? recentLowBg(glucose, now: clock)

        // Time-jump / long-gap reset: minutes since the last decide(). A normal ~5-min cycle is
        // <30 (no reset); a clock jump, timezone change, long loop/pump gap, or app restart (state
        // persisted in UserDefaults) yields a large value → MealHypothesis.resetIfNeeded clears the
        // hypothesis (TIME_JUMP_RESET_MINUTES = 30). Since 2026-10-08 decide() also derives the same
        // reset from the state's own wall-clock anchor (AAPS c237a4d081).
        //
        // The other reset triggers (AAPS 6ab6cf9e3d, audit item 17) are wired from what Trio holds.
        // Every reset sends the meal state to IDLE and keeps the single-confirm lock, so a trigger can
        // only remove meal-state dosing, never add it.
        //  - pumpDisconnected: the pump's suspend state, as the latest suspend or resume event in
        //    pump history records it (AAPS reads RM.Mode.isPumpSuspended).
        //  - profileSwitched: the insulin-scaling override in force differs from the one seen on the
        //    previous cycle. A Trio override with an insulin percentage is the analogue of an AAPS
        //    percentage profile switch. Boost's own activity percentage is applied inside the
        //    determination and creates no override, so it does not trigger this. The first cycle
        //    after a restart only records the key, since the staleness reset covers a restart.
        //  - loopSuspended: false. Trio has no timed loop suspension of the kind AAPS's suspended
        //    running modes represent; a loop that stops running is caught by the staleness reset.
        let nowMs = clock.timeIntervalSince1970 * 1000.0
        let cob = dbl(determination.cob) ?? 0.0
        let mealAnnounced = cob > 0 || manualBolusWithinWindow
        // Atomic load→decide→save under one lock: timeJumpMinutes, the state passed to decide(), and
        // the state written back must all come from the SAME locked snapshot. Otherwise a scheduled
        // loop overlapping a post-bolus determineBasalSync can lose an update (last-writer-wins) —
        // e.g. erase a CONFIRMED hypothesis so the next cycle re-fires its SMB for the same meal.
        var profileSwitched = false
        let decision = store.mutateState { state -> V5Decision in
            let timeJumpMinutes = state.lastRunMs.map { abs((nowMs - $0) / 60000.0) } ?? 0.0
            // Read and updated inside the store's lock, so overlapping cycles see one sequence.
            if let key = profileSwitchKey {
                profileSwitched = lastProfileSwitchKey.map { $0 != key } ?? false
                lastProfileSwitchKey = key
            }

            let inputs = V5Inputs(
                delta: delta,
                shortAvgDelta: shortAvg,
                deltaAccl: deltaAccl,
                bg: bg,
                eventualBg: eventualBg,
                targetBg: v6TargetBg,
                maxDelta: maxDelta,
                minGuardBg: minGuardBg,
                minGuardThreshold: v6Threshold,
                deltaHistory: [longAvg, shortAvg, delta],
                iob: iob,
                maxIob: v6MaxIob,
                baseInsulinReq: baseInsulinReq,
                roundSmbTo: roundSmbTo,
                // AAPS: enableSmbPreChecks = activeMode ? microBolusAllowed : true. In shadow it stays
                // permissive so the logged would-be dose isn't hard-gated to 0 (active dosing unaffected).
                enableSmbPreChecks: mode == .active ? microBolusAllowed : true,
                mlHypoRisk: mlHypoRisk, // bundled LightGBM; nil → score renormalize path
                mlMealLikely: mlMealLikely, // bundled LightGBM; nil → score renormalize path
                // Phase-3 postActionRiskCheck (2026-07-02, AAPS 921a56ea27): re-score the hypo model at
                // the projected post-SMB IOB using this cycle's cached feature vector. In ACTIVE mode V5
                // replaces the SMB AFTER V1's post-SMB damper ran, so without this the delivered dose had
                // neither damper. Honest scope: with the shipped v12 model the IOB→risk response is
                // flat-to-inverted, so this is expected to ~never fire (projected ≤ current → pass-through,
                // identical to the old nil). nil/unavailable → current risk (gate passes through).
                riskAtProjectedIob: { projIob in
                    BoostMLModels.hypoRiskAtProjectedIob(projIob) ?? (mlHypoRisk ?? 0.0)
                },
                recentLowBg: v6RecentLow,
                cumulativeRise30min: max(0.0, shortAvg * 6.0),
                hour: hour,
                // 2026-07-07 (AAPS 2a9d096d8b F2): exercise inputs are now wired LIVE from the V1
                // activity classifier — these were dead on the AAPS live path since the V6 plugin
                // split, so V6's meal-score exercise damping (MealSignalScore.notExercisingTerm),
                // the fastConfirm !exercising gate (MealHypothesisEngine.step), and the
                // AggressionBudget post-exercise damper had never engaged. Trio's ActivityClassifier
                // already derives these (surfaced via BoostActivityStore.flags), matching V3MLG3's
                // state mapping. `asleep` was already live (sleepState == SLEEPING).
                exerciseActive: activity.exerciseActive,
                inPostExerciseWindow: activity.inPostExerciseWindow,
                asleep: activity.asleep,
                // fastCarbConfirmEnabled must appear before postRescueWindow to match the V5Inputs
                // initializer's parameter order.
                fastCarbConfirmEnabled: knobs.fastCarbConfirm,
                // 2026-07-17 aggressive early confirm. Timing only, so it needs no mode gate here:
                // the whole engine result is discarded in shadow mode.
                // Also held off by the 14-day time-below-range gate the composed floor uses (AAPS 2221fcb96c).
                aggressiveEarlyConfirmEnabled: knobs.aggressiveEarlyConfirm && BoostComposedFloorGate.allowed,
                // 2026-07-06/07 composed brake-floor inputs (AAPS e0f18ddd0e + 730b3dcb2c). Computed
                // here from the SAME sources the override seam uses: post-rescue = rolling 45-min CGM
                // low < 75 (SafetyGateConstants.postRescueLowThresholdMgdl); v1WouldDose = the base
                // determination's would-dose SMB (bounds the RECOVERING floor). The toggle only bites
                // when V6 is the active doser.
                postRescueWindow: Self.recentLowBg45Min(glucose, now: clock)
                    < SafetyGateConstants.postRescueLowThresholdMgdl,
                v1WouldDoseU: determination.units.map { ($0 as NSDecimalNumber).doubleValue },
                // 2026-07-08 (AAPS 9110ef2520 + 8b492a08e7): the toggle is additionally gated on the
                // ENFORCED per-user hypo-gate — trailing-14d TBR<63 < 2.0% AND TBR<70 < 3.5%,
                // fail-closed (BoostComposedFloorGate, refreshed hourly by APSManager). The floor is
                // insulin-adding, so it cannot engage for a hypo-prone user even if toggled on.
                composedFloorActive: mode == .active && knobs.composedFloorActive
                    && BoostComposedFloorGate.allowed,
                // 2026-07-17 velocity-budget floor. Insulin-adding like the composed floor, so it
                // sits behind the same fail-closed per-user hypo gate and the same active-mode
                // requirement. A hypo-prone user cannot reach it even with the toggle on.
                velocityBudgetActive: mode == .active && knobs.velocityBudgetActive
                    && BoostComposedFloorGate.allowed,
                // 2026-07-20 early primer. Live only when V6 is the doser; in shadow the whole
                // engine result is discarded, so no gate is needed beyond the mode.
                primerCapU: mode == .active ? knobs.primerCapU : 0,
                primerUseTempBasal: knobs.primerUseTempBasal,
                nowMs: clock.timeIntervalSince1970 * 1000.0,
                profileSwitched: profileSwitched,
                pumpDisconnected: pumpSuspended,
                loopSuspended: false,
                timeJumpMinutes: timeJumpMinutes,
                aggressionUserKnob: knobs.aggression,
                hypoCautionUserKnob: knobs.hypoCaution,
                sensitivityUserKnob: knobs.sensitivity,
                confirmedCapU: knobs.confirmedCapU,
                committedCapU: knobs.committedCapU,
                mealAnnounced: mealAnnounced
            )

            let decision = BoostV5Engine.decide(inputs, persisted: state)
            state = decision.newPersistedState
            state.lastRunMs = nowMs
            return decision
        }
        // V6 learning: record the start of a meal session (meal-time history → pre-meal target).
        // Since 2026-10-05 (AAPS 82f47416c5) this keys on the session start, which is the fresh
        // CONFIRMED for an unannounced meal and the direct COMMITTED for an announced one. A
        // COMMITTED re-engaged inside a held session lock is not a new meal and is not recorded.
        if decision.mealSessionStarted {
            recordMealSessionIfRecordable(knobs: knobs, clock: clock)
        }
        var reason = reasonTag(
            decision,
            mode: mode,
            mlHypoRisk: mlHypoRisk,
            mlMealLikely: mlMealLikely,
            activity: activity
        )
        // Announced-meal telemetry, in the reason string as AAPS carries it.
        if mealAnnounced { reason += " mealAnn=1,\(decision.mealSessionStarted ? "commit" : "-");" }
        if decision.stateReset, pumpSuspended || profileSwitched {
            reason += " v6reset[" + [pumpSuspended ? "pump" : nil, profileSwitched ? "profile" : nil]
                .compactMap { $0 }.joined(separator: ",") + "];"
        }
        return Result(decision: decision, reason: reason)
    }

    /// Records a meal session for the meal-time learner only when it starts outside the configured
    /// night window with the detector AWAKE (AAPS a33752c9aa #8). Overnight sessions in the AAPS
    /// field record were rises with no logged carbs, mostly while the detector read SLEEPING or
    /// PRE_SLEEP, and enough of them move the lowered pre-meal target into the night.
    static func recordMealSessionIfRecordable(knobs: V5Knobs, clock: Date) {
        let inWindow = BoostGate.inNightWindow(
            nowMinuteOfDay: minuteOfDay(clock),
            startMinute: knobs.nightStartMinute,
            endMinute: knobs.nightEndMinute
        )
        let sleepState = BoostActivityStore.shared.sleep(now: clock).state
        guard MealTimeLearner.sessionRecordable(inNightWindow: inWindow, sleepState: sleepState) else {
            debug(
                .algorithm,
                "V6 meal-time learner: session not recorded (night window=\(inWindow), sleep=\(sleepState.rawValue))"
            )
            return
        }
        BoostMealTimeStore.shared.recordConfirmed(at: clock)
    }

    /// The insulin-scaling override key seen on the previous cycle; nil before the first. In memory
    /// only, as AAPS keeps it, and touched only inside `BoostV5Store.mutateState`, whose lock
    /// serialises it.
    private static var lastProfileSwitchKey: String?

    /// Identity of the insulin-scaling override in force, the Trio analogue of an AAPS profile switch.
    /// "none" when no override scales insulin. An override that changes only the target is a temp
    /// target in AAPS terms and does not count.
    static func profileSwitchKey(_ v: TrioCustomOrefVariables) -> String {
        guard v.useOverride, v.overridePercentage != 100 else { return "none" }
        return "\(v.overridePercentage)|\(v.isfAndCr)|\(v.isf)|\(v.cr)"
    }

    /// True when the latest pump suspend or resume event at or before `clock` is a suspend.
    static func pumpSuspended(_ history: [PumpHistoryEvent], clock: Date) -> Bool {
        history
            .filter { ($0.type == .pumpSuspend || $0.type == .pumpResume) && $0.timestamp <= clock }
            .max { $0.timestamp < $1.timestamp }?
            .type == .pumpSuspend
    }

    /// True when a manual or external bolus of positive size lies within the announced-meal window
    /// (AAPS 82f47416c5: BS.Type.NORMAL, which excludes SMBs and priming). Trio records a manual or
    /// wizard bolus as a non-SMB bolus and a pen dose as external insulin; both count, since AAPS
    /// logs a pen dose as a normal bolus too.
    static func manualBolusWithinWindow(_ history: [PumpHistoryEvent], clock: Date) -> Bool {
        let windowStart = clock.addingTimeInterval(-MealHypothesisConstants.mealAnnouncedBolusWindowMs / 1000)
        return history.contains { e in
            guard e.timestamp >= windowStart, e.timestamp <= clock, (e.amount ?? 0) > 0 else { return false }
            switch e.type {
            case .bolus: return e.isSMB != true
            case .isExternal: return true
            default: return false
            }
        }
    }

    /// What the harness consumes: the engine decision plus the telemetry string to append.
    struct Result {
        let decision: V5Decision
        let reason: String
    }

    /// Night-mode evaluation: suppresses SMB overnight (AAPS night mode). Uses the
    /// determination's bg/cob + the monitor's asleep flag + the user's config.
    ///
    /// AAPS `isNightModeActiveImpl` compares against the BASE profile target
    /// (`profile.getTargetMgdl()`) for both the low-TT disable gate and the final
    /// bg-vs-target gate — not the TT-adjusted target. `baseProfileTargetMgdl` is that
    /// base target; `activeTempTargetMgdl` is the active temp-target value (clamped to
    /// AAPS `LIMIT_TEMP_TARGET_BG` = 72–200 mg/dL) or nil when no TT is active.
    /// Returns whether to suppress and a short reason tag.
    static func nightMode(
        determination: Determination,
        preferences: Preferences,
        baseProfileTargetMgdl: Double,
        activeTempTargetMgdl: Double?,
        sleepInActive: Bool = false,
        clock: Date
    ) -> (suppress: Bool, reason: String) {
        guard preferences.boostNightModeEnabled else { return (false, "") }
        // AAPS night-mode sleepActive = autoBySleep && sleepState != AWAKE, so PRE_SLEEP also
        // enables/extends night mode (the proactive pre-warm). This is distinct from the V5
        // dose-suppression gate, which uses == SLEEPING. Stale snapshot (>30 min) → not active.
        let sleepActive = BoostActivityStore.shared.snapshot
            .map { clock.timeIntervalSince($0.updatedAt) <= 1800 && ($0.sleepState?.state ?? .awake) != .awake } ?? false
        let config = NightModeConfig(
            enabled: true,
            startMinute: Int((dbl(preferences.boostNightModeStartHour) ?? 22) * 60),
            endMinute: Int((dbl(preferences.boostNightModeEndHour) ?? 7) * 60),
            bgOffsetMgdl: dbl(preferences.boostNightModeBgOffset) ?? 27,
            disableWithCob: preferences.boostNightModeDisableWithCob,
            disableWithLowTt: preferences.boostNightModeDisableWithLowTt,
            autoBySleep: preferences.boostNightModeAutoBySleep
        )
        let nowMin = Calendar.current.component(.hour, from: clock) * 60
            + Calendar.current.component(.minute, from: clock)
        let result = NightMode.evaluate(NightModeInputs(
            nowMinuteOfDay: nowMin,
            bg: dbl(determination.bg) ?? 0,
            profileTargetMgdl: baseProfileTargetMgdl,
            cob: dbl(determination.cob) ?? 0,
            activeTempTargetMgdl: activeTempTargetMgdl,
            sleepActive: sleepActive,
            sleepInActive: sleepInActive,
            config: config
        ))
        return (result.suppressSmb, result.reason)
    }

    /// Minute-of-day membership of `[start, end)` on a 24-hour clock, wrapping midnight when
    /// `end < start`. `start == end` is an EMPTY window (2026-07-02, AAPS 8ecaf7bbd9) — sleep
    /// detection then governs the night. Mirrors `NightMode.minuteInWindow`.
    static func minuteInWrapped(_ now: Int, _ start: Int, _ end: Int) -> Bool {
        if start == end { return false }
        if end > start { return now >= start && now < end }
        return now >= start || now < end
    }

    /// Local minute-of-day [0, 1440) for `clock`.
    private static func minuteOfDay(_ clock: Date) -> Int {
        Calendar.current.component(.hour, from: clock) * 60 + Calendar.current.component(.minute, from: clock)
    }

    /// Pre-BG-gate "user is in their night/sleep period" — the night time window OR HR/step sleep
    /// detection, gated by the night-mode master toggle. This is the sleep-aware signal that gates the
    /// Boost active override (`boostActive = !this`). It deliberately EXCLUDES the BG / COB / low-TT
    /// gates that `nightMode()` layers on: those must NOT influence the Boost gate, or a nocturnal high
    /// would flip Boost back on and re-fire a V6 dose while asleep. Sleep state is staleness-guarded
    /// (≤30 min) exactly as `nightMode()`'s sleepActive is. (2026-07-02, mirrors AAPS c94c5c72d6.)
    static func isInNightSleepPeriod(preferences: Preferences, clock: Date) -> Bool {
        nightSleepPeriod(
            preferences: preferences,
            minuteOfDay: minuteOfDay(clock),
            sleepState: BoostActivityStore.shared.sleep(now: clock).state
        )
    }

    /// `isInNightSleepPeriod` on explicit inputs, so the activity monitor can evaluate it against
    /// this refresh's sleep state rather than the stored snapshot.
    static func nightSleepPeriod(preferences: Preferences, minuteOfDay: Int, sleepState: SleepState) -> Bool {
        guard preferences.boostNightModeEnabled else { return false }
        let (start, end) = nightWindowMinutes(preferences)
        let inWindow = minuteInWrapped(minuteOfDay, start, end)
        let sleepActive = preferences.boostNightModeAutoBySleep && sleepState != .awake
        return inWindow || sleepActive
    }

    /// The configured night window in minutes of the day, defaulting to 22:00 to 07:00 as AAPS does.
    static func nightWindowMinutes(_ preferences: Preferences) -> (start: Int, end: Int) {
        (
            Int((dbl(preferences.boostNightModeStartHour) ?? 22) * 60),
            Int((dbl(preferences.boostNightModeEndHour) ?? 7) * 60)
        )
    }

    /// Hold applied after a boundary exit: the detector's sleep hysteresis (10 min, as the monitor
    /// configures it) plus one cycle.
    static let sleepBoundaryHoldMin = BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10)

    /// The Boost gate before the lie-in check (AAPS 47a815aedf `boostGateOpen`, with the a33752c9aa
    /// #18 boundary-exit hold). Closed inside the configured night window whatever the night-mode
    /// toggle says, inside the toggle-governed night/sleep period, and while the detector reads
    /// SLEEPING with V6 the doser. Trio has no V1 tier engine, so a closed gate leaves the base oref
    /// SMB, which is what AAPS reaches with Tier 8 alone.
    static func boostGateOpen(preferences: Preferences, clock: Date) -> Bool {
        let sleep = BoostActivityStore.shared.sleep(now: clock)
        let minute = minuteOfDay(clock)
        let (start, end) = nightWindowMinutes(preferences)
        let signals = BoostGate.sleepSignals(
            state: sleep.state,
            nightSleepPeriodRaw: nightSleepPeriod(preferences: preferences, minuteOfDay: minute, sleepState: sleep.state),
            nightModeEnabled: preferences.boostNightModeEnabled,
            autoBySleep: preferences.boostNightModeAutoBySleep,
            nowMs: clock.timeIntervalSince1970 * 1000.0,
            lastBoundaryExitMs: sleep.lastBoundaryExitMs,
            holdMin: sleepBoundaryHoldMin
        )
        return BoostGate.isOpen(
            nightSleepPeriod: signals.nightSleepPeriod,
            inNightWindow: BoostGate.inNightWindow(nowMinuteOfDay: minute, startMinute: start, endMinute: end),
            v6Active: preferences.boostMode == .active,
            detectorSleeping: signals.detectorSleeping
        )
    }

    /// Steps-based sleep-in (lie-in) — the FALSE-AWAKE backstop. In the first `boostSleepInHours` after
    /// night end, 60-min steps below `boostSleepInSteps` ⇒ still lying in even if the HR sleep-state
    /// machine wrongly reported AWAKE; keeps Boost suppressed and (via `nightMode`) applies night-mode
    /// SMB rules. Requires a FRESH snapshot (≤30 min): without live step data we can't confirm a lie-in,
    /// and the HR sleep gate already covers the still-asleep case — so we don't assert one on stale
    /// data. (2026-07-02, mirrors AAPS c94c5c72d6; Trio reads steps from the async snapshot.)
    ///
    /// Boost 6.3.0 (AAPS 290348d59a): the window starts at the detector's effective night end, the
    /// learned one when it is later than configured, and a wake the detector confirmed on steps or HR
    /// plus steps since 90 min before that end stands the failsafe down.
    static func sleepInActive(preferences: Preferences, clock: Date) -> Bool {
        let sleepInMinutes = Int((dbl(preferences.boostSleepInHours) ?? 2.0) * 60)
        guard sleepInMinutes > 0 else { return false }
        guard let snap = BoostActivityStore.shared.snapshot, clock.timeIntervalSince(snap.updatedAt) <= 1800,
              let steps60 = snap.steps60min else { return false }
        let nightEnd = snap.effectiveNightEndMin ?? Int((dbl(preferences.boostNightModeEndHour) ?? 7) * 60)
        let windowEnd = (nightEnd + sleepInMinutes) % 1440
        let now = minuteOfDay(clock)
        guard minuteInWrapped(now, nightEnd, windowEnd) else { return false }
        // Minutes since (nightEnd - 90), on the clock; the wake counts if it is no older than that.
        let sinceGraceStartMin = (now - nightEnd + SleepStateConstants.sleepScheduleToleranceMin + 1440) % 1440
        let genuineWakeThisMorning = BoostActivityStore.lastGenuineWakeMs >=
            clock.timeIntervalSince1970 * 1000 - Double(sinceGraceStartMin) * 60000
        return steps60 < (dbl(preferences.boostSleepInSteps) ?? 250) && !genuineWakeThisMorning
    }

    /// Compact telemetry string appended to the determination reason (shadow + active).
    static func reasonTag(
        _ d: V5Decision,
        mode: BoostMode,
        mlHypoRisk: Double?,
        mlMealLikely: Double?,
        activity: (exerciseActive: Bool, inPostExerciseWindow: Bool, asleep: Bool)
    ) -> String {
        let st = d.mealHypothesis.rawValue
        let smb = String(format: "%.2f", d.finalDose)
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        let ml = " ml(hypo=\(fmt(mlHypoRisk)) meal=\(fmt(mlMealLikely)))"
        var ctx = ""
        if activity.exerciseActive { ctx += " exercise" }
        else if activity.inPostExerciseWindow { ctx += " postEx" }
        if activity.asleep { ctx += " asleep" }
        return "boostV5[\(mode.rawValue)]: state=\(st) score=\(String(format: "%.2f", d.score)) wouldSMB=\(smb)U;\(ml)\(ctx)"
    }
}
