import Foundation

/// SleepStateDetector — HR + step + clock-driven sleep state estimator for Boost night mode.
///
/// Pure 1:1 port of AAPS `SleepStateDetector` (openAPSBoost, Boost-V6-mealtime-alpha). No
/// Android / persistence dependencies: `step` takes the per-cycle inputs and prior state,
/// returns the new state.
///
/// Three-state machine: AWAKE → PRE_SLEEP → SLEEPING → AWAKE.
///
/// Enter PRE_SLEEP (from AWAKE) when clock ∈ [nightStart − preSleepLeadMin, nightStart).
/// Time-only pre-warm window (no HR/step gating).
///
/// Enter SLEEPING (from PRE_SLEEP or AWAKE if already in night window) when ALL hold for
/// ≥ sleepHysteresisMin (the HR-value qualifier), OR the drought qualifier holds:
///   HR qualifier: avgHr ≤ restingHr × 1.15, steps15min < 50, clock ∈ outer window, meal < 0.30/nil
///   Drought qualifier (batched-HR platforms / sparse HealthKit overnight HR): avgHr == nil AND
///     no fresh HR sample for ≥ droughtThresholdMin AND steps15min < 50 AND meal < 0.30/nil.
///
/// Exit SLEEPING (to AWAKE):
///   - clock leaves the hold window, which runs to nightEnd plus the lie-in (hard morning exit), OR
///   - transmission-resume wake: ≥3 fresh HR samples arrive after a ≥droughtThresholdMin drought
///     (no hysteresis), OR
///   - avgHr > restingHr × 1.25 AND steps15min ≥ 100, sustained ≥ wakeHrHysteresisMin.
///
/// PRE_SLEEP → AWAKE when clock leaves both the pre-sleep and outer night windows, or at once on
/// 60-min step growth at the sleep-in steps threshold.
public enum SleepState: String, Codable, Sendable {
    case awake
    case preSleep
    case sleeping
}

/// One HR sample. Mirrors AAPS `HR` (timestamp, beatsPerMinute, duration, isValid). The
/// detector computes its own duration-weighted average and freshness/drought from these, so
/// the host must pass raw samples (not a pre-averaged value).
public struct SleepHrReading: Codable, Equatable, Sendable {
    /// Sample timestamp, epoch-ms.
    public var timestampMs: Double
    public var beatsPerMinute: Double
    /// Sample duration, ms. HealthKit HR samples are typically instantaneous; the host should
    /// supply a nominal positive duration so the duration-weighted average degrades to a mean.
    public var durationMs: Double
    public var isValid: Bool

    public init(timestampMs: Double, beatsPerMinute: Double, durationMs: Double, isValid: Bool = true) {
        self.timestampMs = timestampMs
        self.beatsPerMinute = beatsPerMinute
        self.durationMs = durationMs
        self.isValid = isValid
    }
}

/// Constants matched exactly to the AAPS Kotlin source.
public enum SleepStateConstants {
    /// avgHr ≤ restingHr × this → HR low enough for sleep. (Kotlin: `hrResting * 1.15`)
    public static let sleepHrMultiplier = 1.15
    /// avgHr > restingHr × this → HR high enough to be a wake candidate. (Kotlin: `hrResting * 1.25`)
    public static let wakeHrMultiplier = 1.25
    /// steps15min ≥ this blocks sleep candidacy. (Kotlin: `stepsLast15Min >= 50`)
    public static let sleepStepCeiling = 50
    /// steps15min ≥ this is required to confirm wake. (Kotlin: `stepsLast15Min >= 100`)
    public static let wakeStepFloor = 100
    /// mlMealLikely ≥ this blocks sleep candidacy. (Kotlin: `mlMealLikely >= 0.30`)
    public static let mealLikelyThreshold = 0.30
    /// ≥ this many fresh samples after a drought → transmission-resume wake. (Kotlin: `>= 3`)
    public static let transmissionResumeSampleCount = 3
    /// Minutes in a day, for circular clock math.
    public static let minutesPerDay = 1440
    /// ms per minute, for hysteresis hold computation.
    public static let msPerMinute = 60000.0

    // ── Lump-tolerant genuine-wake constants (2026-07-03 incident, AAPS 5f7a481f28) ──

