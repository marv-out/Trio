import Foundation

struct Preferences: JSON, Equatable {
    var maxIOB: Decimal = 0
    var maxDailySafetyMultiplier: Decimal = 3
    var currentBasalSafetyMultiplier: Decimal = 4
    var autosensMax: Decimal = 1.2
    var autosensMin: Decimal = 0.7
    var smbDeliveryRatio: Decimal = 0.5
    var rewindResetsAutosens: Bool = true
    var highTemptargetRaisesSensitivity: Bool = false
    var lowTemptargetLowersSensitivity: Bool = false
    var sensitivityRaisesTarget: Bool = false
    var resistanceLowersTarget: Bool = false
    var advTargetAdjustments: Bool = false
    var exerciseMode: Bool = false
    var halfBasalExerciseTarget: Decimal = 160
    var maxCOB: Decimal = 120
    var maxMealAbsorptionTime: Decimal = 6
    var wideBGTargetRange: Bool = false
    var skipNeutralTemps: Bool = false
    var unsuspendIfNoTemp: Bool = false
    var min5mCarbimpact: Decimal = 8
    var remainingCarbsFraction: Decimal = 1.0
    var remainingCarbsCap: Decimal = 90
    var enableUAM: Bool = false
    var a52RiskEnable: Bool = false
    var enableSMBWithCOB: Bool = false
    var enableSMBWithTemptarget: Bool = false
    var enableSMBAlways: Bool = false
    var enableSMBAfterCarbs: Bool = false
    var allowSMBWithHighTemptarget: Bool = false
    var maxSMBBasalMinutes: Decimal = 30
    var maxUAMSMBBasalMinutes: Decimal = 30
    var smbInterval: Decimal = 3
    var bolusIncrement: Decimal = 0.1
    var curve: InsulinCurve = .rapidActing
    var useCustomPeakTime: Bool = false
    var insulinPeakTime: Decimal = 75
    var carbsReqThreshold: Decimal = 1.0
    var noisyCGMTargetMultiplier: Decimal = 1.3
    var suspendZerosIOB: Bool = true
    var timestamp: Date?
    var maxDeltaBGthreshold: Decimal = 0.2
    var adjustmentFactor: Decimal = 0.8
    var adjustmentFactorSigmoid: Decimal = 0.5
    var sigmoid: Bool = false
    var useNewFormula: Bool = false
    var useWeightedAverage: Bool = false
    var weightPercentage: Decimal = 0.35
    var tddAdjBasal: Bool = false
    var enableSMB_high_bg: Bool = false
    var enableSMB_high_bg_target: Decimal = 110
    var threshold_setting: Decimal = 60
    var updateInterval: Decimal = 20
    var boostMode: BoostMode = .off
    // Boost DynISF (V1) — used to compute a Boost-flavoured ISF in active mode. Defaults match AAPS.
    var boostUseTdd: Bool = false
    // With TDD-based ISF off, let oref autosens adapt ISF, basal, target and carbohydrate absorption
    // (AAPS ApsBoostAutosensWhenNoTdd, default on from 1c6358ac6c). No effect with TDD on.
    var boostAutosensWhenNoTdd: Bool = true
    var boostDynIsfNormalTarget: Decimal = 99
    var boostDynIsfBgCap: Decimal = 210
    var boostDynIsfVelocity: Decimal = 100 // percent
    var boostDynIsfAdjustmentFactor: Decimal = 100 // percent
    var boostEnableCircadianIsf: Bool = false
    // V1 tier-engine SMB sizing (AAPS DetermineBasalBoost). Not shown in the settings screens, apart from
    // Boost max IOB: V6 replaces V1's SMB on the cycles it runs, but V1's dose still bounds V6 in the
    // non-meal states and the post-rescue window, and is what is delivered whenever V6 stands aside.
    // Defaults and ranges are AAPS's (DoubleKey ApsBoostBolus, ApsBoostMaxIob, ApsBoostInsulinReqPct,
    // ApsBoostScale, ApsBoostPercentScale; BooleanKey ApsBoostEnablePercentScale, ApsBoostAllowWithHighTt).
    // Auto-config carries the bolus cap from the user's max bolus, as AAPS does.
    var boostBolus: Decimal = 2.5 // 0.1…10 U, the per-SMB cap of Tiers 2 to 7
    /// 0.1…12 U. Boost uses min(this, max IOB), so the default of 12, the maximum, uses max IOB and a
    /// lower value is the person's own limit (AAPS ApsBoostMaxIob, same default). Not a 0 sentinel: an
    /// older build reads the stored value raw, and 12 stays bounded by max IOB where 0 stops Boost.
    var boostMaxIOB: Decimal = 12
    /// Written as true with every save. A stored file without it predates the 12 default, when the
    /// value was hidden and so the 1.0 U factory value, an onboarding copy or an imported value, never
    /// a choice; decoding such a file sets it to 12 once.
    var boostMaxIOBMigrated: Bool = true
    var boostInsulinReqPct: Decimal = 50 // 30…100 %, the share of insulinReq an SMB delivers
    var boostScale: Decimal = 1.0 // 0.1…3, multiplier on basal for the UAM and acceleration tiers
    var boostPercentScale: Decimal = 200 // 50…500 %, the percent-scale factor
    // On by default since Boost 6.3.0; a stored off stays off, as in AAPS.
    var boostEnablePercentScale: Bool = true
    var boostAllowWithHighTt: Bool = false // keep Boost active under a high temp target
    // V5 tuning knobs (ranges match AAPS).
    var boostV5Aggression: Decimal = 1.0 // 0.7…1.6 — scales CONFIRMED dose
    var boostV5HypoCaution: Decimal = 1.0 // 1.0…2.0 — deepens ML hypo damping
    var boostV5Sensitivity: Decimal = 1.0 // 0.8…1.2 — budget lever
    var boostV5ConfirmedCapU: Decimal = 2.5 // 0…7.5 U
    var boostV5CommittedCapU: Decimal = 0.5 // 0…5.0 U
    // Rolling-60-min cumulative SMB cap (anti-stacking / dose-frequency safeguard, matches AAPS).
    // 0 disables. Default permissive (10 = max) on purpose: auto-config LOWERS it per user; a
    // conservative default would needlessly throttle before personalisation.
    var boostCumulativeSmbCap60Min: Decimal = 10.0 // 0…10 U
    var boostV5FastCarbConfirm: Bool = true
    // 2026-07 composed Phase-3 brake-floor (AAPS 730b3dcb2c). Advanced, default OFF. When ON (and V6
    // is the active doser), floors the delivered dose at F=0.25 of the hypo-damped budget on
    // meal-session high cycles, preventing the multiplicative brake stack (median 0.037) from
    // rounding mid-meal doses to zero. PER-USER only — enable only where trailing-14d TBR<70 < 3.5%
    // AND TBR<54 < 0.8% (the same-day cohort re-review excluded TBR-heavy users). See ComposedFloor.
    var boostV5ComposedFloorActive: Bool = false
    /// Aggressive early confirm (AAPS `ApsBoostV5AggressiveEarlyConfirm`). Opt-in and auto-config
    /// managed: the sustained-score early-confirm path opens one cycle earlier again. About 28% of
    /// its candidates are fizzle-catches, so it delivers new insulin at roughly the base rate and
    /// is not a cohort default.
    var boostV5AggressiveEarlyConfirm: Bool = false
    /// Velocity-budget floor (AAPS `ApsBoostV5VelocityBudgetActive`). Opt-in and auto-config
    /// managed: on the budget-near-zero high tail it delivers a bounded hold where the base engine
    /// doses about zero. Gated by the same fail-closed 14-day time-below-range test as the composed
    /// floor, and by every Phase-3 hard gate and seam guard.
    var boostV5VelocityBudgetActive: Bool = false
    /// Early-primer ceiling in units (AAPS `ApsBoostV5PrimerCapU`). 0 turns the primer off.
    /// Auto-config sizes it from the person's own committed cap.
    var boostV5PrimerCapU: Decimal = 0
    /// Route the primer as a retractable temp basal rather than a bolus (AAPS
    /// `ApsBoostV5PrimerTbrFallback`). Auto-config sets it for anyone not clearly well-controlled.
    var boostV5PrimerTbrFallback: Bool = true
    /// User override forcing the bolus route even when the fallback above is set (AAPS
    /// `ApsBoostV5PrimerBolusMode`). Honoured always, and recorded in the reason when it overrides.
    var boostV5PrimerBolusMode: Bool = false
    /// Confirm tranche (AAPS `ApsBoostV5ConfirmTranche`). Opt-in: the confirm shot gives a fraction
    /// now and holds the rest for ten minutes, released only if the rise continues.
    var boostV5ConfirmTranche: Bool = false
    /// Fraction of the confirm shot delivered immediately.
    var boostV5TrancheFraction: Decimal = 0.5
    /// Release threshold on the rule's probability. Raising it withholds more, which is a
    /// tightening. Only this is personal; the coefficients are population-derived.
    var boostV5TrancheThreshold: Decimal = 0.48
    /// Enrolment in the pre-registered post-rescue tight-ramp trial (AAPS 2378baf367). Default off,
    /// and deliberately not auto-config managed: enrolling is a decision, not a derivation.
    var boostV5PostRescueTightRampTrial: Bool = false
    // Per-knob "user touched this cap" flags — the Swift equivalent of Android's getIfExists==null.
    // Set true only when the user moves the cap slider (FeatureSettingsView onEditingChanged), never
    // programmatically. Auto-config seeds a cap from history ONLY when its flag is false, so it can
    // raise a cap for a genuine new user yet never override a value the user deliberately set (even
    // to the default). Not user-facing.
    var boostV5ConfirmedCapUUserSet: Bool = false
    var boostV5CommittedCapUUserSet: Bool = false
    var boostCumulativeSmbCap60MinUserSet: Bool = false
    // LEGACY internal one-shot flag (pre per-knob resolution): set true once the V5 knobs had been
    // auto-configured. Superseded 2026-07-06 (AAPS b2c0705e5e) by per-knob resolution below; kept
    // only so existing installs migrate (a set flag marks off-default knobs resolved, then clears).
    var boostV5AutoConfigDone: Bool = false
    // Per-knob auto-config resolution marks (AAPS BooleanComposedKey.BoostV5AutoConfigResolved
    // equivalent): a knob is RESOLVED once auto-config has either applied it or skipped it because
    // the user tuned it; unresolved knobs retry on later cycles (e.g. knobs added to auto-config
    // in an update, or first run with insufficient history). Raw values of BoostAutoConfigKnob.
    // Not user-facing.
    var boostV5AutoConfigResolved: [String] = []
    // Auto-config persistence schema version (see BoostV5AutoConfigApply.autoConfigSchemaVersion,
    // mirrors AAPS 131923247e): bumped when the resolution semantics change so already-persisted
    // per-knob resolved marks can be re-audited (versioned re-migration). 0 = pre-versioning.
    // Not user-facing.
    var boostV5AutoConfigSchemaVersion: Int = 0
    // Night mode (suppresses SMB overnight). Defaults match AAPS.
    var boostNightModeEnabled: Bool = false
    var boostNightModeStartHour: Decimal = 22
    var boostNightModeEndHour: Decimal = 7
    var boostNightModeBgOffset: Decimal = 27 // mg/dL
    var boostNightModeDisableWithCob: Bool = false
    var boostNightModeDisableWithLowTt: Bool = false
    var boostNightModeAutoBySleep: Bool = false
    // Steps-based sleep-in (lie-in) backstop: within this many hours of night end, 60-min steps below
    // the threshold keep Boost suppressed even if the HR sleep-state machine wrongly reported AWAKE.
    // Defaults match AAPS (ApsBoostSleepInHours 2.0, ApsBoostSleepInSteps 250).
    var boostSleepInHours: Decimal = 2.0 // 0…18
    var boostSleepInSteps: Decimal = 250 // 0…1000
    // V6 anticipatory pre-meal target.
    var boostV6PreMealEnabled: Bool = false
    var boostV6PreMealTargetMgdl: Decimal = 72
    var boostV6PreMealLeadMin: Decimal = 60
    // Activity / HR / post-exercise (feed BoostActivityMonitor). Defaults match AAPS.
    var boostActivitySteps5: Decimal = 420
    var boostActivitySteps15: Decimal = 800
    var boostActivitySteps30: Decimal = 1200
    var boostActivitySteps60: Decimal = 1800
    var boostActivityPct: Decimal = 80
    var boostInactivitySteps: Decimal = 500
    var boostInactivityPct: Decimal = 130
    var boostHrIntegrationEnabled: Bool = false
    var boostHrMaxBpm: Decimal = 180
    var boostHrRestingBpm: Decimal = 60
    var boostHrStressDetection: Bool = false
    var boostPostExerciseEnabled: Bool = false
    var boostPostExerciseHours: Decimal = 2
    var boostPostExerciseTarget: Decimal = 144
    var boostPostExerciseScale: Decimal = 0.5
    var boostPostExerciseMinDuration: Decimal = 10
}

