import Foundation

/// Boost "night mode" decision.
///
/// Faithful port of `OpenAPSBoostPlugin.isNightModeActiveImpl()` from AAPS
/// (`plugins/aps/.../openAPSBoost/OpenAPSBoostPlugin.kt`, ~lines 1476–1523).
///
/// In the Kotlin source the *only* effect of night mode being active is that
/// SMB is suppressed (`isSMBModeEnabled` sets the constraint to `false` when
/// `isNightModeActive()` is true, line 1439). Night mode does **not** lower the
/// glucose target — `profileTargetMgdl` is passed through unchanged. The
/// expression `bg < profileTarget + bgOffset` is the *activation gate*, not a
/// target adjustment (the catalog summary conflates the two). See the porting
/// report for details.
///
/// Gate order, matching the Kotlin source exactly:
///   1. `enabled` (else inactive)
///   2. clock-window OR (sleepActive AND autoBySleep) — else inactive
///   3. if `disableWithCob` and `cob > 0` — inactive
///   4. if `disableWithLowTt` and an active TT is *below* profileTarget — inactive
///   5. active iff `bg < profileTarget + bgOffsetMgdl`
public struct NightModeConfig: Equatable, Sendable {
    public var enabled: Bool
    /// Minute-of-day [0, 1440) of the night-window start.
    public var startMinute: Int
    /// Minute-of-day [0, 1440) of the night-window end.
    public var endMinute: Int
    /// BG offset in mg/dL added to the profile target for the activation gate.
    /// AAPS default: `UnitDoubleKey.ApsBoostNightModeBgOffset` = 27.0 mg/dL.
    public var bgOffsetMgdl: Double
    public var disableWithCob: Bool
    public var disableWithLowTt: Bool
    public var autoBySleep: Bool

    public init(
        enabled: Bool = false,
        startMinute: Int,
        endMinute: Int,
        bgOffsetMgdl: Double = 27,
        disableWithCob: Bool = false,
        disableWithLowTt: Bool = false,
        autoBySleep: Bool = false
    ) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.bgOffsetMgdl = bgOffsetMgdl
        self.disableWithCob = disableWithCob
        self.disableWithLowTt = disableWithLowTt
        self.autoBySleep = autoBySleep
    }
}

public struct NightModeInputs: Equatable, Sendable {
    /// Current local clock as minute-of-day [0, 1440).
    public var nowMinuteOfDay: Int
    /// Current glucose, mg/dL.
    public var bg: Double
    /// Profile target, mg/dL.
    public var profileTargetMgdl: Double
    /// Carbs on board (meal COB).
    public var cob: Double
    /// Active temp-target value in mg/dL, or `nil` when no TT is active.
    public var activeTempTargetMgdl: Double?
    /// Sleep detector reports a non-AWAKE state.
    public var sleepActive: Bool
    /// Step-based morning lie-in is in effect (steps below threshold within `sleepInHours` of night
    /// end). Ungated by `autoBySleep` — the false-AWAKE backstop applies regardless — so night-mode
    /// SMB rules also apply during a lie-in. (2026-07-02, mirrors AAPS c94c5c72d6.)
    public var sleepInActive: Bool
    public var config: NightModeConfig

    public init(
        nowMinuteOfDay: Int,
        bg: Double,
        profileTargetMgdl: Double,
        cob: Double,
        activeTempTargetMgdl: Double?,
        sleepActive: Bool,
        sleepInActive: Bool = false,
        config: NightModeConfig
    ) {
        self.nowMinuteOfDay = nowMinuteOfDay
        self.bg = bg
        self.profileTargetMgdl = profileTargetMgdl
        self.cob = cob
        self.activeTempTargetMgdl = activeTempTargetMgdl
        self.sleepActive = sleepActive
        self.sleepInActive = sleepInActive
        self.config = config
    }
}

public struct NightModeResult: Equatable, Sendable {
    /// Whether night mode is active.
    public var active: Bool
    /// Whether SMB should be suppressed (true iff `active` — night mode's only
    /// effect in the AAPS source).
    public var suppressSmb: Bool
    /// The (possibly lowered) target. In the faithful AAPS port night mode does
    /// not change the target, so this equals `profileTargetMgdl`.
    public var targetMgdl: Double
    /// Short tag describing which gate decided the outcome.
    public var reason: String

    public init(active: Bool, suppressSmb: Bool, targetMgdl: Double, reason: String) {
        self.active = active
        self.suppressSmb = suppressSmb
        self.targetMgdl = targetMgdl
        self.reason = reason
    }
}

public enum NightMode {
    /// Pure evaluation of the night-mode decision. No clock or I/O access.
    public static func evaluate(_ inputs: NightModeInputs) -> NightModeResult {
        let cfg = inputs.config
        let target = inputs.profileTargetMgdl

        // Gate 1: master enable.
        guard cfg.enabled else {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "disabled")
        }