    /// Trailing lookback (minutes) over which cumulative stepsToday growth counts as wake evidence.
    /// Wear-bridge steps arrive in batches that predate/straddle any single 15-min bucket (0 → 1326
    /// by 06:02 on 2026-07-03), so the wake test compares stepsToday deltas across a longer window
    /// instead of one bucket. (Kotlin: `WAKE_STEP_LOOKBACK_MIN = 60`)
    public static let wakeStepLookbackMin = 60
    /// Cumulative stepsToday growth over `wakeStepLookbackMin` required as step evidence for a
    /// genuine wake — must clear nocturnal fidgeting over the full lookback. (Kotlin: `WAKE_STEP_THRESHOLD = 100`)
    public static let wakeStepThreshold = 100
    /// Consecutive cycles with avgHr above the wake floor before wake candidacy may start; a single
    /// elevated sample never counts (REM lifts HR without wakefulness). (Kotlin: `WAKE_HR_SUSTAIN_CYCLES = 2`)
    public static let wakeHrSustainCycles = 2

    // ── Degraded-HR fallback + steps-alone wake (2026-07-08 incident, AAPS dea9d300ff) ──

    /// Minimum FRESH HR samples within the fresh window for the feed to count as a reliable live
    /// transmission. Below this the feed is UNRELIABLE — dead OR intermittent. A degraded feed of
    /// ~1 stray sample per 15-20 min defeated both the old avgHr==nil drought gate (each stray reset
    /// the drought clock) and the HR qualifier (avgHr flickered), leaving the detector stuck in
    /// PRE_SLEEP three nights running. A feed below this floor is treated as drought, and stray
    /// samples below it do NOT reset the drought clock. (Kotlin: `HR_RELIABLE_MIN_SAMPLES = 3`)
    public static let hrReliableMinSamples = 3
    /// Cumulative stepsToday growth over `wakeStepLookbackMin` that wakes on STEPS ALONE (no HR
    /// corroboration), sustained — deliberately HIGH (clear getting-up movement, not a bathroom trip
    /// or fidget; `wakeStepThreshold` is the lower HR-corroborated bar). (Kotlin: `WAKE_STEP_STRONG_THRESHOLD = 250`)
    public static let wakeStepStrongThreshold = 250
    /// ±tolerance (minutes) around the scheduled night window: sleep candidacy may begin up to this
    /// long BEFORE nightStart, and the gentle HR+steps wake is trusted only within this long of
    /// nightEnd (earlier genuine rising is caught by `wakeStepStrongThreshold`). (Kotlin: `SLEEP_SCHEDULE_TOLERANCE_MIN = 90`)
    public static let sleepScheduleToleranceMin = 90
    /// Hours without any valid HR after which the person is treated as having no HR feed. A day covers
    /// a watch that uploads in batches or stops overnight, which still counts as a feed.
    /// (Kotlin: `HR_FEED_LOOKBACK_HOURS = 24`, AAPS Boost 6.3.3)
    public static let hrFeedLookbackHours = 24
    /// Steps (in the 15-min bucket, or cumulative growth over `wakeStepLookbackMin`) that must
    /// accompany an HR transmission burst for it to count as a wake before the scheduled-wake grace
    /// window (AAPS 5a1c852a57). Batched watch uploads produce a burst after a drought every 15 to
    /// 30 min overnight with nobody awake; replayed in AAPS over 30 nights on six users this cut
    /// AWAKE between 02:00 and 05:00 by 7.2 min per night [4.7, 9.9], with no distinguishable delay
    /// to morning wakes. A threshold of 1 gave the same result; 20 leaves room for counts registered
    /// by turning over in bed.
    public static let resumeWakeMinSteps = 20
}

/// One (timestamp, cumulative stepsToday) observation for the trailing wake-evidence window
/// (2026-07-03, AAPS 5f7a481f28).
public struct SleepStepSample: Codable, Equatable, Sendable {
    public var tMs: Double
    public var steps: Int
    public init(tMs: Double, steps: Int) {
        self.tMs = tMs
        self.steps = steps
    }
}

