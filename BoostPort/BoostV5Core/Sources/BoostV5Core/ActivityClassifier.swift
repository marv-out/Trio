import Foundation

/// Boost step + heart-rate activity classification.
///
/// Faithful port of AAPS Boost's activity detection, fusing two sources:
///
/// 1. `HrActivityCalculator` (`plugins/aps/.../openAPSBoost/HrActivityCalculator.kt`)
///    — Karvonen Heart Rate Reserve (HRR%) zones 1–5.
/// 2. `OpenAPSBoostPlugin.calculateBoostActivity()` (~lines 468–693)
///    — step-threshold ACTIVE / INACTIVE / normal detection plus the
///      HR-fused exercise states and their resulting profile% / target BG.
///
/// ## Karvonen zones (from `classifyZone`)
/// HRR% = (bpm − rest) / max(max − rest, 1) × 100
///   - Zone 1 (very light):  HRR% < 30
///   - Zone 2 (light):       30 ≤ HRR% < 40
///   - Zone 3 (moderate):    40 ≤ HRR% < 60
///   - Zone 4 (hard):        60 ≤ HRR% < 80
///   - Zone 5 (max):         HRR% ≥ 80
///
/// ## HR-fusion step thresholds (15-minute window, from `HrActivityCalculator`)
///   - high steps:     steps15 ≥ 300
///   - moderate steps: steps15 ≥ 100
///   - low steps:      steps15 < 30
///
/// ## Fused state → effect (from `calculateBoostActivity`)
///   - VIGOROUS_AEROBIC: profile → max(activityPct − 10, 50), target 150
///   - MODERATE / LIGHT aerobic (or no HR): step-only ACTIVE → profile activityPct, target 150
///   - RESISTANCE: profile unchanged, target 160
///   - STRESS: profile unchanged, target 160 (only when `hrStressDetection`)
///   - ACTIVE (step-only): profile activityPct, target 150
///   - INACTIVE (step-only): profile inactivityPct, no activity target. With HR integration on it
///     needs HR in zone 1; zone 2 and above gives HR_ELEVATED and no usable HR gives
///     HR_UNAVAILABLE, both without adjustment. It also needs the Boost gate open.
///   - normal / resting: no adjustment
///
/// Pure, stateless, Foundation-only.

/// Combined exercise / activity state.
public enum ExerciseState: String, Codable, Sendable {
    case normal
    case active
    case inactive
    case vigorousAerobic
    case moderateAerobic
    case lightAerobic
    case resistance
    case stress
    case resting
    /// HR in zone 2 or above with low steps: the inactivity raise is withheld, target and profile
    /// unchanged, and it is not exercise (AAPS 477e649338, "HR_ELEVATED").
    case hrElevated
    /// HR integration on but no usable HR (none in the window, or a frozen value): the inactivity
    /// raise is withheld, since a missing heart rate is not evidence of rest (AAPS a33752c9aa #12,
    /// "HR_UNAVAILABLE").
    case hrUnavailable
    /// The step feed is not delivering, so 0 steps is not evidence of rest: no INACTIVE raise and
    /// the profile stays at 100% (AAPS StepFeed, "steps-unknown"). In Trio this is a locked iPhone,
    /// whose Health store cannot be read.
    case stepsUnknown
}

/// Configurable thresholds. Defaults match the AAPS Boost preference defaults.
public struct ActivityThresholds: Equatable, Sendable {
    /// `ApsBoostActivitySteps5` — steps in last 5 min that trigger ACTIVE.
    public var steps5: Int
    /// `ApsBoostActivitySteps15` — steps in last 15 min that trigger ACTIVE.
    public var steps15: Int
    /// `ApsBoostActivitySteps30` — steps in last 30 min that trigger ACTIVE.
    public var steps30: Int
    /// `ApsBoostActivitySteps60` — steps in last 60 min that trigger ACTIVE.
    public var steps60: Int
    /// `ApsBoostActivityPct` — profile % applied when ACTIVE.
    public var activityPct: Double
    /// `ApsBoostInactivitySteps` — 60-min step count below which INACTIVE applies.
    public var inactivitySteps: Int
    /// `ApsBoostInactivityPct` — profile % applied when INACTIVE.
    public var inactivityPct: Double
    /// `ApsBoostHrMaxBpm` — Karvonen HRmax.
    public var hrMaxBpm: Int
    /// `ApsBoostHrRestingBpm` — Karvonen resting HR.
    public var hrRestingBpm: Int
    /// `ApsBoostHrStressDetection` — opt-in STRESS classification.
    public var hrStressDetection: Bool
    /// `ApsBoostHrIntegrationEnabled` — gate for the HR-fused path.
    public var hrIntegrationEnabled: Bool

