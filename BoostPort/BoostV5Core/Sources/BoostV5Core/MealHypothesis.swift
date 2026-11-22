import Foundation

public enum MealHypothesis: String, Codable, Equatable, Sendable {
    case idle = "IDLE"
    case observing = "OBSERVING"
    case confirmed = "CONFIRMED"
    case committed = "COMMITTED"
    case recovering = "RECOVERING"
}

public struct MealHypothesisState: Codable, Equatable, Sendable {
    public var state: MealHypothesis
    public var ageCycles: Int
    public var maxScoreInObserving: Double
    public var maxEventualBgOffsetInObserving: Double
    public var committedInSession: Bool
    /// Epoch-ms anchor for the wall-clock age tick (AAPS 0b1587f6b6). The ages are cycle counts
    /// with thresholds tuned on a five-minute loop, so at a one-minute sensor cadence the loop runs
    /// five times as often and the same counts elapse five times sooner. Measured on live data, the
    /// time from entering OBSERVING to age 2 is 10.0 min (p10 9.7 to 10.0) for every five-minute
    /// user and 2.0 min for the one-minute user. Anchoring the advance on wall clock makes the
    /// thresholds mean the same thing at any cadence. 0 means never stamped.
    ///
    /// Last in the parameter list on purpose: existing call sites construct this positionally, and
    /// inserting a field mid-list would silently rebind their arguments.
    public var lastAgeMs: Double
    /// Epoch-ms of the last cycle spent in CONFIRMED or COMMITTED, 0 meaning none or a state written
    /// before the field existed (AAPS c237a4d081). Starts the `sessionLockMinMs` clock on the session
    /// lock, which since 8 October 2026 survives the RECOVERING to IDLE exit.
    public var lastCommitMs: Double
    /// Epoch-ms at which the current unbroken run of non-positive deltas began, 0 meaning no run.
    public var nonPositiveRunStartMs: Double
    /// Epoch-ms at which `maxScoreInObserving` was set. Peaks older than `confirmPeakWindowMs` expire.
    public var maxScoreAtMs: Double
    /// Epoch-ms at which `maxEventualBgOffsetInObserving` was set, with the same expiry.
    public var maxOffsetAtMs: Double

    public init(
        state: MealHypothesis = .idle,
        ageCycles: Int = 0,
        maxScoreInObserving: Double = 0.0,
        maxEventualBgOffsetInObserving: Double = 0.0,
        committedInSession: Bool = false,
        lastAgeMs: Double = 0,
        lastCommitMs: Double = 0,
        nonPositiveRunStartMs: Double = 0,
        maxScoreAtMs: Double = 0,
        maxOffsetAtMs: Double = 0
    ) {
        self.state = state
        self.ageCycles = ageCycles
        self.maxScoreInObserving = maxScoreInObserving
        self.maxEventualBgOffsetInObserving = maxEventualBgOffsetInObserving
        self.committedInSession = committedInSession
        self.lastAgeMs = lastAgeMs
        self.lastCommitMs = lastCommitMs
        self.nonPositiveRunStartMs = nonPositiveRunStartMs
        self.maxScoreAtMs = maxScoreAtMs
        self.maxOffsetAtMs = maxOffsetAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case ageCycles
        case maxScoreInObserving
        case maxEventualBgOffsetInObserving
        case committedInSession
        case lastAgeMs
        case lastCommitMs
        case nonPositiveRunStartMs
        case maxScoreAtMs
        case maxOffsetAtMs
    }

    /// Fields added after the first release decode as 0 when absent, as AAPS V5StateStore reads them
    /// with `optLong(..., 0L)`. Without this a state saved by an earlier build would fail to decode
    /// and BoostV5Store would discard it, losing the session lock it carries. A zero lock clock starts
    /// on the next cycle and zero peak times re-seed from the current values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(MealHypothesis.self, forKey: .state)
        ageCycles = try c.decode(Int.self, forKey: .ageCycles)
        maxScoreInObserving = try c.decode(Double.self, forKey: .maxScoreInObserving)
        maxEventualBgOffsetInObserving = try c.decode(Double.self, forKey: .maxEventualBgOffsetInObserving)
        committedInSession = try c.decodeIfPresent(Bool.self, forKey: .committedInSession) ?? false
        lastAgeMs = try c.decodeIfPresent(Double.self, forKey: .lastAgeMs) ?? 0
        lastCommitMs = try c.decodeIfPresent(Double.self, forKey: .lastCommitMs) ?? 0
        nonPositiveRunStartMs = try c.decodeIfPresent(Double.self, forKey: .nonPositiveRunStartMs) ?? 0
        maxScoreAtMs = try c.decodeIfPresent(Double.self, forKey: .maxScoreAtMs) ?? 0
        maxOffsetAtMs = try c.decodeIfPresent(Double.self, forKey: .maxOffsetAtMs) ?? 0
    }
}