/// Persisted state carried across cycles. Mirrors the Kotlin `State` serialized fields.
public struct SleepDetectorState: Codable, Equatable, Sendable {
    public var state: SleepState
    /// When the current PRE_SLEEP→SLEEPING qualification window started (nil = none in progress).
    public var sleepCandidateSinceMs: Double?
    /// When the current SLEEPING→AWAKE qualification window started (nil = none in progress).
    public var wakeCandidateSinceMs: Double?
    /// When the current state was entered (epoch-ms).
    public var enteredAtMs: Double
    /// Most recent fresh HR-sample timestamp seen (epoch-ms). 0 until the first fresh sample;
    /// persists across cycles so drought duration survives gaps between `step` calls. (2026-06-05)
    public var lastFreshHrSampleMs: Double
    /// Which qualifier promoted the current SLEEPING entry: "hr" or "drought"; nil when not
    /// SLEEPING. Telemetry only. (2026-06-06)
    public var sleepEntryReason: String?
    /// Why a SLEEPING→AWAKE transition happened on the cycle that produced this state:
    /// "boundary" (hard night-window exit), "resume", or "hr_steps"; nil otherwise. TRANSIENT —
    /// excluded from CodingKeys so it is not persisted; it exists only to carry the wake reason
    /// to the host within the same cycle, so the learner trains only on genuine wakes (not the
    /// hard exit, which would otherwise feed its own learned wake → the night-window collapse).
    public var wakeReason: String?
    /// 2026-07-03 lump-tolerant wake evidence (AAPS 5f7a481f28): trailing (timestamp, stepsToday)
    /// samples over the last `wakeStepLookbackMin` (+1 anchor just older, so the first in-window
    /// increment counts). Persisted; a legacy blob without it decodes to [].
    public var stepSamples: [SleepStepSample]
    /// Count of consecutive cycles with avgHr above the wake floor; any miss (null or low) resets it.
    /// Persisted; a legacy blob without it decodes to 0.
    public var hrHighStreak: Int
    /// True on a cycle where a resume burst arrived while SLEEPING but was not corroborated by
    /// steps, so it did not wake the detector (AAPS 5a1c852a57 "resume-burst-ignored"). TRANSIENT,
    /// like `wakeReason`: telemetry for the host, never persisted.
    public var resumeBurstIgnored: Bool = false

    public init(
        state: SleepState = .awake,
        sleepCandidateSinceMs: Double? = nil,
        wakeCandidateSinceMs: Double? = nil,
        enteredAtMs: Double = 0,
        lastFreshHrSampleMs: Double = 0,
        sleepEntryReason: String? = nil,
        wakeReason: String? = nil,
        stepSamples: [SleepStepSample] = [],
        hrHighStreak: Int = 0
    ) {
        self.state = state
        self.sleepCandidateSinceMs = sleepCandidateSinceMs
        self.wakeCandidateSinceMs = wakeCandidateSinceMs
        self.enteredAtMs = enteredAtMs
        self.lastFreshHrSampleMs = lastFreshHrSampleMs
        self.sleepEntryReason = sleepEntryReason
        self.wakeReason = wakeReason
        self.stepSamples = stepSamples
        self.hrHighStreak = hrHighStreak
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case sleepCandidateSinceMs
        case wakeCandidateSinceMs
        case enteredAtMs
        case lastFreshHrSampleMs
        case sleepEntryReason
        case stepSamples
        case hrHighStreak
    }

    // Custom decode so a snapshot persisted before the 2026-06 drought fields existed still
    // decodes (missing lastFreshHrSampleMs/sleepEntryReason default to 0/nil) rather than
    // failing the whole BoostActivitySnapshot decode and dropping a cycle of sleep state.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(SleepState.self, forKey: .state) ?? .awake
        sleepCandidateSinceMs = try c.decodeIfPresent(Double.self, forKey: .sleepCandidateSinceMs)
        wakeCandidateSinceMs = try c.decodeIfPresent(Double.self, forKey: .wakeCandidateSinceMs)
        enteredAtMs = try c.decodeIfPresent(Double.self, forKey: .enteredAtMs) ?? 0
        lastFreshHrSampleMs = try c.decodeIfPresent(Double.self, forKey: .lastFreshHrSampleMs) ?? 0
        sleepEntryReason = try c.decodeIfPresent(String.self, forKey: .sleepEntryReason)
        wakeReason = nil // transient — never persisted/decoded
        resumeBurstIgnored = false // transient
        stepSamples = try c.decodeIfPresent([SleepStepSample].self, forKey: .stepSamples) ?? []
        hrHighStreak = try c.decodeIfPresent(Int.self, forKey: .hrHighStreak) ?? 0
    }
}

