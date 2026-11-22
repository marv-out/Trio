import Foundation

public enum SafetyGateConstants {
    public static let maxDeltaBgRatioDisable = 0.30
    public static let iobHeadroomThreshold0 = 0.50
    public static let iobHeadroomThreshold1 = 0.70
    public static let iobHeadroomThreshold2 = 0.85
    public static let iobHeadroomScale1 = 0.85
    public static let iobHeadroomScale2 = 0.60
    public static let iobHeadroomScale3 = 0.40
    public static let decelBrakeAcclFull = -15.0
    public static let decelBrakeFloor = 0.30
    public static let decelBrakeVelocityFallback = 8.0
    public static let postActionRiskThreshold = 0.40
    public static let postActionRiskDeltaThreshold = 0.15
    public static let postActionRiskFloor = 0.30
    public static let sensorQualityBadScale = 0.7
    public static let dynamicSpikeCapMultiplier = 2.5
    // Dose-cap fallbacks (only used if the host preference is unset; the Trio adapter normally
    // passes the user's boostV5ConfirmedCapU/CommittedCapU through). 2026-06-26: aligned to the
    // AAPS defaults (2.5 / 0.5) so an unset-preference path can't revert to the old conservative caps.
    public static let maxConfirmedCommitDoseU = 2.5
    public static let maxCommittedDoseU = 0.5
    public static let velocityRiseLoMgdl = 25.0
    public static let velocityRiseHiMgdl = 50.0
    public static let velocityScaleFloor = 0.40
    /// 2026-07-04 post-rescue window threshold (mg/dL): the rolling 45-min CGM low below which
    /// the V6 override's meal-state exemption is suppressed. Trio's acting engine is trio-oref
    /// (there is no V1-side post-rescue tier guard here to share a constant with), so this is
    /// the named shared constant — the SAME value as AAPS
    /// `DetermineBasalBoost.POST_RESCUE_LOW_THRESHOLD_MGDL` (75.0), where the alignment with
    /// V1's Fix A v2 tier guard is load-bearing. Keep in lock-step with AAPS.
    public static let postRescueLowThresholdMgdl = 75.0

    /// Graduated rebound scale as a function of glucose alone: 0.3 below 120 mg/dL, rising
    /// linearly to 1.0 across 120 to 170, and 1.0 at or above 170, where nothing is suppressed.
    /// Ports AAPS `DetermineBasalBoost.postRescueReboundScale` (2026-07-23), which shares one
    /// definition between its in-tier fast-carb scaling and its composed post-rescue guard so the
    /// two paths cannot diverge in magnitude.
    ///
    /// The AAPS guard that consumes this applies it to the final microbolus of the V1 Boost tier
    /// engine. Trio has no V1 tier engine, so nothing calls this yet; the placement of the Trio
    /// equivalent is an open decision. Kept here as the single definition of the curve.
    public static func postRescueReboundScale(bg: Double) -> Double {
        if bg < 120 { return 0.3 }
        if bg < 170 { return 0.3 + 0.7 * (bg - 120) / 50 }
        return 1.0
    }

    /// Glucose at or above which the shipped guard does not apply at all. This is a cliff rather
    /// than a relaxation, and it is the thing the tight-ramp trial arm removes.
    public static let postRescueGuardCeilingMgdl = 170.0

    /// Treatment-arm cap on the post-rescue scale.
    public static let tightRampCap = 0.60

    /// The scale to apply to a post-rescue cycle, or nil when the guard does not apply.
    ///
    /// On a control day, or when nobody is enrolled, this is the shipped guard byte for byte: the
    /// graduated scale below 170 mg/dL and nothing at or above it. On a treatment day the guard runs
    /// across the whole window with the scale capped, which is the arm under test. Because the cap
    /// can only lower the scale, a treatment cycle can never deliver more insulin than the same
    /// cycle would without the trial, at any glucose value.
    public static func postRescueScale(bg: Double, tightRamp: Bool) -> Double? {
        guard tightRamp || bg < postRescueGuardCeilingMgdl else { return nil }
        let base = postRescueReboundScale(bg: bg)
        return tightRamp ? min(base, tightRampCap) : base
    }
}