/// Calibrated transition thresholds (HARDCODED — not user knobs). Mirrors the Kotlin constants 1:1.
public enum MealHypothesisConstants {
    public static let enterObservingScore = 0.44
    public static let confirmScore = 0.55
    public static let confirmEventualBgOffsetMgdl = 30.0
    /// Minimum wall-clock spacing between age increments (AAPS `AGE_TICK_MS`, 2026-07-30).
    ///
    /// Four minutes rather than five, deliberately. Live five-minute users increment about every
    /// 4.85 to 5.0 minutes, so a five-minute tick would intermittently skip an increment and slow
    /// the whole existing cohort from 10 minutes to 15. Four minutes clears their observed p10 with
    /// about 0.85 minutes of margin. The cost is that a one-minute user reaches age 2 at about 8
    /// minutes rather than 10, which is 80% of the target and four times better than the 2.0
    /// minutes measured without it.
    public static let ageTickMs: Double = 4 * 60 * 1000

    public static let confirmMinObservingAge = 2
    /// 2026-07-03 sustained-score early confirm (AAPS 242a6e179d): OBSERVING → CONFIRMED may fire
    /// ONE cycle before `confirmMinObservingAge` when the INSTANTANEOUS score has been ≥
    /// `confirmScore` on BOTH this cycle and the immediately preceding one (`scoreReadyStreak` —
    /// supplied by the caller, same cross-cycle-input pattern as `deltaDeclining`). All other
    /// confirm conditions (peak eventualBG offset ≥ 30, confirmDoseAdequate, !committedInSession)
    /// are unchanged.
    ///
    /// WHY: replay vs the cohort DB (2026-07-03) showed 53% of confirm latency was purely
    /// mechanical — the score was already ≥ confirmScore for ≥2 cycles before the age gate opened.
    /// Shifting the SAME commit-shot 1 cycle earlier measured 0.0pp additional pre-low exposure,
    /// vs +14–17% for added-insulin levers evaluated in the same sweep. The early path requires
    /// the CURRENT score ≥ threshold (not just the tracked max) because the whole point is a
    /// sustained-ready score, not a transient peak.
    public static let confirmMinObservingAgeScoreReady = confirmMinObservingAge - 1

    /// Aggressive early confirm (AAPS 3ea7479572, "confirm sooner"): one cycle earlier again, so a
    /// meal whose score is confirm-strength on two consecutive cycles confirms as soon as it enters
    /// OBSERVING. It still moves the same commit shot rather than adding one, with the same
    /// streak protection, but the pre-push backtest found about 28% of its candidates are
    /// fizzle-catches, meaning episodes that would have fallen back to IDLE, so it delivers new
    /// insulin at roughly the base rate. That is not a clean cohort default, so it is opt-in and
    /// auto-config managed, enabled only for clearly well-controlled users. False keeps the
    /// audit-validated timing above, which was priced at 0.0 percentage points of harm.
    public static let confirmMinObservingAgeScoreReadyAggressive = confirmMinObservingAge - 2
    /// 2026-07-02 dose-adequacy gate: the confirm floor is committedCapU, clamped to at most this
    /// fraction of confirmedCapU so a manual committedCap ≥ confirmedCap can't make the gate
    /// unsatisfiable (which would silently disable V6's meal response). See BoostV5Engine.decide().
    public static let confirmDoseFloorMaxFracOfConfirmedCap = 0.8