    public init(
        steps5: Int = 420,
        steps15: Int = 800,
        steps30: Int = 1200,
        steps60: Int = 1800,
        activityPct: Double = 80,
        inactivitySteps: Int = 500,
        inactivityPct: Double = 130,
        hrMaxBpm: Int = 180,
        hrRestingBpm: Int = 60,
        hrStressDetection: Bool = false,
        hrIntegrationEnabled: Bool = false
    ) {
        self.steps5 = steps5
        self.steps15 = steps15
        self.steps30 = steps30
        self.steps60 = steps60
        self.activityPct = activityPct
        self.inactivitySteps = inactivitySteps
        self.inactivityPct = inactivityPct
        self.hrMaxBpm = hrMaxBpm
        self.hrRestingBpm = hrRestingBpm
        self.hrStressDetection = hrStressDetection
        self.hrIntegrationEnabled = hrIntegrationEnabled
    }
}

/// Inputs to a single classification.
public struct ActivityInputs: Equatable, Sendable {
    public var steps5: Int
    public var steps15: Int
    public var steps30: Int
    public var steps60: Int
    /// Duration-weighted average HR over the HR window. `0` (or any value when
    /// HR integration is disabled) means "no HR signal".
    public var avgHeartRate: Double
    /// Inside the CONFIGURED night window, read regardless of the night-mode enable flag
    /// (AAPS `NightWindow.contains`, 2026-07-31). The start and end times state when this person
    /// is overnight, which is a fact about them; the enable flag states whether Boost should dose
    /// overnight, which is a policy. The inactivity branch adds insulin and needs the fact.
    /// Needs no sensor, so it is the exclusion that holds by default rather than by configuration.
    public var inNightWindow: Bool
    /// Sleep detector reports SLEEPING or PRE_SLEEP. Covers sleep outside the configured window,
    /// on the cycles where the detector has data.
    public var asleep: Bool
    /// Steps-based morning lie-in. Covers oversleeping past the configured night end.
    public var sleepInActive: Bool
    /// The Boost gate (`BoostGate.isOpen`, AAPS `boostActive`). Gates only the INACTIVE raise,
    /// the one outcome of the classification that adds insulin; exercise, resistance and the
    /// elevated-HR handling lower the profile or raise the target and run whatever it says
    /// (AAPS a33752c9aa #11). Defaults open, which is the behaviour before 2026-10-08.
    public var raiseGateOpen: Bool
    /// The step counts were read (AAPS `StepFeed.available`). False when the feed is dark, where the
    /// windows read 0 without meaning the person is still. Defaults true, the behaviour before
    /// 2026-11-20.
    public var stepsAvailable: Bool
    public var thresholds: ActivityThresholds

    public init(
        steps5: Int,
        steps15: Int,
        steps30: Int,
        steps60: Int,
        avgHeartRate: Double,
        inNightWindow: Bool = false,
        asleep: Bool = false,
        sleepInActive: Bool = false,
        raiseGateOpen: Bool = true,
        stepsAvailable: Bool = true,
        thresholds: ActivityThresholds
    ) {
        self.steps5 = steps5
        self.steps15 = steps15
        self.steps30 = steps30
        self.steps60 = steps60
        self.avgHeartRate = avgHeartRate
        self.inNightWindow = inNightWindow
        self.asleep = asleep
        self.sleepInActive = sleepInActive
        self.raiseGateOpen = raiseGateOpen
        self.stepsAvailable = stepsAvailable
        self.thresholds = thresholds
    }
}

/// Result of a classification.
public struct ActivityResult: Equatable, Sendable {
    public let state: ExerciseState
    /// Resulting profile percentage (starting from a baseline of 100%).
    public let profilePercent: Double
    /// Target BG in mg/dL, or `nil` when the state imposes no activity target.
    public let targetBgMgdl: Double?
    /// `true` when `state` is one of the exercise states.
    public let exerciseActive: Bool