/// Day-level arm assignment for the pre-registered post-rescue tight-ramp trial (AAPS 2378baf367).
///
/// The cohort evidence for tightening the post-rescue ramp is unproven: every candidate's
/// cluster-bootstrap interval over users overlaps zero, and only two of eight users showed
/// favourable targeting. So it ships as a randomised within-user trial rather than as a change,
/// default off, and enrolment is a deliberate act rather than something auto-config decides.
///
/// AAPS records that the trial is underpowered for its primary endpoint, at roughly 28 episodes per
/// arm in eight weeks against the 30 percentage points it could detect, and is run for mechanism
/// confirmation and safety surveillance.
public enum PostRescueTrial {
    /// Whether `dayIndex`, in local days since the epoch, is a treatment day for this install's
    /// seed. Pure and deterministic, so an offline analysis reproduces every arm from the seed
    /// alone rather than trusting a logged flag.
    ///
    /// Balanced in 7-day blocks, four treatment days in even blocks and three in odd, so the arms
    /// stay even over any fortnight. Positions within a block are shuffled per block, so the arm is
    /// never confounded with the weekday.
    public static func tightRampArm(seed: String, dayIndex: Int) -> Bool {
        guard !seed.isEmpty else { return false }
        let block = Int(floor(Double(dayIndex) / 7.0))
        let pos = ((dayIndex % 7) + 7) % 7
        let treatDays = ((block % 2) + 2) % 2 == 0 ? 4 : 3
        let order = (0 ... 6).sorted { fnv1a64("\(seed)|\(block)|\($0)") < fnv1a64("\(seed)|\(block)|\($1)") }
        return order.prefix(treatDays).contains(pos)
    }

    /// FNV-1a 64, stable across platforms and trivially re-implementable in the analysis.
    public static func fnv1a64(_ s: String) -> Int64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        for scalar in s.unicodeScalars {
            h ^= UInt64(scalar.value)
            h = h &* 1_099_511_628_211
        }
        return Int64(bitPattern: h)
    }
}

public struct Phase3Inputs {
    public var insulinToDeliver: Double
    public var enableSmbPreChecks: Bool
    public var minGuardBg: Double
    public var minGuardThreshold: Double
    public var maxDelta: Double
    public var bg: Double
    public var iob: Double
    public var maxIob: Double
    public var deltaAccl: Double
    public var delta: Double
    public var baseInsulinReq: Double
    public var roundSmbTo: Double
    public var sensorQualityOk: Bool
    public var riskAtProjectedIob: ((Double) -> Double)?
    public var mlHypoRisk: Double?

    public init(
        insulinToDeliver: Double,
        enableSmbPreChecks: Bool,
        minGuardBg: Double,
        minGuardThreshold: Double,
        maxDelta: Double,
        bg: Double,
        iob: Double,
        maxIob: Double,
        deltaAccl: Double,
        delta: Double = 0.0,
        baseInsulinReq: Double,
        roundSmbTo: Double,
        sensorQualityOk: Bool = true,
        riskAtProjectedIob: ((Double) -> Double)? = nil,
        mlHypoRisk: Double? = nil
    ) {
        self.insulinToDeliver = insulinToDeliver
        self.enableSmbPreChecks = enableSmbPreChecks
        self.minGuardBg = minGuardBg
        self.minGuardThreshold = minGuardThreshold
        self.maxDelta = maxDelta
        self.bg = bg
        self.iob = iob
        self.maxIob = maxIob
        self.deltaAccl = deltaAccl
        self.delta = delta
        self.baseInsulinReq = baseInsulinReq
        self.roundSmbTo = roundSmbTo
        self.sensorQualityOk = sensorQualityOk
        self.riskAtProjectedIob = riskAtProjectedIob
        self.mlHypoRisk = mlHypoRisk
    }
}

public struct GateReductions: Equatable, Sendable {
    public var hardGateFired: String?
    public var maxIobClampApplied: Bool
    public var iobHeadroomBrake: Double
    public var postActionRiskCheck: Double
    public var decelerationBrake: Double
    public var sensorQualityCheck: Double
    public var dynamicSpikeCapped: Bool
    public init(
        hardGateFired: String? = nil,
        maxIobClampApplied: Bool = false,
        iobHeadroomBrake: Double = 1.0,
        postActionRiskCheck: Double = 1.0,
        decelerationBrake: Double = 1.0,
        sensorQualityCheck: Double = 1.0,
        dynamicSpikeCapped: Bool = false
    ) {
        self.hardGateFired = hardGateFired
        self.maxIobClampApplied = maxIobClampApplied
        self.iobHeadroomBrake = iobHeadroomBrake
        self.postActionRiskCheck = postActionRiskCheck
        self.decelerationBrake = decelerationBrake
        self.sensorQualityCheck = sensorQualityCheck
        self.dynamicSpikeCapped = dynamicSpikeCapped
    }
}

