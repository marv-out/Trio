import Foundation

protocol OverrideHandler {
    func overrideProfileParameters(profile: Profile, override: Override?) throws -> Profile

    // TODO: handle mutation of profile parameters that the user can alter using Overrides
    /// This could also possibly be handled via an extension of our existing `ProfileGenerator` (?)
}

enum DeterminationGenerator {
    // override data can just be fetched from the DB
    // handling via overrideManager ?

    /// Top-level determination generator, callers should use this function
    static func generate(
        profile: Profile,
        preferences: Preferences,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        autosensData: Autosens,
        glucose: [BloodGlucose],
        microBolusAllowed: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date,
        // Boost active mode runs the V1 engine, which needs the SMB record and to know whether it
        // may persist learned state. Nil for callers that never run Boost (stock path unchanged);
        // a Boost-active caller without a context gets the preview context.
        boostV1Context: BoostV1CycleContext? = nil
    ) throws -> Determination? {
        let glucoseStatus = try Self.getGlucoseStatus(glucoseReadings: glucose)
        guard let glucoseStatus = glucoseStatus else { throw DeterminationError.missingInputs }
        return try determineBasal(
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iobData,
            mealData: mealData,
            autosensData: autosensData,
            glucoseStatus: glucoseStatus,
            microBolusAllowed: microBolusAllowed,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: currentTime,
            // Boost pre-meal target: the post-rescue window needs the 45-min glucose low, which only
            // this entry point holds. Nil outside Boost active mode, and for direct test callers.
            boostRecentLowBg45Min: preferences.boostMode == .active
                ? BoostV5Adapter.recentLowBg45Min(glucose, now: currentTime)
                : nil,
            boostV1Context: preferences.boostMode == .active ? (boostV1Context ?? .preview) : nil,
            boostGlucose: glucose
        )
    }