    public init(
        state: ExerciseState,
        profilePercent: Double,
        targetBgMgdl: Double?,
        exerciseActive: Bool
    ) {
        self.state = state
        self.profilePercent = profilePercent
        self.targetBgMgdl = targetBgMgdl
        self.exerciseActive = exerciseActive
    }
}

public enum ActivityClassifier {
    // MARK: - Constants (from source)

    /// Activity / resistance / stress aerobic target (from `activityBgTarget = 150.0`).
    private static let aerobicTargetBg: Double = 150.0
    /// Resistance & stress target (from `resistanceBgTarget` / `stressBgTarget = 160.0`).
    private static let resistanceStressTargetBg: Double = 160.0
    /// Baseline profile percentage (the source only adjusts when `currentProfileSwitch == 100`).
    private static let baselineProfilePercent: Double = 100.0

    /// Minimum readings in the window before a zero-variance run is judged frozen. Below this a
    /// stuck value cannot be told apart from merely sparse data, so nothing is suppressed.
    private static let frozenMinReadings = 4

    /// Whether the HR window holds enough readings that are all bit-identical, which is the
    /// signature of a stuck sensor value rather than a heartbeat: a genuine averaged heart rate
    /// always has some spread across a fifteen-minute window. Observed as a value pinned at 124 bpm
    /// all night, which mis-fired resistance on every cycle. (AAPS `isHrWindowFrozen`, 2026-07-16.)
    ///
    /// The caller treats a frozen window as no HR signal, which withholds every HR-driven activity
    /// and target modifier. It is not read as rest: with HR integration on, the inactivity raise
    /// needs positive HR evidence of rest and is withheld when there is none (AAPS a33752c9aa #12,
    /// which corrected the earlier note that the step-only fallback was safe-side).
    public static func isHrWindowFrozen(
        readings: [SleepHrReading],
        nowMs: Double,
        windowMinutes: Int
    ) -> Bool {
        let cutoff = nowMs - Double(windowMinutes) * 60000
        let inWindow = readings.filter { $0.isValid && $0.timestampMs > cutoff && $0.timestampMs <= nowMs }
        guard inWindow.count >= frozenMinReadings else { return false }
        guard let lo = inWindow.map(\.beatsPerMinute).min(),
              let hi = inWindow.map(\.beatsPerMinute).max() else { return false }
        return lo == hi
    }

    // HR-fusion step thresholds (15-min window), from `HrActivityCalculator`.
    private static let steps15HighThreshold = 300 // brisk walk
    private static let steps15ModerateThreshold = 100 // slow walk
    private static let steps15LowThreshold = 30 // near-stationary

    // MARK: - Karvonen zone

    /// Karvonen HR zone (1–5).
    ///
    /// Mirrors `HrActivityCalculator.classifyZone`. `reserve` is coerced to at
    /// least 1 to avoid division by zero.
    public static func karvonenZone(hr: Double, rest: Int, max: Int) -> Int {
        let reserve = Swift.max(max - rest, 1)
        let hrrPct = ((hr - Double(rest)) / Double(reserve)) * 100.0
        switch hrrPct {
        case ..<30.0: return 1
        case ..<40.0: return 2
        case ..<60.0: return 3
        case ..<80.0: return 4
        default: return 5
        }
    }

    // MARK: - Classification