extension Preferences {
    private enum CodingKeys: String, CodingKey {
        case maxIOB = "max_iob"
        case maxDailySafetyMultiplier = "max_daily_safety_multiplier"
        case currentBasalSafetyMultiplier = "current_basal_safety_multiplier"
        case autosensMax = "autosens_max"
        case autosensMin = "autosens_min"
        case smbDeliveryRatio = "smb_delivery_ratio"
        case rewindResetsAutosens = "rewind_resets_autosens"
        case highTemptargetRaisesSensitivity = "high_temptarget_raises_sensitivity"
        case lowTemptargetLowersSensitivity = "low_temptarget_lowers_sensitivity"
        case sensitivityRaisesTarget = "sensitivity_raises_target"
        case resistanceLowersTarget = "resistance_lowers_target"
        case advTargetAdjustments = "adv_target_adjustments"
        case exerciseMode = "exercise_mode"
        case halfBasalExerciseTarget = "half_basal_exercise_target"
        case maxCOB
        case maxMealAbsorptionTime
        case wideBGTargetRange = "wide_bg_target_range"
        case skipNeutralTemps = "skip_neutral_temps"
        case unsuspendIfNoTemp = "unsuspend_if_no_temp"
        case min5mCarbimpact = "min_5m_carbimpact"
        case remainingCarbsFraction
        case remainingCarbsCap
        case enableUAM
        case a52RiskEnable = "A52_risk_enable"
        case enableSMBWithCOB = "enableSMB_with_COB"
        case enableSMBWithTemptarget = "enableSMB_with_temptarget"
        case enableSMBAlways = "enableSMB_always"
        case enableSMBAfterCarbs = "enableSMB_after_carbs"
        case allowSMBWithHighTemptarget = "allowSMB_with_high_temptarget"
        case maxSMBBasalMinutes
        case maxUAMSMBBasalMinutes
        case smbInterval = "SMBInterval"
        case bolusIncrement = "bolus_increment"
        case curve
        case useCustomPeakTime
        case insulinPeakTime
        case carbsReqThreshold
        case noisyCGMTargetMultiplier
        case suspendZerosIOB = "suspend_zeros_iob"
        case maxDeltaBGthreshold = "maxDelta_bg_threshold"
        case adjustmentFactor
        case adjustmentFactorSigmoid
        case sigmoid
        case useNewFormula
        case useWeightedAverage
        case weightPercentage
        case tddAdjBasal
        case enableSMB_high_bg
        case enableSMB_high_bg_target
        case threshold_setting
        case updateInterval
        case boostMode
        case boostUseTdd
        case boostAutosensWhenNoTdd
        case boostDynIsfNormalTarget
        case boostDynIsfBgCap
        case boostDynIsfVelocity
        case boostDynIsfAdjustmentFactor
        case boostEnableCircadianIsf
        case boostBolus
        case boostMaxIOB
        case boostMaxIOBMigrated
        case boostInsulinReqPct
        case boostScale
        case boostPercentScale
        case boostEnablePercentScale
        case boostAllowWithHighTt
        case boostV5Aggression
        case boostV5HypoCaution
        case boostV5Sensitivity
        case boostV5ConfirmedCapU
        case boostV5CommittedCapU
        case boostCumulativeSmbCap60Min
        case boostV5FastCarbConfirm
        case boostV5ComposedFloorActive
        case boostV5AggressiveEarlyConfirm
        case boostV5VelocityBudgetActive
        case boostV5PrimerCapU
        case boostV5PrimerTbrFallback
        case boostV5PrimerBolusMode
        case boostV5ConfirmTranche
        case boostV5TrancheFraction
        case boostV5TrancheThreshold
        case boostV5PostRescueTightRampTrial
        case boostV5ConfirmedCapUUserSet
        case boostV5CommittedCapUUserSet
        case boostCumulativeSmbCap60MinUserSet
        case boostV5AutoConfigDone
        case boostV5AutoConfigResolved
        case boostV5AutoConfigSchemaVersion
        case boostNightModeEnabled
        case boostNightModeStartHour
        case boostNightModeEndHour
        case boostNightModeBgOffset
        case boostNightModeDisableWithCob
        case boostNightModeDisableWithLowTt
        case boostNightModeAutoBySleep
        case boostSleepInHours
        case boostSleepInSteps
        case boostV6PreMealEnabled
        case boostV6PreMealTargetMgdl
        case boostV6PreMealLeadMin
        case boostActivitySteps5
        case boostActivitySteps15
        case boostActivitySteps30
        case boostActivitySteps60
        case boostActivityPct
        case boostInactivitySteps
        case boostInactivityPct
        case boostHrIntegrationEnabled
        case boostHrMaxBpm
        case boostHrRestingBpm
        case boostHrStressDetection
        case boostPostExerciseEnabled
        case boostPostExerciseHours
        case boostPostExerciseTarget
        case boostPostExerciseScale
        case boostPostExerciseMinDuration
    }
}