    /// Internal function to implement the core determine basal logic. We have a separate function
    /// from `generate` so that we can pass GlucoseStatus values directly into the function
    /// for testing.
    static func determineBasal(
        profile: Profile,
        preferences: Preferences,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        autosensData: Autosens,
        glucoseStatus: GlucoseStatus,
        microBolusAllowed: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date,
        boostRecentLowBg45Min: Double? = nil,
        boostV1Context: BoostV1CycleContext? = nil,
        boostGlucose: [BloodGlucose] = []
    ) throws -> Determination? {
        var autosensData = autosensData

        try checkDeterminationInputs(
            glucoseStatus: glucoseStatus,
            currentTemp: currentTemp,
            iobData: iobData,
            profile: profile,
            trioCustomOrefVariables: trioCustomOrefVariables
        )

        let currentGlucose: Decimal = glucoseStatus.glucose

        // Boost active: the determination is AAPS's V1 Boost engine (BoostV1Engine), which carries
        // its own stale-data, low-glucose and SMB logic. Only Trio's check that the running temp
        // matches the pump record runs first.
        if preferences.boostMode == .active, let boostV1Context {
            guard let lastTemp = iobData.first?.lastTemp else { throw DeterminationError.missingIob }
            if let reason = checkCurrentTempBasalRateSafety(
                currentTemp: currentTemp,
                lastTempTarget: lastTemp,
                currentTime: currentTime
            ) {
                return Determination(
                    id: UUID(), reason: reason, units: nil, insulinReq: nil, eventualBG: nil, sensitivityRatio: nil,
                    rate: 0, duration: 0, iob: nil, cob: nil, predictions: nil, deliverAt: currentTime, carbsReq: nil,
                    temp: .absolute, bg: nil, reservoir: nil, isf: nil, timestamp: nil, tdd: nil, current_target: nil,
                    minDelta: nil, expectedDelta: nil, minGuardBG: nil, minPredBG: nil, threshold: nil, carbRatio: nil,
                    received: false
                )
            }
            return try BoostV1Determination.determine(
                profile: profile,
                preferences: preferences,
                currentTemp: currentTemp,
                iobData: iobData,
                mealData: mealData,
                orefAutosensRatio: autosensData.ratio,
                glucoseStatus: glucoseStatus,
                glucose: boostGlucose,
                microBolusAllowed: microBolusAllowed,
                trioCustomOrefVariables: trioCustomOrefVariables,
                currentTime: currentTime,
                context: boostV1Context
            )
        }

        if let errorDetermination = try handleTempBasalCases(
            glucoseStatus: glucoseStatus,
            profile: profile,
            currentTemp: currentTemp,
            currentTime: currentTime,
            trioCustomOrefVariables: trioCustomOrefVariables
        ) {
            return errorDetermination
        }

        // Safety check: current temp vs. last temp in iob
        guard let lastTempTarget = iobData.first?.lastTemp else {
            throw DeterminationError.missingIob
        }
        if let reason = checkCurrentTempBasalRateSafety(
            currentTemp: currentTemp,
            lastTempTarget: lastTempTarget,
            currentTime: currentTime
        ) {
            return Determination(
                id: UUID(),
                reason: reason,
                units: nil,
                insulinReq: nil,
                eventualBG: nil,
                sensitivityRatio: nil,
                rate: 0,
                duration: 0,
                iob: nil,
                cob: nil,
                predictions: nil,
                deliverAt: currentTime,
                carbsReq: nil,
                temp: .absolute,
                bg: nil,
                reservoir: nil,
                isf: nil,
                timestamp: nil,
                tdd: nil,
                current_target: nil,
                minDelta: nil,
                expectedDelta: nil,
                minGuardBG: nil,
                minPredBG: nil,
                threshold: nil,
                carbRatio: nil,
                received: false
            )
        }

        // The oref autosens ratio as it arrived, before Trio's dynamic ISF or a temp target replaces
        // it below. Boost's static-ISF autosens (AAPS 1c6358ac6c) must read this one.
        let orefAutosensRatio = autosensData.ratio

        let dynamicIsfResult = DynamicISF.calculate(
            profile: profile,
            preferences: preferences,
            currentGlucose: currentGlucose,
            trioCustomOrefVariables: trioCustomOrefVariables
        )

        if let dynamicIsfResult = dynamicIsfResult {
            autosensData = Autosens(
                ratio: dynamicIsfResult.ratio,
                newisf: autosensData.newisf,
                deviationsUnsorted: autosensData.deviationsUnsorted,
                timestamp: autosensData.timestamp
            )
        }
        let (sensitivityRatio, updateAutosensRatio) = calculateSensitivityRatio(
            currentGlucose: currentGlucose,
            profile: profile,
            autosens: autosensData,
            targetGlucose: profile.profileTarget(trioCustomOrefVariables: trioCustomOrefVariables) ?? 120,
            temptargetSet: profile.temptargetSet ?? false,
            dynamicIsfResult: dynamicIsfResult
        )
        if updateAutosensRatio {
            autosensData = Autosens(
                ratio: sensitivityRatio,
                newisf: autosensData.newisf,
                deviationsUnsorted: autosensData.deviationsUnsorted,
                timestamp: autosensData.timestamp
            )
        }

        // Boost active mode: the activity profile % from the classifier snapshot (100 = none),
        // fresh-guarded (≤30 min). Used for both basal scaling and the ISF 100/profile% scaling.
        let boostActive = preferences.boostMode == .active
        let boostProfilePercent: Double = {
            guard boostActive,
                  let snap = BoostActivityStore.shared.snapshot,
                  currentTime.timeIntervalSince(snap.updatedAt) <= 1800 else { return 100 }
            return snap.profilePercent
        }()

        // Boost sensitivity (AAPS 3d9d471dbb, 1c6358ac6c). TDD-based ISF and oref autosens are
        // alternatives: with TDD on, autosens is not applied; with TDD off and "Autosens without TDD"
        // on, the oref ratio adapts ISF (inside BoostISF), basal, the autosens target shift and
        // carbohydrate absorption time, as it does in stock oref. Otherwise the ratio is neutral.
        let boostAutosens: BoostISF.AutosensContext = boostActive ? .make(
            orefRatio: orefAutosensRatio,
            isTempTarget: profile.temptargetSet ?? false,
            targetBg: profile.profileTarget(trioCustomOrefVariables: trioCustomOrefVariables) ?? 120,
            profile: profile,
            preferences: preferences
        ) : .neutral
        let boostSensitivityRatio = BoostISF.sensitivityRatio(autosens: boostAutosens, preferences: preferences)
        // The ratio this cycle reports and feeds to the forecast: Boost's own choice in active mode,
        // stock's otherwise, so the stock path is unchanged.
        let effectiveSensitivityRatio = boostActive ? boostSensitivityRatio : sensitivityRatio

        var basal = profile.currentBasal ?? profile.basalFor(time: currentTime)
        basal *= trioCustomOrefVariables.overrideFactor()
        if boostActive {
            // Apply the activity profile % (active → lower, inactive → higher), then the selected
            // sensitivity ratio, which is 1 unless autosens owns sensitivity (AAPS applies the
            // activity % to the pump basal and determine_basal then multiplies by the ratio).
            if boostProfilePercent != 100 {
                basal = (basal * Decimal(boostProfilePercent) / 100).jsRounded(scale: 3)
            }
            if boostSensitivityRatio != 1 {
                basal = TempBasalFunctions.roundBasal(profile: profile, basalRate: basal * boostSensitivityRatio)
            }
        } else if dynamicIsfResult == nil {
            basal = computeAdjustedBasal(
                profile: profile,
                currentBasalRate: profile.currentBasal ?? profile.basalFor(time: currentTime),
                sensitivityRatio: sensitivityRatio,
                overrideFactor: trioCustomOrefVariables.overrideFactor()
            )
        } else if let dynamicIsfResult = dynamicIsfResult, profile.tddAdjBasal {
            basal = computeAdjustedBasal(
                profile: profile,
                currentBasalRate: profile.currentBasal ?? profile.basalFor(time: currentTime),
                sensitivityRatio: dynamicIsfResult.tddRatio,
                overrideFactor: trioCustomOrefVariables.overrideFactor()
            )
        }

        // this is the `sens` variable in JS, it's the adjusted sensitivity.
        // Boost active mode swaps in Boost DynISF here (V1, profile-% scaled, autosens only on a
        // static ISF), so eventualBG/predictions/insulinReq (and V5's baseInsulinReq) are
        // Boost-flavoured.
        let baseSensitivity = profile.sens ?? profile.sensitivityFor(time: currentTime)
        let adjustedSensitivity: Decimal
        if boostActive {
            adjustedSensitivity = BoostISF.adjustedSensitivity(
                profileSens: trioCustomOrefVariables.override(sensitivity: baseSensitivity),
                currentGlucose: currentGlucose,
                tdd: trioCustomOrefVariables.tdd(profile: profile),
                profilePercent: boostProfilePercent,
                hourOfDay: Calendar.current.component(.hour, from: currentTime),
                autosens: boostAutosens,
                profile: profile,
                preferences: preferences
            )
        } else {
            adjustedSensitivity = computeAdjustedSensitivity(
                sensitivity: baseSensitivity,
                sensitivityRatio: sensitivityRatio,
                trioCustomOrefVariables: trioCustomOrefVariables
            )
        }

        // Under Boost the autosens target shift follows the selected ratio, as determine_basal's does
        // in AAPS: the oref ratio when autosens owns sensitivity, neutral otherwise.
        let targetAutosens = boostActive ? Autosens(
            ratio: boostSensitivityRatio,
            newisf: autosensData.newisf,
            deviationsUnsorted: autosensData.deviationsUnsorted,
            timestamp: autosensData.timestamp
        ) : autosensData
        let (computedTargets, threshold) = adjustGlucoseTargets(
            profile: profile,
            autosens: targetAutosens,
            trioCustomOrefVariables: trioCustomOrefVariables,
            temptargetSet: profile.temptargetSet ?? false,
            targetGlucose: profile.minBg ?? 100,
            minGlucose: profile.minBg ?? 70, // TODO: can we force unwrap?
            maxGlucose: profile.maxBg ?? 180,
            noise: 1
        )
        var adjustedGlucoseTargets = computedTargets

        // Boost V6: in active mode, fire an anticipatory low target inside the learned pre-meal
        // window (lower-only), so insulinReq rises before carbs land. Suppressed during exercise.
        let boostPreMeal = boostPreMealTarget(
            preferences: preferences,
            profile: profile,
            currentTargetGlucose: adjustedGlucoseTargets.targetGlucose,
            recentLowBg45Min: boostRecentLowBg45Min ?? .infinity,
            currentTime: currentTime
        )
        let boostPreMealNote = boostPreMeal.note
        if let preTarget = boostPreMeal.target {
            adjustedGlucoseTargets.targetGlucose = preTarget
            adjustedGlucoseTargets.minGlucose = min(adjustedGlucoseTargets.minGlucose, preTarget)
            adjustedGlucoseTargets.maxGlucose = min(adjustedGlucoseTargets.maxGlucose, preTarget)
        }

        let glucoseImpactSeries = buildGlucoseImpactSeries(iobDataSeries: iobData, sensitivity: adjustedSensitivity)
        let glucoseImpactSeriesWithZeroTemp = buildGlucoseImpactSeries(
            iobDataSeries: iobData,
            sensitivity: adjustedSensitivity,
            withZeroTemp: true
        )

        guard let currentGlucoseImpact = glucoseImpactSeries.first?.jsRounded(scale: 2) else {
            throw DeterminationError.determinationError
        }

        let minDelta = min(glucoseStatus.delta, glucoseStatus.shortAvgDelta)
        let minAvgDelta = min(glucoseStatus.shortAvgDelta, glucoseStatus.longAvgDelta)
        let longAvgDelta = glucoseStatus.longAvgDelta

        let intervals: Decimal = 6 // 30 / 5

        var deviation = (intervals * (minDelta - currentGlucoseImpact)).jsRounded()
        if deviation < 0 {
            deviation = (intervals * (minAvgDelta - currentGlucoseImpact)).jsRounded()
            if deviation < 0 {
                deviation = (intervals * (longAvgDelta - currentGlucoseImpact)).jsRounded()
            }
        }

        // Calculate what oref calls "naive eventual glucose"
        guard let currentIob = iobData.first?.iob else {
            throw DeterminationError.missingIob
        }

        let naiveEventualGlucose: Decimal
        if currentIob > 0 {
            naiveEventualGlucose = (currentGlucose - (currentIob * adjustedSensitivity)).jsRounded()
        } else {
            naiveEventualGlucose =
                (
                    currentGlucose -
                        (
                            currentIob *
                                min(
                                    profile.profileSensitivity(at: currentTime, trioCustomOrefVaribales: trioCustomOrefVariables),

                                    adjustedSensitivity
                                )
                        )
                )
                .jsRounded()
        }

        let eventualGlucose = naiveEventualGlucose + deviation

        // Safety: if we ever get an invalid Decimal (very rare with Decimal), handle
        guard eventualGlucose.isFinite else {
            throw DeterminationError.eventualGlucoseCalculationError(sensitivity: adjustedSensitivity, deviation: deviation)
        }

        // Boost active: predictions recompute ISF per predicted BG (AAPS getIsfByProfile per tick),
        // not a fixed ISF. sensNormalTarget is BG-independent — compute once, reuse for both the
        // per-BG closure and the dosing future_sens below.
        let boostSensNT: Double? = boostActive ? BoostISF.sensNormalTarget(
            profileSens: trioCustomOrefVariables.override(sensitivity: baseSensitivity),
            tdd: trioCustomOrefVariables.tdd(profile: profile),
            profilePercent: boostProfilePercent,
            autosens: boostAutosens,
            profile: profile,
            preferences: preferences
        ) : nil

        let boostIsfAt: ((Decimal) -> Decimal)? = boostSensNT.map { sensNT in
            { bg in
                Decimal(BoostISF.isfByProfile(
                    bg: (bg as NSDecimalNumber).doubleValue,
                    sensNormalTarget: sensNT,
                    profile: profile,
                    preferences: preferences,
                    useCap: true
                ))
            }
        }

        let forecastResult = ForecastGenerator.generate(
            glucose: currentGlucose,
            glucoseStatus: glucoseStatus,
            currentGlucoseImpact: currentGlucoseImpact,
            glucoseImpactSeries: glucoseImpactSeries,
            glucoseImpactSeriesWithZeroTemp: glucoseImpactSeriesWithZeroTemp,
            iobData: iobData,
            mealData: mealData,
            profile: profile,
            preferences: preferences,
            trioCustomOrefVariables: trioCustomOrefVariables,
            dynamicIsfResult: dynamicIsfResult,
            targetGlucose: adjustedGlucoseTargets.targetGlucose,
            adjustedSensitivity: adjustedSensitivity,
            sensitivityRatio: effectiveSensitivityRatio,
            naiveEventualGlucose: naiveEventualGlucose,
            eventualGlucose: eventualGlucose,
            threshold: threshold,
            currentTime: currentTime,
            boostIsfAt: boostIsfAt
        )

        // used for pre dosing decision sanity later on
        let expectedDelta = calculateExpectedDelta(
            targetGlucose: adjustedGlucoseTargets.targetGlucose,
            eventualGlucose: eventualGlucose,
            glucoseImpact: currentGlucoseImpact
        )

        // Build isfReason: "Autosens ratio: X, ISF: Y→Z"
        let originalSensitivity = profile.profileSensitivity(at: currentTime, trioCustomOrefVaribales: trioCustomOrefVariables)
        let isfReason =
            "Autosens ratio: \(effectiveSensitivityRatio.jsRounded(scale: 2)), ISF: \(originalSensitivity.jsRounded())→\(adjustedSensitivity.jsRounded())"

        // Build targetLog: "X" or "X→Y" or "X→Y→Z" if target was adjusted
        let profileTarget = profile.profileTarget(trioCustomOrefVariables: trioCustomOrefVariables) ?? 100
        let overrideTarget = trioCustomOrefVariables.overrideTarget
        let targetLog: String
        if adjustedGlucoseTargets.targetGlucose != profileTarget {
            // Include overrideTarget in the middle if it's set and different from final target
            if overrideTarget != 0, overrideTarget != 6, overrideTarget != adjustedGlucoseTargets.targetGlucose {
                targetLog =
                    "\(profileTarget.jsRounded())→\(overrideTarget.jsRounded())→\(adjustedGlucoseTargets.targetGlucose.jsRounded())"
            } else {
                targetLog = "\(profileTarget.jsRounded())→\(adjustedGlucoseTargets.targetGlucose.jsRounded())"
            }
        } else {
            targetLog = "\(adjustedGlucoseTargets.targetGlucose.jsRounded())"
        }

        // Build tddReason: ", Dynamic ISF: On, Sigmoid function, AF: X, Basal ratio: Y, SMB Ratio: Z"
        var tddReason = ""
        if let dynamicIsfResult = dynamicIsfResult {
            tddReason = ", Dynamic ISF: On"
            if preferences.sigmoid {
                tddReason += ", Sigmoid function"
            } else {
                tddReason += ", Logarithmic formula"
            }
            if let limitValue = dynamicIsfResult.limitValue {
                tddReason +=
                    ", Autosens/Dynamic Limit: \(limitValue) (\(dynamicIsfResult.uncappedRatio.jsRounded(scale: 2)))"
            }
            let af = preferences.sigmoid ? preferences.adjustmentFactorSigmoid : preferences.adjustmentFactor
            tddReason += ", AF: \(af)"
            if profile.tddAdjBasal {
                tddReason += ", Basal ratio: \(dynamicIsfResult.tddRatio)"
            }
        }
        // SMB Ratio is added if not default (0.5)
        if profile.smbDeliveryRatio != 0.5 {
            tddReason += ", SMB Ratio: \(min(profile.smbDeliveryRatio, 1))"
        }

        let dosingInputs = DosingEngine.prepareDosingInputs(
            profile: profile,
            mealData: mealData,
            forecast: forecastResult,
            naiveEventualGlucose: naiveEventualGlucose,
            threshold: threshold,
            glucoseImpact: currentGlucoseImpact,
            deviation: deviation,
            currentBasal: profile.currentBasal ?? profile.basalFor(time: currentTime),
            overrideFactor: trioCustomOrefVariables.overrideFactor(),
            adjustedSensitivity: adjustedSensitivity,
            isfReason: isfReason,
            tddReason: tddReason,
            targetLog: targetLog
        )

        let smbDecision = try DosingEngine.makeSMBDosingDecision(
            profile: profile,
            meal: mealData,
            currentGlucose: currentGlucose,
            adjustedTargetGlucose: adjustedGlucoseTargets.targetGlucose,
            minGuardGlucose: forecastResult.minGuardGlucose,
            threshold: threshold,
            glucoseStatus: glucoseStatus,
            trioCustomOrefVariables: trioCustomOrefVariables,
            clock: currentTime
        )

        let smbIsEnabled = smbDecision.isEnabled
        var reason = dosingInputs.reason
        if let smbReason = smbDecision.reason {
            reason += smbReason
        }
        // Add carbs message after smbReason to match JS order
        if let carbsReq = dosingInputs.carbsRequired {
            reason += "\(carbsReq.carbs) add'l carbs req w/in \(carbsReq.minutes)m; "
        }
        if let boostPreMealNote {
            reason += boostPreMealNote
        }

        var determination = Determination(
            id: UUID(),
            reason: reason,
            units: nil,
            insulinReq: 0,
            eventualBG: Int(forecastResult.eventualGlucose.jsRounded()),
            sensitivityRatio: effectiveSensitivityRatio, // this would only the AS-adjusted one for now
            rate: nil,
            duration: nil,
            iob: iobData.first?.iob,
            cob: mealData.mealCOB.jsRounded(),
            predictions: Predictions(
                iob: forecastResult.iob.map { Int($0.jsRounded()) },
                zt: forecastResult.zt.map { Int($0.jsRounded()) },
                cob: forecastResult.cob?.map { Int($0.jsRounded()) },
                uam: forecastResult.uam?.map { Int($0.jsRounded()) }
            ),
            deliverAt: currentTime,
            carbsReq: dosingInputs.carbsRequired?.carbs,
            temp: nil,
            bg: currentGlucose,
            reservoir: nil,
            isf: adjustedSensitivity.jsRounded(),
            timestamp: currentTime,
            tdd: nil,
            current_target: adjustedGlucoseTargets.targetGlucose,
            minDelta: nil,
            expectedDelta: expectedDelta,
            minGuardBG: smbDecision.minGuardGlucose ?? forecastResult.minGuardGlucose,
            minPredBG: forecastResult.minForecastedGlucose,
            threshold: threshold.jsRounded(),
            carbRatio: forecastResult.adjustedCarbRatio.jsRounded(scale: 1),
            received: false
        )
        determination.cobProjection = forecastResult.cobProjection

        // MARK: - Core dosing logic

        let (shouldSetTempBasalForLowGlucoseSuspend, lowGlucoseSuspendDetermination) = try DosingEngine.lowGlucoseSuspend(
            currentGlucose: currentGlucose,
            minGuardGlucose: forecastResult.minGuardGlucose,
            iob: currentIob,
            minDelta: minDelta,
            expectedDelta: expectedDelta,
            threshold: threshold,
            overrideFactor: trioCustomOrefVariables.overrideFactor(),
            profile: profile,
            adjustedSensitivity: adjustedSensitivity,
            targetGlucose: adjustedGlucoseTargets.targetGlucose,
            currentTemp: currentTemp,
            determination: determination
        )
        determination = lowGlucoseSuspendDetermination
        if shouldSetTempBasalForLowGlucoseSuspend {
            return determination
        }

        // basal testing acts only on the low handled above; every stage below moves the curve
        if profile.suspendOnly {
            return DosingEngine.recommendNoChange(determination: determination)
        }

        let (shouldSetTempBasalForSkipNeutralTemp, skipNeutralTempDetermination) = try DosingEngine.skipNeutralTempBasal(
            smbIsEnabled: smbIsEnabled,
            profile: profile,
            clock: currentTime,
            currentTemp: currentTemp,
            determination: determination
        )
        determination = skipNeutralTempDetermination
        if shouldSetTempBasalForSkipNeutralTemp {
            return determination
        }

        // Boost active: dosing uses `future_sens` — a BG-context-weighted ISF (AAPS) — for the
        // insulinReq math (low-temp + SMB), distinct from the prediction ISF. Shadow/off use the
        // stock adjustedSensitivity. Computed once here from the forecast outputs.
        let dosingSensitivity: Decimal
        if boostActive, let sensNT = boostSensNT {
            let dStatusDelta = (glucoseStatus.delta as NSDecimalNumber).doubleValue
            let dStatusShort = (glucoseStatus.shortAvgDelta as NSDecimalNumber).doubleValue
            let dStatusLong = (glucoseStatus.longAvgDelta as NSDecimalNumber).doubleValue
            dosingSensitivity = BoostISF.futureSens(
                currentBg: (currentGlucose as NSDecimalNumber).doubleValue,
                eventualBg: (forecastResult.eventualGlucose as NSDecimalNumber).doubleValue,
                minPredBg: (forecastResult.minIOBForecastedGlucose as NSDecimalNumber).doubleValue,
                delta: dStatusDelta,
                shortAvgDelta: dStatusShort,
                longAvgDelta: dStatusLong,
                deltaAccl: DynIsf.deltaAccl(delta: dStatusDelta, shortAvgDelta: dStatusShort),
                cob: (mealData.mealCOB as NSDecimalNumber).doubleValue,
                sensNormalTarget: sensNT,
                profile: profile,
                preferences: preferences
            )
        } else {
            dosingSensitivity = adjustedSensitivity
        }

        let (shouldSetTempBasalForLowEventualGlucose, lowEventualGlucoseDetermination) = try DosingEngine
            .handleLowEventualGlucose(
                eventualGlucose: forecastResult.eventualGlucose,
                minGlucose: adjustedGlucoseTargets.minGlucose,
                targetGlucose: adjustedGlucoseTargets.targetGlucose,
                minDelta: minDelta,
                expectedDelta: expectedDelta,
                carbsRequired: dosingInputs.rawCarbsRequired,
                naiveEventualGlucose: naiveEventualGlucose,
                glucoseStatus: glucoseStatus,
                currentTemp: currentTemp,
                basal: basal,
                profile: profile,
                determination: determination,
                adjustedSensitivity: adjustedSensitivity, // naive + worst-case legs: stock sens
                insulinReqSensitivity: dosingSensitivity, // primary leg: future_sens (active) / stock
                overrideFactor: trioCustomOrefVariables.overrideFactor()
            )
        determination = lowEventualGlucoseDetermination
        if shouldSetTempBasalForLowEventualGlucose {
            return determination
        }

        let (
            shouldSetTempBasalForGlucoseFallingFasterThanExpected,
            glucoseFallingFasterThanExpectedDetermination
        ) = try DosingEngine.glucoseFallingFasterThanExpected(
            eventualGlucose: forecastResult.eventualGlucose,
            minGlucose: adjustedGlucoseTargets.minGlucose,
            minDelta: minDelta,
            expectedDelta: expectedDelta,
            glucoseStatus: glucoseStatus,
            currentTemp: currentTemp,
            basal: basal,
            smbIsEnabled: smbIsEnabled,
            profile: profile,
            determination: determination
        )
        determination = glucoseFallingFasterThanExpectedDetermination
        if shouldSetTempBasalForGlucoseFallingFasterThanExpected {
            return determination
        }

        let (
            shouldSetTempBasalEventualOrForecastGlucoseLessThanMax,
            eventualOrForecastGlucoseLessThanMaxDetermination
        ) = try DosingEngine.eventualOrForecastGlucoseLessThanMax(
            eventualGlucose: forecastResult.eventualGlucose,
            maxGlucose: adjustedGlucoseTargets.maxGlucose,
            minForecastGlucose: forecastResult.minForecastedGlucose,
            currentTemp: currentTemp,
            basal: basal,
            smbIsEnabled: smbIsEnabled,
            profile: profile,
            determination: determination
        )
        determination = eventualOrForecastGlucoseLessThanMaxDetermination
        if shouldSetTempBasalEventualOrForecastGlucoseLessThanMax {
            return determination
        }

        if forecastResult.eventualGlucose >= adjustedGlucoseTargets.maxGlucose {
            determination
                .reason +=
                "Eventual BG \(forecastResult.eventualGlucose.jsRounded()) >= \(adjustedGlucoseTargets.maxGlucose.jsRounded()), "
        }

        let (shouldSetTempBasalForIobGreaterThanMax, iobGreaterThanMaxDetermination) = try DosingEngine.iobGreaterThanMax(
            iob: currentIob,
            maxIob: profile.maxIob,
            currentTemp: currentTemp,
            basal: basal,
            profile: profile,
            determination: determination
        )
        determination = iobGreaterThanMaxDetermination
        if shouldSetTempBasalForIobGreaterThanMax {
            return determination
        }

        // MARK: - Aggressive dosing logic (SMB, High Temps)

        // Calculate Insulin Required
        let (insulinRequired, insulinReqDetermination) = DosingEngine.calculateInsulinRequired(
            minForecastGlucose: forecastResult.minForecastedGlucose,
            eventualGlucose: forecastResult.eventualGlucose,
            targetGlucose: adjustedGlucoseTargets.targetGlucose,
            adjustedSensitivity: dosingSensitivity, // Boost: future_sens in active; stock ISF otherwise
            maxIob: profile.maxIob,
            currentIob: currentIob,
            determination: determination
        )
        determination = insulinReqDetermination

        // SMB Delivery
        let (shouldSetTempBasalForSMB, smbDetermination) = try DosingEngine.determineSMBDelivery(
            insulinRequired: insulinRequired,
            microBolusAllowed: microBolusAllowed,
            smbIsEnabled: smbIsEnabled,
            currentGlucose: currentGlucose,
            threshold: threshold,
            profile: profile,
            trioCustomOrefVariables: trioCustomOrefVariables,
            mealData: mealData,
            iobData: iobData,
            currentTime: currentTime,
            targetGlucose: adjustedGlucoseTargets.targetGlucose,
            naiveEventualGlucose: naiveEventualGlucose,
            minIOBForecastedGlucose: forecastResult.minIOBForecastedGlucose,
            adjustedSensitivity: adjustedSensitivity,
            adjustedCarbRatio: forecastResult.adjustedCarbRatio,
            basal: basal,
            determination: determination
        )
        determination = smbDetermination
        if shouldSetTempBasalForSMB {
            return determination
        }

        // High Temp Basal (Fallback)
        return try DosingEngine.determineHighTempBasal(
            insulinRequired: insulinRequired,
            basal: basal,
            profile: profile,
            currentTemp: currentTemp,
            determination: determination
        )
    }