/// Per-cycle inputs from the host.
public struct SleepDetectorInputs {
    /// Recent HR samples; the detector filters by window and computes its own average + drought.
    public var hrReadings: [SleepHrReading]
    /// Minutes of HR history to average for state evaluation. (Kotlin default 5)
    public var hrWindowMinutes: Int
    /// User's resting HR, bpm.
    public var restingHeartRate: Double
    /// Steps in the last 15 minutes.
    public var steps15min: Int
    /// Local minute-of-day (0..1439).
    public var nowMinuteOfDay: Int
    /// Night-mode start minute-of-day (e.g. 22:00 → 1320).
    public var nightStartMinute: Int
    /// Night-mode end minute-of-day (e.g. 07:00 → 420).
    public var nightEndMinute: Int
    /// How early before nightStart to enter PRE_SLEEP.
    public var preSleepLeadMin: Int
    /// Minutes sleep conditions must hold before SLEEPING.
    public var sleepHysteresisMin: Int
    /// Minutes HR+steps wake conditions must hold before AWAKE.
    public var wakeHrHysteresisMin: Int
    /// Minutes without a fresh HR sample before drought-based sleep qualification applies.
    /// (Kotlin default 30; set very high to disable drought promotion.)
    public var droughtThresholdMin: Int
    /// How recent (relative to nowMs) an HR sample must be to count as "fresh"/live. (Kotlin default 10)
    public var freshHrWindowMin: Int
    /// Optional meal-likelihood score (nil if model unavailable).
    public var mlMealLikely: Double?
    /// Current system time, epoch-ms.
    public var nowMs: Double
    /// Whether automatic sleep detection is enabled (gates only downstream night-mode, not `step`).
    public var autoBySleep: Bool
    /// Today's CUMULATIVE steps from the best available source (max of wear-reconstructed and phone;
    /// resets at local midnight). Feeds the lump-tolerant trailing wake-evidence window (2026-07-03,
    /// AAPS 5f7a481f28) — the wear bridge delivers steps in batches invisible to the phone-bucket
    /// `steps15min`. -1 = unavailable (legacy 15-min-bucket wake evidence only).
    public var stepsToday: Int
    /// The morning lie-in (AAPS 3111f79ee2, live in Boost 6.3.2): SLEEPING is held this many minutes
    /// past nightEnd, and 60-min step growth at `sleepInStepsThreshold` (the sleep-in steps setting)
    /// ends it. 0 disables the hold. A threshold of 0 falls back to `wakeStepStrongThreshold`.
    public var sleepInStepsThreshold: Int
    public var sleepInWindowMin: Int
    /// False when the host has seen no valid HR in `hrFeedLookbackHours`. Without a feed the HR rules
    /// do not apply: sleep can start only from nightStart, on the clock with the step and meal gates
    /// (AAPS Boost 6.3.3, ecaad5ec6b).
    public var hrFeedPresent: Bool

    public init(
        hrReadings: [SleepHrReading],
        hrWindowMinutes: Int = 5,
        restingHeartRate: Double,
        steps15min: Int,
        nowMinuteOfDay: Int,
        nightStartMinute: Int,
        nightEndMinute: Int,
        preSleepLeadMin: Int,
        sleepHysteresisMin: Int,
        wakeHrHysteresisMin: Int,
        droughtThresholdMin: Int = 30,
        freshHrWindowMin: Int = 10,
        mlMealLikely: Double?,
        nowMs: Double,
        autoBySleep: Bool,
        stepsToday: Int = -1,
        sleepInStepsThreshold: Int = 0,
        sleepInWindowMin: Int = 0,
        hrFeedPresent: Bool = true
    ) {
        self.hrReadings = hrReadings
        self.hrWindowMinutes = hrWindowMinutes
        self.restingHeartRate = restingHeartRate
        self.steps15min = steps15min
        self.nowMinuteOfDay = nowMinuteOfDay
        self.nightStartMinute = nightStartMinute
        self.nightEndMinute = nightEndMinute
        self.preSleepLeadMin = preSleepLeadMin
        self.sleepHysteresisMin = sleepHysteresisMin
        self.wakeHrHysteresisMin = wakeHrHysteresisMin
        self.droughtThresholdMin = droughtThresholdMin
        self.freshHrWindowMin = freshHrWindowMin
        self.mlMealLikely = mlMealLikely
        self.nowMs = nowMs
        self.autoBySleep = autoBySleep
        self.stepsToday = stepsToday
        self.sleepInStepsThreshold = sleepInStepsThreshold
        self.sleepInWindowMin = sleepInWindowMin
        self.hrFeedPresent = hrFeedPresent
    }
}

