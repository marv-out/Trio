import Foundation

// Port of AAPS DetermineBasalBoost.determine_basal (Boost-AAPS-core origin/dev 579fc0cd19), the V1
// Boost engine: oref1 determine_basal with Boost's per-BG ISF in the predictions, future_sens for
// dosing, the hypo-prediction target raise, the eight-tier SMB sizing and the iTimeActive high temp.
//
// V6 is built on top of this engine in AAPS. Its dose replaces V1's SMB only on cycles where V6 runs,
// and V1's dose bounds V6 in the non-meal states and inside the post-rescue window, so without V1 the
// V6 override is bounded by base oref instead and doses far less than AAPS does on the same trace.
//
// The translation is line for line and keeps the Kotlin's arithmetic: Double throughout, Java
// Math.round for rounding (ties towards positive infinity), and Java Math.min/max, which return NaN
// when either argument is NaN where Swift.min/max do not. Reason strings follow the Kotlin's wording
// with glucose in mg/dL; they are not part of the parity check. Parity with the Kotlin is checked by
// BoostV1ParityTests against outputs of the real DetermineBasalBoost on the same inputs.

// MARK: - Inputs

public struct V1GlucoseStatus: Equatable, Sendable {
    public var glucose: Double
    public var noise: Double
    public var delta: Double
    public var shortAvgDelta: Double
    public var longAvgDelta: Double
    /// Epoch milliseconds of the reading.
    public var date: Double

    public init(glucose: Double, noise: Double = 0, delta: Double, shortAvgDelta: Double, longAvgDelta: Double, date: Double) {
        self.glucose = glucose
        self.noise = noise
        self.delta = delta
        self.shortAvgDelta = shortAvgDelta
        self.longAvgDelta = longAvgDelta
        self.date = date
    }
}

public struct V1CurrentTemp: Equatable, Sendable {
    public var duration: Int
    public var rate: Double

    public init(duration: Int, rate: Double) {
        self.duration = duration
        self.rate = rate
    }
}

public struct V1IobTick: Equatable, Sendable {
    public var iob: Double
    public var activity: Double
    public var basaliob: Double
    public var netbasalinsulin: Double
    /// Epoch milliseconds of the last bolus.
    public var lastBolusTime: Double
    /// Activity of the zero-temp IOB projection at this tick.
    public var zeroTempActivity: Double

    public init(
        iob: Double,
        activity: Double,
        basaliob: Double = 0,
        netbasalinsulin: Double = 0,
        lastBolusTime: Double = 0,
        zeroTempActivity: Double
    ) {
        self.iob = iob
        self.activity = activity
        self.basaliob = basaliob
        self.netbasalinsulin = netbasalinsulin
        self.lastBolusTime = lastBolusTime
        self.zeroTempActivity = zeroTempActivity
    }
}

public struct V1MealData: Equatable, Sendable {
    public var carbs: Double
    public var mealCOB: Double
    /// Epoch milliseconds of the last carb entry.
    public var lastCarbTime: Double
    public var slopeFromMaxDeviation: Double
    public var slopeFromMinDeviation: Double

    public init(
        carbs: Double = 0,
        mealCOB: Double = 0,
        lastCarbTime: Double = 0,
        slopeFromMaxDeviation: Double = 0,
        slopeFromMinDeviation: Double = 0
    ) {
        self.carbs = carbs
        self.mealCOB = mealCOB
        self.lastCarbTime = lastCarbTime
        self.slopeFromMaxDeviation = slopeFromMaxDeviation
        self.slopeFromMinDeviation = slopeFromMinDeviation
    }
}

/// The OapsProfileBoost fields determine_basal reads.
public struct V1Profile: Equatable, Sendable {
    public var maxIob: Double
    public var maxDailyBasal: Double
    public var maxBasal: Double
    public var minBg: Double
    public var maxBg: Double
    public var carbRatio: Double
    public var sens: Double
    public var maxDailySafetyMultiplier: Double
    public var currentBasalSafetyMultiplier: Double
    public var sensitivityRaisesTarget: Bool
    public var resistanceLowersTarget: Bool
    public var advTargetAdjustments: Bool
    public var halfBasalExerciseTarget: Int
    public var skipNeutralTemps: Bool
    public var remainingCarbsCap: Int
    public var enableUAM: Bool
    public var smbInterval: Int
    public var enableSMBWithCOB: Bool
    public var enableSMBWithTemptarget: Bool
    public var allowSMBWithHighTemptarget: Bool
    public var enableSMBAlways: Bool
    public var enableSMBAfterCarbs: Bool
    public var maxSMBBasalMinutes: Int
    public var maxUAMSMBBasalMinutes: Int
    public var bolusIncrement: Double
    public var carbsReqThreshold: Int
    public var currentBasal: Double
    public var temptargetSet: Bool
    public var autosensMax: Double
    public var lgsThreshold: Int?
    public var variableSens: Double
    public var insulinDivisor: Int
    public var tdd: Double
    public var dynISFBgCap: Double
    public var dynISFBgCapped: Double
    public var sensNormalTarget: Double
    public var normalTarget: Double
    public var dynISFvelocity: Double
    public var insulinPeak: Int
    public var boostActive: Bool
    public var profileSwitch: Int
    public var boostBolus: Double
    public var boostMaxIOB: Double
    public var boostInsulinReq: Double
    public var boostScale: Double
    public var boostPercentScale: Double
    public var enableBoostPercentScale: Bool
    public var enableCircadianISF: Bool
    public var recentLowBG: Double
    public var dynIsfMode: Bool

    public init(
        maxIob: Double, maxDailyBasal: Double, maxBasal: Double, minBg: Double, maxBg: Double, carbRatio: Double,
        sens: Double, maxDailySafetyMultiplier: Double, currentBasalSafetyMultiplier: Double,
        sensitivityRaisesTarget: Bool = true, resistanceLowersTarget: Bool = true, advTargetAdjustments: Bool = true,
        halfBasalExerciseTarget: Int = 160, skipNeutralTemps: Bool = false, remainingCarbsCap: Int = 90,
        enableUAM: Bool, smbInterval: Int, enableSMBWithCOB: Bool, enableSMBWithTemptarget: Bool,
        allowSMBWithHighTemptarget: Bool, enableSMBAlways: Bool, enableSMBAfterCarbs: Bool,
        maxSMBBasalMinutes: Int, maxUAMSMBBasalMinutes: Int, bolusIncrement: Double, carbsReqThreshold: Int,
        currentBasal: Double, temptargetSet: Bool, autosensMax: Double, lgsThreshold: Int?,
        variableSens: Double, insulinDivisor: Int, tdd: Double, dynISFBgCap: Double, dynISFBgCapped: Double,
        sensNormalTarget: Double, normalTarget: Double, dynISFvelocity: Double, insulinPeak: Int,
        boostActive: Bool, profileSwitch: Int, boostBolus: Double, boostMaxIOB: Double, boostInsulinReq: Double,
        boostScale: Double, boostPercentScale: Double, enableBoostPercentScale: Bool, enableCircadianISF: Bool,
        recentLowBG: Double, dynIsfMode: Bool = true
    ) {
        self.maxIob = maxIob
        self.maxDailyBasal = maxDailyBasal
        self.maxBasal = maxBasal
        self.minBg = minBg
        self.maxBg = maxBg
        self.carbRatio = carbRatio
        self.sens = sens
        self.maxDailySafetyMultiplier = maxDailySafetyMultiplier
        self.currentBasalSafetyMultiplier = currentBasalSafetyMultiplier
        self.sensitivityRaisesTarget = sensitivityRaisesTarget
        self.resistanceLowersTarget = resistanceLowersTarget
        self.advTargetAdjustments = advTargetAdjustments
        self.halfBasalExerciseTarget = halfBasalExerciseTarget
        self.skipNeutralTemps = skipNeutralTemps
        self.remainingCarbsCap = remainingCarbsCap
        self.enableUAM = enableUAM
        self.smbInterval = smbInterval
        self.enableSMBWithCOB = enableSMBWithCOB
        self.enableSMBWithTemptarget = enableSMBWithTemptarget
        self.allowSMBWithHighTemptarget = allowSMBWithHighTemptarget
        self.enableSMBAlways = enableSMBAlways
        self.enableSMBAfterCarbs = enableSMBAfterCarbs
        self.maxSMBBasalMinutes = maxSMBBasalMinutes
        self.maxUAMSMBBasalMinutes = maxUAMSMBBasalMinutes
        self.bolusIncrement = bolusIncrement
        self.carbsReqThreshold = carbsReqThreshold
        self.currentBasal = currentBasal
        self.temptargetSet = temptargetSet
        self.autosensMax = autosensMax
        self.lgsThreshold = lgsThreshold
        self.variableSens = variableSens
        self.insulinDivisor = insulinDivisor
        self.tdd = tdd
        self.dynISFBgCap = dynISFBgCap
        self.dynISFBgCapped = dynISFBgCapped
        self.sensNormalTarget = sensNormalTarget
        self.normalTarget = normalTarget
        self.dynISFvelocity = dynISFvelocity
        self.insulinPeak = insulinPeak
        self.boostActive = boostActive
        self.profileSwitch = profileSwitch
        self.boostBolus = boostBolus
        self.boostMaxIOB = boostMaxIOB
        self.boostInsulinReq = boostInsulinReq
        self.boostScale = boostScale
        self.boostPercentScale = boostPercentScale
        self.enableBoostPercentScale = enableBoostPercentScale
        self.enableCircadianISF = enableCircadianISF
        self.recentLowBG = recentLowBG
        self.dynIsfMode = dynIsfMode
    }
}

/// The values determine_basal hands its ML models, so a host can build either model's feature
/// vector (the v12 hypo model also pushes a ring-buffer snapshot from these).
public struct V1MlInputs: Equatable, Sendable {
    public var bg: Double
    public var iob: Double
    public var basaliob: Double
    public var activity: Double
    public var netbasalinsulin: Double
    public var targetBg: Double
    public var directionNum: Double
    public var insulinReq: Double
    public var cob: Double
    public var eventualBG: Double
    public var expectedDelta: Double
    public var minDelta: Double
    public var tdd: Double
    public var recentSmbVolume60Min: Double
    public var timeSinceLastSmbMin: Double
    /// Epoch milliseconds of the cycle.
    public var currentTime: Double
}