    public static func classify(_ inputs: ActivityInputs) -> ActivityResult {
        let t = inputs.thresholds

        // Step-only ACTIVE detection (mirrors `isActive` in calculateBoostActivity).
        let isActive =
            (t.steps5 > 0 && inputs.steps5 > t.steps5)
                || (t.steps15 > 0 && inputs.steps15 > t.steps15)
                || (t.steps30 > 0 && inputs.steps30 > t.steps30)
                || (t.steps60 > 0 && inputs.steps60 > t.steps60)

        // HR-fused exercise state (nil when HR integration disabled — step-only path).
        let hrState: ExerciseState? = t.hrIntegrationEnabled
            ? fuseHrState(avgHr: inputs.avgHeartRate, steps15: inputs.steps15, thresholds: t)
            : nil

        if isActive {
            return resolveActive(hrState: hrState, thresholds: t)
        }

        // Not step-active. Inactivity branch (mirrors `currentProfileSwitch == 100
        // && recentSteps60Min < inactivitySteps`).
        //
        // Sleep exclusion (AAPS 37a79aac83 then 483d2fec20, ported into the predicate rather than
        // the gate above it because that gate has several defeat paths). A sleeping person has
        // near-zero steps by definition, so the step test is satisfied every night and the branch
        // reads "asleep" as "sedentary". It then raises the profile, which scales DynISF by
        // 100/inactivityPct and lifts basal: it adds insulin. Reported live at 06:09, profile 130%
        // with glucose at 71 and falling. Three independent exclusions, none of which covers every
        // case alone: the configured clock window, the detector, and the morning lie-in.
        // A dark step feed reads 0 too, so the branch also needs the feed (AAPS StepFeed.inactivityStepsMet).
        if inputs.stepsAvailable, inputs.steps60 < t.inactivitySteps,
           !inputs.inNightWindow, !inputs.asleep, !inputs.sleepInActive
        {
            // 2026-07-21 safety guard (AAPS 45f17cca5a), the companion to the dead-zone fix in
            // `fuseHrState`. The inactivity branch adds insulin on the assumption the person is
            // sedentary, and an elevated heart rate contradicts that assumption whatever the step
            // count says. Keyed on the Karvonen zone directly rather than the fused state, so it
            // still holds when the fusion is wrong. Suppresses the profile raise and raises the
            // target instead.
            if t.hrIntegrationEnabled,
               inactivitySuppressedByElevatedHr(avgHr: inputs.avgHeartRate, thresholds: t)
            {
                return result(.resistance, profile: baselineProfilePercent, target: resistanceStressTargetBg)
            }
            // Stress takes precedence over INACTIVE when detection enabled.
            if t.hrStressDetection, hrState == .stress {
                return result(.stress, profile: baselineProfilePercent, target: resistanceStressTargetBg)
            }
            // 2026-09-28 (AAPS 477e649338): zone 2 with low steps is easy cycling or rowing, not
            // sedentary, so the raise is withheld and nothing else changes. Zone 2 is also reached
            // by ordinary daily HR, so it starts no exercise handling. 2026-10-08 (AAPS a33752c9aa
            // #12): with HR integration on, no usable HR withholds the raise as well. The user chose
            // HR as part of the evidence that they are sedentary, so its absence is unknown rather
            // than rest. Fails closed: it can only withhold insulin.
            if t.hrIntegrationEnabled,
               inactivityRaiseBlockedByHr(avgHr: inputs.avgHeartRate, thresholds: t)
            {
                let state: ExerciseState = inputs.avgHeartRate > 0 ? .hrElevated : .hrUnavailable
                return result(state, profile: baselineProfilePercent, target: nil)
            }
            // 2026-10-08 (AAPS a33752c9aa #11): the raise also needs the Boost gate open.
            guard inputs.raiseGateOpen else {
                return result(.normal, profile: baselineProfilePercent, target: nil)
            }
            return result(.inactive, profile: t.inactivityPct, target: nil)
        }

        // HR-only resistance detection (steps don't detect this).
        if t.hrIntegrationEnabled, hrState == .resistance {
            return result(.resistance, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        }

        // HR-only stress detection.
        if t.hrStressDetection, hrState == .stress {
            return result(.stress, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        }

        return result(inputs.stepsAvailable ? .normal : .stepsUnknown, profile: baselineProfilePercent, target: nil)
    }

    // MARK: - Helpers

    /// Resolves the effect of a step-only ACTIVE detection, refined by HR.
    private static func resolveActive(hrState: ExerciseState?, thresholds t: ActivityThresholds) -> ActivityResult {
        switch hrState {
        case .vigorousAerobic:
            let profile = Swift.max(t.activityPct - 10.0, 50.0)
            return result(.vigorousAerobic, profile: profile, target: aerobicTargetBg)
        case .resistance:
            // Raise target, do NOT reduce profile.
            return result(.resistance, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        case .lightAerobic,
             .moderateAerobic,
             nil:
            // Step-only ACTIVE behaviour.
            return result(.active, profile: t.activityPct, target: aerobicTargetBg)
        default:
            // HR signal contradicts steps (e.g. resting/stress) — fall back to ACTIVE.
            return result(.active, profile: t.activityPct, target: aerobicTargetBg)
        }
    }

    /// Whether the inactivity profile raise must be suppressed because the heart rate says
    /// exercise (mirrors `HrActivityCalculator.inactivitySuppressedByElevatedHr`). Zone 3 is
    /// HRR >= 40%, which is exercise range. No HR signal returns false, matching the Kotlin
    /// null check, so a dark HR feed never suppresses on its own.
    public static func inactivitySuppressedByElevatedHr(avgHr: Double, thresholds t: ActivityThresholds) -> Bool {
        guard avgHr > 0 else { return false }
        return karvonenZone(hr: avgHr, rest: t.hrRestingBpm, max: t.hrMaxBpm) >= 3
    }

    /// Whether the inactivity raise is withheld on HR grounds (mirrors
    /// `HrActivityCalculator.inactivityRaiseBlockedByHr`). True from zone 2 (HRR >= 30%) upward
    /// (AAPS 477e649338), and true with no usable HR (AAPS a33752c9aa #12): the host passes 0 for
    /// no reading in the window and for a frozen value, which is the Kotlin null classification.
    /// Callers consult it only with HR integration on; with it off the raise stays step-only.
    public static func inactivityRaiseBlockedByHr(avgHr: Double, thresholds t: ActivityThresholds) -> Bool {
        guard avgHr > 0 else { return true }
        return karvonenZone(hr: avgHr, rest: t.hrRestingBpm, max: t.hrMaxBpm) >= 2
    }

    /// HR + step fusion (mirrors `HrActivityCalculator.classify`).
    private static func fuseHrState(avgHr: Double, steps15: Int, thresholds t: ActivityThresholds) -> ExerciseState? {
        // No HR signal → no fused classification.
        guard avgHr > 0 else { return nil }

        let zone = karvonenZone(hr: avgHr, rest: t.hrRestingBpm, max: t.hrMaxBpm)

        let highSteps = steps15 >= steps15HighThreshold
        let moderateSteps = steps15 >= steps15ModerateThreshold
        let lowSteps = steps15 < steps15LowThreshold

        // Vigorous aerobic: high steps + zone ≥ 3.
        if highSteps, zone >= 3 {
            return .vigorousAerobic
        }
        // Moderate aerobic: moderate steps + zone ≥ 2.
        if moderateSteps, zone >= 2 {
            return .moderateAerobic
        }
        // Light aerobic: above-sedentary steps + zone ≤ 2.
        if !lowSteps, zone <= 2 {
            return .lightAerobic
        }
        // Resistance / non-step exercise: HR clearly elevated (zone 3–4) with steps below the
        // MODERATE-aerobic threshold. 2026-07-21 fix (AAPS 45f17cca5a): the condition was
        // `lowSteps` (< 30), which left a dead zone. 30 to 99 steps at zone 3 or 4 matched no
        // branch and fell through to resting, so non-step exercise with incidental stepping
        // classified as resting and the inactivity branch then added insulin. Reported incident:
        // profile raised to 130% at zone 3 while glucose fell 12 mg/dL per 5 min.
        if !moderateSteps, zone >= 3, zone <= 4 {
            return .resistance
        }
        // STRESS is intentionally NOT classified — it is dead code in AAPS (the classifier only
        // ever tags STRESS with LOW confidence, and the plugin gates it behind `confidence != LOW`,
        // so it never reaches activityState or raises the target). We mirror that: low-steps + zone
        // 2–3 falls through to resting/inactive, never STRESS. (The `hrStressDetection` toggle is
        // kept for parity but, like AAPS, has no effect until STRESS is deliberately enabled.)
        // Inactive: low steps + zone 1.
        if lowSteps, zone == 1 {
            return .inactive
        }
        return .resting
    }

    /// Builds a result, deriving `exerciseActive` from the state.
    private static func result(_ state: ExerciseState, profile: Double, target: Double?) -> ActivityResult {
        ActivityResult(
            state: state,
            profilePercent: profile,
            targetBgMgdl: target,
            exerciseActive: isExerciseState(state)
        )
    }

    /// `true` when the state represents detected exercise (not normal/inactive/resting).
    private static func isExerciseState(_ state: ExerciseState) -> Bool {
        switch state {
        case .active,
             .lightAerobic,
             .moderateAerobic,
             .resistance,
             .vigorousAerobic:
            return true
        case .hrElevated,
             .hrUnavailable,
             .inactive,
             .normal,
             .resting,
             .stepsUnknown,
             .stress: // STRESS is inert (AAPS dead code) — never an exercise state
            return false
        }
    }
}
