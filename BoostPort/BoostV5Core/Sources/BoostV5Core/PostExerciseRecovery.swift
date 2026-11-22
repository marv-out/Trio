import Foundation

/// Configuration for the post-exercise recovery feature.
///
/// 1:1 port of the Boost preference keys consumed by
/// `OpenAPSBoostPlugin` (`plugins/aps/.../openAPSBoost/OpenAPSBoostPlugin.kt`):
///   - `ApsBoostPostExerciseRecoveryHours`  → `recoveryHours`        (default 2.0)
///   - `ApsBoostPostExerciseRecoveryTarget` → `recoveryTargetMgdl`   (default 144 mg/dL)
///   - `ApsBoostPostExerciseRecoveryScale`  → `recoveryScale`        (default 0.5)
///   - `ApsBoostPostExerciseMinDuration`    → `minDurationMin`       (default 10 min)
///   - `ApsBoostPostExerciseRecoveryEnabled`→ `enabled`              (default false)
public struct PostExerciseConfig: Codable, Equatable, Sendable {
    public var recoveryHours: Double
    public var recoveryTargetMgdl: Double
    public var recoveryScale: Double
    public var minDurationMin: Int
    public var enabled: Bool

    public init(
        recoveryHours: Double = 2.0,
        recoveryTargetMgdl: Double = 144.0,
        recoveryScale: Double = 0.5,
        minDurationMin: Int = 10,
        enabled: Bool = false
    ) {
        self.recoveryHours = recoveryHours
        self.recoveryTargetMgdl = recoveryTargetMgdl
        self.recoveryScale = recoveryScale
        self.minDurationMin = minDurationMin
        self.enabled = enabled
    }
}

/// Mutable recovery state held by the *caller* (the Kotlin plugin keeps these as
/// `@Volatile` instance vars; this port is pure, so the caller owns them).
///
/// Maps to the Kotlin fields:
///   - `recoveryWindowEnd`          → `recoveryWindowEndMs`
///   - `activeRecoveryScale`        → `activeRecoveryScale`
///   - `activeRecoveryTargetOffset` → `activeRecoveryTargetOffset`
///   - `wasExerciseActive`          → `wasExerciseActive`
///   - `exerciseStartTime`          → `exerciseStartMs`
///
/// Kotlin initial values: `recoveryWindowEnd = 0L`, `activeRecoveryScale = 0.5`,
/// `activeRecoveryTargetOffset = 0.0`, `wasExerciseActive = false`,
/// `exerciseStartTime = 0L`. The Kotlin plugin also keeps
/// `lastExerciseStateAtTransition`; here the latest exercise type is passed in on
/// each `step` call, so it is not stored.
public struct RecoveryState: Codable, Equatable, Sendable {
    public var recoveryWindowEndMs: Double
    public var activeRecoveryScale: Double
    public var activeRecoveryTargetOffset: Double
    public var wasExerciseActive: Bool
    public var exerciseStartMs: Double?

    public init(
        recoveryWindowEndMs: Double = 0.0,
        activeRecoveryScale: Double = 0.5,
        activeRecoveryTargetOffset: Double = 0.0,
        wasExerciseActive: Bool = false,
        exerciseStartMs: Double? = nil
    ) {
        self.recoveryWindowEndMs = recoveryWindowEndMs
        self.activeRecoveryScale = activeRecoveryScale
        self.activeRecoveryTargetOffset = activeRecoveryTargetOffset
        self.wasExerciseActive = wasExerciseActive
        self.exerciseStartMs = exerciseStartMs
    }
}

/// Result of a single `PostExerciseRecovery.step` evaluation.
///
/// - `inRecoveryWindow`: true when `now < recoveryWindowEndMs` (mirrors Kotlin
///   `now < recoveryWindowEnd`). While true the caller multiplies its boost
///   bolus / scale by `smbScale`.
/// - `smbScale`: the active SMB scale to apply (1.0 when not in window).
/// - `targetOffsetMgdl`: the active target offset added on top of the recovery
///   target (0.0 when not in window).
/// - `newState`: the updated state the caller must persist for the next call.
public struct RecoveryResult: Equatable, Sendable {
    public var inRecoveryWindow: Bool
    public var smbScale: Double
    public var targetOffsetMgdl: Double
    public var newState: RecoveryState

    public init(
        inRecoveryWindow: Bool,
        smbScale: Double,
        targetOffsetMgdl: Double,
        newState: RecoveryState
    ) {
        self.inRecoveryWindow = inRecoveryWindow
        self.smbScale = smbScale
        self.targetOffsetMgdl = targetOffsetMgdl
        self.newState = newState
    }
}

/// Pure port of the Boost post-exercise recovery transition logic.
///
/// Faithful to `OpenAPSBoostPlugin.kt` (~lines 813–876, 1061–1070):
/// on the transition out of an exercise state (after exercising for at least
/// `minDurationMin`), a recovery window opens whose length, SMB scale, and target
/// offset depend on the exercise type. While inside the window the caller scales
/// its SMB output by the active scale and offsets its target.
public enum PostExerciseRecovery {
    private static let hourMs: Double = 3_600_000.0
    private static let minuteMs: Double = 60000.0