public struct Phase3Result: Equatable, Sendable {
    public let finalDose: Double
    public let reductions: GateReductions
}

public enum SafetyGates {
    private typealias C = SafetyGateConstants

    public static func applyPhase3(_ input: Phase3Inputs) -> Phase3Result {
        var dose = input.insulinToDeliver

        // HARD gate: non-finite inputs must DISABLE dosing, not slip through. A NaN (bad CGM frame,
        // or an upstream ISF/TDD divide-by-zero) makes every comparison below false, so the
        // min-guard and max-delta disable gates would fail OPEN and keep dosing. Guard explicitly.
        guard dose.isFinite, input.bg.isFinite, input.maxDelta.isFinite,
              input.minGuardBg.isFinite, input.minGuardThreshold.isFinite
        else {
            return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "non_finite_input"))
        }

        // HARD gates (binary disable)
        if !input
            .enableSmbPreChecks
        {
            return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "enable_smb_pre_checks")) }
        if input.minGuardBg < input
            .minGuardThreshold { return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "min_guard_bg")) }
        if input.maxDelta > C.maxDeltaBgRatioDisable * input
            .bg { return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "max_delta")) }

        let headroom = max(0.0, input.maxIob - input.iob)
        var maxIobClampApplied = false
        if dose > headroom { dose = headroom
            maxIobClampApplied = true }

        // SOFT gates (ordered)
        let iobBrake = iobHeadroomBrake(input.iob, input.maxIob)
        dose *= iobBrake
        let parScale = postActionRiskCheck(
            dose: dose,
            currentMlHypoRisk: input.mlHypoRisk,
            currentIob: input.iob,
            riskAtProjectedIob: input.riskAtProjectedIob
        )
        dose *= parScale
        let decelScale = decelerationBrake(input.deltaAccl, input.delta)
        dose *= decelScale
        let sensorScale = sensorQualityCheck(input.sensorQualityOk)
        dose *= sensorScale

        // FINAL clamp
        if input.roundSmbTo > 0.0 { dose = floor(dose / input.roundSmbTo + 1E-9) * input.roundSmbTo }
        let spikeCap = dynamicSpikeCap(input.baseInsulinReq)
        var spikeCapped = false
        if dose > spikeCap { dose = spikeCap
            spikeCapped = true }
        dose = max(0.0, dose)

        return Phase3Result(finalDose: dose, reductions: GateReductions(
            hardGateFired: nil, maxIobClampApplied: maxIobClampApplied, iobHeadroomBrake: iobBrake,
            postActionRiskCheck: parScale, decelerationBrake: decelScale, sensorQualityCheck: sensorScale,
            dynamicSpikeCapped: spikeCapped
        ))
    }

    static func iobHeadroomBrake(_ iob: Double, _ maxIob: Double) -> Double {
        if maxIob <= 0.0 { return 1.0 }
        let f = iob / maxIob
        if f < C.iobHeadroomThreshold0 { return 1.0 }
        if f < C.iobHeadroomThreshold1 { return C.iobHeadroomScale1 }
        if f < C.iobHeadroomThreshold2 { return C.iobHeadroomScale2 }
        return C.iobHeadroomScale3
    }

    static func decelerationBrake(_ deltaAccl: Double, _ delta: Double) -> Double {
        if delta > C.decelBrakeVelocityFallback { return 1.0 }
        if deltaAccl >= 0.0 { return 1.0 }
        let frac = min(max((deltaAccl - C.decelBrakeAcclFull) / (0.0 - C.decelBrakeAcclFull), 0.0), 1.0)
        return C.decelBrakeFloor + (1.0 - C.decelBrakeFloor) * frac
    }

    static func postActionRiskCheck(
        dose: Double,
        currentMlHypoRisk: Double?,
        currentIob: Double,
        riskAtProjectedIob: ((Double) -> Double)?
    ) -> Double {
        guard let riskFn = riskAtProjectedIob, let current = currentMlHypoRisk else { return 1.0 }
        let projected = riskFn(currentIob + dose)
        if projected > current + C.postActionRiskDeltaThreshold, projected > C.postActionRiskThreshold {
            let raw = 1.0 - (projected - C.postActionRiskThreshold) / (1.0 - C.postActionRiskThreshold)
            return max(C.postActionRiskFloor, raw)
        }
        return 1.0
    }

    static func sensorQualityCheck(_ ok: Bool) -> Double { ok ? 1.0 : C.sensorQualityBadScale }
    static func dynamicSpikeCap(_ baseInsulinReq: Double) -> Double { C.dynamicSpikeCapMultiplier * baseInsulinReq }

    // Fix-6 velocity scaling + state dose cap
    public static func velocityScaledDoseFactor(_ cumulativeRise30min: Double) -> Double {
        if cumulativeRise30min >= C.velocityRiseHiMgdl { return 1.0 }
        if cumulativeRise30min <= C.velocityRiseLoMgdl { return C.velocityScaleFloor }
        let span = C.velocityRiseHiMgdl - C.velocityRiseLoMgdl
        let frac = (cumulativeRise30min - C.velocityRiseLoMgdl) / span
        return C.velocityScaleFloor + (1.0 - C.velocityScaleFloor) * frac
    }

    public static func applyStateDoseCap(
        _ state: MealHypothesis,
        _ dose: Double,
        confirmedCapU: Double = SafetyGateConstants.maxConfirmedCommitDoseU,
        committedCapU: Double = SafetyGateConstants.maxCommittedDoseU
    ) -> Double {
        switch state {
        case .confirmed: return min(dose, confirmedCapU)
        // RECOVERING never gives more in one cycle than COMMITTED (AAPS Boost 6.3.0, 72f8bc93bc).
        case .committed,
             .recovering: return min(dose, committedCapU)
        default: return dose
        }
    }

    // MARK: - V6 override caps (the active-override seam)

    /// Which V6-override cap bound the dose this cycle (`none` when uncapped).
    public enum V6OverrideCap: String, Equatable, Sendable {
        case none
        case nonMeal
        case postRescue
    }

    /// Outcome of the V6-override dose caps: the dose to deliver plus which cap bound.
    public struct V6OverrideCapsResult: Equatable, Sendable {
        public let dose: Double
        public let cap: V6OverrideCap
    }

    /// V6-override dose caps (pure — unit-tested directly). Mirrors AAPS
    /// `OpenAPSBoostPlugin.applyV6OverrideCaps` (5b5026e10b + c306241a35):
    ///  - non-meal-state cap (2026-07-02): in IDLE/OBSERVING/RECOVERING V6 never out-doses the
    ///    base oref determination;
    ///  - post-rescue meal-state cap (2026-07-04): inside the post-rescue window
    ///    (recentLowBG45Min < `SafetyGateConstants.postRescueLowThresholdMgdl`) the meal-state
    ///    exemption is suppressed, so CONFIRMED/COMMITTED are ALSO capped at the base engine's
    ///    would-dose.
    ///
    /// Incident 2026-07-03 19:47 BST (AAPS): severe hypo (nadir 40) → unannounced rescue carbs →
    /// violent rebound. V6 CONFIRMED at BG 119 delivered 2.7U while V1's 45-min post-rescue tier
    /// guard had restrained the base engine to 1.05U — the meal-state exemption discarded that
    /// restraint. BG then ran 181 → nadir 81 with zero margin, and the 2.7U tripped the 2.5U
    /// cumulative cap, silencing V6 for the following hour.
    ///
    /// DB backtest (2026-07-04): 20.4% of meal-state cycles are post-rescue; 27% of the insulin
    /// this cap removes sits directly ahead of a second low < 70 (vs 14-19% for every other lever
    /// evaluated). Cost side: 10% genuine post-hypo meals, median 0.15U under-delivery, zero
    /// double-dips. Verdict SHIP.
    ///
    /// WHY inherit the base dose (alignment is load-bearing in AAPS): the 75 mg/dL / 45-min
    /// window is the SAME constant + source value as V1's post-rescue tier guard, so whenever the
    /// cap binds, the base would-dose is by construction the hypo-restrained dose — the cap
    /// inherits that restraint instead of inventing a second, divergent notion of "post-rescue".
    /// In Trio the base engine is trio-oref, whose own low-side guards (minGuard/threshold, LGS)
    /// shape `orefWouldDose` in the same window.
    public static func applyV6OverrideCaps(
        inMealState: Bool,
        inPostRescueWindow: Bool,
        v5FinalDose: Double,
        orefWouldDose: Double
    ) -> V6OverrideCapsResult {
        let dose = (inMealState && !inPostRescueWindow) ? v5FinalDose : min(v5FinalDose, orefWouldDose)
        let cap: V6OverrideCap = dose >= v5FinalDose ? .none : (inMealState ? .postRescue : .nonMeal)
        return V6OverrideCapsResult(dose: dose, cap: cap)
    }
}