    /// 2026-07-06 confirm-floor pin (AAPS 311703ddf5): the committedCapU term of the confirm dose
    /// floor is pinned at the FACTORY default COMMITTED cap (0.5 U — the `boostV5CommittedCapU`
    /// preference default), regardless of the live preference value.
    ///
    /// The floor's job is "the commit-shot must beat one ROUTINE hold". A user-RAISED committedCap
    /// describes a bigger PERMITTED hold, not a bigger routine one — so it must not move the floor.
    /// Without the pin, raising committedCap silently TIGHTENS the confirm gate: the 2026-07-06
    /// backtest on live telemetry showed a 0.5 → 1.0 cap raise would newly block ~18% of confirms
    /// (prospective shots ≤ 1.0 U) — exactly the mid-meal starvation the gate exists to prevent.
    /// A user-LOWERED committedCap still lowers the floor (min semantics preserved — see
    /// `confirmDoseFloorU`).
    public static let confirmFloorCommittedTermMax = 0.5

    /// The OBSERVING→CONFIRMED dose-adequacy floor (U):
    /// `min(min(committedCapU, confirmFloorCommittedTermMax), 0.8 × confirmedCapU)`.
    ///
    /// The committedCap term is pinned at the factory default (`confirmFloorCommittedTermMax`) so
    /// raising the COMMITTED cap can't tighten the confirm gate (2026-07-06 — see the pin doc);
    /// lowering it below the pin still lowers the floor. The confirmedCap clamp
    /// (`confirmDoseFloorMaxFracOfConfirmedCap`, 2026-07-02) keeps the gate satisfiable.
    public static func confirmDoseFloorU(committedCapU: Double, confirmedCapU: Double) -> Double {
        min(
            min(committedCapU, confirmFloorCommittedTermMax),
            confirmDoseFloorMaxFracOfConfirmedCap * confirmedCapU
        )
    }

    public static let fallBackToIdleScore = 0.36
    public static let fallBackToIdleAge = 2
    public static let confirmedToCommittedAge = 0
    public static let recoveringDecelThreshold = -5.0
    public static let recoveringToIdleScore = 0.18
    public static let recoveringReengageAccl = 10.0
    public static let recoveringReengageDelta = 3.0
    public static let recoveringReengageOffsetMgdl = 20.0
    public static let recoveringReengageMinAge = 1
    /// COMMITTED backs off only once the rise is below this (mg/dL per 5 min), so a meal that is
    /// slowing but still climbing keeps its dosing (AAPS Boost 6.3.0, 5600a68cfb).
    public static let recoveringEntryMaxDelta = 3.0
    /// RECOVERING re-engages COMMITTED on a rise above this whatever the acceleration. The gap to
    /// recoveringEntryMaxDelta stops the state flicking between the two (AAPS 5600a68cfb).
    public static let recoveringReengageRiseDelta = 8.0
    // 2026-07-03 retune (AAPS d2f9a08108; replay sweep over the cohort): Δ 8→6, accl 15→10,
    // score 0.60→0.65. This point catches +21 meals ~9 min earlier while REDUCING false fires
    // 39%→32% — the score raise pays for the physics relaxation. A plain physics relaxation
    // WITHOUT the score raise is worse (40% false); the tighter score gate is what makes the
    // looser Δ/accl thresholds safe. All guards (awake, not exercising, recentLowBg ≥ 80,
    // !committedInSession, pref toggle) unchanged.
    public static let fastConfirmDelta = 6.0 // mg/dL per 5 min — sharp rise (2026-07-03: 8.0 → 6.0)
    public static let fastConfirmAccl = 10.0 // delta_accl % — accelerating (2026-07-03: 15.0 → 10.0)
    public static let fastConfirmScore = 0.65 // meal score must corroborate (2026-07-03: 0.60 → 0.65; > enterObserving 0.44)
    /// 2026-07-02 post-hypo rescue-carb guard: the fast-carb fast-path is suppressed when the 60-min
    /// BG low is below this. A rescue-carb rebound routinely satisfies delta≥8 + accl≥15 + score≥0.60,
    /// and the fast path is EXEMPT from the confirmDoseAdequate gate — so it was the only unguarded
    /// CONFIRMED entry within an hour of a hypo. Replay-calibrated (AAPS 1245d33a9a).
    public static let fastConfirmMinRecentLowMgdl = 80.0
    /// Time-jump threshold in minutes for forcing IDLE. Since 8 October 2026 (AAPS c237a4d081) it is
    /// also the staleness bound on the persisted meal state: decide() treats a state whose wall-clock
    /// anchor is more than this far from now as a time jump. Thirty minutes is six missed five-minute
    /// cycles, after which the score and eventualBG evidence a state carries no longer describes the
    /// glucose the loop is about to act on.
    public static let timeJumpResetMinutes = 30.0

