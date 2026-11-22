import Foundation

/// What the V1 engine needs from outside the determination: the SMB record from pump history, and
/// whether this cycle may persist learned state (the ML ring buffer). A bolus-calculator preview runs
/// the determination repeatedly and must leave that state alone.
struct BoostV1CycleContext {
    var recentSmbVolume60Min: Double
    var timeSinceLastSmbMin: Double
    var persistState: Bool

    static let preview = BoostV1CycleContext(recentSmbVolume60Min: 0, timeSinceLastSmbMin: 720, persistState: false)

    /// AAPS recentSmbVolume60Min / timeSinceLastSmbMin: SMBs only, summed over the last 60 minutes,
    /// minutes since the latest capped at 720 (720 when there is none).
    static func from(pumpHistory: [PumpHistoryEvent], clock: Date, persistState: Bool) -> BoostV1CycleContext {
        let smbEvents = pumpHistory.filter { ($0.isSMB ?? false) && $0.timestamp <= clock }
        let sixtyMinAgo = clock.addingTimeInterval(-3600)
        let recent = smbEvents
            .filter { $0.timestamp >= sixtyMinAgo }
            .reduce(0.0) { $0 + (($1.amount ?? 0) as NSDecimalNumber).doubleValue }
        let since = smbEvents.map(\.timestamp).max()
            .map { min(720.0, clock.timeIntervalSince($0) / 60.0) } ?? 720.0
        return BoostV1CycleContext(recentSmbVolume60Min: recent, timeSinceLastSmbMin: since, persistState: persistState)
    }
}

/// What the V1 engine computed that the V6 seam reads, carried on the Determination outside its
/// serialised form (as cobProjection is), so the stored and uploaded JSON is unchanged.
struct BoostV1Telemetry: Equatable {
    var tier: String
    var mlHypoRisk: Double?
    var mlMealLikely: Double?
    var mlRiskScale: Double?
    /// The target the engine was given, before its own autosens, hypo-prediction and high-BG
    /// adjustments. AAPS's V6 reads this (opb.target_bg), not V1's adjusted target.
    var inputTargetBg: Double
    /// min(Boost max IOB, max IOB), the IOB ceiling AAPS gives V6 and the confirm tranche.
    var v6MaxIob: Double
    var lgsThreshold: Double?
    /// Lowest glucose in the last 60 minutes (AAPS recentLowBG), 999 when there is none.
    var recentLowBg: Double
    var boostActive: Bool
    var sleepInActive: Bool
    var cumulativeCapReached: Bool
    var recentSmbVolume60Min: Double
    var timeSinceLastSmbMin: Double
}

/// Runs AAPS's V1 Boost engine (BoostV1Engine, a parity-checked port of DetermineBasalBoost) as the
/// Boost-active determination. Every input is assembled as OpenAPSBoostPlugin assembles it.
enum BoostV1Determination {
    private static func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
    private static func dbl(_ d: Decimal?) -> Double? { d.map { ($0 as NSDecimalNumber).doubleValue } }

    /// Boost's IOB limit: min(Boost max IOB, max IOB), read on every cycle, so at the 12 U default it
    /// follows a change to max IOB (up to 12) and is 0 in a dosing mode that sets max IOB to 0. Passed
    /// to V1 already reduced, as AAPS passes boost_maxIOB, so its tier guards see the operative limit.
    static func boostMaxIob(preferences: Preferences, profile: Profile) -> Double {
        min(dbl(preferences.boostMaxIOB), dbl(profile.maxIob))
    }

    /// Lowest glucose in the last 60 minutes (AAPS recentLowBG), 999 when there is no reading.
    static func recentLowBg60Min(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = glucose.filter { $0.dateString >= cutoff && $0.dateString <= now }.compactMap(\.sgv)
        return recent.min().map(Double.init) ?? 999
    }

    /// AAPS insulin peak for Boost: the insulin's peak in whole minutes, coerced to 30…75.
    static func insulinPeakMinutes(profile: Profile, preferences: Preferences) -> Int {
        let peak: Double
        if preferences.useCustomPeakTime {
            peak = dbl(profile.insulinPeakTime)
        } else {
            switch profile.curve {
            case .ultraRapid: peak = 55
            default: peak = 75
            }
        }
        return min(max(Int(peak.rounded()), 30), 75)
    }