/// The ML models determine_basal consults. Either closure may return nil (model unavailable), which
/// leaves V1's baseline behaviour, as an absent model does in AAPS.
public struct V1MlModels {
    public var hypoRisk: ((V1MlInputs) -> Double?)?
    public var mealLikely: ((V1MlInputs) -> Double?)?

    public init(hypoRisk: ((V1MlInputs) -> Double?)? = nil, mealLikely: ((V1MlInputs) -> Double?)? = nil) {
        self.hypoRisk = hypoRisk
        self.mealLikely = mealLikely
    }
}

public struct V1Inputs {
    public var glucoseStatus: V1GlucoseStatus
    public var currentTemp: V1CurrentTemp
    /// IOB ticks, current first, one per 5 min (48 in AAPS).
    public var iobArray: [V1IobTick]
    public var profile: V1Profile
    public var autosensRatio: Double
    public var meal: V1MealData
    public var microBolusAllowed: Bool
    /// Epoch milliseconds.
    public var currentTime: Double
    public var flatBGsDetected: Bool
    public var ml: V1MlModels
    public var recentSmbVolume60Min: Double
    public var cumulativeSmbCap60Min: Double
    public var recentLowBG45Min: Double
    public var timeSinceLastSmbMin: Double
    public var postRescueTightRampCap: Double?
    /// The local calendar used for the circadian hour and the minutes past the hour.
    public var calendar: Calendar

    public init(
        glucoseStatus: V1GlucoseStatus,
        currentTemp: V1CurrentTemp,
        iobArray: [V1IobTick],
        profile: V1Profile,
        autosensRatio: Double,
        meal: V1MealData,
        microBolusAllowed: Bool,
        currentTime: Double,
        flatBGsDetected: Bool = false,
        ml: V1MlModels = V1MlModels(),
        recentSmbVolume60Min: Double = 0,
        cumulativeSmbCap60Min: Double = 1.5,
        recentLowBG45Min: Double = 999,
        timeSinceLastSmbMin: Double = 720,
        postRescueTightRampCap: Double? = nil,
        calendar: Calendar = .current
    ) {
        self.glucoseStatus = glucoseStatus
        self.currentTemp = currentTemp
        self.iobArray = iobArray
        self.profile = profile
        self.autosensRatio = autosensRatio
        self.meal = meal
        self.microBolusAllowed = microBolusAllowed
        self.currentTime = currentTime
        self.flatBGsDetected = flatBGsDetected
        self.ml = ml
        self.recentSmbVolume60Min = recentSmbVolume60Min
        self.cumulativeSmbCap60Min = cumulativeSmbCap60Min
        self.recentLowBG45Min = recentLowBG45Min
        self.timeSinceLastSmbMin = timeSinceLastSmbMin
        self.postRescueTightRampCap = postRescueTightRampCap
        self.calendar = calendar
    }
}

// MARK: - Result

/// The RT fields determine_basal sets.
public struct V1Result: Equatable, Sendable {
    public var reason: String = ""
    public var units: Double?
    public var rate: Double?
    public var duration: Int?
    public var insulinReq: Double?
    public var eventualBG: Double?
    public var targetBG: Double?
    public var sensitivityRatio: Double?
    public var bg: Double?
    public var cob: Double?
    public var iob: Double?
    public var variableSens: Double?
    public var dynamicISF: Double?
    public var minGuardBG: Double?
    public var predIOB: [Int]?
    public var predZT: [Int]?
    public var predCOB: [Int]?
    public var predUAM: [Int]?
    public var carbsReq: Int?
    public var carbsReqWithin: Int?
    public var boostTier: String = "NONE"
    public var fastCarbProtection: Bool = false
    public var insulinReqPctEffective: Double = 0
    public var mlHypoRisk: Double?
    public var mlMealLikely: Double?
    public var mlRiskScale: Double?
    public var mlMealG3Released: Bool?
    public var mlG3ReleaseSource: String?
    public var deltaAcceleration: Double?
    public var deliverAt: Double?
    /// Not RT fields: values Trio's Determination carries that determine_basal holds locally.
    public var minDelta: Double?
    public var expectedDelta: Double?
    public var threshold: Double?
    public var minPredBG: Double?
    /// Every line determine_basal writes to its console, for the log.
    public var console: [String] = []

    public init() {}
}

// MARK: - Engine

/// The Kotlin throws where determine_basal meets NaN (roundToInt of NaN, a NaN carb impact), which
/// fails that loop cycle in AAPS. The port throws the same, so the cycle fails rather than doses.
public enum V1EngineError: Error, Equatable {
    case nan(String)
}

public enum BoostV1Engine {
    /// Appended to the reason by every zero temp V1 sets for a low. The V6 override reads it and
    /// leaves the cycle to V1, so no meal-state SMB lands on a cycle V1 suspended (DetermineBasalBoost
    /// LOW_SUSPEND_TAG, Boost 6.3.0).
    public static let lowSuspendTag = "lowSuspend=1; "
    /// Post-rescue window threshold (mg/dL) for the 45-min rolling minimum (DetermineBasalBoost
    /// POST_RESCUE_LOW_THRESHOLD_MGDL), shared with the V6 seam's post-rescue cap.
    public static let postRescueLowThresholdMgdl = 75.0
    /// Treatment-arm cap on the post-rescue scale (DetermineBasalBoost TIGHT_RAMP_CAP).
    public static let tightRampCap = 0.60

    // MARK: Kotlin arithmetic

