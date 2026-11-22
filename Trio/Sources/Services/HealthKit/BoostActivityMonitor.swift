import Foundation
import HealthKit
import Swinject

/// Reads step + heart-rate activity from HealthKit and publishes a `BoostActivitySnapshot`
/// for the Boost V5 engine's context (exercise / post-exercise / asleep). Observer queries
/// (with background delivery) refresh on new data; an initial refresh runs at launch. Inert
/// until the user grants Health read access (queries silently return nothing).
///
/// Each refresh runs the ported sensing modules: ActivityClassifier (step buckets + HR),
/// SleepStateDetector, and PostExerciseRecovery — advancing the latter two machines from the
/// previous snapshot's persisted state. Thresholds/windows use AAPS defaults until the Boost
/// settings tree lands. Sleep + post-exercise are enabled here (they steer V5 conservatively:
/// no fast-carb overnight, reduced budget post-exercise); both become user settings later.
protocol BoostActivityMonitor {
    func refresh() async
    func requestAuthorization()
}

final class BaseBoostActivityMonitor: BoostActivityMonitor, Injectable {
    @Injected() private var healthKitStore: HKHealthStore!
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var watchActivityStorage: WatchActivityStorage!

    /// Where this refresh reads steps and heart rate. Set at the start of each (serialized) refresh.
    private enum Feed: String {
        /// The iPhone's HealthKit store; unreadable while the iPhone is locked
        case healthKit
        /// Sent by the Trio watch app on the G7 sensor wake (Direct-to-Watch), stored by `WatchActivityStorage`
        case watch
    }

    private var feed: Feed = .healthKit

    /// Newest watch step minute older than this: the step feed is unavailable (as a locked iPhone is for
    /// HealthKit), which withholds the inactivity raise. The sensor wakes the watch about every 5 min and
    /// the newest complete minute is then up to 1 min old, so this allows one missed wake.
    static let watchMaxStepAge: TimeInterval = 10 * 60
    /// Inputs read before the sleep and activity steps, from either feed.
    private struct RecentInputs {
        var stepSums: [Double?] // 5, 15, 30, 60 min; nil = unavailable
        /// False when the counts may read too low (newest minutes written late): they still feed activity
        /// detection, but the feed counts as unavailable, which withholds the inactivity raise
        var stepsReliable = true
        var avgHr: Double?
        var latestHr: Double?
        var restingHr: Double?
        var hrReadings: [SleepHrReading]
    }

    private var observers: [HKObserverQuery] = []

    // Serialize refreshes. The step + HR observer callbacks (plus the launch refresh) each
    // fire refresh() on their own Task; without serialization two concurrent runs read the
    // same previous snapshot, advance the sleep/recovery state machines independently, and
    // the last writer wins — silently dropping a machine transition. Chaining each refresh
    // after the previous one makes the prev-read → step → snapshot-write atomic. The lock
    // only guards the brief chain swap, never an `await`.
    private let refreshLock = NSLock()
    private var refreshChain: Task<Void, Never>?
    // Whether any valid HR arrived in the last day (AAPS Boost 6.3.3). Touched only inside the
    // serialized performRefresh; the day's query runs at most every 30 min.
    private var hrFeedCheckedAt: Date = .distantPast
    private var hrFeedPresentCached = true