    /// The V6 anticipatory pre-meal target for this cycle (AAPS 7b), lower-only: the target to use
    /// when it applies and is below `currentTargetGlucose`, and a reason note when it was suppressed.
    /// Active mode only; suppressed during exercise, inside the night window, while asleep, under a
    /// temp target and in the post-rescue window (AAPS a33752c9aa #8).
    static func boostPreMealTarget(
        preferences: Preferences,
        profile: Profile,
        currentTargetGlucose: Decimal,
        recentLowBg45Min: Double,
        currentTime: Date
    ) -> (target: Decimal?, note: String?) {
        guard preferences.boostMode == .active,
              preferences.boostV6PreMealEnabled,
              !BoostActivityStore.shared.flags(now: currentTime).exerciseActive
        else { return (nil, nil) }
        let offsetMs = Double(TimeZone.current.secondsFromGMT(for: currentTime)) * 1000.0
        let nowMin = Calendar.current.component(.hour, from: currentTime) * 60
            + Calendar.current.component(.minute, from: currentTime)
        let leadMax = Int((preferences.boostV6PreMealLeadMin as NSDecimalNumber).doubleValue)
        let nightWindow = BoostV5Adapter.nightWindowMinutes(preferences)
        let history = BoostMealTimeStore.shared.historyWithoutNightEvents(
            nightStartMin: nightWindow.start, nightEndMin: nightWindow.end, localOffsetMs: offsetMs
        )
        guard MealTimeLearner.preMealWindow(history, nowMin: nowMin, localOffsetMs: offsetMs, leadMaxMin: leadMax) != nil
        else { return (nil, nil) }
        if let why = MealTimeLearner.preMealTargetBlock(
            inNightWindow: BoostGate.inNightWindow(
                nowMinuteOfDay: nowMin, startMinute: nightWindow.start, endMinute: nightWindow.end
            ),
            sleepState: BoostActivityStore.shared.sleep(now: currentTime).state,
            tempTargetActive: profile.temptargetSet ?? false,
            postRescueWindow: recentLowBg45Min < SafetyGateConstants.postRescueLowThresholdMgdl
        ) {
            return (nil, "V6 pre-meal SUPPRESSED (\(why)); ")
        }
        let preTarget = preferences.boostV6PreMealTargetMgdl
        return (preTarget < currentTargetGlucose ? preTarget : nil, nil)
    }