    /// Minimum time the single-confirm session lock is held after the last CONFIRMED or COMMITTED
    /// cycle, even once the state machine has fallen back to IDLE (AAPS c237a4d081, audit item 7).
    ///
    /// The lock was cleared on the first RECOVERING to IDLE exit, which fires on a single negative
    /// delta, the trough between two phases of one meal. The fast path then re-confirmed from IDLE
    /// with neither the eventualBG-offset gate nor the dose-adequacy gate. Over the 60 days to 8
    /// October 2026, 772 of 2,569 confirms that followed an earlier commit came within 90 minutes of
    /// it. Ninety minutes is a modelling choice, the time to peak action of rapid-acting analogues.
    public static let sessionLockMinMs: Double = 90 * 60 * 1000
    /// An unbroken run of non-positive deltas this long ends the session early and releases the lock.
    /// The same data put the median longest non-positive run between two close confirms at 15
    /// minutes, so a trough is normally shorter than this and a finished meal normally longer.
    public static let sessionEndNonPositiveMs: Double = 30 * 60 * 1000
    /// The OBSERVING peak score and peak eventualBG offset count towards the confirm test for this
    /// long after they were set (AAPS c237a4d081, audit item 17). Fix 1 and Fix 5 needed a lead of one
    /// or two cycles; thirty minutes keeps that with margin.
    public static let confirmPeakWindowMs: Double = 30 * 60 * 1000
    /// How far back a manual or wizard bolus marks the next confirm as an announced meal (AAPS
    /// 82f47416c5). A modelling choice, not a calibrated value: it covers a pre-bolus given 20 to 30
    /// minutes before eating plus the 30 to 60 minutes a rise takes to reach CONFIRMED.
    public static let mealAnnouncedBolusWindowMs: Double = 120 * 60 * 1000
}

public enum MealHypothesisEngine {
    /// Effective fast-carb fast-path enable for this cycle: the user toggle AND the post-hypo
    /// rescue-carb guard (`fastConfirmMinRecentLowMgdl`). Computed by the caller (`decide()`) and
    /// passed to `step` as `fastConfirmEnabled` — same pattern as `confirmDoseAdequate`. (AAPS 1245d33a9a)
    public static func fastConfirmAllowed(_ fastCarbConfirmEnabled: Bool, recentLowBg: Double) -> Bool {
        fastCarbConfirmEnabled && recentLowBg >= MealHypothesisConstants.fastConfirmMinRecentLowMgdl
    }

    /// Minutes since the state's wall-clock anchor, as an absolute value so that a clock set
    /// backwards counts as a jump as well (AAPS c237a4d081, audit item 17). The anchor is restamped
    /// on every age tick and every state change, so a live loop never reads more than about four
    /// minutes here; a larger value means the loop did not run, or the state was restored from
    /// storage after a gap. 0 when either clock is unknown.
    public static func staleStateMinutes(_ state: MealHypothesisState, nowMs: Double) -> Double {
        if nowMs <= 0 || state.lastAgeMs <= 0 { return 0 }
        return abs(nowMs - state.lastAgeMs) / 60000.0
    }

    /// Running maximum that expires: returns the new (peak, setAtMs). With no clock it is the plain
    /// running maximum, the behaviour before 8 October 2026.
    static func windowedPeak(peak: Double, peakAtMs: Double, value: Double, nowMs: Double) -> (Double, Double) {
        if nowMs <= 0 { return (max(peak, value), peakAtMs) }
        if value >= peak || peakAtMs <= 0 || nowMs - peakAtMs > MealHypothesisConstants.confirmPeakWindowMs {
            return (value, nowMs)
        }
        return (peak, peakAtMs)
    }