    /// Per-exercise-type recovery multipliers.
    ///
    /// Exact Kotlin `when` block:
    /// ```
    /// "VIGOROUS_AEROBIC" -> Triple(1.25, 0.0,  0.8)   // window, targetOffset, scale
    /// "RESISTANCE"       -> Triple(1.5,  10.0, 1.2)
    /// "LIGHT_AEROBIC"    -> Triple(0.5,  0.0,  1.4)
    /// else               -> Triple(1.0,  0.0,  1.0)   // ACTIVE / MODERATE_AEROBIC / default
    /// ```
    ///
    /// Accepts either the Swift `ExerciseState` raw string
    /// (`vigorousAerobic` / `resistance` / `lightAerobic` / …) or the original
    /// Kotlin uppercase form (`VIGOROUS_AEROBIC` / `RESISTANCE` / `LIGHT_AEROBIC`).
    public static func multipliers(
        forExerciseType exerciseType: String
    ) -> (window: Double, smb: Double, targetOffset: Double) {
        switch normalize(exerciseType) {
        case "vigorousaerobic":
            return (window: 1.25, smb: 0.8, targetOffset: 0.0)
        case "resistance":
            return (window: 1.5, smb: 1.2, targetOffset: 10.0)
        case "lightaerobic":
            return (window: 0.5, smb: 1.4, targetOffset: 0.0)
        default:
            // ACTIVE / MODERATE_AEROBIC / anything else — baseline (no multiplier)
            return (window: 1.0, smb: 1.0, targetOffset: 0.0)
        }
    }

    /// Evaluate one decision cycle of the recovery state machine.
    ///
    /// - Parameters:
    ///   - nowMs: current epoch time in milliseconds (pass explicitly; no `Date.now`).
    ///   - exerciseActive: whether the activity classifier currently reports an
    ///     exercise state (Kotlin `isCurrentlyActive`: state in
    ///     {ACTIVE, VIGOROUS_AEROBIC, MODERATE_AEROBIC, LIGHT_AEROBIC, RESISTANCE}).
    ///   - exerciseType: the current `ExerciseState` raw string. On the transition
    ///     *out* of exercise this carries the last active exercise type (Kotlin
    ///     `lastExerciseStateAtTransition`), which selects the multipliers.
    ///   - config: feature configuration / defaults.
    ///   - state: caller-held recovery state from the previous cycle.
    public static func step(
        nowMs: Double,
        exerciseActive: Bool,
        exerciseType: String,
        config: PostExerciseConfig,
        state: RecoveryState
    ) -> RecoveryResult {
        var newState = state

        // Disabled → no-op transition tracking; never in a recovery window.
        // (Mirrors the `if (postExerciseRecoveryEnabled)` guard around the block.)
        guard config.enabled else {
            return RecoveryResult(
                inRecoveryWindow: false,
                smbScale: 1.0,
                targetOffsetMgdl: 0.0,
                newState: newState
            )
        }

        let wasActive = state.wasExerciseActive

        if exerciseActive, !wasActive {
            // Exercise started.
            newState.exerciseStartMs = nowMs
        } else if !exerciseActive, wasActive {
            // Exercise ended — evaluate the recovery window.
            let startMs = state.exerciseStartMs ?? nowMs
            let exerciseDurationMin = (nowMs - startMs) / minuteMs
            if exerciseDurationMin >= Double(config.minDurationMin) {
                let m = multipliers(forExerciseType: exerciseType)
                let recoveryMillis = config.recoveryHours * hourMs * m.window
                // Kotlin: (postExerciseRecoveryScale * scaleMultiplier).coerceIn(0.1, 1.0)
                let scale = (config.recoveryScale * m.smb).coerced(in: 0.1 ... 1.0)
                newState.activeRecoveryScale = scale
                newState.activeRecoveryTargetOffset = m.targetOffset
                newState.recoveryWindowEndMs = nowMs + recoveryMillis
            }
            // Too-brief exercise: leave window/scale/offset untouched (Kotlin does
            // nothing in the `else` branch).
        }

        // Update transition tracking (Kotlin updates `wasExerciseActive` every cycle).
        newState.wasExerciseActive = exerciseActive

        // Window evaluation: Kotlin `now < recoveryWindowEnd`.
        let inWindow = nowMs < newState.recoveryWindowEndMs
        return RecoveryResult(
            inRecoveryWindow: inWindow,
            smbScale: inWindow ? newState.activeRecoveryScale : 1.0,
            targetOffsetMgdl: inWindow ? newState.activeRecoveryTargetOffset : 0.0,
            newState: newState
        )
    }

    /// Lowercase, strip underscores so "VIGOROUS_AEROBIC" and "vigorousAerobic"
    /// both normalize to "vigorousaerobic".
    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "")
    }
}

private extension Double {
    /// Equivalent of Kotlin `Double.coerceIn(min, max)`.
    func coerced(in range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