enum InsulinCurve: String, JSON, Identifiable, CaseIterable {
    case rapidActing = "rapid-acting"
    case ultraRapid = "ultra-rapid"
    case bilinear

    var id: InsulinCurve { self }
}

extension Preferences: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var preferences = Preferences()

        if let maxIOB = try? container.decode(Decimal.self, forKey: .maxIOB) {
            preferences.maxIOB = maxIOB
        }

        if let maxDailySafetyMultiplier = try? container.decode(Decimal.self, forKey: .maxDailySafetyMultiplier) {
            preferences.maxDailySafetyMultiplier = maxDailySafetyMultiplier
        }

        if let currentBasalSafetyMultiplier = try? container.decode(Decimal.self, forKey: .currentBasalSafetyMultiplier) {
            preferences.currentBasalSafetyMultiplier = currentBasalSafetyMultiplier
        }

        if let autosensMax = try? container.decode(Decimal.self, forKey: .autosensMax) {
            preferences.autosensMax = autosensMax
        }

        if let autosensMin = try? container.decode(Decimal.self, forKey: .autosensMin) {
            preferences.autosensMin = autosensMin
        }

        if let smbDeliveryRatio = try? container.decode(Decimal.self, forKey: .smbDeliveryRatio) {
            preferences.smbDeliveryRatio = smbDeliveryRatio
        }

        if let rewindResetsAutosens = try? container.decode(Bool.self, forKey: .rewindResetsAutosens) {
            preferences.rewindResetsAutosens = rewindResetsAutosens
        }

        if let highTemptargetRaisesSensitivity = try? container.decode(Bool.self, forKey: .highTemptargetRaisesSensitivity) {
            preferences.highTemptargetRaisesSensitivity = highTemptargetRaisesSensitivity
        }

        if let lowTemptargetLowersSensitivity = try? container.decode(Bool.self, forKey: .lowTemptargetLowersSensitivity) {
            preferences.lowTemptargetLowersSensitivity = lowTemptargetLowersSensitivity
        }

        if let sensitivityRaisesTarget = try? container.decode(Bool.self, forKey: .sensitivityRaisesTarget) {
            preferences.sensitivityRaisesTarget = sensitivityRaisesTarget
        }

        if let resistanceLowersTarget = try? container.decode(Bool.self, forKey: .resistanceLowersTarget) {
            preferences.resistanceLowersTarget = resistanceLowersTarget
        }

        if let advTargetAdjustments = try? container.decode(Bool.self, forKey: .advTargetAdjustments) {
            preferences.advTargetAdjustments = advTargetAdjustments
        }

        if let exerciseMode = try? container.decode(Bool.self, forKey: .exerciseMode) {
            preferences.exerciseMode = exerciseMode
        }

        if let halfBasalExerciseTarget = try? container.decode(Decimal.self, forKey: .halfBasalExerciseTarget) {
            preferences.halfBasalExerciseTarget = halfBasalExerciseTarget
        }

        if let maxCOB = try? container.decode(Decimal.self, forKey: .maxCOB) {
            preferences.maxCOB = maxCOB
        }

        if let maxMealAbsorptionTime = try? container.decode(Decimal.self, forKey: .maxMealAbsorptionTime) {
            preferences.maxMealAbsorptionTime = maxMealAbsorptionTime
        }

        if let wideBGTargetRange = try? container.decode(Bool.self, forKey: .wideBGTargetRange) {
            preferences.wideBGTargetRange = wideBGTargetRange
        }

        if let skipNeutralTemps = try? container.decode(Bool.self, forKey: .skipNeutralTemps) {
            preferences.skipNeutralTemps = skipNeutralTemps
        }

        if let unsuspendIfNoTemp = try? container.decode(Bool.self, forKey: .unsuspendIfNoTemp) {
            preferences.unsuspendIfNoTemp = unsuspendIfNoTemp
        }

        if let min5mCarbimpact = try? container.decode(Decimal.self, forKey: .min5mCarbimpact) {
            preferences.min5mCarbimpact = min5mCarbimpact
        }

        if let remainingCarbsFraction = try? container.decode(Decimal.self, forKey: .remainingCarbsFraction) {
            preferences.remainingCarbsFraction = remainingCarbsFraction
        }

        if let remainingCarbsCap = try? container.decode(Decimal.self, forKey: .remainingCarbsCap) {
            preferences.remainingCarbsCap = remainingCarbsCap
        }

        if let enableUAM = try? container.decode(Bool.self, forKey: .enableUAM) {
            preferences.enableUAM = enableUAM
        }

        if let a52RiskEnable = try? container.decode(Bool.self, forKey: .a52RiskEnable) {
            preferences.a52RiskEnable = a52RiskEnable
        }

        if let enableSMBWithCOB = try? container.decode(Bool.self, forKey: .enableSMBWithCOB) {
            preferences.enableSMBWithCOB = enableSMBWithCOB
        }

        if let enableSMBWithTemptarget = try? container.decode(Bool.self, forKey: .enableSMBWithTemptarget) {
            preferences.enableSMBWithTemptarget = enableSMBWithTemptarget
        }

        if let enableSMBAlways = try? container.decode(Bool.self, forKey: .enableSMBAlways) {
            preferences.enableSMBAlways = enableSMBAlways
        }

        if let enableSMBAfterCarbs = try? container.decode(Bool.self, forKey: .enableSMBAfterCarbs) {
            preferences.enableSMBAfterCarbs = enableSMBAfterCarbs
        }

        if let allowSMBWithHighTemptarget = try? container.decode(Bool.self, forKey: .allowSMBWithHighTemptarget) {
            preferences.allowSMBWithHighTemptarget = allowSMBWithHighTemptarget
        }

        if let maxSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxSMBBasalMinutes) {
            preferences.maxSMBBasalMinutes = maxSMBBasalMinutes
        }

        if let maxUAMSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxUAMSMBBasalMinutes) {
            preferences.maxUAMSMBBasalMinutes = maxUAMSMBBasalMinutes
        }

        if let smbInterval = try? container.decode(Decimal.self, forKey: .smbInterval) {
            preferences.smbInterval = smbInterval
        }

        if let bolusIncrement = try? container.decode(Decimal.self, forKey: .bolusIncrement) {
            preferences.bolusIncrement = bolusIncrement > 0 ? bolusIncrement : 0.1
        }

        if let curve = try? container.decode(InsulinCurve.self, forKey: .curve) {
            preferences.curve = curve
        }

        if let useCustomPeakTime = try? container.decode(Bool.self, forKey: .useCustomPeakTime) {
            preferences.useCustomPeakTime = useCustomPeakTime
        }

        if let insulinPeakTime = try? container.decode(Decimal.self, forKey: .insulinPeakTime) {
            preferences.insulinPeakTime = insulinPeakTime
        }

        if let carbsReqThreshold = try? container.decode(Decimal.self, forKey: .carbsReqThreshold) {
            preferences.carbsReqThreshold = carbsReqThreshold
        }

        if let noisyCGMTargetMultiplier = try? container.decode(Decimal.self, forKey: .noisyCGMTargetMultiplier) {
            preferences.noisyCGMTargetMultiplier = noisyCGMTargetMultiplier
        }

        if let suspendZerosIOB = try? container.decode(Bool.self, forKey: .suspendZerosIOB) {
            preferences.suspendZerosIOB = suspendZerosIOB
        }

        if let maxDeltaBGthreshold = try? container.decode(Decimal.self, forKey: .maxDeltaBGthreshold) {
            preferences.maxDeltaBGthreshold = maxDeltaBGthreshold
        }

        if let adjustmentFactor = try? container.decode(Decimal.self, forKey: .adjustmentFactor) {
            preferences.adjustmentFactor = adjustmentFactor
        }

        if let adjustmentFactorSigmoid = try? container.decode(Decimal.self, forKey: .adjustmentFactorSigmoid) {
            preferences.adjustmentFactorSigmoid = adjustmentFactorSigmoid
        }

        if let sigmoid = try? container.decode(Bool.self, forKey: .sigmoid) {
            preferences.sigmoid = sigmoid
        }

        if let useNewFormula = try? container.decode(Bool.self, forKey: .useNewFormula) {
            preferences.useNewFormula = useNewFormula
        }

        if let useWeightedAverage = try? container.decode(Bool.self, forKey: .useWeightedAverage) {
            preferences.useWeightedAverage = useWeightedAverage
        }

        if let weightPercentage = try? container.decode(Decimal.self, forKey: .weightPercentage) {
            preferences.weightPercentage = weightPercentage
        }

        if let tddAdjBasal = try? container.decode(Bool.self, forKey: .tddAdjBasal) {
            preferences.tddAdjBasal = tddAdjBasal
        }

        if let enableSMB_high_bg = try? container.decode(Bool.self, forKey: .enableSMB_high_bg) {
            preferences.enableSMB_high_bg = enableSMB_high_bg
        }

        if let enableSMB_high_bg_target = try? container.decode(Decimal.self, forKey: .enableSMB_high_bg_target) {
            preferences.enableSMB_high_bg_target = enableSMB_high_bg_target
        }

        if let threshold_setting = try? container.decode(Decimal.self, forKey: .threshold_setting) {
            preferences.threshold_setting = threshold_setting
        }

        if let updateInterval = try? container.decode(Decimal.self, forKey: .updateInterval) {
            preferences.updateInterval = updateInterval
        }

        if let boostMode = try? container.decode(BoostMode.self, forKey: .boostMode) {
            preferences.boostMode = boostMode
        }

        if let boostUseTdd = try? container.decode(Bool.self, forKey: .boostUseTdd) {
            preferences.boostUseTdd = boostUseTdd
        }

        if let v = try? container.decode(Bool.self, forKey: .boostAutosensWhenNoTdd) {
            preferences.boostAutosensWhenNoTdd = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfNormalTarget) {
            // >0 critical: feeds ln(target/divisor + 1); 0 would zero the log → divide-by-zero ISF.
            preferences.boostDynIsfNormalTarget = max(70, min(120, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfBgCap) {
            preferences.boostDynIsfBgCap = max(100, min(300, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfVelocity) {
            preferences.boostDynIsfVelocity = max(0, min(100, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfAdjustmentFactor) {
            preferences.boostDynIsfAdjustmentFactor = max(1, min(300, v))
        }

        if let v = try? container.decode(Bool.self, forKey: .boostEnableCircadianIsf) {
            preferences.boostEnableCircadianIsf = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostBolus) {
            preferences.boostBolus = max(0.1, min(10, v))
        }
        if (try? container.decode(Bool.self, forKey: .boostMaxIOBMigrated)) == true,
           let v = try? container.decode(Decimal.self, forKey: .boostMaxIOB)
        {
            preferences.boostMaxIOB = max(0.1, min(12, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostInsulinReqPct) {
            preferences.boostInsulinReqPct = max(30, min(100, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostScale) {
            preferences.boostScale = max(0.1, min(3, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostPercentScale) {
            preferences.boostPercentScale = max(50, min(500, v))
        }
        if let v = try? container.decode(Bool.self, forKey: .boostEnablePercentScale) {
            preferences.boostEnablePercentScale = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostAllowWithHighTt) {
            preferences.boostAllowWithHighTt = v
        }

        // Boost dosing knobs are clamped to their documented slider ranges on decode. The UI sliders
        // already enforce these, but an imported / remote / corrupted preferences JSON bypasses the
        // UI and feeds the engine directly — for dosing-magnitude caps an out-of-range value must not
        // reach the dosing path.
        if let v = try? container.decode(Decimal.self, forKey: .boostV5Aggression) {
            preferences.boostV5Aggression = max(0.7, min(1.6, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5HypoCaution) {
            preferences.boostV5HypoCaution = max(1.0, min(2.0, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5Sensitivity) {
            preferences.boostV5Sensitivity = max(0.8, min(1.2, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5ConfirmedCapU) {
            preferences.boostV5ConfirmedCapU = max(0, min(7.5, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5CommittedCapU) {
            preferences.boostV5CommittedCapU = max(0, min(5.0, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostCumulativeSmbCap60Min) {
            preferences.boostCumulativeSmbCap60Min = max(0, min(10, v))
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5ConfirmedCapUUserSet) {
            preferences.boostV5ConfirmedCapUUserSet = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5CommittedCapUUserSet) {
            preferences.boostV5CommittedCapUUserSet = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostCumulativeSmbCap60MinUserSet) {
            preferences.boostCumulativeSmbCap60MinUserSet = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5FastCarbConfirm) {
            preferences.boostV5FastCarbConfirm = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostV5ComposedFloorActive) {
            preferences.boostV5ComposedFloorActive = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5AggressiveEarlyConfirm) {
            preferences.boostV5AggressiveEarlyConfirm = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5VelocityBudgetActive) {
            preferences.boostV5VelocityBudgetActive = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5PrimerCapU) {
            preferences.boostV5PrimerCapU = max(0, min(2.5, v))
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5PrimerTbrFallback) {
            preferences.boostV5PrimerTbrFallback = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5PrimerBolusMode) {
            preferences.boostV5PrimerBolusMode = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5ConfirmTranche) {
            preferences.boostV5ConfirmTranche = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5TrancheFraction) {
            preferences.boostV5TrancheFraction = max(0, min(1, v))
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5TrancheThreshold) {
            preferences.boostV5TrancheThreshold = max(0, min(1, v))
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5PostRescueTightRampTrial) {
            preferences.boostV5PostRescueTightRampTrial = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostV5AutoConfigDone) {
            preferences.boostV5AutoConfigDone = v
        }
        if let v = try? container.decode([String].self, forKey: .boostV5AutoConfigResolved) {
            preferences.boostV5AutoConfigResolved = v
        }
        if let v = try? container.decode(Int.self, forKey: .boostV5AutoConfigSchemaVersion) {
            preferences.boostV5AutoConfigSchemaVersion = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostNightModeEnabled) {
            preferences.boostNightModeEnabled = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeStartHour) {
            preferences.boostNightModeStartHour = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeEndHour) {
            preferences.boostNightModeEndHour = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeBgOffset) {
            preferences.boostNightModeBgOffset = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeDisableWithCob) {
            preferences.boostNightModeDisableWithCob = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeDisableWithLowTt) {
            preferences.boostNightModeDisableWithLowTt = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeAutoBySleep) {
            preferences.boostNightModeAutoBySleep = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostSleepInHours) {
            preferences.boostSleepInHours = max(0, min(18, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostSleepInSteps) {
            preferences.boostSleepInSteps = max(0, min(1000, v))
        }
        if let v = try? container.decode(Bool.self, forKey: .boostV6PreMealEnabled) {
            preferences.boostV6PreMealEnabled = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostV6PreMealTargetMgdl) {
            preferences.boostV6PreMealTargetMgdl = max(65, min(90, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostV6PreMealLeadMin) {
            preferences.boostV6PreMealLeadMin = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps5) { preferences.boostActivitySteps5 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps15) { preferences.boostActivitySteps15 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps30) { preferences.boostActivitySteps30 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps60) { preferences.boostActivitySteps60 = v }
        // >0 critical: profilePercent feeds globalScale = 100/profilePercent; 0 → divide-by-zero.
        if let v = try? container.decode(Decimal.self, forKey: .boostActivityPct) {
            preferences.boostActivityPct = max(30, min(150, v))
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostInactivitySteps) { preferences.boostInactivitySteps = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostInactivityPct) {
            preferences.boostInactivityPct = max(100, min(200, v))
        }
        if let v = try? container
            .decode(Bool.self, forKey: .boostHrIntegrationEnabled) { preferences.boostHrIntegrationEnabled = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostHrMaxBpm) { preferences.boostHrMaxBpm = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostHrRestingBpm) { preferences.boostHrRestingBpm = v }
        if let v = try? container.decode(Bool.self, forKey: .boostHrStressDetection) { preferences.boostHrStressDetection = v }
        if let v = try? container
            .decode(Bool.self, forKey: .boostPostExerciseEnabled) { preferences.boostPostExerciseEnabled = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostPostExerciseHours) { preferences.boostPostExerciseHours = v }
        if let v = try? container
            .decode(Decimal.self, forKey: .boostPostExerciseTarget) { preferences.boostPostExerciseTarget = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostPostExerciseScale) {
            preferences.boostPostExerciseScale = max(0, min(1, v))
        }
        if let v = try? container
            .decode(Decimal.self, forKey: .boostPostExerciseMinDuration) { preferences.boostPostExerciseMinDuration = v }

        self = preferences
    }
}