    /// The session lock after the release rules (AAPS c237a4d081). In CONFIRMED and COMMITTED the
    /// lock is always held. Elsewhere it is released once `sessionLockMinMs` has passed since the last
    /// CONFIRMED or COMMITTED cycle, or once the deltas have been non-positive without a break for
    /// `sessionEndNonPositiveMs` including this cycle. A lock with no commit time, written by an older
    /// build, has its clock started now. With no clock the state is returned unchanged. Idempotent,
    /// so decide()'s telemetry and `step` can both apply it.
    public static func releaseEndedSessionLock(_ s: MealHypothesisState, nowMs: Double, delta: Double) -> MealHypothesisState {
        if nowMs <= 0 || !s.committedInSession { return s }
        if s.state == .confirmed || s.state == .committed { return s }
        var out = s
        if s.lastCommitMs <= 0 {
            out.lastCommitMs = nowMs
            return out
        }
        let expired = nowMs - s.lastCommitMs >= MealHypothesisConstants.sessionLockMinMs
        // The run counts from the later of its own start and the last commit cycle, so only the part
        // of it after the commit shot can end the session.
        let sustainedFall = delta <= 0 && s.nonPositiveRunStartMs > 0
            && nowMs - max(s.nonPositiveRunStartMs, s.lastCommitMs) >= MealHypothesisConstants.sessionEndNonPositiveMs
        if expired || sustainedFall { out.committedInSession = false }
        return out
    }

    /// OBSERVING falls back to IDLE: total age past the hysteresis and the current score below the bar.
    static func observingFallsBack(_ current: MealHypothesisState, score: Double) -> Bool {
        score < MealHypothesisConstants.fallBackToIdleScore && current.ageCycles >= MealHypothesisConstants.fallBackToIdleAge
    }

    /// OBSERVING → CONFIRMED eligibility EXCLUDING the dose-adequacy gate — the exact
    /// sub-conditions `step`'s OBSERVING branch checks (age gate incl. the 2026-07-03
    /// sustained-score early path, peak score, peak eventualBG offset, single-confirm-per-session
    /// lock), minus `confirmDoseAdequate`. `step` calls this SAME function for its dosing
    /// decision, so any caller-side use (e.g. gate diagnostics) can never diverge from what the
    /// state machine doses with. (AAPS 242a6e179d / 6067ec9a6d.)
    ///
    /// Since 8 October 2026 (AAPS c237a4d081, audit item 17) a score that has fallen to the
    /// fall-back level ends the run before any peak can confirm it, matching the order `step`
    /// applies, and the peaks expire after `confirmPeakWindowMs` when a clock is supplied.
    public static func confirmEligibleExceptDoseGate(
        current: MealHypothesisState,
        score: Double,
        eventualBg: Double,
        targetBg: Double,
        scoreReadyStreak: Bool = false,
        /// Opens the sustained-score path one cycle earlier again. Opt-in and auto-config managed;
        /// see `confirmMinObservingAgeScoreReadyAggressive`.
        aggressiveEarlyConfirm: Bool = false,
        /// Wall clock for the peak expiry. 0 keeps the plain running maximum.
        nowMs: Double = 0
    ) -> Bool {
        let C = MealHypothesisConstants.self
        if current.state != .observing || current.committedInSession { return false }
        if observingFallsBack(current, score: score) { return false }
        let newMaxScore = windowedPeak(
            peak: current.maxScoreInObserving, peakAtMs: current.maxScoreAtMs, value: score, nowMs: nowMs
        ).0
        let newMaxOffset = windowedPeak(
            peak: current.maxEventualBgOffsetInObserving, peakAtMs: current.maxOffsetAtMs,
            value: eventualBg - targetBg, nowMs: nowMs
        ).0
        let age = current.ageCycles
        // 2026-07-03: age gate opens one cycle early when the score has been ≥ confirmScore on
        // BOTH this cycle and the previous one (see confirmMinObservingAgeScoreReady). The early
        // path checks the CURRENT score, not the tracked max — a sustained-ready score, not a
        // transient peak, is what justifies shaving the hysteresis.
        let scoreReadyFloor = aggressiveEarlyConfirm
            ? C.confirmMinObservingAgeScoreReadyAggressive
            : C.confirmMinObservingAgeScoreReady
        let ageEligible = age >= C.confirmMinObservingAge ||
            (age >= scoreReadyFloor && score >= C.confirmScore && scoreReadyStreak)
        return ageEligible && newMaxScore >= C.confirmScore && newMaxOffset >= C.confirmEventualBgOffsetMgdl
    }