public enum SleepStateDetector {
    /// Pure transition. Returns the new persisted state. Caller stores it and passes it back next cycle.
    public static func step(_ inputs: SleepDetectorInputs, _ state: SleepDetectorState) -> SleepDetectorState {
        // NOTE: the detector always advances its state machine (matching AAPS, which runs the
        // detector every cycle). `autoBySleep` is NOT gated here — it gates only the downstream
        // night-mode extension (see NightMode). Resetting to AWAKE here would discard in-progress
        // hysteresis and diverge from AAPS, so it is intentionally not done.
        let C = SleepStateConstants.self
        let avgHr = averageHr(inputs.hrReadings, nowMs: inputs.nowMs, windowMinutes: inputs.hrWindowMinutes)
        let sleepCap = inputs.restingHeartRate * C.sleepHrMultiplier
        let wakeFloor = inputs.restingHeartRate * C.wakeHrMultiplier

        let inOuterWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, inputs.nightStartMinute, inputs.nightEndMinute)
        let preSleepStart = (inputs.nightStartMinute - inputs.preSleepLeadMin + C.minutesPerDay) % C.minutesPerDay
        let inPreSleep = minuteInWrappedRange(inputs.nowMinuteOfDay, preSleepStart, inputs.nightStartMinute)
        // 2026-07-08 (AAPS dea9d300ff): sleep candidacy is allowed ±sleepScheduleToleranceMin early
        // (before nightStart) through nightEnd — an unusually-early onset up to 90 min pre-nightStart
        // is detected promptly regardless of the (SMB-pre-warm) preSleepLead. And the gentle HR+steps
        // wake is trusted only within sleepScheduleToleranceMin of nightEnd.
        // The early start exists because HR can corroborate an early onset. Without an HR feed nothing
        // separates an evening on the sofa from sleep, so candidacy, and with it the hold, waits for
        // nightStart (AAPS Boost 6.3.3).
        let sleepCandStart = inputs.hrFeedPresent
            ? (inputs.nightStartMinute - C.sleepScheduleToleranceMin + C.minutesPerDay) % C.minutesPerDay
            : inputs.nightStartMinute
        let inSleepCandidateWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, sleepCandStart, inputs.nightEndMinute)
        let wakeGraceStart = (inputs.nightEndMinute - C.sleepScheduleToleranceMin + C.minutesPerDay) % C.minutesPerDay
        let nearScheduledWake = minuteInWrappedRange(inputs.nowMinuteOfDay, wakeGraceStart, inputs.nightEndMinute)
        _ = inOuterWindow // retained for readability; candidacy now keys on inSleepCandidateWindow
        // Boost 6.3.0 pre-window hold (AAPS f88e53ba52, c361734560): SLEEPING is held from the start of
        // candidacy, 90 min before nightStart, so a sleep detected early is not ended as "boundary" on
        // the next cycle. The lie-in (AAPS 3111f79ee2) carries the hold past nightEnd to lieInEnd, so
        // the boundary exit moves there; a new sleep still cannot start after nightEnd.
        let lieInEnd = inputs.sleepInWindowMin > 0
            ? (inputs.nightEndMinute + inputs.sleepInWindowMin) % C.minutesPerDay : inputs.nightEndMinute
        let inHoldWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, sleepCandStart, lieInEnd)
        let inPreWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, sleepCandStart, inputs.nightStartMinute)
        let inLieIn = inputs.sleepInWindowMin > 0 &&
            minuteInWrappedRange(inputs.nowMinuteOfDay, inputs.nightEndMinute, lieInEnd)
        // One threshold for every steps-alone route, as in AAPS since 3111f79ee2 and 68ec1e2603.
        let strongStepsThreshold = inputs.sleepInStepsThreshold > 0
            ? inputs.sleepInStepsThreshold : C.wakeStepStrongThreshold

        var newState = state

        // Drought-based sleep + transmission-resume wake (2026-06-05). The most recent FRESH HR
        // sample (timestamp within freshHrWindowMin of now — distinguishes live transmission from
        // backfilled sync) drives drought duration; persists in `lastFreshHrSampleMs`.
        let freshCutoff = inputs.nowMs - Double(inputs.freshHrWindowMin) * C.msPerMinute
        let freshReadings = inputs.hrReadings
            .filter { $0.isValid && $0.timestampMs > freshCutoff && $0.timestampMs <= inputs.nowMs }
        let mostRecentFreshTs = freshReadings.map(\.timestampMs).max() ?? 0
        let fifteenMinCutoff = inputs.nowMs - 15 * C.msPerMinute
        let freshSamplesInLast15Min = freshReadings.filter { $0.timestampMs >= fifteenMinCutoff }.count
        // 2026-07-08 (AAPS dea9d300ff): only a RELIABLE live feed (≥ hrReliableMinSamples fresh)
        // resets the drought clock. A lone stray sample every 15-20 min must NOT reset it — that
        // intermittency is what kept droughtMinutes below threshold all night and left the detector
        // stuck in PRE_SLEEP.
        let hrTransmitting = freshSamplesInLast15Min >= C.hrReliableMinSamples
        if mostRecentFreshTs > newState.lastFreshHrSampleMs, hrTransmitting {
            newState.lastFreshHrSampleMs = mostRecentFreshTs
        }
        let droughtMinutes = newState.lastFreshHrSampleMs > 0
            ? Int((inputs.nowMs - newState.lastFreshHrSampleMs) / C.msPerMinute)
            : Int.max
        let droughtEstablished = droughtMinutes >= inputs.droughtThresholdMin
        // The HR feed is UNRELIABLE (dead OR intermittent) when fewer than hrReliableMinSamples
        // fresh samples landed in the last 15 min — this, not avgHr==nil, drives the drought fallback.
        let hrUnreliable = freshSamplesInLast15Min < C.hrReliableMinSamples

        // 2026-07-03 lump-tolerant wake evidence (AAPS 5f7a481f28): record (nowMs, stepsToday) each
        // cycle and derive cumulative growth over the trailing lookback (sum of positive inter-sample
        // increments, so the local-midnight stepsToday reset never yields false deltas). HR sustain
        // streak: consecutive cycles with avgHr above the wake floor; any miss (nil or low) resets it.
        // (`var newState = state` deep-copies stepSamples — Swift arrays are value types.)
        if inputs.stepsToday >= 0 {
            Self.recordStepSample(&newState.stepSamples, nowMs: inputs.nowMs, stepsToday: inputs.stepsToday)
        }
        let stepsInLookback = Self.stepGrowth(newState.stepSamples, nowMs: inputs.nowMs, lookbackMin: C.wakeStepLookbackMin)
        newState.hrHighStreak = (avgHr != nil && avgHr! > wakeFloor) ? newState.hrHighStreak + 1 : 0

        // Drought-qualified candidacy (2026-06-05 / 2026-07-08): HR feed UNRELIABLE (dead OR
        // intermittent) + established drought + step/meal gates pass. Lets the detector reach SLEEPING
        // on batched-HR platforms AND on a degraded feed dribbling one stray sample every 15-20 min
        // (the old avgHr==nil gate never fired because the strays kept avgHr non-nil + reset drought).
        let droughtQualifies = hrUnreliable && droughtEstablished &&
            inputs.steps15min < C.sleepStepCeiling &&
            (inputs.mlMealLikely == nil || inputs.mlMealLikely! < C.mealLikelyThreshold)
        let hrQualifies = qualifiesAsSleepCandidate(
            avgHr, sleepCap: sleepCap, steps15min: inputs.steps15min, mlMealLikely: inputs.mlMealLikely
        )
        let anyQualifies = hrQualifies || droughtQualifies
        // 2026-07-08: three-way entry reason — "hr" (corroborated), "drought" (fully dead feed), or
        // "time" (intermittent/degraded feed reaching SLEEPING on the clock via the drought fallback).
        let sleepEntryReasonValue = hrQualifies ? "hr" : (avgHr == nil ? "drought" : "time")

        // Transmission-resume wake: a burst of fresh samples following an actual drought.
        let priorDroughtMinutes = state.lastFreshHrSampleMs > 0
            ? Int((inputs.nowMs - state.lastFreshHrSampleMs) / C.msPerMinute)
            : Int.max
        let resumeBurst = freshSamplesInLast15Min >= C.transmissionResumeSampleCount &&
            priorDroughtMinutes >= inputs.droughtThresholdMin
        // 2026-10-08 (AAPS 5a1c852a57): a burst alone is not a wake. Watches that upload HR in
        // batches produce a burst after a drought all night, and each one woke the detector. In the
        // core night it now needs step evidence. From sleepScheduleToleranceMin before the scheduled
        // wake it still wakes on the burst alone: the burst that answers a morning wake often lands
        // before the steps do, and it consumes the drought, so a later step lump would find no burst
        // to confirm. The same holds through the lie-in.
        let resumeCorroborated = nearScheduledWake || inLieIn ||
            inputs.steps15min >= C.resumeWakeMinSteps || stepsInLookback >= C.resumeWakeMinSteps
        let transmissionResumeWake = resumeBurst && resumeCorroborated

        var transitioned = false

        switch state.state {
        case .awake:
            // Sleep candidacy possible from AWAKE anywhere in the ±90-early candidate window (so an
            // unusually-early onset up to sleepScheduleToleranceMin before nightStart is detected
            // promptly, independent of the PRE_SLEEP SMB-pre-warm lead). (2026-07-08, AAPS dea9d300ff.)
            if inSleepCandidateWindow, anyQualifies {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(
                            state: .sleeping, enteredAtMs: inputs.nowMs,
                            lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                            sleepEntryReason: sleepEntryReasonValue,
                            stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                        )
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

            if !transitioned, inPreSleep {
                newState = SleepDetectorState(
                    state: .preSleep, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                    stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                )
                transitioned = true
            }

        case .preSleep:
            // Clear activity ends PRE_SLEEP at any hour (AAPS 68ec1e2603): it is not confirmed sleep,
            // and without this someone up at 05:00 stayed in it, under night-mode SMB rules, until
            // the clock. Not a sleep-to-wake, so no wake reason and nothing for the learner.
            if stepsInLookback >= strongStepsThreshold {
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                    stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                )
                transitioned = true
            }
            // Exit if we've left both the outer night window and the pre-sleep window (morning exit).
            else if !inOuterWindow, !inPreSleep {
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                    stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                )
                transitioned = true
                // PRE_SLEEP starts preSleepLeadMin before nightStart and does not check the candidacy
                // window; without an HR feed it must, or the clock qualifier starts sleep in the lead.
            } else if anyQualifies, inputs.hrFeedPresent || inSleepCandidateWindow {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(
                            state: .sleeping, enteredAtMs: inputs.nowMs,
                            lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                            sleepEntryReason: sleepEntryReasonValue,
                            stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                        )
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

        case .sleeping:
            // Hard morning exit, at the end of the hold window.
            if !inHoldWindow {
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                    wakeReason: "boundary", // NOT a genuine wake — excluded from learning
                    stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                )
                transitioned = true
            } else if transmissionResumeWake {
                // Sync burst after a drought → user resumed interaction. No hysteresis.
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                    wakeReason: "resume", // genuine wake signal
                    stepSamples: newState.stepSamples, hrHighStreak: newState.hrHighStreak
                )
                transitioned = true
            } else {
                // Two wake rules (2026-07-08, AAPS dea9d300ff), both lump-tolerant + hysteresis-
                // sustained; BG trend alone still NEVER wakes.
                // Step evidence is lump-tolerant (cumulative stepsToday growth over the trailing
                // lookback, OR the legacy 15-min phone bucket); HR evidence is SUSTAINED (≥
                // wakeHrSustainCycles consecutive cycles above the wake floor — a single sample never
                // counts, REM lifts HR).
                let stepsConfirmWake = inputs.steps15min >= C.wakeStepFloor || stepsInLookback >= C.wakeStepThreshold
                let hrAboveWakeFloor = avgHr != nil && avgHr! > wakeFloor &&
                    newState.hrHighStreak >= C.wakeHrSustainCycles
                // Rule 1 (gentle): HR-rise + steps, trusted ONLY within sleepScheduleToleranceMin of
                // scheduled wake and through the lie-in (earlier HR rises are REM/restlessness)
                // → reason "hr_steps".
                let gentleWake = stepsConfirmWake && hrAboveWakeFloor && (nearScheduledWake || inLieIn)
                // Rule 2 (strong steps-alone): clear sustained getting-up movement wakes WITHOUT HR,
                // but ONLY when the feed is unreliable (drought established, can't corroborate). When
                // HR is live the gentle rule governs and steps-alone must NOT wake (both-required
                // guard preserved). Safety net for HR-death nights + the 2026-07-03 over-sleep lump.
                // Also in the 90 min before nightEnd, where the HR streak often fails while someone is
                // up and walking; there it needs 100 steps in the last 15 min, so a batched upload of
                // older steps does not wake (AAPS 1d09463b40). Anywhere in the lie-in it needs no HR:
                // past the alarm, movement means up.
                let strongStepsWake = stepsInLookback >= strongStepsThreshold &&
                    (droughtEstablished || inLieIn || (nearScheduledWake && inputs.steps15min >= C.wakeStepThreshold))
                // Pre-window wake routes (AAPS c361734560). With HR live and the clock far from the
                // scheduled wake none of the routes above can fire, so a sleep held from the pre-window
                // could not end before the night. Steps count from the SLEEPING entry, not the 60-min
                // lookback, so the walk to bed cannot end the sleep it preceded.
                let stepsSinceEntry: Int = {
                    guard inPreWindow else { return 0 }
                    let sinceEntryMin = Int((inputs.nowMs - newState.enteredAtMs) / C.msPerMinute)
                    return stepGrowth(
                        newState.stepSamples, nowMs: inputs.nowMs,
                        lookbackMin: min(max(sinceEntryMin, 0), C.wakeStepLookbackMin)
                    )
                }()
                let preWindowStepsWake = inPreWindow && stepsSinceEntry >= strongStepsThreshold
                let preWindowHrWake = inPreWindow && hrAboveWakeFloor &&
                    (inputs.steps15min >= C.wakeStepFloor || stepsSinceEntry >= C.wakeStepThreshold)
                if gentleWake || strongStepsWake || preWindowStepsWake || preWindowHrWake {
                    if newState.wakeCandidateSinceMs == nil {
                        newState.wakeCandidateSinceMs = inputs.nowMs
                    } else {
                        let heldMin = Int((inputs.nowMs - newState.wakeCandidateSinceMs!) / C.msPerMinute)
                        if heldMin >= inputs.wakeHrHysteresisMin {
                            // The step history and HR streak start empty, as AAPS does (SleepStateDetector.kt
                            // 687): the steps that ended this sleep would otherwise stay in the 60-min
                            // lookback and end a return to sleep with no new movement.
                            newState = SleepDetectorState(
                                state: .awake, enteredAtMs: inputs.nowMs,
                                lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                                // all genuine wakes; the learner trains on hr_steps and steps only
                                wakeReason: gentleWake ? "hr_steps"
                                    : strongStepsWake ? "steps"
                                    : preWindowHrWake ? "pw_hr_steps" : "pw_steps"
                            )
                            transitioned = true
                        }
                    }
                } else {
                    newState.wakeCandidateSinceMs = nil
                }
            }
        }

        _ = transitioned
        // Set every cycle, so a flag carried in an in-memory previous state never survives it.
        newState.resumeBurstIgnored = resumeBurst && !resumeCorroborated && state.state == .sleeping
        return newState
    }

    /// Append the current cumulative-stepsToday observation and prune samples older than
    /// `wakeStepLookbackMin`, keeping ONE just-older anchor so the first in-window increment still
    /// counts. Bounded to ~lookback/cycle-interval entries. (AAPS `recordStepSample`, 5f7a481f28.)
    static func recordStepSample(_ samples: inout [SleepStepSample], nowMs: Double, stepsToday: Int) {
        samples.append(SleepStepSample(tMs: nowMs, steps: stepsToday))
        let cutoff = nowMs - Double(SleepStateConstants.wakeStepLookbackMin) * SleepStateConstants.msPerMinute
        while samples.count >= 2, samples[1].tMs <= cutoff { samples.removeFirst() }
    }

    /// Cumulative POSITIVE stepsToday growth across the trailing `lookbackMin`: sum of positive
    /// increments between consecutive samples ending inside the window. Negative jumps (the local-
    /// midnight stepsToday reset, a step-source switch) contribute 0 — not movement. (AAPS `stepGrowth`.)
    static func stepGrowth(_ samples: [SleepStepSample], nowMs: Double, lookbackMin: Int) -> Int {
        let cutoff = nowMs - Double(lookbackMin) * SleepStateConstants.msPerMinute
        var sum = 0
        for i in 1 ..< max(1, samples.count) {
            if samples[i].tMs <= cutoff { continue }
            sum += max(0, samples[i].steps - samples[i - 1].steps)
        }
        return sum
    }

    /// Duration-weighted average HR over the window; nil if no readings or zero total duration.
    /// Matches Kotlin `averageHr`.
    static func averageHr(_ readings: [SleepHrReading], nowMs: Double, windowMinutes: Int) -> Double? {
        let cutoff = nowMs - Double(windowMinutes) * SleepStateConstants.msPerMinute
        let inWindow = readings.filter { $0.isValid && $0.timestampMs > cutoff && $0.timestampMs <= nowMs }
        if inWindow.isEmpty { return nil }
        let totalDur = inWindow.reduce(0.0) { $0 + $1.durationMs }
        if totalDur <= 0 { return nil }
        return inWindow.reduce(0.0) { $0 + $1.beatsPerMinute * $1.durationMs } / totalDur
    }

    /// True if `minute` lies within [start, end) on a 24-hour clock, handling wrap-around
    /// (e.g. start=1320 (22:00), end=420 (07:00)). Matches Kotlin `minuteInWrappedRange`.
    static func minuteInWrappedRange(_ minute: Int, _ start: Int, _ end: Int) -> Bool {
        if start == end { return false }
        if end > start {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    /// Matches Kotlin `qualifiesAsSleepCandidate` (HR-value qualifier).
    static func qualifiesAsSleepCandidate(_ avgHr: Double?, sleepCap: Double, steps15min: Int, mlMealLikely: Double?) -> Bool {
        guard let avgHr else { return false } // no HR → can't confirm
        if avgHr > sleepCap { return false } // HR too high
        if steps15min >= SleepStateConstants.sleepStepCeiling { return false } // recent activity
        if let meal = mlMealLikely, meal >= SleepStateConstants.mealLikelyThreshold { return false } // about to eat
        return true
    }
}