    static func checkDeterminationInputs(
        glucoseStatus: GlucoseStatus?,
        currentTemp _: TempBasal?,
        iobData: [IobResult]?,
        profile: Profile?,
        trioCustomOrefVariables: TrioCustomOrefVariables
    ) throws {
        guard let glucoseStatus = glucoseStatus else {
            throw DeterminationError.missingGlucoseStatus
        }
        guard let profile = profile else {
            throw DeterminationError.missingProfile
        }
        guard profile.profileTarget(trioCustomOrefVariables: trioCustomOrefVariables) != nil else {
            throw DeterminationError.invalidProfileTarget
        }
        // we have to allow 38 values so that we can cancel high temps
        if glucoseStatus.glucose < 38 || glucoseStatus.glucose > 600 {
            throw DeterminationError.glucoseOutOfRange(glucose: glucoseStatus.glucose)
        }
        guard let _ = iobData else {
            throw DeterminationError.missingIob
        }
    }

    static func handleTempBasalCases(
        glucoseStatus: GlucoseStatus,
        profile: Profile,
        currentTemp: TempBasal?,
        currentTime: Date,
        trioCustomOrefVariables: TrioCustomOrefVariables
    ) throws -> Determination? {
        let glucose = glucoseStatus.glucose
        let noise = glucoseStatus.noise
        let bgTime = glucoseStatus.date
        let minAgo = Decimal(currentTime.timeIntervalSince(bgTime) / 60) // minutes
        let shortAvgDelta = glucoseStatus.shortAvgDelta
        let longAvgDelta = glucoseStatus.longAvgDelta
        let delta = glucoseStatus.delta

        // Always use profile-supplied basal
        guard let profileBasal = profile.currentBasal else {
            throw DeterminationError.missingCurrentBasal
        }
        let basal = profileBasal * trioCustomOrefVariables.overrideFactor()

        let minDelta = min(delta, shortAvgDelta)

        var reason = ""

        // === ERROR CONDITIONS ===
        // xDrip code 38 = sensor error; BG <= 10 = ???/calibrating; noise >= 3 = high noise
        if glucose <= 10 || glucose == 38 || noise >= 3 {
            reason = "CGM is calibrating, in ??? state, or noise is high"
        }
        // minAgo (BG age) > 12 or < -5 = old/future BG - can overwrite calibration reason (matches JS)
        if minAgo > 12 || minAgo < -5 {
            reason =
                "If current system time \(currentTime.jsDateString()) is correct, then BG data is too old. The last BG data was read \(minAgo.jsRounded(scale: 1))m ago at \(bgTime.jsDateString())"
        } else if shortAvgDelta == 0 && longAvgDelta == 0 {
            // CGM data unchanged (flat) - only checked if BG is not too old
            if glucoseStatus.lastCalIndex != nil, glucoseStatus.lastCalIndex! < 3 {
                reason = "CGM was just calibrated"
            } else {
                reason =
                    "CGM data is unchanged (\(glucose)+\(delta)) for 5m w/ \(shortAvgDelta) mg/dL ~15m change & \(longAvgDelta) mg/dL ~45m change"
            }
        }

        let errorDetected =
            glucose <= 10 ||
            glucose == 38 ||
            noise >= 3 ||
            minAgo > 12 ||
            minAgo < -5

        // === IF ERROR, CANCEL/SHORTEN TEMPS ===
        guard errorDetected, let currentTemp = currentTemp else { return nil }

        if currentTemp.rate >= basal { // high temp is running
            // Replace high temp with neutral temp at scheduled basal rate for 30min
            let reasonWithAction = reason +
                ". Replacing high temp basal of \(currentTemp.rate) with neutral temp of \(basal)"
            return Determination(
                id: UUID(),
                reason: reasonWithAction,
                units: nil,
                insulinReq: nil,
                eventualBG: nil,
                sensitivityRatio: nil,
                rate: basal,
                duration: 30,
                iob: nil,
                cob: nil,
                predictions: nil,
                deliverAt: currentTime,
                carbsReq: nil,
                temp: .absolute,
                bg: nil,
                reservoir: nil,
                isf: profile.sens,
                timestamp: currentTime,
                tdd: nil,
                current_target: nil,
                minDelta: minDelta,
                expectedDelta: nil,
                minGuardBG: nil,
                minPredBG: nil,
                threshold: nil,
                carbRatio: nil,
                received: false
            )
        } else if currentTemp.rate == 0, currentTemp.duration > 30 {
            // Shorten long zero temp to 30m
            let reasonWithAction = reason + ". Shortening \(currentTemp.duration)m long zero temp to 30m. "
            return Determination(
                id: UUID(),
                reason: reasonWithAction,
                units: nil,
                insulinReq: nil,
                eventualBG: nil,
                sensitivityRatio: nil,
                rate: 0,
                duration: 30,
                iob: nil,
                cob: nil,
                predictions: nil,
                deliverAt: currentTime,
                carbsReq: nil,
                temp: .absolute,
                bg: nil,
                reservoir: nil,
                isf: profile.sens,
                timestamp: currentTime,
                tdd: nil,
                current_target: nil,
                minDelta: minDelta,
                expectedDelta: nil,
                minGuardBG: nil,
                minPredBG: nil,
                threshold: nil,
                carbRatio: nil,
                received: false
            )
        } else {
            // Do nothing (temp already safe)
            let reasonWithAction = reason + ". Temp \(currentTemp.rate) <= current basal \(basal)U/hr; doing nothing. "
            return Determination(
                id: UUID(),
                reason: reasonWithAction,
                units: nil,
                insulinReq: nil,
                eventualBG: nil,
                sensitivityRatio: nil,
                rate: nil,
                duration: nil,
                iob: nil,
                cob: nil,
                predictions: nil,
                deliverAt: nil,
                carbsReq: nil,
                temp: currentTemp.temp,
                bg: nil,
                reservoir: nil,
                isf: profile.sens,
                timestamp: currentTime,
                tdd: nil,
                current_target: nil,
                minDelta: minDelta,
                expectedDelta: nil,
                minGuardBG: nil,
                minPredBG: nil,
                threshold: nil,
                carbRatio: nil,
                received: false
            )
        }
    }
}