    private var stepType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .stepCount) }
    private var hrType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .heartRate) }
    private var restingHRType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .restingHeartRate) }
    private var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    private func d(_ v: Decimal) -> Double { (v as NSDecimalNumber).doubleValue }

    /// Clamp a learned minute-of-day to within the band around the configured minute-of-day.
    /// Delegates to `SleepHistoryTracker`, which owns the learned aggregate and is where the
    /// behaviour is unit-tested.
    static func clampToConfiguredBand(
        _ learned: Int?,
        _ configured: Int,
        bandMin: Int = SleepHistoryTracker.learnedWindowBandMin,
        allowEarlier: Bool = true
    ) -> Int {
        SleepHistoryTracker.clampToConfiguredBand(
            learned: learned, configured: configured, bandMin: bandMin, allowEarlier: allowEarlier
        )
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        startObserving()
        Task { await refresh() }
        debug(.healthKit, "BoostActivityMonitor did create")
    }

    private func startObserving() {
        for type in [stepType, hrType].compactMap({ $0 }) {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task {
                    await self?.refresh()
                    completion()
                }
            }
            healthKitStore.execute(query)
            observers.append(query)
            healthKitStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Request HealthKit READ access for Boost's activity inputs (steps, heart rate, resting HR).
    /// The observers are registered at launch but stay inert until read access is granted, and the
    /// app otherwise only requests Health access via the separate Apple Health integration toggle —
    /// so without this, enabling Boost leaves activity / sleep / post-exercise sensing silently off.
    /// Called when the user enables Boost. Idempotent: iOS shows the prompt only until the user has
    /// made a choice, then calls back immediately. Refreshes on completion so sensing engages.
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes = Set([stepType, hrType, restingHRType].compactMap { $0 })
        guard !readTypes.isEmpty else { return }
        healthKitStore.requestAuthorization(toShare: [], read: readTypes) { [weak self] success, _ in
            guard success else { return }
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        refreshLock.lock()
        let previous = refreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        refreshChain = task
        refreshLock.unlock()
        await task.value
    }

    private func performRefresh() async {
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000.0

        // With "Heart Rate and Steps from Watch" on, the watch's own data replaces the iPhone's HealthKit
        // store for every input that steers dosing. HealthKit stays the feed when it is off.
        feed = settingsManager.settings.watchActivityEnabled ? .watch : .healthKit
        let inputs: RecentInputs
        if feed == .watch {
            inputs = watchRecentInputs(now: now)
        } else {
            inputs = await healthKitRecentInputs(now: now)
        }

        let stepSums = inputs.stepSums
        // A failed read is what HealthKit returns while the iPhone is locked; for the watch feed, data
        // older than `watchMaxStepAge` or with gaps. The windows then read 0, which is not evidence of
        // rest, so the inactivity raise is withheld (AAPS StepFeed).
        let stepsAvailable = !stepSums.contains(nil) && inputs.stepsReliable
        let steps5 = Int(stepSums[0] ?? 0)
        let steps15 = Int(stepSums[1] ?? 0)
        let steps30 = stepSums[2] ?? 0
        let steps60 = Int(stepSums[3] ?? 0)
        let avgHr = inputs.avgHr ?? 0
        let latestHr = inputs.latestHr ?? 0
        let restingHr = inputs.restingHr ?? 0
        let hrReadings = inputs.hrReadings
        let restingForCalc = restingHr > 0 ? restingHr : 60

        let prev = BoostActivityStore.shared.snapshot
        let prefs = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()

        // 1) Activity classification — thresholds from user settings.
        // Prefer the measured HealthKit resting HR; fall back to the configured value.
        let resting = restingHr > 0 ? restingHr : d(prefs.boostHrRestingBpm)
        _ = restingForCalc
        let thresholds = ActivityThresholds(
            steps5: Int(d(prefs.boostActivitySteps5)),
            steps15: Int(d(prefs.boostActivitySteps15)),
            steps30: Int(d(prefs.boostActivitySteps30)),
            steps60: Int(d(prefs.boostActivitySteps60)),
            activityPct: d(prefs.boostActivityPct),
            inactivitySteps: Int(d(prefs.boostInactivitySteps)),
            inactivityPct: d(prefs.boostInactivityPct),
            hrMaxBpm: Int(d(prefs.boostHrMaxBpm)),
            hrRestingBpm: Int(resting),
            hrStressDetection: prefs.boostHrStressDetection,
            hrIntegrationEnabled: prefs.boostHrIntegrationEnabled
        )
        // 2) Sleep state machine — uses the LEARNED night window + resting HR once enough
        // sessions exist (AAPS SleepHistoryTracker.aggregate → effective values feed the
        // detector; the night-mode clock window itself stays configured). Below the learning
        // threshold these fall back to the configured night window / measured resting HR.
        let history = BoostSleepHistoryStore.load()
        let agg = SleepHistoryTracker.aggregate(history, offsetAt: { ms in
            Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000))) * 1000.0
        })
        let configNightStart = Int(d(prefs.boostNightModeStartHour) * 60)
        let configNightEnd = Int(d(prefs.boostNightModeEndHour) * 60)
        // The learned window may only nudge the configured night start/end by ±BAND, and the wake
        // side trains on genuine wakes only (see SleepHistoryTracker). Together these anchor the
        // hard sleep/wake bounds to the configured times and cap how far learning can move them —
        // preventing the self-reinforcing earlier-every-night collapse. No/insufficient data →
        // effective == configured.
        // Without an HR feed the learned start may move later but not earlier: those sessions began on
        // the clock fallback, about 80 min before the configured start (AAPS Boost 6.3.3).
        let hrFeed = await hrFeedPresent(now: now, recent: hrReadings)
        let effectiveNightStart = SleepHistoryTracker.effectiveNightStartMin(
            learned: agg.sleepStartMinAvg, configured: configNightStart, hrFeedPresent: hrFeed
        )
        // Wake side is one-sided: learning may push the night end later than configured, never
        // earlier, so protection is never lifted before the configured wake. See the clamp's note.
        let effectiveNightEnd = Self.clampToConfiguredBand(agg.wakeMinAvg, configNightEnd, allowEarlier: false)
        let effectiveResting = agg.restingHrBpm.map(Double.init) ?? resting

        let nowMinute = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        // Per-source step history + today's cumulative counts. Fetched here (ahead of the sleep
        // detector) so the lump-tolerant genuine-wake evidence (2026-07-03, AAPS 5f7a481f28) can see
        // today's cumulative steps; also reused by the activity-load section below.
        let (multi, todayBySource, todayIndex) = await fetchStepsBySource(
            days: ActivityLoadTracker.Const.windowDays, now: now
        )
        // stepsToday = highest cumulative today count across all sources (AAPS: max(wear, phone)) —
        // -1 when no source reported, so the detector falls back to the legacy 15-min bucket.
        var stepsTodayCumulative = todayBySource.values.max() ?? -1
        if feed == .watch, let watchToday = watchActivityStorage.stepsToday(now: now, maxAge: Self.watchMaxStepAge) {
            // The watch's count when HealthKit has none (locked iPhone) or less, as AAPS takes max(wear, phone)
            stepsTodayCumulative = max(stepsTodayCumulative, watchToday)
        }
        let sleep = SleepStateDetector.step(
            SleepDetectorInputs(
                hrReadings: hrReadings,
                hrWindowMinutes: 5,
                restingHeartRate: effectiveResting,
                steps15min: steps15,
                nowMinuteOfDay: nowMinute,
                nightStartMinute: effectiveNightStart,
                nightEndMinute: effectiveNightEnd,
                preSleepLeadMin: 60,
                sleepHysteresisMin: 10,
                wakeHrHysteresisMin: 5,
                mlMealLikely: nil,
                nowMs: nowMs,
                autoBySleep: prefs.boostNightModeAutoBySleep,
                stepsToday: stepsTodayCumulative,
                // The lie-in hold, as AAPS passes it since Boost 6.3.2.
                sleepInStepsThreshold: Int(d(prefs.boostSleepInSteps)),
                sleepInWindowMin: Int(d(prefs.boostSleepInHours) * 60),
                hrFeedPresent: hrFeed
            ),
            prev?.sleepState ?? SleepDetectorState(state: .awake, enteredAtMs: nowMs)
        )
        let asleep = sleep.state == .sleeping
        if sleep.resumeBurstIgnored {
            // AAPS 5a1c852a57: a batched-upload burst after a drought, with no steps, in the core night.
            debug(.healthKit, "Boost sleep: resume-burst-ignored (no steps)")
        }
        // A boundary exit this refresh starts the hold; otherwise carry the last one forward.
        let lastBoundaryExitMs: Double? = sleep.wakeReason == "boundary" ? nowMs : prev?.lastSleepBoundaryExitMs
        if let reason = sleep.wakeReason, BoostActivityStore.genuineStepWakes.contains(reason) {
            BoostActivityStore.lastGenuineWakeMs = nowMs
        }

        // Activity classification runs AFTER the sleep detector because its inactivity branch is
        // excluded during sleep (AAPS 37a79aac83 / 483d2fec20) and needs this cycle's state. The
        // exclusions use the CONFIGURED night window rather than the learned one, matching the
        // Kotlin, and read it whether or not night mode is enabled. `inBed` here is SLEEPING or
        // PRE_SLEEP (the person is in bed for both), held for one hysteresis period after the
        // detector leaves SLEEPING by its clock boundary (AAPS a33752c9aa #18).
        let inNightWindow = NightMode.minuteInWindow(
            now: nowMinute, start: configNightStart, end: configNightEnd
        )
        let sleepSignals = BoostGate.sleepSignals(
            state: sleep.state,
            nightSleepPeriodRaw: BoostV5Adapter.nightSleepPeriod(
                preferences: prefs, minuteOfDay: nowMinute, sleepState: sleep.state
            ),
            nightModeEnabled: prefs.boostNightModeEnabled,
            autoBySleep: prefs.boostNightModeAutoBySleep,
            nowMs: nowMs,
            lastBoundaryExitMs: lastBoundaryExitMs,
            holdMin: BoostV5Adapter.sleepBoundaryHoldMin
        )
        let inBed = sleepSignals.detectorAsleep
        // Morning lie-in, computed locally from this cycle's steps rather than from the stored
        // snapshot (which is the previous cycle's). Window is [nightEnd, nightEnd + sleepInHours),
        // from the detector's effective night end since Boost 6.3.0 (AAPS 290348d59a).
        let sleepInMinutes = Int(d(prefs.boostSleepInHours) * 60)
        let lieIn: Bool = {
            guard sleepInMinutes > 0 else { return false }
            let windowEnd = (effectiveNightEnd + sleepInMinutes) % 1440
            guard NightMode.minuteInWindow(now: nowMinute, start: effectiveNightEnd, end: windowEnd)
            else { return false }
            return Double(steps60) < d(prefs.boostSleepInSteps)
        }()
        // Frozen-HR guard (AAPS 220d747d4d). A run of bit-identical readings across the 15-minute
        // averaging window is a stuck sensor value, not a heartbeat. Trusting a stuck elevated value
        // mis-fires resistance every cycle. Pass 0, which the classifier reads as no HR signal: no
        // HR-driven modifier, and with HR integration on the inactivity raise is withheld, since a
        // stuck value is not evidence of rest (AAPS a33752c9aa #12).
        let hrFrozen = ActivityClassifier.isHrWindowFrozen(
            readings: hrReadings, nowMs: nowMs, windowMinutes: 15
        )
        if hrFrozen {
            debug(.healthKit, "Boost activity: HR window frozen at \(avgHr) bpm — treating HR as unavailable")
        }
        // The Boost gate as the loop will see it (AAPS a33752c9aa #11). Classification runs whatever
        // it says; only the inactivity raise, which adds insulin, needs it open.
        let raiseGateOpen = BoostGate.isOpen(
            nightSleepPeriod: sleepSignals.nightSleepPeriod,
            inNightWindow: inNightWindow,
            v6Active: prefs.boostMode == .active,
            detectorSleeping: sleepSignals.detectorSleeping
        ) && !lieIn
        let activity = ActivityClassifier.classify(ActivityInputs(
            steps5: steps5, steps15: steps15, steps30: Int(steps30), steps60: steps60,
            avgHeartRate: hrFrozen ? 0 : avgHr,
            inNightWindow: inNightWindow, asleep: inBed, sleepInActive: lieIn,
            raiseGateOpen: raiseGateOpen,
            stepsAvailable: stepsAvailable,
            thresholds: thresholds
        ))

        // Record sleep/wake transitions into the rolling history (AAPS: onSleepStart on any
        // non-SLEEPING→SLEEPING; onWake on SLEEPING→non-SLEEPING, with HR p10 over the sleep
        // period + the preceding awake period). The learned aggregate then shapes future cycles.
        let prevSleepState = prev?.sleepState?.state ?? .awake
        if prevSleepState != .sleeping, sleep.state == .sleeping {
            BoostSleepHistoryStore.save(SleepHistoryTracker.onSleepStart(history, sleepStartMs: nowMs))
        } else if prevSleepState == .sleeping, sleep.state != .sleeping, let openStart = history.openSleepStartMs {
            let sleepHr = await fetchHrBpms(since: Date(timeIntervalSince1970: openStart / 1000.0), to: now)
            let daytimeHr: [Double]
            if let lastWake = SleepHistoryTracker.lastWakeMs(history), lastWake < openStart {
                daytimeHr = await fetchHrBpms(
                    since: Date(timeIntervalSince1970: lastWake / 1000.0),
                    to: Date(timeIntervalSince1970: openStart / 1000.0)
                )
            } else {
                daytimeHr = []
            }
            BoostSleepHistoryStore.save(SleepHistoryTracker.onWake(
                history, wakeMs: nowMs, sleepHrBpms: sleepHr, daytimeHrBpms: daytimeHr,
                wakeReason: sleep.wakeReason
            ))
        }

        // 3) Post-exercise recovery — config from settings.
        let recovery = PostExerciseRecovery.step(
            nowMs: nowMs,
            exerciseActive: activity.exerciseActive,
            exerciseType: activity.state.rawValue,
            config: PostExerciseConfig(
                recoveryHours: d(prefs.boostPostExerciseHours),
                recoveryTargetMgdl: d(prefs.boostPostExerciseTarget),
                recoveryScale: d(prefs.boostPostExerciseScale),
                minDurationMin: Int(d(prefs.boostPostExerciseMinDuration)),
                enabled: prefs.boostPostExerciseEnabled
            ),
            state: prev?.recoveryState ?? RecoveryState()
        )

        // 4) Activity-load source abstraction (SHADOW): pick the active step source across ALL
        // HealthKit writers (Apple Watch > Garmin > other > iPhone), build the per-source history,
        // and compute the bridged baseline + would-ΔISF. Telemetry only — not applied to dosing.
        // (multi/todayBySource/todayIndex fetched above, ahead of the sleep detector.)
        let freshSources = await freshStepSources(minutes: 20, now: now)
        let candidateSources = Set(multi.sources.keys).union(todayBySource.keys)
        let states = candidateSources.map { src in
            StepSourceResolver.SourceState(
                source: src,
                fresh: freshSources.contains(src),
                coverageDays: multi.sources[src]?.days.count ?? 0,
                stepsToday: todayBySource[src] ?? 0
            )
        }
        let stepRes = StepSourceResolver.resolve(states)
        // Baseline from the PHONE-ANCHORED rolling window — the iPhone runs continuously across watch
        // SWAPS (one watch ceases as the next starts → they never overlap), so it is the calibration
        // frame; worn sources are scaled into phone units. Replaces watch-to-watch bridging, which
        // could never calibrate a swap. (2026-07-02, AAPS a3bb4afc2a.)
        let bridged = ActivityLoadTracker.phoneAnchoredWindow(multi, todayIndex: todayIndex)
        let load = ActivityLoadTracker.compute(bridged.history, todayIndex: todayIndex)
        // Intraday "running hot?" — today's count converted to PHONE units so it matches the
        // phone-anchored baseline (worn-source today × phone/worn calibration).
        let stepsTodayPhone = ActivityLoadTracker.toPhoneUnits(
            steps: stepRes.stepsToday, activeSource: stepRes.active, multi: multi
        )
        let intraday = ActivityLoadTracker.intradayLoad(
            stepsToday: stepsTodayPhone,
            baseline: load.baselineSteps,
            hourOfDay: Calendar.current.component(.hour, from: now)
        )
        let bridgeNote = bridged.donorsUsed.isEmpty
            ? "phone"
            : "phone<-" + bridged.donorsUsed.joined(separator: "+") + (bridged.calibrated ? "" : "(raw)")

        // 5) HR source visibility (SHADOW) — which device feeds HR + silent-death detection.
        let hrSourceReadings: [HrSourceResolver.Reading]
        if feed == .watch {
            hrSourceReadings = watchActivityStorage.heartRates(since: now.addingTimeInterval(-16 * 60)).map {
                HrSourceResolver.Reading(device: "Apple Watch", timestamp: $0.date)
            }
        } else {
            hrSourceReadings = await fetchHrSourceReadings(since: now.addingTimeInterval(-16 * 60), now: now)
        }
        let hrRes = HrSourceResolver.resolve(hrSourceReadings, now: now)

        let snap = BoostActivitySnapshot(
            steps30min: steps30,
            steps60min: Double(steps60),
            latestHeartRate: latestHr,
            restingHeartRate: restingHr,
            exerciseActive: activity.exerciseActive,
            inPostExerciseWindow: recovery.inRecoveryWindow,
            asleep: asleep,
            exerciseState: activity.state.rawValue,
            profilePercent: activity.profilePercent,
            targetBgMgdl: activity.targetBgMgdl,
            lastExerciseAt: activity.exerciseActive ? now : prev?.lastExerciseAt,
            sleepState: sleep,
            recoveryState: recovery.newState,
            stepSource: stepRes.active,
            stepSourceStates: stepRes.note,
            activityBaselineSteps: load.baselineSteps,
            activityRatio: load.ratio,
            activityWouldDeltaIsfPct: load.wouldDeltaIsfPct,
            activityIntradayDeltaIsfPct: intraday,
            activityBridge: bridgeNote,
            hrSource: hrRes.active,
            hrSourceStates: hrRes.note,
            lastSleepBoundaryExitMs: lastBoundaryExitMs,
            effectiveNightEndMin: effectiveNightEnd,
            updatedAt: now
        )
        BoostActivityStore.shared.snapshot = snap

        debug(
            .healthKit,
            "BoostActivityMonitor: feed=\(feed.rawValue) steps5/15/30/60=\(steps5)/\(steps15)/\(Int(steps30))/\(steps60) hr=\(Int(latestHr)) rhr=\(Int(restingHr)) state=\(activity.state.rawValue) asleep=\(asleep) postEx=\(recovery.inRecoveryWindow) gate=\(raiseGateOpen)\(sleepSignals.boundaryHold ? " boundaryHold" : "")\(stepsAvailable ? "" : " steps:UNAVAILABLE")\(inputs.stepsReliable ? "" : " steps:LATE")"
        )
        debug(
            .healthKit,
            "BoostActivitySource: step=\(stepRes.active ?? "none") [\(stepRes.note)] base=\(load.baselineSteps.map { String(Int($0)) } ?? "nil") ratio=\(load.ratio.map { String(format: "%.2f", $0) } ?? "nil") wouldΔISF=\(load.wouldDeltaIsfPct.map { String(format: "%.1f", $0) } ?? "nil")% bridge=\(bridgeNote) hr=\(hrRes.active ?? "none") [\(hrRes.note)]"
        )
    }

    // MARK: - Recent inputs

    private func healthKitRecentInputs(now: Date) async -> RecentInputs {
        async let steps5Task = sumSteps(since: now.addingTimeInterval(-300), now: now)
        async let steps15Task = sumSteps(since: now.addingTimeInterval(-900), now: now)
        async let steps30Task = sumSteps(since: now.addingTimeInterval(-1800), now: now)
        async let steps60Task = sumSteps(since: now.addingTimeInterval(-3600), now: now)
        async let hrAvgTask = avgQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let latestHrTask = latestQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let restingTask = latestQuantity(restingHRType, unit: bpmUnit, since: now.addingTimeInterval(-7 * 86400), now: now)
        // Raw HR samples for the sleep detector: it computes its own duration-weighted average
        // AND freshness/drought from per-sample timestamps. ~16 min covers the 5-min average
        // window, the 10-min freshness cutoff, and the 15-min fresh-sample count. Drought beyond
        // this window is carried by the persisted lastFreshHrSampleMs.
        async let hrReadingsTask = fetchHrReadings(since: now.addingTimeInterval(-16 * 60), now: now)

        return await RecentInputs(
            stepSums: [steps5Task, steps15Task, steps30Task, steps60Task],
            avgHr: hrAvgTask,
            latestHr: latestHrTask,
            restingHr: restingTask,
            hrReadings: hrReadingsTask
        )
    }

    /// The same inputs from the watch's data.
    ///
    /// Steps: the windows end at the newest minute the watch sent, not at "now", because the minutes
    /// since the last sensor wake are still on the watch and would otherwise read as 0 steps, which the
    /// classifier takes for rest. A window is unavailable (nil) when the newest minute is older than
    /// `watchMaxStepAge` or a minute in it is missing. When the watch reads steps from its HealthKit store
    /// (CoreMotion restricted) or the source is not known yet, the newest minutes can read too low: the
    /// counts still go to activity detection, where too low only detects exercise late, but the feed counts
    /// as unavailable, so a low count never raises insulin for inactivity.
    ///
    /// Heart rate: the same windows before "now" as the HealthKit feed. Each sample carries the time the
    /// watch measured it, so stale values fall out of the windows by themselves.
    private func watchRecentInputs(now: Date) -> RecentInputs {
        let stepSource = watchActivityStorage.latestStatus()?.stepSource
        // Unknown (no status since launch) or HealthKit-backed: not reliable enough to read as rest
        let stepsReliable = stepSource == "motion"
        let stepSums: [Double?] = [5, 15, 30, 60].map { minutes in
            guard let count = watchActivityStorage.stepCount(
                      minutesEndingAtNewest: minutes, now: now, maxAge: Self.watchMaxStepAge
                  )
            else { return nil }
            return Double(count)
        }

        let samples16 = watchActivityStorage.heartRates(since: now.addingTimeInterval(-16 * 60))
            .filter { $0.date <= now }
        let samples15 = samples16.filter { $0.date >= now.addingTimeInterval(-15 * 60) }
        let avgHr = samples15.isEmpty ? nil : samples15.reduce(0) { $0 + $1.bpm } / Double(samples15.count)
        let latestHr = samples15.last?.bpm
        let resting = watchActivityStorage.latestRestingHeartRate()
            .flatMap { now.timeIntervalSince($0.date) <= 7 * 86400 ? $0.bpm : nil }
        let hrReadings = samples16.map {
            // Instantaneous samples: 1 s nominal duration, as for HealthKit samples
            SleepHrReading(timestampMs: $0.date.timeIntervalSince1970 * 1000.0, beatsPerMinute: $0.bpm, durationMs: 1000.0)
        }

        return RecentInputs(
            stepSums: stepSums,
            stepsReliable: stepsReliable,
            avgHr: avgHr,
            latestHr: latestHr,
            restingHr: resting,
            hrReadings: hrReadings
        )
    }

    /// Any error but `errorNoData`, which is how HealthKit reports a window with no samples (0 steps).
    /// A locked iPhone gives `errorDatabaseInaccessible`. `HealthKit.` because Trio has its own HKError.
    static func stepReadFailed(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain != HKErrorDomain || error.code != HealthKit.HKError.Code.errorNoData.rawValue
    }

    /// nil when the read failed.
    private func sumSteps(since: Date, now: Date) async -> Double? {
        guard let stepType else { return 0 }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if Self.stepReadFailed(error) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
                }
            }
            healthKitStore.execute(query)
        }
    }

    /// Any valid HR in the last `SleepStateConstants.hrFeedLookbackHours`. A failed query, which is
    /// what HealthKit returns while the phone is locked, keeps the cached answer.
    private func hrFeedPresent(now: Date, recent: [SleepHrReading]) async -> Bool {
        if recent.contains(where: \.isValid) {
            hrFeedPresentCached = true
            hrFeedCheckedAt = now
        } else if now.timeIntervalSince(hrFeedCheckedAt) >= 30 * 60,
                  let any = await anyHrSample(
                      since: now.addingTimeInterval(-Double(SleepStateConstants.hrFeedLookbackHours) * 3600),
                      now: now
                  )
        {
            hrFeedPresentCached = any
            hrFeedCheckedAt = now
        }
        return hrFeedPresentCached
    }

    /// Whether HealthKit holds at least one HR sample in [since, now]; nil when the query failed.
    private func anyHrSample(since: Date, now: Date) async -> Bool? {
        if feed == .watch {
            return watchActivityStorage.heartRates(since: since).contains { $0.date <= now }
        }
        guard let hrType else { return false }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: HKQuery.predicateForSamples(withStart: since, end: now),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                continuation.resume(returning: error == nil ? !(samples ?? []).isEmpty : nil)
            }
            healthKitStore.execute(query)
        }
    }

    /// Raw HR samples in the window, mapped to `SleepHrReading` for the sleep detector. Each
    /// sample's `timestampMs` is its end date; `durationMs` is the sample span floored at a 1 s
    /// nominal so HealthKit's (typically instantaneous) samples make the detector's duration-
    /// weighted average degrade to a simple mean rather than divide-by-zero.
    private func fetchHrReadings(since: Date, now: Date) async -> [SleepHrReading] {
        guard let hrType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let readings = (samples as? [HKQuantitySample] ?? []).map { s in
                    SleepHrReading(
                        timestampMs: s.endDate.timeIntervalSince1970 * 1000.0,
                        beatsPerMinute: s.quantity.doubleValue(for: self.bpmUnit),
                        durationMs: max(s.endDate.timeIntervalSince(s.startDate) * 1000.0, 1000.0),
                        isValid: true
                    )
                }
                continuation.resume(returning: readings)
            }
            healthKitStore.execute(query)
        }
    }

    /// HR sample BPM values over an arbitrary [since, to] window — used at a SLEEPING→AWAKE
    /// transition to summarise the just-ended sleep period (and the preceding awake period) into
    /// p10s for SleepHistoryTracker. Empty if no HR access / no samples.
    private func fetchHrBpms(since: Date, to: Date) async -> [Double] {
        if feed == .watch {
            // The watch data covers the last 24 h; a longer window is summarised from what is kept
            return watchActivityStorage.heartRates(since: since).filter { $0.date <= to }.map(\.bpm)
        }
        guard let hrType, to > since else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: to)
            let query = HKSampleQuery(
                sampleType: hrType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                let bpms = (samples as? [HKQuantitySample] ?? []).map { $0.quantity.doubleValue(for: self.bpmUnit) }
                continuation.resume(returning: bpms)
            }
            healthKitStore.execute(query)
        }
    }

    private func avgQuantity(_ type: HKQuantityType?, unit: HKUnit, since: Date, now: Date) async -> Double? {
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            healthKitStore.execute(query)
        }
    }

    private func latestQuantity(_ type: HKQuantityType?, unit: HKUnit, since: Date, now: Date) async -> Double? {
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            healthKitStore.execute(query)
        }
    }

    // MARK: - Activity-load source abstraction (2026-06-28, SHADOW)

    /// Local epoch-day index — mirrors AAPS `DailyStepHistoryTracker.dayIndex`.
    private func dayIndex(_ date: Date, _ offsetMs: Double) -> Int {
        Int((date.timeIntervalSince1970 * 1000.0 + offsetMs) / 86_400_000.0)
    }

    /// Canonical source id for an `HKSource` — prefer its name (Apple Watch / iPhone carry the device
    /// name; Garmin's name "Garmin Connect" and bundle both contain "garmin").
    private func canonicalId(_ source: HKSource) -> String {
        StepSourceResolver.canonical(source.name.isEmpty ? source.bundleIdentifier : source.name)
    }

    /// Per-source COMPLETED-day step totals over `days` days + today-by-source, via one
    /// statistics-collection query split by source. HealthKit is the persistent per-source store, so
    /// the multi-source history is rebuilt each refresh (no app-side persistence needed).
    private func fetchStepsBySource(days: Int, now: Date)
    async -> (multi: ActivityLoadTracker.MultiSourceHistory, todayBySource: [String: Int], todayIndex: Int)
    {
        guard let stepType else { return (.init(), [:], 0) }
        let cal = Calendar.current
        let offsetMs = Double(cal.timeZone.secondsFromGMT(for: now)) * 1000.0
        let todayIndex = dayIndex(now, offsetMs)
        let anchor = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -days, to: anchor) ?? anchor
        var interval = DateComponents()
        interval.day = 1
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource],
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var perSource: [String: [ActivityLoadTracker.DailyStepTotal]] = [:]
                var todayBySource: [String: Int] = [:]
                collection?.enumerateStatistics(from: start, to: now) { stats, _ in
                    let di = self.dayIndex(stats.startDate, offsetMs)
                    for src in stats.sources ?? [] {
                        guard let qty = stats.sumQuantity(for: src) else { continue }
                        let steps = Int(qty.doubleValue(for: .count()))
                        if steps <= 0 { continue }
                        let canon = self.canonicalId(src)
                        if di < todayIndex {
                            perSource[canon, default: []].append(.init(dayIndex: di, steps: steps, source: canon))
                        } else {
                            todayBySource[canon, default: 0] += steps
                        }
                    }
                }
                var multi = ActivityLoadTracker.MultiSourceHistory()
                for (src, totals) in perSource {
                    multi = ActivityLoadTracker.mergeSource(multi, source: src, totals: totals, todayIndex: todayIndex)
                }
                continuation.resume(returning: (multi, todayBySource, todayIndex))
            }
            healthKitStore.execute(query)
        }
    }

    /// Canonical step sources that produced steps in the last `minutes` minutes — the "fresh" set.
    private func freshStepSources(minutes: Double, now: Date) async -> Set<String> {
        guard let stepType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-minutes * 60), end: now)
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource]
            ) { _, stats, _ in
                var fresh = Set<String>()
                for src in stats?.sources ?? [] {
                    if let qty = stats?.sumQuantity(for: src), qty.doubleValue(for: .count()) > 0 {
                        fresh.insert(self.canonicalId(src))
                    }
                }
                continuation.resume(returning: fresh)
            }
            healthKitStore.execute(query)
        }
    }

    /// Recent HR samples tagged with their source, for `HrSourceResolver` (visibility only).
    private func fetchHrSourceReadings(since: Date, now: Date) async -> [HrSourceResolver.Reading] {
        guard let hrType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKSampleQuery(
                sampleType: hrType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                let readings = (samples as? [HKQuantitySample] ?? []).map { s in
                    HrSourceResolver.Reading(device: s.sourceRevision.source.name, timestamp: s.endDate)
                }
                continuation.resume(returning: readings)
            }
            healthKitStore.execute(query)
        }
    }
}