    /// Single-step transition. Pure; caller threads state across cycles.
    public static func step(
        current: MealHypothesisState,
        score: Double,
        eventualBg: Double,
        targetBg: Double,
        delta: Double,
        deltaAccl: Double,
        deltaDeclining: Bool,
        asleep: Bool = false,
        exerciseActive: Bool = false,
        fastConfirmEnabled: Bool = false,
        // 2026-07-02: OBSERVING→CONFIRMED dose-adequacy gate. Caller sets it true when the prospective
        // commit-shot (budget × CONFIRMED mult) exceeds one routine COMMITTED hold (committedCapU,
        // clamped < confirmedCapU). Defaults true so the fast-carb path and existing callers/tests are
        // unaffected.
        confirmDoseAdequate: Bool = true,
        // 2026-07-03 (AAPS 242a6e179d): sustained-score early confirm. True when the PREVIOUS
        // cycle's score was already ≥ confirmScore — computed by the caller from last cycle's
        // score (cross-cycle input, same pattern as deltaDeclining). With the CURRENT score also
        // ≥ confirmScore, the age gate opens one cycle early (confirmMinObservingAgeScoreReady).
        // Defaults false = legacy timing for all existing callers/tests.
        scoreReadyStreak: Bool = false,
        /// Aggressive early-confirm opt-in (auto-config managed). False keeps the audit-validated
        /// timing for every existing caller.
        aggressiveEarlyConfirm: Bool = false,
        /// Wall clock for the age tick, epoch-ms. 0 (tests and legacy callers) or a never-stamped
        /// state ticks on every call, preserving the previous behaviour exactly.
        nowMs: Double = 0,
        /// The meal was announced, by carbs on board or a recent manual or wizard bolus (AAPS
        /// 82f47416c5). A transition that would CONFIRM goes to COMMITTED instead. The 1.8x commit
        /// shot is a catch-up for insulin withheld while OBSERVING, and after a pre-bolus none was
        /// withheld: oref's insulinReq already nets the bolus and the carbs. In the AAPS field report
        /// of 5 October 2026 (TDD about 20 U, 1.5 U pre-bolus, 24 g entered) CONFIRMED delivered
        /// 1.25 U against an insulinReq of 0.93 U and glucose reached 74 mg/dL within 45 minutes. The
        /// transition timing is unchanged; only the destination differs, so this can deliver less
        /// insulin than before and never more.
        mealAnnounced: Bool = false
    ) -> MealHypothesisState {
        // 2026-10-08 (AAPS c237a4d081, audit item 7): apply the session-lock release rules before
        // anything reads the lock. With no clock this is a no-op and the earlier handling applies.
        let cur = releaseEndedSessionLock(current, nowMs: nowMs, delta: delta)
        let timed = nowMs > 0
        // Wall-clock age tick (AAPS 0b1587f6b6). Ages are cycle counts tuned on a five-minute loop,
        // so gating them on elapsed time stops a one-minute loop advancing them five times too fast.
        let ageTick = nowMs <= 0 || cur.lastAgeMs <= 0
            || (nowMs - cur.lastAgeMs) >= MealHypothesisConstants.ageTickMs
        let bumped = ageTick ? 1 : 0
        let tickMs = (ageTick && nowMs > 0) ? nowMs : cur.lastAgeMs
        // A state change always re-stamps the anchor: the new state's clock starts now.
        let enterMs = nowMs > 0 ? nowMs : cur.lastAgeMs
        let C = MealHypothesisConstants.self
        let state = cur.state
        let age = cur.ageCycles
        let committedInSession = cur.committedInSession
        // The lock carried out of RECOVERING and into a new OBSERVING run. With a clock it is
        // whatever the release rules left; without one it is cleared there, as before 8 October.
        let carriedLock = timed && committedInSession
        let currentOffset = eventualBg - targetBg

        // 2026-06-16 corroborated fast-carb fast-path. Since 8 October 2026 never while the session
        // lock is held, from any state.
        let fastConfirm = fastConfirmEnabled && !asleep && !exerciseActive && !committedInSession &&
            delta >= C.fastConfirmDelta && deltaAccl >= C.fastConfirmAccl && score >= C.fastConfirmScore
        // The state a confirm transition enters: CONFIRMED, or COMMITTED for an announced meal.
        // Either way the session lock is set, so an announced meal cannot CONFIRM later in the session.
        let commitEntry = MealHypothesisState(
            state: mealAnnounced ? .committed : .confirmed, ageCycles: 0, committedInSession: true, lastAgeMs: enterMs
        )

        var next: MealHypothesisState
        switch state {
        case .idle:
            if fastConfirm {
                next = commitEntry
            } else if score >= C.enterObservingScore {
                // New OBSERVING run, both peaks seeded with the entry-cycle values. The lock is
                // carried: a rise inside `sessionLockMinMs` of the last commit is the same meal and
                // may re-engage COMMITTED but not CONFIRM again.
                next = MealHypothesisState(
                    state: .observing,
                    ageCycles: 0,
                    maxScoreInObserving: score,
                    maxEventualBgOffsetInObserving: currentOffset,
                    committedInSession: carriedLock, lastAgeMs: enterMs,
                    maxScoreAtMs: timed ? nowMs : 0, maxOffsetAtMs: timed ? nowMs : 0
                )
            } else {
                next = MealHypothesisState(
                    state: state, ageCycles: age + bumped, committedInSession: committedInSession, lastAgeMs: tickMs
                )
            }

        case .observing:
            // Fix 1 and Fix 5 track the peak score and offset in this OBSERVING run. Since 8 October
            // 2026 the peaks expire after `confirmPeakWindowMs` and the fall-back test runs before
            // the confirm test, so a peak cannot confirm a rise the current score has left.
            let (newMaxScore, newMaxScoreMs) = windowedPeak(
                peak: cur.maxScoreInObserving, peakAtMs: cur.maxScoreAtMs, value: score, nowMs: nowMs
            )
            let (newMaxOffset, newMaxOffsetMs) = windowedPeak(
                peak: cur.maxEventualBgOffsetInObserving, peakAtMs: cur.maxOffsetAtMs, value: currentOffset, nowMs: nowMs
            )
            // Eligibility sub-conditions live in confirmEligibleExceptDoseGate — the single shared
            // predicate, so a caller-side eligibility read can never diverge from the dosing
            // decision. (AAPS 242a6e179d.)
            let confirmEligible = confirmEligibleExceptDoseGate(
                current: cur, score: score, eventualBg: eventualBg, targetBg: targetBg,
                scoreReadyStreak: scoreReadyStreak,
                aggressiveEarlyConfirm: aggressiveEarlyConfirm,
                nowMs: nowMs
            ) && confirmDoseAdequate // 2026-07-02: don't spend the token on a shot < one COMMITTED hold
            // Inside a locked session the same slow-path test (age, peaks, dose adequacy) re-engages
            // COMMITTED, Fix 7's 1.0x hold. The fast path has no route here.
            var unlocked = cur
            unlocked.committedInSession = false
            let reEngage = committedInSession && confirmDoseAdequate && confirmEligibleExceptDoseGate(
                current: unlocked, score: score, eventualBg: eventualBg, targetBg: targetBg,
                scoreReadyStreak: scoreReadyStreak,
                aggressiveEarlyConfirm: aggressiveEarlyConfirm,
                nowMs: nowMs
            )
            if observingFallsBack(cur, score: score) {
                next = MealHypothesisState(state: .idle, ageCycles: 0, committedInSession: carriedLock, lastAgeMs: enterMs)
            } else if fastConfirm || confirmEligible {
                next = commitEntry
            } else if reEngage {
                next = MealHypothesisState(state: .committed, ageCycles: 0, committedInSession: true, lastAgeMs: enterMs)
            } else {
                next = MealHypothesisState(
                    state: state,
                    ageCycles: age + bumped,
                    maxScoreInObserving: newMaxScore,
                    maxEventualBgOffsetInObserving: newMaxOffset,
                    committedInSession: committedInSession, lastAgeMs: tickMs,
                    maxScoreAtMs: newMaxScoreMs, maxOffsetAtMs: newMaxOffsetMs
                )
            }

        case .confirmed:
            if age >= C.confirmedToCommittedAge {
                next = MealHypothesisState(state: .committed, ageCycles: 0, committedInSession: true, lastAgeMs: enterMs)
            } else {
                next = MealHypothesisState(state: state, ageCycles: age + bumped, committedInSession: true, lastAgeMs: tickMs)
            }

        case .committed:
            let backOff = deltaAccl < C.recoveringDecelThreshold && deltaDeclining && delta < C.recoveringEntryMaxDelta
            if backOff {
                next = MealHypothesisState(state: .recovering, ageCycles: 0, committedInSession: true, lastAgeMs: enterMs)
            } else {
                next = MealHypothesisState(state: state, ageCycles: age + bumped, committedInSession: true, lastAgeMs: tickMs)
            }

        case .recovering:
            // Two routes: re-acceleration, or a fast rise with any acceleration.
            let reEngage = age >= C.recoveringReengageMinAge &&
                currentOffset > C.recoveringReengageOffsetMgdl &&
                (
                    (deltaAccl > C.recoveringReengageAccl && delta > C.recoveringReengageDelta) ||
                        delta > C.recoveringReengageRiseDelta
                )
            if reEngage {
                next = MealHypothesisState(state: .committed, ageCycles: 0, committedInSession: true, lastAgeMs: enterMs)
            } else if delta < 0 || score < C.recoveringToIdleScore {
                // 2026-10-08 (AAPS c237a4d081, audit item 7): leaving RECOVERING no longer ends the
                // session. A single negative delta is also what the trough between two phases of one
                // meal looks like, so the lock is carried into IDLE and released by
                // releaseEndedSessionLock.
                next = MealHypothesisState(state: .idle, ageCycles: 0, committedInSession: carriedLock, lastAgeMs: enterMs)
            } else {
                next = MealHypothesisState(state: state, ageCycles: age + bumped, committedInSession: true, lastAgeMs: tickMs)
            }
        }

        if !timed {
            next.lastCommitMs = cur.lastCommitMs
            next.nonPositiveRunStartMs = cur.nonPositiveRunStartMs
            return next
        }
        // Session clock and the non-positive-delta run, maintained every cycle whatever the state.
        let inCommit = next.state == .confirmed || next.state == .committed
        next.lastCommitMs = inCommit ? nowMs : cur.lastCommitMs
        next.nonPositiveRunStartMs = delta > 0 ? 0 : (cur.nonPositiveRunStartMs > 0 ? cur.nonPositiveRunStartMs : nowMs)
        return next
    }