        // Gate 2: clock window OR (sleepActive AND autoBySleep).
        // Kotlin: `if (!active && !sleepActive) return false`, where `sleepActive`
        // is itself gated by `autoBySleep`.
        let inWindow = minuteInWindow(
            now: inputs.nowMinuteOfDay,
            start: cfg.startMinute,
            end: cfg.endMinute
        )
        let sleepActive = cfg.autoBySleep && inputs.sleepActive
        // A step-based morning lie-in also counts as "in the night/sleep period" so night-mode SMB
        // rules apply during a lie-in — ungated by autoBySleep, the false-AWAKE backstop. (2026-07-02)
        guard inWindow || sleepActive || inputs.sleepInActive else {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "outside-window")
        }

        // Gate 3: disable when COB > 0.
        if cfg.disableWithCob, inputs.cob > 0 {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "cob")
        }

        // Gate 4: disable when an active temp target is below the profile target.
        if cfg.disableWithLowTt, let tt = inputs.activeTempTargetMgdl, tt < target {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "low-tt")
        }

        // Gate 5: BG must be below profileTarget + bgOffset.
        let active = inputs.bg < target + cfg.bgOffsetMgdl
        if active {
            return NightModeResult(active: true, suppressSmb: true, targetMgdl: target, reason: "active")
        }
        return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "bg-high")
    }

    /// Circular minute-of-day window membership: `[start, end)`.
    ///
    /// Mirrors the Kotlin midnight-wrap logic (`if (end > start) now in start until end else wrap`).
    /// `end > start` → half-open interval; `end < start` wraps midnight (e.g. 22:00→07:00). When
    /// `start == end` the window is EMPTY (2026-07-02, AAPS 8ecaf7bbd9): it previously covered the
    /// full 24h → always-night, which silently made V6 never dose; HR/step sleep detection still
    /// governs the night via the caller.
    static func minuteInWindow(now: Int, start: Int, end: Int) -> Bool {
        if start == end { return false } // empty window
        if end > start {
            return now >= start && now < end
        }
        // end < start: wraps midnight → [start, 1440) ∪ [0, end).
        return now >= start || now < end
    }
}

/// Whether Boost may dose this cycle, before the lie-in check, and the sleep signals that feed it.
///
/// Port of `OpenAPSBoostPlugin.boostGateOpen` (AAPS 47a815aedf) and `sleepSignals` (AAPS
/// a33752c9aa #18). Trio has no V1 tier engine, so with the gate closed the base oref SMB stands,
/// which is what AAPS reaches with Tier 8 alone.
public enum BoostGate {
    /// The gate. Closed by any of:
    ///  - `nightSleepPeriod`: the night-mode period (toggle-dependent, as before).
    ///  - `inNightWindow`: the configured night window as a clock fact, whatever the night-mode
    ///    toggle says. With the toggle off the gate used to stay open all night: on 2026-10-08 at
    ///    05:30 an AAPS user received 1.95 U from a Boost tier with the detector reading SLEEPING.
    ///  - `v6Active && detectorSleeping`: V6 stands down while SLEEPING, which also covers sleep
    ///    outside the window (early nights, lie-ins).
    /// The detector can only close the gate. It cannot reopen it inside the window, because a
    /// batched heart-rate upload reads as a wake there. Carbs on board do not reopen it either.
    public static func isOpen(
        nightSleepPeriod: Bool,
        inNightWindow: Bool,
        v6Active: Bool,
        detectorSleeping: Bool
    ) -> Bool {
        !nightSleepPeriod && !inNightWindow && !(v6Active && detectorSleeping)
    }

    /// The sleep signals the gate and the inactivity exclusion use, after the boundary-exit hold.
    public struct SleepSignals: Equatable, Sendable {
        /// SLEEPING, or inside the hold.
        public let detectorSleeping: Bool
        /// SLEEPING or PRE_SLEEP, or inside the hold.
        public let detectorAsleep: Bool
        /// The night/sleep period, held where it was sleep-driven.
        public let nightSleepPeriod: Bool
        /// Whether the hold applied this cycle (telemetry).
        public let boundaryHold: Bool
    }

    /// Minutes the sleep exclusions are held after a boundary exit: the detector's sleep hysteresis
    /// plus one five-minute cycle, the shortest time in which it can re-enter SLEEPING.
    public static func boundaryExitHoldMin(sleepHysteresisMin: Int) -> Int {
        max(sleepHysteresisMin, 0) + 5
    }

    /// Sleep signals with the boundary-exit hold (AAPS a33752c9aa #18). The detector can enter
    /// SLEEPING up to 90 min before the night window opens, and its boundary rule ends a sleep
    /// outside the window on the next cycle; it re-enters after the hysteresis. Each such exit left
    /// one cycle reading AWAKE, which opened the inactivity raise and, with sleep-driven night mode,
    /// the gate. For `holdMin` minutes after a boundary exit the user is treated as SLEEPING for the
    /// gate and the inactivity exclusion, and the night/sleep period is held where it was
    /// sleep-driven (night mode and auto-by-sleep both on). The same rule ends a sleep at the
    /// morning boundary, where the hold delays Boost by one hysteresis period, the conservative
    /// direction. Genuine wakes (steps, HR, resume) record no boundary exit and are not held.
    public static func sleepSignals(
        state: SleepState,
        nightSleepPeriodRaw: Bool,
        nightModeEnabled: Bool,
        autoBySleep: Bool,
        nowMs: Double,
        lastBoundaryExitMs: Double?,
        holdMin: Int
    ) -> SleepSignals {
        let sleeping = state == .sleeping
        let hold: Bool = {
            guard !sleeping, let exit = lastBoundaryExitMs else { return false }
            return nowMs >= exit && nowMs - exit < Double(holdMin) * 60000
        }()
        return SleepSignals(
            detectorSleeping: sleeping || hold,
            detectorAsleep: sleeping || state == .preSleep || hold,
            nightSleepPeriod: nightSleepPeriodRaw || (hold && nightModeEnabled && autoBySleep),
            boundaryHold: hold
        )
    }

    /// The configured night window as a clock fact, read whatever the night-mode toggle says.
    /// Same `[start, end)` wrap semantics as `NightMode`, equal times being an empty window.
    public static func inNightWindow(nowMinuteOfDay: Int, startMinute: Int, endMinute: Int) -> Bool {
        NightMode.minuteInWindow(now: nowMinuteOfDay, start: startMinute, end: endMinute)
    }
}