    /// Java Math.min: NaN if either argument is NaN, and -0.0 below 0.0.
    static func jmin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0, b == 0 { return a.sign == .minus ? a : b }
        return a <= b ? a : b
    }

    /// Java Math.max: NaN if either argument is NaN, and 0.0 above -0.0.
    static func jmax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0, b == 0 { return a.sign == .minus ? b : a }
        return a >= b ? a : b
    }

    /// Java Math.round(double) as a Double: floor(x + 0.5), NaN to 0 as a long would be.
    static func jround(_ x: Double) -> Double {
        if x.isNaN { return 0 }
        if x.isInfinite { return x }
        return (x + 0.5).rounded(.down)
    }

    /// DetermineBasalBoost.round(value, digits).
    static func round(_ value: Double, _ digits: Int) -> Double {
        if value.isNaN { return .nan }
        let scale = pow(10.0, Double(digits))
        return jround(value * scale) / scale
    }

    /// DetermineBasalBoost.round(value): Int, i.e. Kotlin roundToInt (ties towards positive infinity).
    static func roundInt(_ value: Double) throws -> Int {
        if value.isNaN { throw V1EngineError.nan("roundToInt") }
        let r = (value + 0.5).rounded(.down)
        if r >= Double(Int.max) { return Int.max }
        if r <= Double(Int.min) { return Int.min }
        return Int(r)
    }

    static func floorTo(_ value: Double, _ roundTo: Double) -> Double {
        (value * roundTo).rounded(.down) / roundTo
    }

    // MARK: Boost helpers

    static func calculateExpectedDelta(targetBg: Double, eventualBg: Double, bgi: Double) -> Double {
        let fiveMinBlocks = Double((2 * 60) / 5)
        let targetDelta = targetBg - eventualBg
        return round(bgi + (targetDelta / fiveMinBlocks), 1)
    }

    /// DetermineBasalBoost.getIsfByProfile.
    static func getIsfByProfile(_ bg: Double, _ p: V1Profile, useCap: Bool) -> Double {
        var bgAdj = bg
        if useCap {
            let cap = p.dynISFBgCap
            if bgAdj > cap { bgAdj = cap + (bgAdj - cap) / 3.0 }
        }
        let sensBG = log((bgAdj / Double(p.insulinDivisor)) + 1)
        let scaler = log((p.normalTarget / Double(p.insulinDivisor)) + 1) / sensBG
        return p.sensNormalTarget * (1 - (1 - scaler) * p.dynISFvelocity)
    }

    /// DetermineBasalBoost.getCircadianSensitivity.
    static func circadianSensitivity(hourOfDay: Int) -> Double {
        let now = jmax(Double(hourOfDay), 0)
        switch now {
        case 0.0 ..< 2.0:
            let n = jmax(now, 0.5)
            return (0.09130 * pow(n, 3)) - (0.33261 * pow(n, 2)) + 1.4
        case 2.0 ..< 3.0: return (0.0869 * pow(now, 3)) - (0.05217 * pow(now, 2)) - (0.23478 * now) + 0.8
        case 3.0 ..< 8.0: return (0.0007 * pow(now, 3)) - (0.000730 * pow(now, 2)) - (0.0007826 * now) + 0.6
        case 8.0 ..< 11.0: return (0.001244 * pow(now, 3)) - (0.007619 * pow(now, 2)) - (0.007826 * now) + 0.4
        case 11.0 ..< 15.0: return (0.00078 * pow(now, 3)) - (0.00272 * pow(now, 2)) - (0.07619 * now) + 0.8
        case 15.0 ... 22.0: return 1.0
        case 22.0 ... 24.0: return (0.000125 * pow(now, 3)) - (0.0015 * pow(now, 2)) - (0.0045 * now) + 1.2
        default: return 1.0
        }
    }

    /// DetermineBasalBoost.baseSensitivity.
    static func baseSensitivity(_ p: V1Profile, variableSens: Double, autosensRatio: Double) -> Double {
        if p.dynIsfMode || autosensRatio <= 0.0 { return variableSens }
        return round(p.sens / autosensRatio, 1)
    }

    /// BoostV1SafetyRules.boostPercentScaleReduction (audit item 4).
    static func percentScaleReduction(bg: Double, slope: Double) -> Double {
        if bg > 180.0, slope > 0.0 { return 0.0 }
        return (abs(bg - 180) / 72) * slope
    }

    /// BoostV1SafetyRules.boostSmbWithinMaxIob (audit item 5).
    static func smbWithinMaxIob(_ microBolus: Double, maxIob: Double, iob: Double, bolusIncrement: Double) -> Double {
        let headroom = maxIob - iob
        if !(headroom > 0.0) { return 0.0 }
        if microBolus <= headroom { return microBolus }
        if !(bolusIncrement > 0.0) { return jmin(microBolus, headroom) }
        let steps = 1.0 / bolusIncrement
        return (headroom * steps + 1E-9).rounded(.down) / steps
    }

    /// BoostV1SafetyRules.boostG3HoldConditionsMet (audit item 19).
    static func g3HoldConditionsMet(mealCob: Double, delta: Double, shortAvgDelta: Double) -> Bool {
        mealCob < 1.0 && delta >= 5.0 && shortAvgDelta >= 3.0
    }

    /// BoostV1SafetyRules.boostSpikeOverrideAllowed (audit item 20).
    static func spikeOverrideAllowed(boostActive: Bool, tier: String?, inPostRescueWindow: Bool, mlTierDowngrade: Bool) -> Bool {
        boostActive && tier == "REGULAR_OREF1" && !inPostRescueWindow && !mlTierDowngrade
    }

    /// DetermineBasalBoost.postRescueReboundScale.
    public static func postRescueReboundScale(bg: Double) -> Double {
        if bg < 120.0 { return 0.3 }
        if bg < 170.0 { return 0.3 + 0.7 * (bg - 120.0) / 50.0 }
        return 1.0
    }

    static func directionNum(shortAvgDelta: Double) -> Double {
        if shortAvgDelta > 15.0 { return 2.0 }
        if shortAvgDelta > 10.0 { return 1.5 }
        if shortAvgDelta > 5.0 { return 1.0 }
        if shortAvgDelta > -5.0 { return 0.0 }
        if shortAvgDelta > -10.0 { return -1.0 }
        if shortAvgDelta > -15.0 { return -1.5 }
        return -2.0
    }

    static func fmt(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        let r = round(v, 2)
        if r == r.rounded() { return String(Int(r)) }
        return String(r)
    }

    // MARK: Temp basal

    static func maxSafeBasal(_ p: V1Profile) -> Double {
        jmin(p.maxBasal, jmin(p.maxDailySafetyMultiplier * p.maxDailyBasal, p.currentBasalSafetyMultiplier * p.currentBasal))
    }

    static func setTempBasal(
        _ rateIn: Double,
        _ duration: Int,
        _ p: V1Profile,
        _ rT: inout V1Result,
        _ currentTemp: V1CurrentTemp
    ) {
        let maxSafe = maxSafeBasal(p)
        var rate = rateIn
        if rate < 0 { rate = 0.0 } else if rate > maxSafe { rate = maxSafe }
        let suggestedRate = rate
        if currentTemp.duration > (duration - 10), currentTemp.duration <= 120,
           suggestedRate <= currentTemp.rate * 1.2, suggestedRate >= currentTemp.rate * 0.8, duration > 0
        {
            rT
                .reason +=
                " \(currentTemp.duration)m left and \(fmt(currentTemp.rate)) ~ req \(fmt(suggestedRate))U/hr: no temp required"
            return
        }
        if suggestedRate == p.currentBasal {
            if p.skipNeutralTemps {
                if currentTemp.duration > 0 {
                    appendReason(&rT, "Suggested rate is same as profile rate, a temp basal is active, canceling current temp")
                    rT.duration = 0
                    rT.rate = 0.0
                } else {
                    appendReason(&rT, "Suggested rate is same as profile rate, no temp basal is active, doing nothing")
                }
            } else {
                appendReason(&rT, "Setting neutral temp basal of \(fmt(p.currentBasal))U/hr")
                rT.duration = duration
                rT.rate = suggestedRate
            }
        } else {
            rT.duration = duration
            rT.rate = suggestedRate
        }
    }

    /// The low-glucose zero temp, tagged with `lowSuspendTag` (DetermineBasalBoost lowSuspendTempBasal).
    static func lowSuspendTempBasal(_ duration: Int, _ p: V1Profile, _ rT: inout V1Result, _ currentTemp: V1CurrentTemp) {
        rT.reason += lowSuspendTag
        setTempBasal(0.0, duration, p, &rT, currentTemp)
    }

    /// A low temp from the eventualBG-below-target branch; at a rate of zero or less it is a zero
    /// temp for a low and is tagged (DetermineBasalBoost lowTempBasal).
    static func lowTempBasal(
        _ rate: Double,
        _ duration: Int,
        _ p: V1Profile,
        _ rT: inout V1Result,
        _ currentTemp: V1CurrentTemp
    ) {
        if rate <= 0 { lowSuspendTempBasal(duration, p, &rT, currentTemp) }
        else { setTempBasal(rate, duration, p, &rT, currentTemp) }
    }

    /// The threshold drop to 65 on an accelerating rise (BoostV1SafetyRules boostAccelLoweredThreshold,
    /// Boost 6.3.0). It needs a rising delta, since deltaAccl is also positive on a slowing fall, and
    /// never goes below the LGS setting.
    static func boostAccelLoweredThreshold(
        _ threshold: Double, delta: Double, shortAvgDelta: Double, lgsThreshold: Int?
    ) -> Double {
        let accelerating = abs(shortAvgDelta) > 0.001 && delta > shortAvgDelta
        guard accelerating, delta > 0 else { return threshold }
        return Swift.max(65.0, Double(lgsThreshold ?? 0))
    }

    static func appendReason(_ rT: inout V1Result, _ msg: String) {
        if !rT.reason.isEmpty { rT.reason += ". " }
        rT.reason += msg
        rT.console.append(msg)
    }

    static func enableSmb(
        _ p: V1Profile,
        microBolusAllowed: Bool,
        meal: V1MealData,
        targetBg: Double,
        console: inout [String]
    ) -> Bool {
        if !microBolusAllowed {
            console.append("SMB disabled (!microBolusAllowed)")
            return false
        } else if !p.allowSMBWithHighTemptarget, p.temptargetSet, targetBg > 100 {
            console.append("SMB disabled due to high temptarget of \(fmt(targetBg))")
            return false
        }
        if p.enableSMBAlways {
            console.append("SMB enabled due to enableSMB_always")
            return true
        }
        if p.enableSMBWithCOB, meal.mealCOB != 0.0 {
            console.append("SMB enabled for COB of \(fmt(meal.mealCOB))")
            return true
        }
        if p.enableSMBAfterCarbs, meal.carbs != 0.0 {
            console.append("SMB enabled for 6h after carb entry")
            return true
        }
        if p.enableSMBWithTemptarget, p.temptargetSet, targetBg < 100 {
            console.append("SMB enabled for temptarget of \(fmt(targetBg))")
            return true
        }
        console.append("SMB disabled (no enableSMB preferences active or no condition satisfied)")
        return false
    }

    // MARK: determine_basal

    public static func determineBasal(_ input: V1Inputs) throws -> V1Result {
        let gs = input.glucoseStatus
        let currenttemp = input.currentTemp
        let profile = input.profile
        let meal = input.meal
        let iobArray = input.iobArray
        let microBolusAllowed = input.microBolusAllowed
        let currentTime = input.currentTime

        var rT = V1Result()
        rT.boostTier = "NONE"
        var console: [String] = []

        let deliverAt = currentTime
        let profileCurrentBasal = profile.currentBasal
        var basal = profileCurrentBasal
        let systemTime = currentTime
        let bgTime = gs.date
        let minAgo = round((systemTime - bgTime) / 60.0 / 1000.0, 1)
        let bg = gs.glucose
        let noise = gs.noise

        // BG validation
        if bg <= 10 || bg == 38.0 || noise >= 3 {
            rT.reason += "CGM is calibrating, in ??? state, or noise is high"
        }
        if minAgo > 12 || minAgo < -5 {
            rT
                .reason +=
                "If current system time \(fmt(systemTime)) is correct, then BG data is too old. The last BG data was read \(fmt(minAgo))m ago at \(fmt(bgTime))"
        } else if bg > 60, input.flatBGsDetected {
            rT.reason += "Error: CGM data is unchanged for the past ~45m"
        }
        if bg <= 10 || bg == 38.0 || noise >= 3 || minAgo > 12 || minAgo < -5 || (bg > 60 && input.flatBGsDetected) {
            if currenttemp.rate > basal {
                rT.reason += ". Replacing high temp basal of \(fmt(currenttemp.rate)) with neutral temp of \(fmt(basal))"
                rT.deliverAt = deliverAt
                rT.duration = 30
                rT.rate = basal
                rT.console = console
                return rT
            } else if currenttemp.rate == 0.0, currenttemp.duration > 30 {
                rT.reason += ". Shortening \(currenttemp.duration)m long zero temp to 30m. "
                rT.deliverAt = deliverAt
                rT.duration = 30
                rT.rate = 0.0
                rT.console = console
                return rT
            } else {
                rT.reason += ". Temp \(fmt(currenttemp.rate)) <= current basal \(fmt(round(basal, 2)))U/hr; doing nothing. "
                rT.console = console
                return rT
            }
        }

        let maxIob = profile.maxIob

        var targetBg = (profile.minBg + profile.maxBg) / 2
        var minBg = profile.minBg
        var maxBg = profile.maxBg

        // Delta acceleration, denominator floored at 2 mg/dL/5 min.
        let shortAvgDelta = gs.shortAvgDelta
        let deltaAccl = abs(shortAvgDelta) > 0.001
            ? round(100.0 * (gs.delta - shortAvgDelta) / jmax(abs(shortAvgDelta), 2.0), 2)
            : 0.0

        var iTimeActive = false

        let sensBg = profile.dynISFBgCapped
        let variableSens = profile.variableSens

        // Circadian ISF
        let hour = input.calendar.component(.hour, from: Date(timeIntervalSince1970: currentTime / 1000))
        let circadian = circadianSensitivity(hourOfDay: hour)
        let baseSens = baseSensitivity(profile, variableSens: variableSens, autosensRatio: input.autosensRatio)
        let sens: Double = profile.enableCircadianISF ? round(baseSens * circadian, 1) : round(baseSens, 1)

        // Autosens ratio and basal
        var sensitivityRatio = input.autosensRatio
        basal = profile.currentBasal * sensitivityRatio

        if profile.temptargetSet {
            // Temp target set, not adjusting with autosens
        } else if sensitivityRatio != 1.0 {
            if profile.sensitivityRaisesTarget && input.autosensRatio < 1 || profile.resistanceLowersTarget && input
                .autosensRatio > 1
            {
                minBg = round((minBg - 60) / sensitivityRatio, 0) + 60
                maxBg = round((maxBg - 60) / sensitivityRatio, 0) + 60
                var newTargetBg = round((targetBg - 60) / sensitivityRatio, 0) + 60
                newTargetBg = jmax(80.0, newTargetBg)
                targetBg = newTargetBg
            }
        }

        // HypoPredBG and the hypo target
        let bgiRaw = round(-iobArray[0].activity * sens * 5, 2)
        let minDeltaRaw = jmin(gs.delta, gs.shortAvgDelta)
        let hypoPredBG = try roundInt(bg - (iobArray[0].iob * sens)) + roundInt(60.0 / 5 * (minDeltaRaw - bgiRaw))

        let ebg = (0.02 * gs.delta * gs.delta) + (0.58 * gs.longAvgDelta) + bg
        var halfBasalTarget = profile.halfBasalExerciseTarget
        let normalTarget = 100

        if !profile.temptargetSet, hypoPredBG <= 125, profile.sensitivityRaisesTarget {
            var hypoTarget = round(jmin(200.0, minBg + (ebg - minBg) / 3), 0)
            if hypoTarget <= targetBg {
                hypoTarget = targetBg + 10
                console.append("target_bg from \(fmt(targetBg)) to \(fmt(hypoTarget)) because HypoPredBG <= 125: \(hypoPredBG)")
            }
            targetBg = hypoTarget
            halfBasalTarget = 160
            let c = Double(halfBasalTarget - normalTarget)
            sensitivityRatio = c / (c + targetBg - Double(normalTarget))
            sensitivityRatio = jmin(sensitivityRatio, profile.autosensMax)
            sensitivityRatio = round(sensitivityRatio, 2)
            basal = profile.currentBasal * sensitivityRatio
        }

        let iobData = iobArray[0]

        let tick: String = gs.delta > -0.5 ? "+" + String(try roundInt(gs.delta)) : String(try roundInt(gs.delta))
        let minDelta = jmin(gs.delta, gs.shortAvgDelta)
        let minAvgDelta = jmin(gs.shortAvgDelta, gs.longAvgDelta)
        let maxDelta = jmax(gs.delta, jmax(gs.shortAvgDelta, gs.longAvgDelta))

        // BG impact
        let bgi = round(-iobData.activity * sens * 5, 2)
        var deviation = try roundInt(30.0 / 5 * (minDelta - bgi))
        if deviation < 0 {
            deviation = try roundInt((30.0 / 5) * (minAvgDelta - bgi))
            if deviation < 0 {
                deviation = try roundInt((30.0 / 5) * (gs.longAvgDelta - bgi))
            }
        }

        let naiveEventualBG: Double = iobData.iob > 0
            ? round(bg - (iobData.iob * sens), 0)
            : round(bg - (iobData.iob * jmin(sens, profile.sens)), 0)
        var eventualBG = naiveEventualBG + Double(deviation)

        // Targets for high BG
        if bg > maxBg, profile.advTargetAdjustments, !profile.temptargetSet {
            let adjustedMinBG = round(jmax(80.0, minBg - (bg - minBg) / 3.0), 0)
            let adjustedTargetBG = round(jmax(80.0, targetBg - (bg - targetBg) / 3.0), 0)
            let adjustedMaxBG = round(jmax(80.0, maxBg - (bg - maxBg) / 3.0), 0)
            if eventualBG > adjustedMinBG, naiveEventualBG > adjustedMinBG, minBg > adjustedMinBG {
                minBg = adjustedMinBG
            }
            if eventualBG > adjustedTargetBG, naiveEventualBG > adjustedTargetBG, targetBg > adjustedTargetBG {
                targetBg = adjustedTargetBG
            }
            if eventualBG > adjustedMaxBG, naiveEventualBG > adjustedMaxBG, maxBg > adjustedMaxBG {
                maxBg = adjustedMaxBG
            }
        }

        let expectedDelta = calculateExpectedDelta(targetBg: targetBg, eventualBg: eventualBG, bgi: bgi)

        // Threshold, lowered while BG accelerates upward
        var threshold = minBg - 0.5 * (minBg - 40)
        if let lgs = profile.lgsThreshold, Double(lgs) > threshold {
            threshold = Double(lgs)
        }
        threshold = boostAccelLoweredThreshold(
            threshold, delta: gs.delta, shortAvgDelta: gs.shortAvgDelta, lgsThreshold: profile.lgsThreshold
        )

        rT = V1Result()
        rT.bg = bg
        rT.eventualBG = eventualBG
        rT.targetBG = targetBg
        rT.insulinReq = 0.0
        rT.deliverAt = deliverAt
        rT.sensitivityRatio = sensitivityRatio
        rT.variableSens = sens
        rT.deltaAcceleration = deltaAccl
        rT.boostTier = "NONE"
        rT.fastCarbProtection = false
        rT.insulinReqPctEffective = 0.0
        rT.minDelta = minDelta
        rT.expectedDelta = expectedDelta
        rT.threshold = threshold

        // Predictions
        var COBpredBGs: [Double] = [bg]
        var aCOBpredBGs: [Double] = [bg]
        var IOBpredBGs: [Double] = [bg]
        var ZTpredBGs: [Double] = [bg]
        var UAMpredBGs: [Double] = [bg]

        var enableSMB = enableSmb(
            profile,
            microBolusAllowed: microBolusAllowed,
            meal: meal,
            targetBg: targetBg,
            console: &console
        )
        let enableUAM = profile.enableUAM

        var ci = round(minDelta - bgi, 1)
        let uci = round(minDelta - bgi, 1)

        let csf = profile.sens / profile.carbRatio

        let maxCarbAbsorptionRate = 30.0
        let maxCI = round(maxCarbAbsorptionRate * csf * 5.0 / 60, 1)
        if ci > maxCI { ci = maxCI }
        var remainingCATimeMin = 3.0 / sensitivityRatio
        let assumedCarbAbsorptionRate = 20.0
        var remainingCATime = remainingCATimeMin
        var lastCarbAge = 0
        if meal.carbs != 0.0 {
            remainingCATimeMin = jmax(remainingCATimeMin, meal.mealCOB / assumedCarbAbsorptionRate)
            lastCarbAge = try roundInt((systemTime - meal.lastCarbTime) / 60000.0)
            remainingCATime = remainingCATimeMin + 1.5 * Double(lastCarbAge) / 60
            remainingCATime = round(remainingCATime, 1)
        }

        let totalCI = jmax(0.0, ci / 5 * 60 * remainingCATime / 2)
        let totalCA = totalCI / csf
        let remainingCarbsCap = Swift.min(90, profile.remainingCarbsCap)
        var remainingCarbs = jmax(0.0, meal.mealCOB - totalCA)
        remainingCarbs = jmin(Double(remainingCarbsCap), remainingCarbs)
        let remainingCIpeak = remainingCarbs * csf * 5 / 60 / (remainingCATime / 2)
        if remainingCIpeak.isNaN { throw V1EngineError.nan("remainingCIpeak") }

        let slopeFromMaxDeviation = round(meal.slopeFromMaxDeviation, 2)
        let slopeFromMinDeviation = round(meal.slopeFromMinDeviation, 2)
        let slopeFromDeviations = jmin(slopeFromMaxDeviation, -slopeFromMinDeviation / 3)

        let aci = 10.0
        let cid: Double = ci == 0.0 ? 0.0 : jmin(remainingCATime * 60 / 5 / 2, jmax(0.0, meal.mealCOB * csf / ci))
        let acid = jmax(0.0, meal.mealCOB * csf / aci)

        var minIOBPredBG = 999.0
        var minCOBPredBG = 999.0
        var minUAMPredBG = 999.0
        var minGuardBG: Double = bg
        var minGuardBGSource = "IOB"
        var minCOBGuardBG = 999.0
        var minUAMGuardBG = 999.0
        var minIOBGuardBG = 999.0
        var minZTGuardBG = 999.0
        var minPredBG: Double
        var avgPredBG: Double
        var IOBpredBG: Double = eventualBG
        var maxIOBPredBG = bg
        var maxCOBPredBG = bg
        let lastIOBpredBG: Double
        var lastCOBpredBG: Double?
        var lastUAMpredBG: Double?
        var UAMpredBG: Double?
        var COBpredBG: Double?

        let insulinPeakTime = Double(profile.insulinPeak + 30)
        let insulinPeak5m = (insulinPeakTime / 60.0) * 12.0

        for iobTick in iobArray {
            let predBGI = round(-iobTick.activity * sens * 5, 2)
            let IOBpredBGI = round(
                -iobTick.activity * getIsfByProfile(jmax(IOBpredBGs[IOBpredBGs.count - 1], 39.0), profile, useCap: true) * 5,
                2
            )
            let predZTBGI = round(
                -iobTick
                    .zeroTempActivity * getIsfByProfile(jmax(ZTpredBGs[ZTpredBGs.count - 1], 39.0), profile, useCap: true) * 5,
                2
            )
            let predUAMBGI = round(
                -iobTick.activity * getIsfByProfile(jmax(UAMpredBGs[UAMpredBGs.count - 1], 39.0), profile, useCap: true) * 5,
                2
            )

            let predDev: Double = ci * (1 - jmin(1.0, Double(IOBpredBGs.count) / (60.0 / 5.0)))
            IOBpredBG = IOBpredBGs[IOBpredBGs.count - 1] + IOBpredBGI + predDev
            let ZTpredBG = ZTpredBGs[ZTpredBGs.count - 1] + predZTBGI
            let predCI: Double = jmax(0.0, jmax(0.0, ci) * (1 - Double(COBpredBGs.count) / jmax(cid * 2, 1.0)))
            let predACI = jmax(0.0, jmax(0, aci) * (1 - Double(COBpredBGs.count) / jmax(acid * 2, 1.0)))
            let intervals = jmin(Double(COBpredBGs.count), (remainingCATime * 12) - Double(COBpredBGs.count))
            let remainingCI = jmax(0.0, intervals / (remainingCATime / 2 * 12) * remainingCIpeak)
            if remainingCI.isNaN { throw V1EngineError.nan("remainingCI") }
            let cobPred = COBpredBGs[COBpredBGs.count - 1] + predBGI + jmin(0.0, predDev) + predCI + remainingCI
            COBpredBG = cobPred
            let aCOBpred = aCOBpredBGs[aCOBpredBGs.count - 1] + predBGI + jmin(0.0, predDev) + predACI
            let predUCIslope = jmax(0.0, uci + (Double(UAMpredBGs.count) * slopeFromDeviations))
            let predUCImax = jmax(0.0, uci * (1 - Double(UAMpredBGs.count) / jmax(3.0 * 60 / 5, 1.0)))
            let predUCI = jmin(predUCIslope, predUCImax)
            let uamPred = UAMpredBGs[UAMpredBGs.count - 1] + predUAMBGI + jmin(0.0, predDev) + predUCI
            UAMpredBG = uamPred

            if IOBpredBGs.count < 48 { IOBpredBGs.append(IOBpredBG) }
            if COBpredBGs.count < 48 { COBpredBGs.append(cobPred) }
            if aCOBpredBGs.count < 48 { aCOBpredBGs.append(aCOBpred) }
            if UAMpredBGs.count < 48 { UAMpredBGs.append(uamPred) }
            if ZTpredBGs.count < 48 { ZTpredBGs.append(ZTpredBG) }

            if cobPred < minCOBGuardBG { minCOBGuardBG = Double(try roundInt(cobPred)) }
            if uamPred < minUAMGuardBG { minUAMGuardBG = Double(try roundInt(uamPred)) }
            if IOBpredBG < minIOBGuardBG { minIOBGuardBG = IOBpredBG }
            if ZTpredBG < minZTGuardBG { minZTGuardBG = round(ZTpredBG, 0) }

            if Double(IOBpredBGs.count) > insulinPeak5m, IOBpredBG < minIOBPredBG { minIOBPredBG = round(IOBpredBG, 0) }
            if IOBpredBG > maxIOBPredBG { maxIOBPredBG = IOBpredBG }
            if cid != 0.0 || remainingCIpeak > 0, Double(COBpredBGs.count) > insulinPeak5m,
               cobPred < minCOBPredBG { minCOBPredBG = round(cobPred, 0) }
            if cid != 0.0 || remainingCIpeak > 0, cobPred > maxIOBPredBG { maxCOBPredBG = cobPred }
            if enableUAM, UAMpredBGs.count > 12, uamPred < minUAMPredBG { minUAMPredBG = round(uamPred, 0) }
            // AAPS assigns maxUAMPredBG here, but nothing reads it.
        }

        IOBpredBGs = IOBpredBGs.map { round(jmin(401.0, jmax(39.0, $0)), 0) }
        trimFlatTail(&IOBpredBGs, downTo: 13)
        rT.predIOB = IOBpredBGs.map { Int($0) }
        lastIOBpredBG = Double(try roundInt(IOBpredBGs[IOBpredBGs.count - 1]))
        ZTpredBGs = ZTpredBGs.map { round(jmin(401.0, jmax(39.0, $0)), 0) }
        if ZTpredBGs.count - 1 >= 7 {
            for i in stride(from: ZTpredBGs.count - 1, through: 7, by: -1) {
                if ZTpredBGs[i - 1] >= ZTpredBGs[i] || ZTpredBGs[i] <= targetBg { break }
                ZTpredBGs.removeLast()
            }
        }
        rT.predZT = ZTpredBGs.map { Int($0) }
        if meal.mealCOB > 0 {
            aCOBpredBGs = aCOBpredBGs.map { round(jmin(401.0, jmax(39.0, $0)), 0) }
            trimFlatTail(&aCOBpredBGs, downTo: 13)
        }
        if meal.mealCOB > 0, ci > 0 || remainingCIpeak > 0 {
            COBpredBGs = COBpredBGs.map { round(jmin(401.0, jmax(39.0, $0)), 0) }
            trimFlatTail(&COBpredBGs, downTo: 13)
            rT.predCOB = COBpredBGs.map { Int($0) }
            lastCOBpredBG = COBpredBGs[COBpredBGs.count - 1]
            eventualBG = jmax(eventualBG, round(COBpredBGs[COBpredBGs.count - 1], 0))
        }
        if ci > 0 || remainingCIpeak > 0 {
            if enableUAM {
                UAMpredBGs = UAMpredBGs.map { round(jmin(401.0, jmax(39.0, $0)), 0) }
                trimFlatTail(&UAMpredBGs, downTo: 13)
                rT.predUAM = UAMpredBGs.map { Int($0) }
                lastUAMpredBG = UAMpredBGs[UAMpredBGs.count - 1]
                eventualBG = jmax(eventualBG, round(UAMpredBGs[UAMpredBGs.count - 1], 0))
            }
            rT.eventualBG = eventualBG
        }

        minIOBPredBG = jmax(39.0, minIOBPredBG)
        minCOBPredBG = jmax(39.0, minCOBPredBG)
        minUAMPredBG = jmax(39.0, minUAMPredBG)
        minPredBG = round(minIOBPredBG, 0)

        // future_sens for dosing
        let boostActive = profile.boostActive
        let sensBgCap = profile.dynISFBgCap
        let fsensBg = eventualBG > sensBgCap ? (sensBgCap + ((eventualBG - sensBgCap) / 2)) : eventualBG

        var futureSens: Double
        if boostActive, meal.mealCOB > 0, deltaAccl > 0 {
            futureSens = getIsfByProfile((fsensBg * 0.75) + (sensBg * 0.25), profile, useCap: false)
            rT.reason += "Dosing sensitivity: \(fmt(futureSens)) weighted on predicted BG due to COB;"
        } else if boostActive, gs.delta > 4, deltaAccl > 10, bg < 180, eventualBG > bg {
            futureSens = getIsfByProfile((fsensBg * 0.5) + (sensBg * 0.5), profile, useCap: false)
            rT.reason += "Dosing sensitivity: \(fmt(futureSens)) weighted on predicted BG due to delta;"
        } else if bg > 180, gs.delta < 2, gs.delta > -2, gs.shortAvgDelta > -2, gs.shortAvgDelta < 2, gs.longAvgDelta > -2,
                  gs.longAvgDelta < 2
        {
            futureSens = getIsfByProfile((minPredBG * 0.25) + (sensBg * 0.75), profile, useCap: false)
            rT.reason += "Dosing sensitivity: \(fmt(futureSens)) using current BG;"
        } else if gs.delta > 0 && deltaAccl > 1 || eventualBG > bg {
            futureSens = getIsfByProfile(sensBg, profile, useCap: false)
        } else {
            futureSens = getIsfByProfile(jmax(minPredBG, 1.0), profile, useCap: false)
            rT.reason += "Dosing sensitivity: \(fmt(futureSens)) using lowest predicted BG;"
        }
        futureSens = round(futureSens, 1)
        rT.dynamicISF = futureSens

        // minPredBG, as oref1
        let fractionCarbsLeft = meal.mealCOB / meal.carbs
        if minUAMPredBG < 999, minCOBPredBG < 999 {
            avgPredBG = round((1 - fractionCarbsLeft) * UAMpredBG! + fractionCarbsLeft * COBpredBG!, 0)
        } else if minCOBPredBG < 999 {
            avgPredBG = round((IOBpredBG + COBpredBG!) / 2.0, 0)
        } else if minUAMPredBG < 999 {
            avgPredBG = round((IOBpredBG + UAMpredBG!) / 2.0, 0)
        } else {
            avgPredBG = round(IOBpredBG, 0)
        }
        if minZTGuardBG > avgPredBG {
            avgPredBG = minZTGuardBG
        }

        if cid > 0.0 || remainingCIpeak > 0 {
            if enableUAM {
                minGuardBG = fractionCarbsLeft * minCOBGuardBG + (1 - fractionCarbsLeft) * minUAMGuardBG
                minGuardBGSource = "COB+UAM"
            } else {
                minGuardBG = minCOBGuardBG
                minGuardBGSource = "COB"
            }
        } else if enableUAM {
            minGuardBG = minUAMGuardBG
            minGuardBGSource = "UAM"
        } else {
            minGuardBG = minIOBGuardBG
            minGuardBGSource = "IOB"
        }
        minGuardBG = round(minGuardBG, 0)
        rT.minGuardBG = minGuardBG

        var minZTUAMPredBG = minUAMPredBG
        if minZTGuardBG < threshold {
            minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
        } else if minZTGuardBG < targetBg {
            let blendPct = (minZTGuardBG - threshold) / (targetBg - threshold)
            let blendedMinZTGuardBG = minUAMPredBG * blendPct + minZTGuardBG * (1 - blendPct)
            minZTUAMPredBG = (minUAMPredBG + blendedMinZTGuardBG) / 2.0
        } else if minZTGuardBG > minUAMPredBG {
            minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
        }
        minZTUAMPredBG = round(minZTUAMPredBG, 0)

        if meal.carbs != 0.0 {
            if !enableUAM, minCOBPredBG < 999 {
                minPredBG = round(jmax(minIOBPredBG, minCOBPredBG), 0)
            } else if minCOBPredBG < 999 {
                let blendedMinPredBG = fractionCarbsLeft * minCOBPredBG + (1 - fractionCarbsLeft) * minZTUAMPredBG
                minPredBG = round(jmax(minIOBPredBG, jmax(minCOBPredBG, blendedMinPredBG)), 0)
            } else if enableUAM {
                minPredBG = minZTUAMPredBG
            } else {
                minPredBG = minGuardBG
            }
        } else if enableUAM {
            minPredBG = round(jmax(minIOBPredBG, minZTUAMPredBG), 0)
        }
        minPredBG = jmin(minPredBG, avgPredBG)
        if maxCOBPredBG > bg {
            minPredBG = jmin(minPredBG, maxCOBPredBG)
        }
        rT.minPredBG = minPredBG

        rT.cob = meal.mealCOB
        rT.iob = iobData.iob
        rT
            .reason +=
            "COB: \(fmt(round(meal.mealCOB, 1))), Dev: \(deviation), BGI: \(fmt(bgi)), ISF: \(fmt(sens)), CR: \(fmt(round(profile.carbRatio, 2))), Target: \(fmt(targetBg)), minPredBG \(fmt(minPredBG)), minGuardBG \(fmt(minGuardBG)) (\(minGuardBGSource)), IOBpredBG \(fmt(lastIOBpredBG))"
        if let lastCOBpredBG { rT.reason += ", COBpredBG \(fmt(lastCOBpredBG))" }
        if let lastUAMpredBG { rT.reason += ", UAMpredBG \(fmt(lastUAMpredBG))" }
        rT.reason += "; "

        var carbsReqBG = naiveEventualBG
        if carbsReqBG < 40 {
            carbsReqBG = jmin(minGuardBG, carbsReqBG)
        }
        var bgUndershoot: Double = threshold - carbsReqBG
        var minutesAboveThreshold = 240
        if meal.mealCOB > 0, ci > 0 || remainingCIpeak > 0 {
            for (i, v) in COBpredBGs.enumerated() where v < threshold {
                minutesAboveThreshold = 5 * i
                break
            }
        } else {
            for (i, v) in IOBpredBGs.enumerated() where v < threshold {
                minutesAboveThreshold = 5 * i
                break
            }
        }

        if enableSMB, minGuardBG < threshold {
            console
                .append("minGuardBG \(fmt(minGuardBG)) (\(minGuardBGSource)) projected below \(fmt(threshold)) - disabling SMB")
            enableSMB = false
        }
        // Boost disables SMB at 30% maxDelta (stock 20%).
        if maxDelta > 0.30 * bg {
            rT.reason += "maxDelta \(fmt(maxDelta)) > 30% of BG \(fmt(bg)): SMB disabled; "
            enableSMB = false
        }

        let zeroTempDuration = minutesAboveThreshold
        let zeroTempEffectDouble = profile.currentBasal * sens * Double(zeroTempDuration) / 60
        let COBforCarbsReq = jmax(0.0, meal.mealCOB - 0.25 * meal.carbs)
        let carbsReq = try roundInt((bgUndershoot - zeroTempEffectDouble) / csf - COBforCarbsReq)
        if carbsReq >= profile.carbsReqThreshold, minutesAboveThreshold <= 45 {
            rT.carbsReq = carbsReq
            rT.carbsReqWithin = minutesAboveThreshold
            rT.reason += "\(carbsReq) add'l carbs req w/in \(minutesAboveThreshold)m; "
        }

        // Low glucose suspend (Boost compares IOB with -40 min of basal)
        if bg < threshold, iobData.iob < -profile.currentBasal * 40 / 60, minDelta > 0, minDelta > expectedDelta {
            rT.reason += "IOB \(fmt(iobData.iob)) < \(fmt(round(-profile.currentBasal * 40 / 60, 2)))"
            rT.reason += " and minDelta \(fmt(minDelta)) > expectedDelta \(fmt(expectedDelta)); "
        } else if bg < threshold || minGuardBG < threshold {
            rT.reason += "minGuardBG \(fmt(minGuardBG)) (\(minGuardBGSource)) < \(fmt(threshold))"
            bgUndershoot = targetBg - minGuardBG
            let worstCaseInsulinReq = bgUndershoot / sens
            var durationReq = try roundInt(60 * worstCaseInsulinReq / profile.currentBasal)
            durationReq = try roundInt(Double(durationReq) / 30.0) * 30
            durationReq = Swift.min(120, Swift.max(30, durationReq))
            lowSuspendTempBasal(durationReq, profile, &rT, currenttemp)
            return finish(rT, console)
        }

        // Cancel temps before the top of the hour
        let minutes = input.calendar.component(.minute, from: Date(timeIntervalSince1970: deliverAt / 1000))
        if profile.skipNeutralTemps, minutes >= 55 {
            rT.reason += "; Canceling temp at \(minutes) m past the hour. "
            setTempBasal(0.0, 0, profile, &rT, currenttemp)
            return finish(rT, console)
        }

        // eventualBG below target
        if eventualBG < minBg {
            rT.reason += "Eventual BG \(fmt(eventualBG)) < \(fmt(minBg))"
            if minDelta > expectedDelta, minDelta > 0, carbsReq == 0 {
                if naiveEventualBG < 40 {
                    rT.reason += ", naive_eventualBG < 40. "
                    lowSuspendTempBasal(30, profile, &rT, currenttemp)
                    return finish(rT, console)
                }
                if gs.delta > minDelta {
                    rT.reason += ", but Delta \(tick) > expectedDelta \(fmt(expectedDelta))"
                } else {
                    rT.reason += ", but Min. Delta \(fmt(minDelta)) > Exp. Delta \(fmt(expectedDelta))"
                }
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp \(fmt(currenttemp.rate)) ~ req \(fmt(round(basal, 2)))U/hr. "
                    return finish(rT, console)
                } else {
                    rT.reason += "; setting current basal of \(fmt(round(basal, 2))) as temp. "
                    setTempBasal(basal, 30, profile, &rT, currenttemp)
                    return finish(rT, console)
                }
            }

            var insulinReq = 2 * jmin(0.0, (eventualBG - targetBg) / futureSens)
            insulinReq = round(insulinReq, 2)
            var naiveInsulinReq = jmin(0.0, (naiveEventualBG - targetBg) / sens)
            naiveInsulinReq = round(naiveInsulinReq, 2)
            if minDelta < 0, minDelta > expectedDelta {
                insulinReq = round(insulinReq * (minDelta / expectedDelta), 2)
            }
            let rate = basal + (2 * insulinReq)

            let insulinScheduled = Double(currenttemp.duration) * (currenttemp.rate - basal) / 60
            let minInsulinReq = jmin(insulinReq, naiveInsulinReq)
            if insulinScheduled < minInsulinReq - basal * 0.3 {
                rT.reason += ", \(currenttemp.duration)m@\(fmt(currenttemp.rate)) is a lot less than needed. "
                lowTempBasal(rate, 30, profile, &rT, currenttemp)
                return finish(rT, console)
            }
            if currenttemp.duration > 5, rate >= currenttemp.rate * 0.8 {
                rT.reason += ", temp \(fmt(currenttemp.rate)) ~< req \(fmt(round(rate, 2)))U/hr. "
                return finish(rT, console)
            } else {
                if rate <= 0 {
                    bgUndershoot = targetBg - naiveEventualBG
                    let worstCaseInsulinReq = bgUndershoot / sens
                    var durationReq = try roundInt(60 * worstCaseInsulinReq / profile.currentBasal)
                    if durationReq < 0 {
                        durationReq = 0
                    } else {
                        durationReq = try roundInt(Double(durationReq) / 30.0) * 30
                        durationReq = Swift.min(120, Swift.max(0, durationReq))
                    }
                    if durationReq > 0 {
                        rT.reason += ", setting \(durationReq)m zero temp. "
                        // rate <= 0 here, and setTempBasal floors it at 0
                        lowSuspendTempBasal(durationReq, profile, &rT, currenttemp)
                        return finish(rT, console)
                    }
                } else {
                    rT.reason += ", setting \(fmt(round(rate, 2)))U/hr. "
                }
                lowTempBasal(rate, 30, profile, &rT, currenttemp)
                return finish(rT, console)
            }
        }

        // eventualBG above min but BG falling faster than expected
        if minDelta < expectedDelta {
            if !(microBolusAllowed && enableSMB) {
                if gs.delta < minDelta {
                    rT
                        .reason +=
                        "Eventual BG \(fmt(eventualBG)) > \(fmt(minBg)) but Delta \(tick) < Exp. Delta \(fmt(expectedDelta))"
                } else {
                    rT
                        .reason +=
                        "Eventual BG \(fmt(eventualBG)) > \(fmt(minBg)) but Min. Delta \(fmt(minDelta)) < Exp. Delta \(fmt(expectedDelta))"
                }
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp \(fmt(currenttemp.rate)) ~ req \(fmt(round(basal, 2)))U/hr. "
                    return finish(rT, console)
                } else {
                    rT.reason += "; setting current basal of \(fmt(round(basal, 2))) as temp. "
                    setTempBasal(basal, 30, profile, &rT, currenttemp)
                    return finish(rT, console)
                }
            }
        }

        // eventualBG or minPredBG below max_bg
        if jmin(eventualBG, minPredBG) < maxBg {
            if !(microBolusAllowed && enableSMB) {
                rT.reason += "\(fmt(eventualBG))-\(fmt(minPredBG)) in range: no temp required"
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp \(fmt(currenttemp.rate)) ~ req \(fmt(round(basal, 2)))U/hr. "
                    return finish(rT, console)
                } else {
                    rT.reason += "; setting current basal of \(fmt(round(basal, 2))) as temp. "
                    setTempBasal(basal, 30, profile, &rT, currenttemp)
                    return finish(rT, console)
                }
            }
        }

        if eventualBG >= maxBg {
            rT.reason += "Eventual BG \(fmt(eventualBG)) >= \(fmt(maxBg)), "
        }
        if iobData.iob > maxIob {
            rT.reason += "IOB \(fmt(round(iobData.iob, 2))) > max_iob \(fmt(maxIob))"
            if currenttemp.duration > 15, basal == currenttemp.rate {
                rT.reason += ", temp \(fmt(currenttemp.rate)) ~ req \(fmt(round(basal, 2)))U/hr. "
                return finish(rT, console)
            } else {
                rT.reason += "; setting current basal of \(fmt(round(basal, 2))) as temp. "
                setTempBasal(basal, 30, profile, &rT, currenttemp)
                return finish(rT, console)
            }
        }

        // MARK: High temp and SMB, Boost version

        var insulinReq = round((jmin(minPredBG, eventualBG) - targetBg) / futureSens, 2)
        if insulinReq > maxIob - iobData.iob {
            rT.reason += "max_iob \(fmt(maxIob)), "
            insulinReq = maxIob - iobData.iob
        }

        var rate = basal + (2 * insulinReq)
        insulinReq = round(insulinReq, 3)
        rT.insulinReq = insulinReq

        let lastBolusAge = round((systemTime - iobData.lastBolusTime) / 60000.0, 1)

        // ML models
        let directionNumValue = directionNum(shortAvgDelta: gs.shortAvgDelta)
        let mlInputs = V1MlInputs(
            bg: bg,
            iob: iobData.iob,
            basaliob: iobData.basaliob,
            activity: iobData.activity,
            netbasalinsulin: iobData.netbasalinsulin,
            targetBg: targetBg,
            directionNum: directionNumValue,
            insulinReq: insulinReq,
            cob: meal.mealCOB,
            eventualBG: eventualBG,
            expectedDelta: expectedDelta,
            minDelta: minDelta,
            tdd: profile.tdd > 0 ? profile.tdd : 0.0,
            recentSmbVolume60Min: input.recentSmbVolume60Min,
            timeSinceLastSmbMin: input.timeSinceLastSmbMin,
            currentTime: currentTime
        )
        let mlHypoRisk = input.ml.hypoRisk?(mlInputs)
        if let mlHypoRisk {
            rT.mlHypoRisk = round(mlHypoRisk, 3)
        }
        let mlMealLikely = input.ml.mealLikely?(mlInputs)
        if let mlMealLikely {
            rT.mlMealLikely = round(mlMealLikely, 3)
        }

        // Layer B: graduated SMB scaling and the tier downgrade
        let riskScale: Double
        if let mlHypoRisk, mlHypoRisk > 0.3 {
            let scale = jmax(0.0, 1.0 - (mlHypoRisk - 0.3) / 0.7)
            rT.mlRiskScale = round(scale, 2)
            riskScale = scale
        } else {
            rT.mlRiskScale = 1.0
            riskScale = 1.0
        }
        let mlTierDowngrade = mlHypoRisk != nil && mlHypoRisk! > 0.6

        // Layer C: G3 pre-UAM uncertainty hold
        let g3Conditions = g3HoldConditionsMet(mealCob: meal.mealCOB, delta: gs.delta, shortAvgDelta: gs.shortAvgDelta)
        let mealModelReleases = mlMealLikely != nil && mlMealLikely! > 0.50
        let accelerationReleases = deltaAccl > 10.0
        let bgThresholdReleases = bg > 160.0 && gs.delta > 5.0
        let g3Released = mealModelReleases || accelerationReleases || bgThresholdReleases
        let g3HoldActive = g3Conditions && !g3Released
        if g3Conditions, g3Released {
            rT.mlMealG3Released = true
            rT.mlG3ReleaseSource = accelerationReleases ? "delta_accl" : (bgThresholdReleases ? "bg_threshold" : "meal_model")
        }

        if microBolusAllowed, enableSMB, bg > threshold {
            var maxBolus: Double
            if iobData.iob > -0.2 {
                maxBolus = round(profile.currentBasal * Double(profile.maxUAMSMBBasalMinutes) / 60.0, 1)
            } else {
                maxBolus = round(profile.currentBasal * Double(profile.maxSMBBasalMinutes) / 60.0, 1)
            }

            // Multi-tier SMB sizing
            let roundSMBTo = 1.0 / profile.bolusIncrement
            let profileSwitch = Double(profile.profileSwitch)

            var insulinReqPCT = 100.0 / profile.boostInsulinReq

            var insulinDivisor: Double
            let scalePct: Double
            if profile.enableBoostPercentScale {
                scalePct = round(100.0 / (profile.boostPercentScale * (profileSwitch / 100.0)), 3)
                insulinDivisor = bg < 108 ? scalePct : insulinReqPCT - percentScaleReduction(
                    bg: bg,
                    slope: insulinReqPCT - scalePct
                )
            } else {
                scalePct = insulinReqPCT
                insulinDivisor = insulinReqPCT
            }

            let uamBoost1 = abs(gs.shortAvgDelta) > 0.001 ? gs.delta / gs.shortAvgDelta : 0.0
            let uamBoost2 = abs(gs.longAvgDelta) > 0.001 ? abs(gs.delta / gs.longAvgDelta) : 0.0

            // Fast-carb rebound
            let lowTriggered = profile.recentLowBG < 100.0
            let reversalScore = gs.longAvgDelta < 0 && gs.delta > 0 ? gs.delta * abs(gs.longAvgDelta) : 0.0
            let reversalTriggered = reversalScore > 30.0
            let fastCarbConditions = (lowTriggered || reversalTriggered) && meal.mealCOB == 0.0 && deltaAccl > 25.0
            var fastCarbScale = 1.0
            let fastCarbRebound: Bool
            if fastCarbConditions, bg < 170.0 {
                let velocityOverride = gs.delta > 10
                let eventualBgOverride = eventualBG > targetBg + 100 && profile.recentLowBG >= 75.0
                if velocityOverride || eventualBgOverride, bg > targetBg + 20 {
                    fastCarbScale = 1.0
                    fastCarbRebound = false
                } else {
                    fastCarbScale = postRescueReboundScale(bg: bg)
                    fastCarbRebound = true
                }
            } else {
                fastCarbRebound = false
            }
            rT.fastCarbProtection = fastCarbRebound
            if fastCarbRebound {
                let trig: String
                if lowTriggered, reversalTriggered {
                    trig = "low \(fmt(round(profile.recentLowBG, 0))) rev \(fmt(round(reversalScore, 0)))"
                } else if lowTriggered {
                    trig = "low \(fmt(round(profile.recentLowBG, 0)))"
                } else {
                    trig = "rev \(fmt(round(reversalScore, 0)))"
                }
                rT.reason += "Fast-carb rebound (\(trig)→\(fmt(bg))): scale \(fmt(round(fastCarbScale * 100, 0)))%; "
            }

            let boostMaxIOB = profile.boostMaxIOB
            let boostMax = profile.boostBolus
            let boostScale = profile.boostScale * (profileSwitch / 100.0)
            var boostInsulinReq = basal

            let COB = meal.mealCOB
            let CR = profile.carbRatio

            rT
                .reason +=
                "UAM Boost 1: \(fmt(round(uamBoost1, 2))); UAM Boost 2: \(fmt(round(uamBoost2, 2))); Delta: \(fmt(gs.delta)); ShortAvg: \(fmt(gs.shortAvgDelta)); "

            var microBolus: Double
            var fastCarbScaleApplied = false

            let inPostRescueWindow = input.recentLowBG45Min < postRescueLowThresholdMgdl

            if boostActive, COB > 0, lastCarbAge < 25 {
                // Tier 1: primary COB handling
                rT.boostTier = "COB_PRIMARY"
                rT.insulinReqPctEffective = round((1.0 / insulinReqPCT) * 100, 1)
                rT.reason += "Primary carb handling code operating; lastCarbAge: \(lastCarbAge); "
                microBolus = floorTo(jmin(insulinReq / insulinReqPCT, insulinReq), roundSMBTo)
            } else if boostActive, COB > 0, lastCarbAge < 40, gs.delta > 5 {
                // Tier 2: secondary COB handling
                rT.boostTier = "COB_SECONDARY"
                rT.insulinReqPctEffective = round((1.0 / insulinReqPCT) * 100, 1)
                let cobBoostMax = jmax((COB / CR) / insulinReqPCT, boostMax)
                rT.reason += "Secondary carb handling; boost_max due to COB = \(fmt(cobBoostMax)); lastCarbAge: \(lastCarbAge); "
                microBolus = floorTo(jmin(insulinReq / insulinReqPCT, cobBoostMax), roundSMBTo)
            } else if !mlTierDowngrade, !inPostRescueWindow, gs.delta >= 5, gs.shortAvgDelta >= 3, uamBoost1 > 1.2, uamBoost2 > 2,
                      boostActive, iobData.iob < boostMaxIOB, boostScale < 3, eventualBG > targetBg, bg > 80, insulinReq > 0
            {
                // Tier 3: UAM Boost
                rT.boostTier = "UAM_BOOST"
                boostInsulinReq = jmin(boostScale * boostInsulinReq, boostMax)
                if boostInsulinReq > boostMaxIOB - iobData.iob {
                    boostInsulinReq = boostMaxIOB - iobData.iob
                }
                if deltaAccl > 1 {
                    insulinReqPCT = insulinDivisor
                }
                if boostInsulinReq < (insulinReq / insulinReqPCT) {
                    microBolus = floorTo(jmin(insulinReq / insulinReqPCT, boostMax), roundSMBTo)
                    rT.reason += "UAM Boost enacted; SMB equals \(fmt(microBolus)); "
                } else {
                    microBolus = floorTo(jmin(boostInsulinReq, boostMax), roundSMBTo)
                }
                if fastCarbRebound {
                    microBolus = floorTo(microBolus * fastCarbScale, roundSMBTo)
                    fastCarbScaleApplied = true
                }
                iTimeActive = true
                rT.reason += "UAM Boost enacted; SMB equals \(fmt(boostInsulinReq)); "
            } else if !mlTierDowngrade, !inPostRescueWindow, deltaAccl > 5 || gs.delta > 8, bg > 180, boostActive,
                      iobData.iob < boostMaxIOB, boostScale < 3, eventualBG > targetBg, bg > 80, insulinReq > 0
            {
                // Tier 4: UAM High Boost
                rT.boostTier = "UAM_HIGH_BOOST"
                boostInsulinReq = jmin(boostScale * boostInsulinReq, boostMax)
                if boostInsulinReq > boostMaxIOB - iobData.iob {
                    boostInsulinReq = boostMaxIOB - iobData.iob
                }
                if boostInsulinReq < (insulinReq / insulinReqPCT) {
                    boostInsulinReq = jmin(boostInsulinReq + (0.5 * (insulinReq / insulinReqPCT)), insulinReq / insulinReqPCT)
                    microBolus = floorTo(jmin(boostInsulinReq / insulinReqPCT, boostMax), roundSMBTo)
                    rT.reason += "UAM High Boost enacted; SMB equals \(fmt(microBolus)); "
                } else {
                    microBolus = floorTo(jmin(boostInsulinReq, boostMax), roundSMBTo)
                }
            } else if !mlTierDowngrade, !g3HoldActive, !inPostRescueWindow, bg > 110, bg < 181, gs.delta > 3, deltaAccl > 0,
                      eventualBG > targetBg, iobData.iob < boostMaxIOB, boostActive
            {
                // Tier 5: percent scale
                rT.boostTier = "PERCENT_SCALE"
                if insulinReq > boostMaxIOB - iobData.iob {
                    insulinReq = boostMaxIOB - iobData.iob
                }
                if insulinReq < 0 {
                    insulinDivisor = insulinReqPCT - ((abs(bg - 180) / 72) * (insulinReqPCT - (2 * scalePct)))
                    insulinReq = boostInsulinReq
                }
                microBolus = floorTo(jmin(insulinReq / insulinDivisor, boostMax), roundSMBTo)
                if fastCarbRebound {
                    microBolus = floorTo(microBolus * fastCarbScale, roundSMBTo)
                    fastCarbScaleApplied = true
                }
                rT
                    .reason +=
                    "Increased SMB as percentage of insulin required to \(fmt((1.0 / insulinDivisor) * 100))%. SMB is \(fmt(microBolus)); "
                iTimeActive = true
            } else if !mlTierDowngrade, !g3HoldActive, deltaAccl > 25, gs.delta > 4, bg > 110, iobData.iob < boostMaxIOB,
                      boostActive, eventualBG > targetBg
            {
                // Tier 6: acceleration bolus
                rT.boostTier = "ACCELERATION"
                boostInsulinReq = jmin(boostScale * boostInsulinReq, boostMax)
                if boostInsulinReq > boostMaxIOB - iobData.iob {
                    boostInsulinReq = boostMaxIOB - iobData.iob
                }
                insulinDivisor = insulinReqPCT - percentScaleReduction(bg: bg, slope: insulinReqPCT - (2 * scalePct))
                insulinReqPCT = insulinDivisor
                microBolus = floorTo(jmin(boostInsulinReq / insulinReqPCT, boostMax), roundSMBTo)
                if fastCarbRebound {
                    microBolus = floorTo(microBolus * fastCarbScale, roundSMBTo)
                    fastCarbScaleApplied = true
                }
                iTimeActive = true
                rT.reason += "Acceleration bolus triggered; SMB equals \(fmt(boostInsulinReq)); "
            } else if !g3HoldActive, boostActive, gs.delta > 0, deltaAccl >= 0.5 {
                // Tier 7: enhanced oref1
                rT.boostTier = "ENHANCED_OREF1"
                if insulinReq > boostMaxIOB - iobData.iob {
                    insulinReq = boostMaxIOB - iobData.iob
                }
                microBolus = floorTo(jmin(insulinReq / insulinReqPCT, boostMax), roundSMBTo)
                rT.reason += "Enhanced oref1 triggered; SMB equals \(fmt(microBolus)); "
            } else if !g3HoldActive {
                // Tier 8: regular oref1
                rT.boostTier = "REGULAR_OREF1"
                microBolus = floorTo(jmin(insulinReq / insulinReqPCT, maxBolus), roundSMBTo)
                rT.reason += "Regular oref1 triggered; SMB equals \(fmt(microBolus)); "
            } else {
                rT.boostTier = "NONE"
                microBolus = 0.0
                rT.reason += "G3 pre-UAM uncertainty hold: T5/6/7/8 suppressed; "
            }

            // Spike override (Tier 8 only, audit item 20)
            if spikeOverrideAllowed(
                boostActive: boostActive,
                tier: rT.boostTier,
                inPostRescueWindow: inPostRescueWindow,
                mlTierDowngrade: mlTierDowngrade
            ),
                bg > 180, gs.delta > 5, insulinReq > 3 * maxBolus,
                microBolus >= maxBolus - profile.bolusIncrement, iobData.iob < boostMaxIOB
            {
                let spikeOverrideCap = jmin(boostMax, boostMaxIOB - iobData.iob)
                let overrideBolus = floorTo(jmin(insulinReq / insulinReqPCT, spikeOverrideCap), roundSMBTo)
                if overrideBolus > microBolus {
                    rT.reason += "Spike override: cap raised from \(fmt(maxBolus)) to \(fmt(round(spikeOverrideCap, 2))); "
                    microBolus = overrideBolus
                }
            }

            // Composed post-rescue rebound guard, with the tight-ramp trial cap
            let tightRamp = input.postRescueTightRampCap != nil
            if inPostRescueWindow, COB == 0.0, bg < 170.0 || tightRamp, microBolus > 0, !fastCarbScaleApplied {
                let prScale = tightRamp
                    ? jmin(postRescueReboundScale(bg: bg), input.postRescueTightRampCap!)
                    : postRescueReboundScale(bg: bg)
                let preSMB = microBolus
                microBolus = floorTo(microBolus * prScale, roundSMBTo)
                rT
                    .reason +=
                    "Post-rescue rebound scale \(fmt(round(prScale * 100, 0)))%: SMB \(fmt(round(preSMB, 2))) → \(fmt(round(microBolus, 2))); "
            }

            // Layer B: ML risk scaling
            if riskScale < 1.0, microBolus > 0 {
                let preSMB = microBolus
                microBolus = floorTo(microBolus * riskScale, roundSMBTo)
                rT
                    .reason +=
                    "ML risk scale \(fmt(round(riskScale * 100, 0)))%: SMB \(fmt(round(preSMB, 2))) → \(fmt(round(microBolus, 2))); "
            }

            // Cumulative SMB cap per rolling 60 min
            if input.cumulativeSmbCap60Min > 0.0, input.recentSmbVolume60Min >= input.cumulativeSmbCap60Min, microBolus > 0 {
                rT
                    .reason +=
                    "Cumulative SMB cap \(fmt(round(input.recentSmbVolume60Min, 2)))U/\(fmt(round(input.cumulativeSmbCap60Min, 2)))U reached — SMB suspended; "
                microBolus = 0.0
                rT.boostTier = "CUMULATIVE_SMB_CAP"
            }
            // Final max_iob clamp (audit item 5)
            microBolus = smbWithinMaxIob(
                microBolus,
                maxIob: profile.maxIob,
                iob: iobData.iob,
                bolusIncrement: profile.bolusIncrement
            )

            // Zero temp for SMB
            let smbTarget = targetBg
            let worstCaseInsulinReq = (smbTarget - (naiveEventualBG + minIOBPredBG) / 2.0) / sens
            var durationReq = try roundInt(60 * worstCaseInsulinReq / profile.currentBasal)

            if insulinReq > 0, microBolus < profile.bolusIncrement {
                durationReq = 0
            }

            var smbLowTempReq = 0.0
            if durationReq <= 0 {
                durationReq = 0
            } else if durationReq >= 30 {
                durationReq = try roundInt(Double(durationReq) / 30.0) * 30
                durationReq = Swift.min(60, Swift.max(0, durationReq))
            } else {
                smbLowTempReq = round(basal * Double(durationReq) / 30.0, 2)
                durationReq = 30
            }
            rT.reason += " insulinReq \(fmt(insulinReq))"
            if microBolus >= maxBolus {
                rT.reason += "; standardMaxBolus \(fmt(maxBolus))"
            }
            if durationReq > 0, !iTimeActive {
                rT.reason += "; setting \(durationReq)m low temp of \(fmt(smbLowTempReq))U/h"
            }
            rT.reason += ". "

            let smbInterval = Double(Swift.min(10, Swift.max(1, profile.smbInterval))) * 60.0
            let lastBolusAgeSec = (systemTime - iobData.lastBolusTime) / 1000.0

            if lastBolusAgeSec > smbInterval - 6.0 {
                if microBolus > 0 {
                    rT.units = microBolus
                    rT.reason += "Microbolusing \(fmt(microBolus))U. "
                }
            } else {
                let nextBolusMins = (smbInterval - lastBolusAgeSec) / 60.0
                let nextBolusSeconds = (smbInterval - lastBolusAgeSec).truncatingRemainder(dividingBy: 60)
                let waitingSeconds = round(nextBolusSeconds, 0).truncatingRemainder(dividingBy: 60)
                let waitingMins = round(nextBolusMins - waitingSeconds / 60.0, 0)
                rT.reason += "Waiting \(fmt(waitingMins))m \(fmt(waitingSeconds))s to microbolus again."
            }

            // iTimeActive triggers
            if (boostActive && COB > 0 && lastCarbAge < 15) ||
                (basal > (4 * profileCurrentBasal) && lastBolusAge < 15 && deltaAccl > 0)
            {
                iTimeActive = true
            }

            if durationReq > 0, !iTimeActive {
                rT.rate = smbLowTempReq
                rT.duration = durationReq
                return finish(rT, console)
            }
        }

        // iTimeActive high basal
        let maxSafe = maxSafeBasal(profile)
        rT.reason += "Additional basal trigger currently set to \(iTimeActive); "

        if iTimeActive, !(microBolusAllowed && enableSMB && bg > threshold) {
            rT.reason += "Boost bolus triggered due to continued acceleration post Boost function; "
        }

        if iTimeActive {
            rT.reason += "Add high basal with Boost: \(fmt((basal * 5 / 60) * 30))U; "
            rT.duration = 15
            rate = basal * 5
        }

        if rate > maxSafe, !iTimeActive {
            rT.reason += "adj. req. rate: \(fmt(round(rate, 2))) to maxSafeBasal: \(fmt(maxSafe)), "
            rate = maxSafe
        }

        let insulinScheduled = Double(currenttemp.duration) * (currenttemp.rate - basal) / 60
        if insulinScheduled >= insulinReq * 2, !iTimeActive {
            rT
                .reason +=
                "\(currenttemp.duration)m@\(fmt(currenttemp.rate)) > 2 * insulinReq. Setting temp basal of \(fmt(round(rate, 2)))U/hr. "
            setTempBasal(rate, 30, profile, &rT, currenttemp)
            return finish(rT, console)
        }

        if currenttemp.duration == 0 {
            rT.reason += "no temp, setting \(fmt(round(rate, 2)))U/hr. "
            setTempBasal(rate, 30, profile, &rT, currenttemp)
            return finish(rT, console)
        }

        if currenttemp.duration > 5, rate <= currenttemp.rate {
            rT.reason += "temp \(fmt(currenttemp.rate)) >~ req \(fmt(round(rate, 2)))U/hr. "
            return finish(rT, console)
        }

        rT.reason += "temp \(fmt(currenttemp.rate)) < \(fmt(round(rate, 2)))U/hr. "
        setTempBasal(rate, 30, profile, &rT, currenttemp)
        return finish(rT, console)
    }

    /// Kotlin `for (i in list.size - 1 downTo n) { if (list[i-1] != list[i]) break else removeAt(lastIndex) }`.
    static func trimFlatTail(_ values: inout [Double], downTo n: Int) {
        let start = values.count - 1
        guard start >= n else { return }
        for i in stride(from: start, through: n, by: -1) {
            if values[i - 1] != values[i] { break }
            values.removeLast()
        }
    }

    static func finish(_ rT: V1Result, _ console: [String]) -> V1Result {
        var out = rT
        out.console = console + rT.console
        return out
    }
}