    /// Force idle on conditions where prior state must not carry over. Returns (state, didReset).
    ///
    /// Since 8 October 2026 (AAPS c237a4d081) the session lock and its commit time survive the
    /// reset. A reset discards the evidence a state carried, but the commit shot it records has still
    /// been delivered, so a restart or gap 40 minutes after a confirm must not open the way to a
    /// second one. The wall-clock anchor is zeroed so the next step ticks immediately.
    public static func resetIfNeeded(
        current: MealHypothesisState,
        profileSwitched: Bool = false,
        pumpDisconnected: Bool = false,
        loopSuspended: Bool = false,
        timeJumpMinutes: Double = 0.0
    ) -> (MealHypothesisState, Bool) {
        if profileSwitched || pumpDisconnected || loopSuspended ||
            timeJumpMinutes > MealHypothesisConstants.timeJumpResetMinutes
        {
            return (
                MealHypothesisState(
                    state: .idle, committedInSession: current.committedInSession, lastAgeMs: 0,
                    lastCommitMs: current.lastCommitMs
                ),
                true
            )
        }
        return (current, false)
    }

    /// Whether delta has declined monotonically over the last `windowCycles` cycles.
    public static func deltaDeclining(_ deltaHistory: [Double], windowCycles: Int = 2) -> Bool {
        guard deltaHistory.count >= windowCycles + 1 else { return false }
        let tail = Array(deltaHistory.suffix(windowCycles + 1))
        for i in 0 ..< (tail.count - 1) where tail[i] <= tail[i + 1] { return false }
        return true
    }
}