    /// The post-rescue tight-ramp trial cap for this cycle (AAPS tightRampArm on the LOCAL day index),
    /// nil when not enrolled or on a control day.
    static func tightRampCap(preferences: Preferences, clock: Date, calendar: Calendar = .current) -> Double? {
        guard preferences.boostV5PostRescueTightRampTrial else { return nil }
        return PostRescueTrial.tightRampArm(seed: BoostTrialSeed.seed, dayIndex: localDayIndex(clock, calendar: calendar))
            ? BoostV1Engine.tightRampCap : nil
    }

    /// Days since 1970-01-01 in the local calendar (java.time LocalDate.toEpochDay).
    static func localDayIndex(_ clock: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: clock)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: comps) ?? clock
        return Int((midnight.timeIntervalSince1970 / 86400).rounded(.down))
    }

    /// AAPS LoopPlugin's "safety check for multiple SMBs", which runs after the APS has returned and
    /// zeroes whatever SMB it asked for while the newest bolus is younger than the SMB interval
    /// (ApsMaxSmbFrequency). It covers the V6 dose and V1's alike. V1 has its own check with six
    /// seconds of slack, so on a loop that runs a few seconds short of the interval V1 doses and this
    /// check withholds it. No bolus on record (lastBolusTime 0 or absent) never blocks.
    static func smbFrequencyExceeded(lastBolusTimeMs: UInt64?, now: Date, smbIntervalMin: Decimal) -> Bool {
        guard let last = lastBolusTimeMs, last != 0 else { return false }
        let intervalMs = Double(truncating: (smbIntervalMin * 60000) as NSDecimalNumber)
        return Double(last) + intervalMs > now.timeIntervalSince1970 * 1000
    }

    /// The Boost gate (AAPS calculateBoostActivity's boostActive): closed in the night window or
    /// night/sleep period, while SLEEPING under V6, under a high temp target unless allowed, and in
    /// a step-confirmed morning lie-in.
    static func boostActive(
        profile: Profile,
        preferences: Preferences,
        clock: Date
    ) -> (active: Bool, sleepIn: Bool) {
        var active = BoostV5Adapter.boostGateOpen(preferences: preferences, clock: clock)
        if active, profile.temptargetSet ?? false, !preferences.boostAllowWithHighTt {
            let tt = ((profile.minBg ?? 100) + (profile.maxBg ?? profile.minBg ?? 100)) / 2
            if tt > preferences.boostDynIsfNormalTarget { active = false }
        }
        let sleepIn = BoostV5Adapter.sleepInActive(preferences: preferences, clock: clock)
        if active, sleepIn { active = false }
        return (active, sleepIn)
    }

    /// The Determination for Boost active mode. Nil inputs the stock path checks are checked here too.
    static func determine(
        profile: Profile,
        preferences: Preferences,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        orefAutosensRatio: Decimal,
        glucoseStatus: GlucoseStatus,
        glucose: [BloodGlucose],
        microBolusAllowed: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date,
        context: BoostV1CycleContext
    ) throws -> Determination {
        guard let currentIob = iobData.first else { throw DeterminationError.missingIob }

        // Activity profile % from the classifier snapshot, fresh-guarded (≤30 min), as the stock
        // Boost path reads it. 100 means none.
        let profilePercent: Double = {
            guard let snap = BoostActivityStore.shared.snapshot,
                  currentTime.timeIntervalSince(snap.updatedAt) <= 1800 else { return 100 }
            return snap.profilePercent
        }()
        let profileScale = profilePercent / 100.0

        // Targets: the profile's (a temp target is already in them), an override target in its place
        // when one is set, then the V6 pre-meal target, lower only.
        var minBg = profile.minBg ?? 100
        var maxBg = profile.maxBg ?? minBg
        let overrideTarget = trioCustomOrefVariables.overrideTarget
        if trioCustomOrefVariables.useOverride, overrideTarget != 0, overrideTarget != 6, !(profile.temptargetSet ?? false) {
            minBg = overrideTarget
            maxBg = overrideTarget
        }
        let recentLow45 = BoostV5Adapter.recentLowBg45Min(glucose, now: currentTime)
        let preMeal = DeterminationGenerator.boostPreMealTarget(
            preferences: preferences,
            profile: profile,
            currentTargetGlucose: (minBg + maxBg) / 2,
            recentLowBg45Min: recentLow45,
            currentTime: currentTime
        )
        if let pre = preMeal.target {
            minBg = min(minBg, pre)
            maxBg = min(maxBg, pre)
        }

        // Sensitivity, as OpenAPSBoostPlugin builds it: the override-adjusted profile ISF, scaled by
        // the activity profile %, with autosens folded in at target where it applies.
        let baseSensitivity = profile.sens ?? profile.sensitivityFor(time: currentTime)
        let profileSens = trioCustomOrefVariables.override(sensitivity: baseSensitivity)
        let autosens = BoostISF.AutosensContext.make(
            orefRatio: orefAutosensRatio,
            isTempTarget: profile.temptargetSet ?? false,
            targetBg: profile.profileTarget(trioCustomOrefVariables: trioCustomOrefVariables) ?? 120,
            profile: profile,
            preferences: preferences
        )
        let tdd = trioCustomOrefVariables.tdd(profile: profile)
        let isf = BoostISF.v1Inputs(
            profileSens: profileSens,
            currentGlucose: glucoseStatus.glucose,
            tdd: tdd,
            profilePercent: profilePercent,
            autosens: autosens,
            profile: profile,
            preferences: preferences
        )
        let sensitivityRatio = dbl(BoostISF.sensitivityRatio(autosens: autosens, preferences: preferences))

        let pumpBasal = dbl(profile.currentBasal ?? profile.basalFor(time: currentTime)) *
            dbl(trioCustomOrefVariables.overrideFactor())
        let currentBasal = profilePercent != 100 ? pumpBasal * profileScale : pumpBasal

        let profileCarbRatio = profile.carbRatio ?? profile.carbRatioFor(time: currentTime)
        let carbRatio: Decimal = trioCustomOrefVariables
            .useOverride && (trioCustomOrefVariables.cr || trioCustomOrefVariables.isfAndCr)
            ? profileCarbRatio / (trioCustomOrefVariables.overridePercentage / 100)
            : profileCarbRatio

        var smbMinutes = profile.maxSMBBasalMinutes
        var uamMinutes = profile.maxUAMSMBBasalMinutes
        if trioCustomOrefVariables.useOverride, trioCustomOrefVariables.advancedSettings {
            smbMinutes = trioCustomOrefVariables.smbMinutes
            uamMinutes = trioCustomOrefVariables.uamMinutes
        }

        let gate = boostActive(profile: profile, preferences: preferences, clock: currentTime)

        // Post-exercise recovery scales the bolus cap and the boost scale (AAPS boost_bolus and
        // boost_scale while now < recoveryWindowEnd).
        var recoveryScale = 1.0
        if preferences.boostPostExerciseEnabled,
           let recovery = BoostActivityStore.shared.snapshot?.recoveryState,
           currentTime.timeIntervalSince1970 * 1000 < recovery.recoveryWindowEndMs
        {
            recoveryScale = recovery.activeRecoveryScale
        }

        let insulinPeak = insulinPeakMinutes(profile: profile, preferences: preferences)
        let insulinDivisor = insulinPeak < 60 ? (90 - insulinPeak) + 30 : (90 - insulinPeak) + 40
        let recentLow60 = recentLowBg60Min(glucose, now: currentTime)

        let v1Profile = V1Profile(
            maxIob: dbl(profile.maxIob),
            maxDailyBasal: dbl(profile.maxDailyBasal ?? 0),
            maxBasal: dbl(profile.maxBasal ?? 0),
            minBg: dbl(minBg),
            maxBg: dbl(maxBg),
            carbRatio: dbl(carbRatio),
            sens: dbl(profileSens),
            maxDailySafetyMultiplier: dbl(profile.maxDailySafetyMultiplier),
            currentBasalSafetyMultiplier: dbl(profile.currentBasalSafetyMultiplier),
            sensitivityRaisesTarget: true,
            resistanceLowersTarget: true,
            advTargetAdjustments: true,
            halfBasalExerciseTarget: 160,
            skipNeutralTemps: profile.skipNeutralTemps,
            remainingCarbsCap: Int(dbl(profile.remainingCarbsCap)),
            enableUAM: profile.enableUAM,
            smbInterval: Int(dbl(profile.smbInterval)),
            enableSMBWithCOB: profile.enableSMBWithCOB,
            enableSMBWithTemptarget: profile.enableSMBWithTemptarget,
            allowSMBWithHighTemptarget: profile.allowSMBWithHighTemptarget,
            enableSMBAlways: profile.enableSMBAlways,
            enableSMBAfterCarbs: profile.enableSMBAfterCarbs,
            maxSMBBasalMinutes: Int(dbl(smbMinutes)),
            maxUAMSMBBasalMinutes: Int(dbl(uamMinutes)),
            bolusIncrement: dbl(profile.bolusIncrement),
            carbsReqThreshold: Int(dbl(profile.carbsReqThreshold)),
            currentBasal: currentBasal,
            temptargetSet: profile.temptargetSet ?? false,
            autosensMax: dbl(profile.autosensMax),
            lgsThreshold: Int(dbl(profile.thresholdSetting)),
            variableSens: isf.variableSens,
            insulinDivisor: insulinDivisor,
            tdd: isf.tdd,
            dynISFBgCap: dbl(preferences.boostDynIsfBgCap),
            dynISFBgCapped: isf.bgCapped,
            sensNormalTarget: isf.sensNormalTarget,
            normalTarget: dbl(preferences.boostDynIsfNormalTarget),
            dynISFvelocity: BoostISF.effectiveVelocity(preferences),
            insulinPeak: insulinPeak,
            boostActive: gate.active,
            profileSwitch: Int(profilePercent.rounded()),
            boostBolus: dbl(preferences.boostBolus) * recoveryScale,
            boostMaxIOB: boostMaxIob(preferences: preferences, profile: profile),
            boostInsulinReq: dbl(preferences.boostInsulinReqPct),
            boostScale: dbl(preferences.boostScale) * recoveryScale,
            boostPercentScale: dbl(preferences.boostPercentScale),
            enableBoostPercentScale: preferences.boostEnablePercentScale,
            enableCircadianISF: preferences.boostEnableCircadianIsf,
            recentLowBG: recentLow60,
            dynIsfMode: true
        )

        let lastBolusMs = currentIob.lastBolusTime.map(Double.init) ?? 0
        let ticks = iobData.enumerated().map { index, tick in
            V1IobTick(
                iob: dbl(tick.iob),
                activity: dbl(tick.activity),
                basaliob: dbl(tick.basaliob),
                netbasalinsulin: dbl(tick.netbasalinsulin),
                lastBolusTime: index == 0 ? lastBolusMs : 0,
                zeroTempActivity: dbl(tick.iobWithZeroTemp.activity)
            )
        }

        let ml = BoostV1MlBridge(persist: context.persistState, clock: currentTime)
        let cumulativeCap = dbl(preferences.boostCumulativeSmbCap60Min)

        // The user's explicit SMB-off levers (master switch, scheduled off-window) stand in Boost too,
        // so the engine sees no microbolus permission while they hold.
        let leversOff = (try? DosingEngine.smbHardDisabledByUserLevers(
            profile: profile,
            adjustedTargetGlucose: (minBg + maxBg) / 2,
            trioCustomOrefVariables: trioCustomOrefVariables,
            clock: currentTime
        )) ?? false

        let input = V1Inputs(
            glucoseStatus: V1GlucoseStatus(
                glucose: dbl(glucoseStatus.glucose),
                noise: Double(glucoseStatus.noise),
                delta: dbl(glucoseStatus.delta),
                shortAvgDelta: dbl(glucoseStatus.shortAvgDelta),
                longAvgDelta: dbl(glucoseStatus.longAvgDelta),
                date: glucoseStatus.date.timeIntervalSince1970 * 1000
            ),
            currentTemp: V1CurrentTemp(duration: Int(currentTemp.duration), rate: dbl(currentTemp.rate)),
            iobArray: ticks,
            profile: v1Profile,
            autosensRatio: sensitivityRatio,
            meal: V1MealData(
                carbs: dbl(mealData.carbs),
                mealCOB: dbl(mealData.mealCOB),
                lastCarbTime: mealData.lastCarbTime,
                slopeFromMaxDeviation: dbl(mealData.slopeFromMaxDeviation),
                slopeFromMinDeviation: dbl(mealData.slopeFromMinDeviation)
            ),
            microBolusAllowed: microBolusAllowed && !leversOff,
            currentTime: currentTime.timeIntervalSince1970 * 1000,
            flatBGsDetected: false,
            ml: V1MlModels(hypoRisk: ml.hypoRisk, mealLikely: ml.mealLikely),
            recentSmbVolume60Min: context.recentSmbVolume60Min,
            cumulativeSmbCap60Min: cumulativeCap,
            recentLowBG45Min: recentLow45,
            timeSinceLastSmbMin: context.timeSinceLastSmbMin,
            postRescueTightRampCap: tightRampCap(preferences: preferences, clock: currentTime)
        )

        let rT = try BoostV1Engine.determineBasal(input)
        ml.persistIfNeeded()

        var reason =
            "Autosens ratio: \(fmt(sensitivityRatio)), ISF: \(profileSens.jsRounded())→\(fmt(rT.variableSens ?? isf.variableSens)), "
        reason += rT.reason
        reason += " Boost V1 tier \(rT.boostTier)" + (gate.active ? "" : " (Boost inactive)") + ";"
        if leversOff { reason += " SMB off (user lever);" }
        if preferences.boostV5PostRescueTightRampTrial {
            reason += " prTrial=\(input.postRescueTightRampCap != nil ? "tight" : "control");"
        }
        if let note = preMeal.note { reason += " " + note }

        var determination = Determination(
            id: UUID(),
            reason: reason,
            units: rT.units.map { Decimal($0) },
            insulinReq: rT.insulinReq.map { Decimal($0) },
            eventualBG: rT.eventualBG.map { Int($0.rounded()) },
            sensitivityRatio: rT.sensitivityRatio.map { Decimal($0) },
            rate: rT.rate.map { Decimal($0) },
            duration: rT.duration.map { Decimal($0) },
            iob: currentIob.iob,
            cob: mealData.mealCOB.jsRounded(),
            predictions: rT.predIOB == nil ? nil : Predictions(
                iob: rT.predIOB,
                zt: rT.predZT,
                cob: rT.predCOB,
                uam: rT.predUAM
            ),
            deliverAt: currentTime,
            carbsReq: rT.carbsReq.map { Decimal($0) },
            temp: rT.rate == nil ? nil : .absolute,
            bg: glucoseStatus.glucose,
            reservoir: nil,
            isf: rT.variableSens.map { Decimal($0) },
            timestamp: currentTime,
            tdd: nil,
            current_target: rT.targetBG.map { Decimal($0) },
            minDelta: rT.minDelta.map { Decimal($0) },
            expectedDelta: rT.expectedDelta.map { Decimal($0) },
            minGuardBG: rT.minGuardBG.map { Decimal($0) },
            minPredBG: rT.minPredBG.map { Decimal($0) },
            threshold: rT.threshold.map { Decimal($0) },
            carbRatio: carbRatio.jsRounded(scale: 1),
            received: false
        )
        determination.boostV1 = BoostV1Telemetry(
            tier: rT.boostTier,
            mlHypoRisk: rT.mlHypoRisk,
            mlMealLikely: rT.mlMealLikely,
            mlRiskScale: rT.mlRiskScale,
            inputTargetBg: dbl((minBg + maxBg) / 2),
            v6MaxIob: boostMaxIob(preferences: preferences, profile: profile),
            lgsThreshold: dbl(profile.thresholdSetting),
            recentLowBg: recentLow60,
            boostActive: gate.active,
            sleepInActive: gate.sleepIn,
            cumulativeCapReached: cumulativeCap > 0 && context.recentSmbVolume60Min >= cumulativeCap,
            recentSmbVolume60Min: context.recentSmbVolume60Min,
            timeSinceLastSmbMin: context.timeSinceLastSmbMin
        )
        debug(
            .algorithm,
            "Boost V1: tier=\(rT.boostTier) units=\(rT.units.map { fmt($0) } ?? "-") rate=\(rT.rate.map { fmt($0) } ?? "-") " +
                "duration=\(rT.duration.map(String.init) ?? "-") insulinReq=\(rT.insulinReq.map { fmt($0) } ?? "-") " +
                "boostActive=\(gate.active) console: \(rT.console.joined(separator: " | "))"
        )
        return determination
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

/// The ML models as the V1 engine consults them, mirroring AAPS DetermineBasalBoost: the v12 hypo model
/// on its 53-feature vector built from the engine's own values and the persisted six-cycle ring buffer,
/// or the legacy 8-feature path when that is what is loaded; the meal model on its 8 features. The ring
/// buffer is pushed only when the engine reaches the dosing section, as in AAPS, and saved only when
/// the cycle may persist state.
final class BoostV1MlBridge {
    private var ring: BoostMlFeatureBuilder.RingBuffer?
    private let persist: Bool
    private let hour: Double

    init(persist: Bool, clock: Date) {
        self.persist = persist
        hour = Double(Calendar.current.component(.hour, from: clock))
    }

    private func features8(_ m: V1MlInputs) -> BoostMLModels.Features {
        BoostMLModels.Features(
            cgmMgdl: m.bg,
            iobTotal: m.iob,
            iobBasal: m.basaliob,
            bgAboveTarget: m.bg - m.targetBg,
            directionNum: m.directionNum,
            hour: hour,
            iobActivity: m.activity,
            insulinReq: m.insulinReq
        )
    }

    lazy var hypoRisk: (V1MlInputs) -> Double? = { [unowned self] m in
        guard let names = BoostMLModels.hypoFeatureNames(), names.count != 8 else {
            return BoostMLModels.hypoRisk(self.features8(m))
        }
        let statics: [String: Double] = [
            "cgm_mgdl": m.bg,
            "iob_iob": m.iob,
            "iob_basaliob": m.basaliob,
            "bg_above_target": m.bg - m.targetBg,
            "direction_num": m.directionNum,
            "hour": self.hour,
            "iob_activity": m.activity,
            "sug_insulinReq": m.insulinReq,
            "sug_COB": m.cob,
            "sug_eventualBG": m.eventualBG,
            "sug_expectedDelta": m.expectedDelta,
            "sug_minDelta": m.minDelta,
            "sug_TDD": m.tdd,
            "iob_bolusiob": max(0.0, m.iob - m.basaliob),
            "iob_netbasalinsulin": m.netbasalinsulin,
            "recent_smb_units_60m": m.recentSmbVolume60Min,
            "time_since_last_smb_min": m.timeSinceLastSmbMin
        ]
        let snapshot = BoostMlFeatureBuilder.CycleSnapshot(
            ts: m.currentTime,
            cgmMgdl: m.bg,
            iobIob: m.iob,
            iobActivity: m.activity,
            sugEventualBG: m.eventualBG,
            recentSmbUnits60m: m.recentSmbVolume60Min,
            sugMinDelta: m.minDelta
        )
        var ring = BoostMlRingBufferStore.load()
        ring.push(snapshot)
        self.ring = ring
        let vector = BoostMlFeatureBuilder.build(featureNames: names, current: snapshot, ring: ring, staticValues: statics)
        return BoostMLModels.hypoRisk(vector: vector)
    }

    lazy var mealLikely: (V1MlInputs) -> Double? = { [unowned self] m in
        BoostMLModels.mealLikely(self.features8(m))
    }

    func persistIfNeeded() {
        guard persist, let ring else { return }
        BoostMlRingBufferStore.save(ring)
    }
}
