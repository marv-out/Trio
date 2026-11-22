import Combine
import CoreData
import Foundation

final class OpenAPS {
    private let processQueue = DispatchQueue(label: "OpenAPS.processQueue", qos: .utility)

    /// Confirm-tranche state, held across cycles. In memory only, matching the Kotlin singleton: a
    /// restart drops any pending hold, which fails safe, because a withheld remainder that is never
    /// released is insulin not given.
    private static let confirmTranche = ConfirmTranche()

    /// The base engine's temp for the primer's temp-basal decision (AAPS a33752c9aa, audit item 10):
    /// the returned rate when there is one, otherwise the temp still running, since a determination
    /// with no rate leaves it in place. Nil when neither exists.
    static func effectiveBaseTempRate(_ returnedRate: Decimal?, currentTemp: TempBasal) -> Decimal? {
        returnedRate ?? (currentTemp.duration > 0 ? currentTemp.rate : nil)
    }

    private let storage: FileStorage
    private let tddStorage: TDDStorage
    private let glucoseStorage: GlucoseStorage
    private let carbsStorage: CarbsStorage

    let jsonConverter = JSONConverter()

    private func newContext(_ name: String) -> NSManagedObjectContext {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = name
        return context
    }

    init(storage: FileStorage, tddStorage: TDDStorage, glucoseStorage: GlucoseStorage, carbsStorage: CarbsStorage) {
        self.storage = storage
        self.tddStorage = tddStorage
        self.glucoseStorage = glucoseStorage
        self.carbsStorage = carbsStorage
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // Helper function to convert a Decimal? to NSDecimalNumber?
    func decimalToNSDecimalNumber(_ value: Decimal?) -> NSDecimalNumber? {
        guard let value = value else { return nil }
        return NSDecimalNumber(decimal: value)
    }

    // Use the helper function for cleaner code
    func processDetermination(_ determination: Determination, on context: NSManagedObjectContext) async {
        await context.perform {
            let newOrefDetermination = OrefDetermination(context: context)
            newOrefDetermination.id = UUID()
            newOrefDetermination.insulinSensitivity = self.decimalToNSDecimalNumber(determination.isf)
            newOrefDetermination.currentTarget = self.decimalToNSDecimalNumber(determination.current_target)
            newOrefDetermination.eventualBG = determination.eventualBG.map(NSDecimalNumber.init)
            newOrefDetermination.deliverAt = determination.deliverAt
            newOrefDetermination.carbRatio = self.decimalToNSDecimalNumber(determination.carbRatio)
            newOrefDetermination.glucose = self.decimalToNSDecimalNumber(determination.bg)
            newOrefDetermination.reservoir = self.decimalToNSDecimalNumber(determination.reservoir)
            newOrefDetermination.insulinReq = self.decimalToNSDecimalNumber(determination.insulinReq)
            newOrefDetermination.temp = determination.temp?.rawValue ?? "absolute"
            newOrefDetermination.rate = self.decimalToNSDecimalNumber(determination.rate)
            newOrefDetermination.reason = determination.reason
            newOrefDetermination.duration = self.decimalToNSDecimalNumber(determination.duration)
            newOrefDetermination.iob = self.decimalToNSDecimalNumber(determination.iob)
            newOrefDetermination.threshold = self.decimalToNSDecimalNumber(determination.threshold)
            newOrefDetermination.minDelta = self.decimalToNSDecimalNumber(determination.minDelta)
            newOrefDetermination.sensitivityRatio = self.decimalToNSDecimalNumber(determination.sensitivityRatio)
            newOrefDetermination.expectedDelta = self.decimalToNSDecimalNumber(determination.expectedDelta)
            newOrefDetermination.cob = Int16(Int(determination.cob ?? 0))
            newOrefDetermination.smbToDeliver = determination.units.map { NSDecimalNumber(decimal: $0) }
            newOrefDetermination.carbsRequired = Int16(Int(determination.carbsReq ?? 0))
            newOrefDetermination.isUploadedToNS = false

            if let predictions = determination.predictions {
                ["iob": predictions.iob, "zt": predictions.zt, "cob": predictions.cob, "uam": predictions.uam]
                    .forEach { type, values in
                        if let values = values {
                            let forecast = Forecast(context: context)
                            forecast.id = UUID()
                            forecast.type = type
                            forecast.date = Date()
                            forecast.orefDetermination = newOrefDetermination

                            for (index, value) in values.enumerated() {
                                let forecastValue = ForecastValue(context: context)
                                forecastValue.index = Int32(index)
                                forecastValue.value = Int32(value)
                                forecast.addToForecastValues(forecastValue)
                            }
                            newOrefDetermination.addToForecasts(forecast)
                        }
                    }
            }
        }

        // First save the current Determination to Core Data
        await attemptToSaveContext(on: context)
    }

    func attemptToSaveContext(on context: NSManagedObjectContext) async {
        await context.perform {
            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Saving the determination failed", error: error)
            }
        }
    }

    private func fetchPumpHistoryObjectIDs(on context: NSManagedObjectContext) async throws -> [NSManagedObjectID]? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.pumpHistoryLast1440Minutes,
            key: "timestamp",
            ascending: false,
            batchSize: 50
        )

        return try await context.perform {
            guard let pumpEventResults = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return pumpEventResults.map(\.objectID)
        }
    }

    private func parsePumpHistory(
        on context: NSManagedObjectContext,
        _ pumpHistoryObjectIDs: [NSManagedObjectID],
        simulatedBolusAmount: Decimal? = nil
    ) async throws -> [PumpHistoryEvent] {
        // Empty history returns an empty array, which also drops any simulated bolus.
        guard !pumpHistoryObjectIDs.isEmpty else { return [] }

        // Addresses https://github.com/nightscout/Trio/issues/898
        //
        // On a cold start (new user, fresh onboarding, or pump disconnected > 24h),
        // the oldest event in pump history can be a resume with no preceding pump
        // activity. oref interprets this as the end of a suspend that never started,
        // which drives negative IOB and can cause excessive insulin delivery.
        let orphanedResumes = try await fetchOrphanedResumes(on: context)

        // Execute all operations on the background context
        return await context.perform {
            // Load and map pump events to native algorithm models
            var events = OpenAPS.nativePumpHistory(
                pumpHistoryObjectIDs,
                orphanedResumes: orphanedResumes,
                from: context
            )

            // Optionally add the simulated bolus for the bolus-preview simulation
            if let simulatedBolusAmount = simulatedBolusAmount {
                events.insert(self.createSimulatedBolusEvent(simulatedBolusAmount: simulatedBolusAmount), at: 0)
            }

            return events
        }
    }

    /// Fetches and maps pump events into `[PumpHistoryEvent]`, expose this as static and not private for testing
    static func nativePumpHistory(
        _ pumpHistoryObjectIDs: [NSManagedObjectID],
        orphanedResumes: [NSManagedObjectID],
        from context: NSManagedObjectContext
    ) -> [PumpHistoryEvent] {
        let orphanedSet = Set(orphanedResumes)
        let filteredObjectIds = pumpHistoryObjectIDs.filter { !orphanedSet.contains($0) }
        let pumpHistory: [PumpEventStored] = filteredObjectIds
            .compactMap { context.object(with: $0) as? PumpEventStored }

        return pumpHistory.flatMap { $0.toPumpHistoryEvents() }
    }

    private func createSimulatedBolusEvent(simulatedBolusAmount: Decimal) -> PumpHistoryEvent {
        // for the timestamp, subtract 1 second from now to ensure
        // that the algorithm take this simulated bolus into account
        PumpHistoryEvent(
            id: UUID().uuidString,
            type: .bolus,
            timestamp: Date().addingTimeInterval(-1),
            amount: simulatedBolusAmount,
            duration: 0,
            isSMB: true,
            isExternal: false
        )
    }

    /// Detects a cold-start orphaned resume: returns the resume's object ID if it's an orphaned resume
    private func fetchOrphanedResumes(on context: NSManagedObjectContext) async throws -> [NSManagedObjectID] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.pumpHistoryLast48h,
            key: "timestamp",
            ascending: true,
            batchSize: 250
        )

        return try await context.perform {
            guard let pumpEventResultsFull = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            let pumpEventResults = pumpEventResultsFull
                .filter { $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue }

            // we define an orphaned resume as one without a paired suspend within
            // the most recent 24 hours.
            // **Important**: we pick 48 hours because the standard pump history
            // is 24 hours + 24 hours of inspection for resumes.
            let orphanedResumes = zip(pumpEventResults, pumpEventResults.dropFirst())
                .compactMap { (prev, curr) -> PumpEventStored? in
                    guard let prevTimestamp = prev.timestamp, let currTimestamp = curr.timestamp else {
                        return nil
                    }
                    let interval = currTimestamp.timeIntervalSince(prevTimestamp)

                    // check if the current event is an orphaned resume
                    //  - previous event not a suspend
                    //  - previous event is a suspend but it's more than 24 hours ago
                    if curr.type == EventType.pumpResume.rawValue,
                       prev.type != EventType.pumpSuspend.rawValue || interval > TimeInterval(hours: 24)
                    {
                        return curr
                    }
                    return nil
                }
            // check the first event to see if it's an orphaned resume
            let firstResumeOrphaned = pumpEventResults.first.flatMap({ event -> [PumpEventStored]? in
                guard event.type == EventType.pumpResume.rawValue else { return nil }
                return [event]
            }) ?? []

            return (firstResumeOrphaned + orphanedResumes).map(\.objectID)
        }
    }

    func determineBasal(
        for dosingMode: DosingMode,
        currentTemp: TempBasal,
        supportedBasalRates: [Decimal],
        shouldSmoothGlucose: Bool,
        clock: Date = Date(),
        simulatedCarbsAmount: Decimal? = nil,
        simulatedBolusAmount: Decimal? = nil,
        simulatedCarbsDate: Date? = nil,
        simulation: Bool = false
    ) async throws -> Determination? {
        let context = newContext("determineBasal")

        // Perform asynchronous calls in parallel
        async let pumpHistoryObjectIDs = fetchPumpHistoryObjectIDs(on: context) ?? []
        async let carbsFetch = carbsStorage.getCarbsForAlgorithm(
            additionalCarbs: simulatedCarbsAmount ?? 0,
            carbsDate: simulatedCarbsDate
        )

        // second, independent read into the algorithm; needs the same clamp as the profile
        var preferences = (await storage.retrieveAsync(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences())
            .clamped(for: dosingMode)
        let glucoseFetchHours = preferences.maxMealAbsorptionTime + 0.5 // MMAT + half hour buffer
        async let glucoseFetch = glucoseStorage.getGlucoseForAlgorithm(
            shouldSmoothGlucose: shouldSmoothGlucose,
            fetchHours: glucoseFetchHours
        )

        async let prepareTrioCustomOrefVariables = prepareTrioCustomOrefVariables(on: context)
        async let profileAsync = loadFileFromStorageAsync(name: Settings.profile)
        async let basalAsync = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let autosenseAsync = loadFileFromStorageAsync(name: Settings.autosense)
        async let hasSufficientTddForDynamic = tddStorage.hasSufficientTDD()

        // Await the results of asynchronous tasks
        let (
            pumpHistory,
            carbs,
            glucose,
            rawTrioCustomOrefVariables,
            rawProfile,
            rawBasalProfile,
            rawAutosens,
            hasSufficientTdd
        ) = await (
            try parsePumpHistory(on: context, await pumpHistoryObjectIDs, simulatedBolusAmount: simulatedBolusAmount),
            try carbsFetch,
            try glucoseFetch,
            try prepareTrioCustomOrefVariables,
            profileAsync,
            basalAsync,
            autosenseAsync,
            try hasSufficientTddForDynamic
        )

        // Decode the JSON-at-rest inputs into native models at the call boundary.
        var profile = try JSONBridge.profile(from: rawProfile)
        // pump capability is injected here rather than persisted, so it can never go stale
        profile.supportedBasalRates = supportedBasalRates
        // derived here, not baked into profile.json, which the JS parity goldens compare
        profile.suspendOnly = dosingMode.automation == .hypoSuspendOnly
        let basalProfile = try JSONBridge.basalProfile(from: rawBasalProfile)
        let autosens = try JSONBridge.autosens(from: rawAutosens.isEmpty ? .null : rawAutosens)
        let trioCustomOrefVariables = try JSONBridge.trioCustomOrefVariables(from: rawTrioCustomOrefVariables)

        // Meal calculation
        let meal = try self.meal(
            pumphistory: pumpHistory,
            profile: profile,
            basalProfile: basalProfile,
            clock: clock,
            carbs: carbs,
            glucose: glucose
        )

        // IOB calculation
        let iob = try self.iob(
            pumphistory: pumpHistory,
            profile: profile,
            clock: clock,
            autosens: autosens
        )

        // TODO: refactor this to core data
        if !simulation {
            storage.save(iob, as: Monitor.iob)
        }

        if !hasSufficientTdd, preferences.useNewFormula || (preferences.useNewFormula && preferences.sigmoid) {
            debug(.algorithm, "Dynamic ISF off for this run: not enough TDD history")
            preferences.useNewFormula = false
            preferences.sigmoid = false
        }

        // Determine basal
        let orefDetermination = try determineBasal(
            glucose: glucose,
            currentTemp: currentTemp,
            iob: iob,
            profile: profile,
            autosens: autosens,
            meal: meal,
            microBolusAllowed: true,
            preferences: preferences,
            trioCustomOrefVariables: trioCustomOrefVariables,
            pumpHistory: pumpHistory,
            simulation: simulation
        )

        debug(
            .algorithm,
            "Determination\(simulation ? " (simulation)" : ""): BG \(orefDetermination?.bg ?? 0) mg/dL, IOB \(orefDetermination?.iob ?? 0) U, COB \(orefDetermination?.cob ?? 0) g, ISF \(orefDetermination?.isf ?? 0) mg/dL/U, sensitivity ratio \(orefDetermination?.sensitivityRatio ?? 1)"
        )

        if var determination = orefDetermination, let deliverAt = determination.deliverAt {
            // set both timestamp and deliverAt to the SAME date; this will be updated for timestamp once it is enacted
            // AAPS does it the same way! we'll follow their example!
            determination.timestamp = deliverAt

            if !simulation {
                // TODO: refactor this to core data
                let cobEntries = (determination.cobProjection ?? []).enumerated().map { index, cob in
                    CobEntry(cob: cob, time: deliverAt.addingTimeInterval(Double(index) * 300))
                }
                storage.save(cobEntries, as: Monitor.cob)

                // save to core data asynchronously
                await processDetermination(determination, on: context)
            }

            return determination
        } else {
            warning(.algorithm, "No determination produced\(orefDetermination == nil ? "" : ": missing delivery time")")
            throw APSError.apsError(message: "No determination data.")
        }
    }

    func prepareTrioCustomOrefVariables(on context: NSManagedObjectContext) async throws -> RawJSON {
        try await context.perform {
            // Retrieve user preferences
            let userPreferences = self.storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            let weightPercentage = userPreferences?.weightPercentage ?? 1.0
            let maxSMBBasalMinutes = userPreferences?.maxSMBBasalMinutes ?? 30
            let maxUAMBasalMinutes = userPreferences?.maxUAMSMBBasalMinutes ?? 30

            // Fetch historical events for Total Daily Dose (TDD) calculation
            let tenDaysAgo = Date().addingTimeInterval(-10.days.timeInterval)
            let twoHoursAgo = Date().addingTimeInterval(-2.hours.timeInterval)
            let historicalTDDData = try self.fetchHistoricalTDDData(from: tenDaysAgo, on: context)

            // Fetch the last active Override
            let activeOverrides = try self.fetchActiveOverrides(on: context)
            let isOverrideActive = activeOverrides.first?.enabled ?? false
            let overridePercentage = Decimal(activeOverrides.first?.percentage ?? 100)
            let isOverrideIndefinite = activeOverrides.first?.indefinite ?? true
            let disableSMBs = activeOverrides.first?.smbIsOff ?? false
            let overrideTargetBG = activeOverrides.first?.target?.decimalValue ?? 0

            // Calculate averages for Total Daily Dose (TDD)
            let totalTDD = historicalTDDData.compactMap { ($0["total"] as? NSDecimalNumber)?.decimalValue }.reduce(0, +)
            let totalDaysCount = max(historicalTDDData.count, 1)

            // Fetch recent TDD data for the past two hours
            let recentTDDData = historicalTDDData.filter { ($0["date"] as? Date ?? Date()) >= twoHoursAgo }
            let recentDataCount = max(recentTDDData.count, 1)
            let recentTotalTDD = recentTDDData.compactMap { ($0["total"] as? NSDecimalNumber)?.decimalValue }
                .reduce(0, +)

            let currentTDD = historicalTDDData.last?["total"] as? Decimal ?? 0
            let averageTDDLastTwoHours = recentTotalTDD / Decimal(recentDataCount)
            let averageTDDLastTenDays = totalTDD / Decimal(totalDaysCount)
            let weightedTDD = weightPercentage * averageTDDLastTwoHours + (1 - weightPercentage) * averageTDDLastTenDays

            // Prepare Trio's custom oref variables
            let trioCustomOrefVariablesData = TrioCustomOrefVariables(
                average_total_data: currentTDD > 0 ? averageTDDLastTenDays : 0,
                weightedAverage: currentTDD > 0 ? weightedTDD : 1,
                currentTDD: currentTDD,
                past2hoursAverage: currentTDD > 0 ? averageTDDLastTwoHours : 0,
                date: Date(),
                overridePercentage: overridePercentage,
                useOverride: isOverrideActive,
                duration: activeOverrides.first?.duration?.decimalValue ?? 0,
                unlimited: isOverrideIndefinite,
                overrideTarget: overrideTargetBG,
                smbIsOff: disableSMBs,
                advancedSettings: activeOverrides.first?.advancedSettings ?? false,
                isfAndCr: activeOverrides.first?.isfAndCr ?? false,
                isf: activeOverrides.first?.isf ?? false,
                cr: activeOverrides.first?.cr ?? false,
                smbIsScheduledOff: activeOverrides.first?.smbIsScheduledOff ?? false,
                start: (activeOverrides.first?.start ?? 0) as Decimal,
                end: (activeOverrides.first?.end ?? 0) as Decimal,
                smbMinutes: activeOverrides.first?.smbMinutes?.decimalValue ?? maxSMBBasalMinutes,
                uamMinutes: activeOverrides.first?.uamMinutes?.decimalValue ?? maxUAMBasalMinutes
            )

            // Save and return contents of Trio's custom oref variables
            self.storage.save(trioCustomOrefVariablesData, as: OpenAPS.Monitor.trio_custom_oref_variables)
            return self.loadFileFromStorage(name: Monitor.trio_custom_oref_variables)
        }
    }

    func autosense(shouldSmoothGlucose: Bool) async throws -> Autosens? {
        let context = newContext("autosense")

        // Perform asynchronous calls in parallel
        async let pumpHistoryObjectIDs = fetchPumpHistoryObjectIDs(on: context) ?? []
        async let carbsFetch = carbsStorage.getCarbsForAlgorithm(additionalCarbs: nil, carbsDate: nil)
        // Autosens needs the full 24h window for its sensitivity algorithm.
        async let glucoseFetch = glucoseStorage.getGlucoseForAlgorithm(
            shouldSmoothGlucose: shouldSmoothGlucose,
            fetchHours: 24
        )
        async let getProfile = loadFileFromStorageAsync(name: Settings.profile)
        async let getBasalProfile = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let getTempTargets = loadFileFromStorageAsync(name: Settings.tempTargets)

        // Await the results of asynchronous tasks
        let (pumpHistory, carbs, glucose, rawProfile, rawBasalProfile, rawTempTargets) = await (
            try parsePumpHistory(on: context, await pumpHistoryObjectIDs),
            try carbsFetch,
            try glucoseFetch,
            getProfile,
            getBasalProfile,
            getTempTargets
        )

        // Decode the JSON-at-rest inputs into native models at the call boundary.
        let profile = try JSONBridge.profile(from: rawProfile)
        let basalProfile = try JSONBridge.basalProfile(from: rawBasalProfile)
        let tempTargets = try JSONBridge.tempTargets(from: rawTempTargets)

        // Autosense
        var autosens = try autosense(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            clock: Date()
        )

        debug(.algorithm, "Autosens ratio \(autosens.ratio)")
        autosens.timestamp = Date()
        await storage.saveAsync(autosens, as: Settings.autosense)

        return autosens
    }

    func createProfiles(for dosingMode: DosingMode) async throws {
        let context = newContext("createProfiles")

        // Load required settings and profiles asynchronously
        async let getPumpSettings = loadFileFromStorageAsync(name: Settings.settings)
        async let getBGTargets = loadFileFromStorageAsync(name: Settings.bgTargets)
        async let getBasalProfile = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let getInsulinSensitivities = loadFileFromStorageAsync(name: Settings.insulinSensitivities)
        async let getCarbRatios = loadFileFromStorageAsync(name: Settings.carbRatios)
        async let getTempTargets = loadFileFromStorageAsync(name: Settings.tempTargets)

        let (pumpSettings, bgTargets, basalProfile, insulinSensitivities, carbRatios, tempTargets) = await (
            getPumpSettings,
            getBGTargets,
            getBasalProfile,
            getInsulinSensitivities,
            getCarbRatios,
            getTempTargets
        )

        // Retrieve user preferences, or set defaults if not available
        let preferences = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()
        let defaultHalfBasalTarget = preferences.halfBasalExerciseTarget
        var adjustedPreferences = preferences

        // Check for active Temp Targets and adjust HBT if necessary
        try await context.perform {
            // Check if a Temp Target is active and check HBT differs from setting and adjust
            if let activeTempTarget = try self.fetchActiveTempTargets(on: context).first,
               activeTempTarget.enabled,
               let targetValue = activeTempTarget.target?.decimalValue
            {
                // Compute effective HBT - handles both custom HBT and standard TT (where HBT might need adjustment)
                let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
                    tempTargetHalfBasalTarget: activeTempTarget.halfBasalTarget?.decimalValue,
                    settingHalfBasalTarget: defaultHalfBasalTarget,
                    target: targetValue,
                    autosensMax: preferences.autosensMax
                )

                if let effectiveHBT, effectiveHBT != defaultHalfBasalTarget {
                    adjustedPreferences.halfBasalExerciseTarget = effectiveHBT
                    let percentage = Int(TempTargetCalculations.computeAdjustedPercentage(
                        halfBasalTarget: effectiveHBT,
                        target: targetValue,
                        autosensMax: preferences.autosensMax
                    ).rounded())
                    debug(
                        .algorithm,
                        "Temp target \(targetValue) mg/dL: half basal target \(defaultHalfBasalTarget) -> \(effectiveHBT) mg/dL, \(percentage)%"
                    )
                }
            }
            // Overwrite the lowTTlowersSens if autosensMax does not support it
            if preferences.lowTemptargetLowersSensitivity, preferences.autosensMax <= 1 {
                adjustedPreferences.lowTemptargetLowersSensitivity = false
                debug(.algorithm, "Low temp target lowers sensitivity off: autosens max \(preferences.autosensMax) is 1 or below")
            }
        }

        // clamp after the HBT block above, which needs the user's real autosensMax
        adjustedPreferences = adjustedPreferences.clamped(for: dosingMode)

        let clock = Date()
        do {
            // Decode the raw settings into native models. The bundled-defaults
            // fallback still happens in loadFileFromStorageAsync above, so decoding
            // here preserves the same behavior it previously had inside makeProfile.
            let pumpSettings = try JSONBridge.pumpSettings(from: pumpSettings)
            let bgTargets = try JSONBridge.bgTargets(from: bgTargets)
            let basalProfile = try JSONBridge.basalProfile(from: basalProfile)
            let insulinSensitivities = try JSONBridge.insulinSensitivities(from: insulinSensitivities)
            let carbRatios = try JSONBridge.carbRatios(from: carbRatios)
            let tempTargets = try JSONBridge.tempTargets(from: tempTargets)

            let pumpProfile = try ProfileGenerator.generate(
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: insulinSensitivities,
                preferences: adjustedPreferences,
                carbRatios: carbRatios,
                tempTargets: tempTargets,
                clock: clock
            )

            let profile = try ProfileGenerator.generate(
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: insulinSensitivities,
                preferences: adjustedPreferences,
                carbRatios: carbRatios,
                tempTargets: tempTargets,
                clock: clock
            )

            // Save the profiles
            await storage.saveAsync(pumpProfile, as: Settings.pumpProfile)
            await storage.saveAsync(profile, as: Settings.profile)
        } catch {
            warning(.algorithm, "Creating profiles failed", error: error)
            throw error
        }
    }

    private func iob(
        pumphistory: [PumpHistoryEvent],
        profile: Profile,
        clock: Date,
        autosens: Autosens?
    ) throws -> [IobResult] {
        // FIXME: For now we'll just remove duplicate suspends here (ISSUE-399)
        let pumphistory = pumphistory.removingDuplicateSuspendResumeEvents()

        return try IobGenerator.generate(
            history: pumphistory,
            profile: profile,
            clock: clock,
            autosens: autosens
        )
    }

    private func meal(
        pumphistory: [PumpHistoryEvent],
        profile: Profile,
        basalProfile: [BasalProfileEntry],
        clock: Date,
        carbs: [CarbsEntry],
        glucose: [BloodGlucose]
    ) throws -> ComputedCarbs? {
        try MealGenerator.generate(
            pumpHistory: pumphistory,
            profile: profile,
            basalProfile: basalProfile,
            clock: clock,
            carbHistory: carbs,
            glucoseHistory: glucose
        )
    }

    private func autosense(
        glucose: [BloodGlucose],
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        profile: Profile,
        carbs: [CarbsEntry],
        tempTargets: [TempTarget],
        clock: Date
    ) throws -> Autosens {
        // both runs use identical inputs, so compute the treatments once;
        // gated on the same count as the generate early return
        let precomputedTreatments = glucose.count >= 72 ? try IobHistory.calcTempTreatments(
            history: pumpHistory.map { $0.computedEvent() },
            profile: profile,
            clock: clock,
            autosens: nil,
            zeroTempDuration: nil
        ) : nil

        // this logic is from prepare/autosens.js
        let ratio8h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 96,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        let ratio24h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 288,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        return ratio8h.ratio < ratio24h.ratio ? ratio8h : ratio24h
    }

    private func determineBasal(
        glucose: [BloodGlucose],
        currentTemp: TempBasal,
        iob: [IobResult],
        profile: Profile,
        autosens: Autosens?,
        meal: ComputedCarbs?,
        microBolusAllowed: Bool,
        preferences: Preferences,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        pumpHistory: [PumpHistoryEvent],
        simulation: Bool
    ) throws -> Determination? {
        let clock = Date()

        guard let meal = meal, let autosens = autosens else {
            throw DeterminationError.missingInputs
        }

        // Boost active runs AAPS's V1 engine as the determination; it needs the SMB record and may
        // persist its ML ring buffer only on a real cycle, never on a bolus-calculator preview.
        let boostV1Context = BoostV1CycleContext.from(pumpHistory: pumpHistory, clock: clock, persistState: !simulation)

        var rawDetermination = try DeterminationGenerator.generate(
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iob,
            mealData: meal,
            autosensData: autosens,
            glucose: glucose,
            microBolusAllowed: microBolusAllowed,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: clock,
            boostV1Context: boostV1Context
        )

        // ── Boost V5 second pass (off | shadow | active). Same engine, two wirings:
        // shadow logs what V5 would do; active overrides the SMB (units), exactly as AAPS
        // V5-active overrides Boost-V1's SMB. baseInsulinReq = the stock determination's
        // insulinReq — V5 adds no sensitivity logic of its own. ──
        // Skip the Boost V5 SECOND PASS for what-if simulations (bolus-calculator previews run
        // this repeatedly). The critical reason is state safety: the adapter writes the ML ring
        // buffer, V5 hypothesis state, meal-time history, and lastRunMs — a simulation snapshot
        // would corrupt the next real cycle's lags / state machine. Skipping it also drops the
        // V5 SMB override + night-mode suppression from the preview, which is correct (a what-if
        // shouldn't assume a hypothetical SMB). Note: the FIRST pass (DeterminationGenerator)
        // still applies the user's active Boost sensitivity model — DynISF / future_sens / the
        // V6 pre-meal target — so the preview reflects the model they actually run on; it is NOT
        // a pure stock-oref determination for an active user.
        let boostMode = preferences.boostMode
        if !simulation,
           boostMode != .off,
           var det = rawDetermination,
           let glucoseStatus = try? DeterminationGenerator.getGlucoseStatus(glucoseReadings: glucose)
        {
            // v12 ML features: cumulative SMB volume over the last 60 min and minutes since the
            // last SMB (AAPS recentSmbVolume60Min / timeSinceLastSmbMin — type==SMB, valid; sum
            // amount over 60 min; tSince = min(720, …), default 720 when none).
            let recentSmb60 = boostV1Context.recentSmbVolume60Min
            let timeSinceSmb = boostV1Context.timeSinceLastSmbMin

            // M2 fidelity: in SHADOW the first pass above is stock oref, so the determination
            // fed to the engine (eventualBG / insulinReq / predictions / minGuard) is NOT what
            // ACTIVE would compute under Boost DynISF + future_sens + the V6 pre-meal target —
            // the logged `wouldSMB` (and its budget / spikeCap) would systematically mis-estimate
            // the active dose. Run a second, Boost-flavoured determination (boostMode forced
            // active) purely as the engine input so shadow predicts active faithfully. The real
            // `det` returned to the pump stays the STOCK determination — shadow never changes
            // dosing. `generate` only READS the Boost stores, so the extra call has no side
            // effects; on any failure we fall back to the stock det. Active already has a
            // Boost-flavoured det; off never reaches this block.
            var engineDet = det
            if boostMode == .shadow {
                var activePrefs = preferences
                activePrefs.boostMode = .active
                if let boostDet = try? DeterminationGenerator.generate(
                    profile: profile,
                    preferences: activePrefs,
                    currentTemp: currentTemp,
                    iobData: iob,
                    mealData: meal,
                    autosensData: autosens,
                    glucose: glucose,
                    microBolusAllowed: microBolusAllowed,
                    trioCustomOrefVariables: trioCustomOrefVariables,
                    currentTime: clock,
                    boostV1Context: boostV1Context
                ) {
                    engineDet = boostDet
                }
            }

            let result = BoostV5Adapter.run(
                determination: engineDet,
                glucoseStatus: glucoseStatus,
                glucose: glucose,
                iobData: iob,
                maxIob: (preferences.maxIOB as NSDecimalNumber).doubleValue,
                // Pump bolus increment (AAPS rounds SMB to the pump step); fall back to 0.05.
                roundSmbTo: preferences.bolusIncrement > 0
                    ? (preferences.bolusIncrement as NSDecimalNumber).doubleValue
                    : 0.05,
                microBolusAllowed: microBolusAllowed,
                mode: boostMode,
                knobs: BoostV5Adapter.V5Knobs(
                    aggression: (preferences.boostV5Aggression as NSDecimalNumber).doubleValue,
                    hypoCaution: (preferences.boostV5HypoCaution as NSDecimalNumber).doubleValue,
                    sensitivity: (preferences.boostV5Sensitivity as NSDecimalNumber).doubleValue,
                    confirmedCapU: (preferences.boostV5ConfirmedCapU as NSDecimalNumber).doubleValue,
                    committedCapU: (preferences.boostV5CommittedCapU as NSDecimalNumber).doubleValue,
                    fastCarbConfirm: preferences.boostV5FastCarbConfirm,
                    composedFloorActive: preferences.boostV5ComposedFloorActive,
                    aggressiveEarlyConfirm: preferences.boostV5AggressiveEarlyConfirm,
                    velocityBudgetActive: preferences.boostV5VelocityBudgetActive,
                    primerCapU: (preferences.boostV5PrimerCapU as NSDecimalNumber).doubleValue,
                    // The recommended routing is the temp basal unless the user has forced a bolus.
                    // The override is always honoured, and recorded in the reason when it applies.
                    primerUseTempBasal: preferences.boostV5PrimerTbrFallback
                        && !preferences.boostV5PrimerBolusMode,
                    nightStartMinute: BoostV5Adapter.nightWindowMinutes(preferences).start,
                    nightEndMinute: BoostV5Adapter.nightWindowMinutes(preferences).end
                ),
                clock: clock,
                recentSmbUnits60m: recentSmb60,
                timeSinceLastSmbMin: timeSinceSmb,
                manualBolusWithinWindow: BoostV5Adapter.manualBolusWithinWindow(pumpHistory, clock: clock),
                pumpSuspended: BoostV5Adapter.pumpSuspended(pumpHistory, clock: clock),
                profileSwitchKey: BoostV5Adapter.profileSwitchKey(trioCustomOrefVariables),
                v1: engineDet.boostV1
            )
            det.reason += " " + result.reason
            // Set when the confirm tranche ran inside the override block this cycle. A hold left
            // over on any other cycle is dropped after the override chain (AAPS a33752c9aa, #1).
            var trancheRan = false
            if boostMode == .active {
                // Sleep gate — faithful port of Boost-V6 OpenAPSBoostPlugin.kt:1239: V5 drives the
                // SMB only when a microbolus is allowed AND not SLEEPING. While asleep the override
                // backs off and the base (V1-equivalent) SMB stands, which night mode then suppresses.
                // `asleep` = SleepStateDetector SLEEPING via the activity snapshot (staleness-guarded).
                let asleep = BoostActivityStore.shared.flags(now: clock).asleep
                // Boost-inactive gate (2026-07-02, faithful port of OpenAPSBoostPlugin.kt c94c5c72d6):
                // the V6 override may replace the SMB ONLY when Boost is active this cycle. Boost is
                // active only OUTSIDE the night/sleep period (night window OR HR/step sleep, EXCLUDING
                // night mode's BG/COB/TT gates so a nocturnal high can't re-enable an amplified V6 dose
                // while asleep) and outside a step-based morning lie-in. Otherwise fall back to V1's
                // base oref1 SMB (which respects night mode + its own hypo/minGuard gates) — because
                // `asleep` reflects ONLY the HR sleep-state machine, never the boost-window gate.
                // 2026-10-08 (AAPS 47a815aedf): the gate also closes inside the configured night
                // window whatever the night-mode toggle says, and while the detector reads SLEEPING
                // (held for one hysteresis period after a boundary exit, a33752c9aa #18), and under a
                // high temp target unless allowed. The V1 engine evaluated the same gate this cycle
                // (BoostV1Determination.boostActive); its value is used so the two cannot disagree.
                let v1Gate = det.boostV1.map { ($0.boostActive, $0.sleepInActive) }
                    ?? BoostV1Determination.boostActive(profile: profile, preferences: preferences, clock: clock)
                let sleepInActive = v1Gate.1
                let boostActive = v1Gate.0
                // V1 zero-temped for a low this cycle: leave the cycle to it, so no meal-state SMB
                // lands on a suspend (AAPS OpenAPSBoostPlugin, Boost 6.3.0, 10c1c01306).
                let v1LowSuspend = det.reason.contains(BoostV1Engine.lowSuspendTag)
                if microBolusAllowed, !asleep, boostActive, !v1LowSuspend {
                    // Anti-stacking hard gate — faithful port of OpenAPSBoostPlugin.kt:1262. The
                    // rolling-60-min cumulative-SMB cap bounds dose FREQUENCY (per-shot caps don't);
                    // suppress the V6 SMB this cycle once the last hour's SMB volume reaches it.
                    // recentSmb60 is computed above; 0 disables. Auto-config sets the per-user value.
                    let cumulativeCap = (preferences.boostCumulativeSmbCap60Min as NSDecimalNumber).doubleValue
                    let cumulativeCapReached = cumulativeCap > 0 && recentSmb60 >= cumulativeCap
                    var boostDose = Decimal(result.decision.finalDose)

                    // Non-meal-state cap (2026-07-02, faithful port of OpenAPSBoostPlugin.kt
                    // 5b5026e10b): V6 may only OUT-dose V1 when it holds a meal hypothesis
                    // (CONFIRMED/COMMITTED). In IDLE/OBSERVING/RECOVERING the V5 state caps don't
                    // apply and IDLE's 1.0× multiplier can front a multi-unit correction that
                    // bypasses V1's per-SMB sizing (cohort shadow: ~1,430U cumulative IDLE excess,
                    // worst 3.7U vs V1 0.45U, incl. 2.0U where V1 dosed 0). Capping at V1's
                    // would-dose makes IDLE match its spec ("standard oref dose"); genuine meal
                    // rises still get full V6 dosing via OBSERVING→CONFIRMED.
                    let v1WouldDose = det.units ?? 0
                    // 2026-07-17 velocity-budget exemption (AAPS 3ea7479572): when the active
                    // velocity-budget floor lifted this cycle's dose, treat it as a meal state so the
                    // floored hold can out-dose the base engine on the budget-near-zero high tail,
                    // where the base engine doses about zero. Bounded by construction: the exempt
                    // dose is capped at the committed cap and the remaining IOB headroom, the floor
                    // requires the person to be awake and outside the post-rescue window, and the
                    // cumulative 60-minute, boost-active and sleep gates below all still run.
                    // 2026-07-20 primer, bolus route: the OBSERVING primer is already folded into
                    // the final dose and netted in the engine, so it must be exempt from the
                    // non-meal cap. It has to out-dose the base engine's OBSERVING dose, because
                    // that is the reclaimed early insulin. Its own floors ran in the engine and the
                    // cumulative, sleep and boost-active guards below still apply.
                    let inMealState = result.decision.mealHypothesis == .confirmed
                        || result.decision.mealHypothesis == .committed
                        || result.decision.velocityBudgetExempt
                        || (result.decision.primerBolusU > 0 && !result.decision.primerUseTempBasal)

                    // Post-rescue meal-state cap (2026-07-04, faithful port of AAPS
                    // c306241a35 / OpenAPSBoostPlugin.applyV6OverrideCaps): inside the
                    // post-rescue window (rolling 45-min CGM low < 75 mg/dL — the shared
                    // SafetyGateConstants.postRescueLowThresholdMgdl, same value as AAPS's
                    // V1 tier-guard constant) the meal-state exemption above is SUPPRESSED,
                    // so CONFIRMED/COMMITTED are also capped at the base engine's would-dose.
                    // Incident 2026-07-03 (AAPS): nadir-40 hypo → unannounced rescue carbs →
                    // rebound; V6 CONFIRMED at BG 119 delivered 2.7U while the hypo-restrained
                    // base engine would give 1.05U. DB backtest 2026-07-04: 27% of the insulin
                    // this cap removes sits directly ahead of a second low <70 (vs 14-19% for
                    // every other lever); cost 10% genuine post-hypo meals at 0.15U median
                    // under-delivery. See SafetyGates.applyV6OverrideCaps (unit-tested).
                    let recentLow45 = BoostV5Adapter.recentLowBg45Min(glucose, now: clock)
                    let inPostRescueWindow = recentLow45 < SafetyGateConstants.postRescueLowThresholdMgdl
                    let preCapDose = boostDose
                    let caps = SafetyGates.applyV6OverrideCaps(
                        inMealState: inMealState,
                        inPostRescueWindow: inPostRescueWindow,
                        v5FinalDose: (preCapDose as NSDecimalNumber).doubleValue,
                        orefWouldDose: (v1WouldDose as NSDecimalNumber).doubleValue
                    )
                    // Apply the binding cap in Decimal (min can only reduce) so no Double
                    // round-trip touches the delivered value.
                    if caps.cap != .none { boostDose = min(boostDose, v1WouldDose) }

                    // 2026-08-27 confirm tranche (AAPS dad3f3a63b + 73c5febb8d). The confirm shot is
                    // otherwise the same size whether the excursion reaches 20 mg/dL or 100, and it
                    // carries 61.7% of the insulin delivered in the following ninety minutes. This
                    // gives a fraction now and holds the rest for ten minutes, releasing it only if
                    // a rule on quantities the loop already holds clears the threshold. It can only
                    // ever deliver less than the engine would without it.
                    //
                    // Since 2026-10-08 (AAPS a33752c9aa, audit item 1) the release is held to the
                    // same bounds as the rest of the dose: released only in COMMITTED (a CONFIRMED
                    // cycle replaces the hold), never when a phase-3 hard gate fired or inside the
                    // post-rescue window, and clamped to the maxIOB headroom and the CONFIRMED cap
                    // left after this cycle's dose. It runs only on cycles where V6 drives the SMB,
                    // which in AAPS excludes the rolling cumulative cap; any other cycle drops the
                    // hold (after the override chain), so a hold never outlives a cycle on which
                    // the engine decided against V6.
                    if preferences.boostV5ConfirmTranche, !cumulativeCapReached {
                        trancheRan = true
                        let tranche = Self.confirmTranche
                        tranche.immediateFraction = (preferences.boostV5TrancheFraction as NSDecimalNumber).doubleValue
                        tranche.releaseThreshold = (preferences.boostV5TrancheThreshold as NSDecimalNumber).doubleValue
                        let sized = boostDose
                        var trancheGateNote = ""
                        let nowMs = clock.timeIntervalSince1970 * 1000.0
                        let bgNow = (glucoseStatus.glucose as NSDecimalNumber).doubleValue
                        if result.decision.mealHypothesis == .confirmed {
                            boostDose = Decimal(tranche.onConfirm(
                                nowMs: nowMs, bg: bgNow,
                                sizedDose: (sized as NSDecimalNumber).doubleValue
                            ))
                        } else {
                            let release = tranche.onCycleBounded(
                                nowMs: nowMs, bg: bgNow,
                                bounds: ConfirmTranche.ReleaseBounds(
                                    inMealState: result.decision.mealHypothesis == .committed,
                                    hardGateFired: result.decision.phase3.reductions.hardGateFired != nil,
                                    postRescueWindow: inPostRescueWindow,
                                    // AAPS min(boost_maxIOB, max_iob).
                                    ceilingU: ConfirmTranche.releaseCeiling(
                                        cycleDoseU: (sized as NSDecimalNumber).doubleValue,
                                        maxIobU: det.boostV1?.v6MaxIob ?? (preferences.maxIOB as NSDecimalNumber).doubleValue,
                                        iobU: (iob.first?.iob as NSDecimalNumber?)?.doubleValue ?? 0,
                                        confirmedCapU: (preferences.boostV5ConfirmedCapU as NSDecimalNumber).doubleValue
                                    )
                                )
                            )
                            trancheGateNote = release.note
                            boostDose = sized + Decimal(release.units)
                        }
                        // Sized and delivered together, so the withheld amount is priced without
                        // needing a counterfactual.
                        det.reason += " tranche=\(String(format: "%.3f", (sized as NSDecimalNumber).doubleValue))," +
                            "\(String(format: "%.3f", (boostDose as NSDecimalNumber).doubleValue))," +
                            "held=\(String(format: "%.3f", tranche.heldU));"
                        if !trancheGateNote.isEmpty { det.reason += " trancheGate=\(trancheGateNote);" }
                    } else if result.decision.mealHypothesis == .idle {
                        // Drop any hold once the engine has left the meal state entirely, so a
                        // remainder cannot survive a toggle-off and a later session.
                        Self.confirmTranche.reset()
                    }

                    // The composed post-rescue rebound guard (AAPS 0eb4a65b39) and its tight-ramp trial
                    // arm (2378baf367) scale the V1 tier dose inside the engine, as in AAPS; the V6 dose
                    // is not scaled again here. The trial tag is written by BoostV1Determination.
                    let nonMealCapped = caps.cap == .nonMeal
                    let postRescueCapped = caps.cap == .postRescue

                    // Honour the user's explicit "no SMB" levers even in active mode: master
                    // SMB-off, the scheduled SMB-off window, and a high temp target with "Allow
                    // SMB with high temp target" off (the exercise/illness back-off). The active
                    // override otherwise bypasses the stock smbIsEnabled gate, so without this a
                    // raised temp target or scheduled off-window would still get a Boost SMB.
                    // Boost still doses detected meals where stock's enableSMB_* would not.
                    // current_target mirrors the first pass's adjustedTargetGlucose. try? → false
                    // (don't suppress) on a calendar error so this can never fail the loop cycle.
                    let smbUserDisabled = (try? DosingEngine.smbHardDisabledByUserLevers(
                        profile: profile,
                        adjustedTargetGlucose: det.current_target ?? 100,
                        trioCustomOrefVariables: trioCustomOrefVariables,
                        clock: clock
                    )) ?? false

                    // No re-clamp to the basal-derived per-SMB limit (maxSMBBasalMinutes /
                    // maxUAMSMBBasalMinutes). AAPS applies that limit only inside its V1 tier engine
                    // and lets the V6 override replace the dose without it; the override is bounded
                    // by the engine's state caps, maxIOB, the cumulative 60-min cap and pump Max
                    // Bolus. Trio clamped here from 2026-06-28 (audit D1) until the 2026-10 soak
                    // showed it held every Boost dose to 0.27-0.40 U against AAPS SMBs up to 3.9 U.

                    // The SMB interval is not checked here. AAPS replaces the SMB unconditionally at
                    // this point and enforces the interval once, in LoopPlugin, on whatever SMB the
                    // determination carries (the check after night mode below). A second check here
                    // that held V6 aside let V1's dose through on loops a few seconds short of the
                    // interval (round 4 soak, 2026-10-22: 1.4 U delivered where V6 sized 0.20 U).
                    if smbUserDisabled {
                        det.units = 0
                        det.reason += " V6 suppressed (SMB off: temp target / schedule);"
                    } else if cumulativeCapReached {
                        det.units = 0
                        det
                            .reason +=
                            " V6 suppressed (cumulative SMB cap \(String(format: "%.2f", recentSmb60))U/\(String(format: "%.2f", cumulativeCap))U reached);"
                    } else {
                        det.units = boostDose
                        // 2026-07 composed brake-floor breadcrumb (AAPS 730b3dcb2c): when the
                        // toggle is ON, decision.floorWouldAdd carries the uplift the floor
                        // actually APPLIED inside decide(). On a floored cycle the seam caps don't
                        // bind (post-rescue is a floor pre-condition; RECOVERING is v1-bounded
                        // inside the target), so decision.finalDose is the delivered truth. Log
                        // the un-floored → floored dose so a floored cycle is auditable.
                        let floorUplift = preferences.boostV5ComposedFloorActive
                            ? (result.decision.floorWouldAdd ?? 0) : 0
                        if floorUplift > 0 {
                            det.reason += " brake-floor applied: " +
                                "\(String(format: "%.3f", result.decision.finalDose - floorUplift))→" +
                                "\(String(format: "%.3f", result.decision.finalDose)) U;"
                        }
                        if postRescueCapped {
                            det.reason += " V6 post-rescue-capped to V1 base " +
                                "\(String(format: "%.3f", (v1WouldDose as NSDecimalNumber).doubleValue))U (from " +
                                "\(String(format: "%.3f", (preCapDose as NSDecimalNumber).doubleValue))U, " +
                                "45-min low \(String(format: "%.0f", recentLow45)));"
                        } else if nonMealCapped {
                            det.reason += " V6 non-meal-capped to V1 base " +
                                "\(String(format: "%.3f", (v1WouldDose as NSDecimalNumber).doubleValue))U (from " +
                                "\(String(format: "%.3f", (preCapDose as NSDecimalNumber).doubleValue))U, " +
                                "state=\(result.decision.mealHypothesis.rawValue));"
                        }
                    }

                    // 2026-07-20 early-primer delivery. Skipped once the rolling cumulative cap is
                    // reached, matching the Kotlin, which excludes the whole block in that case.
                    if !cumulativeCapReached, result.decision.primerBolusU > 0 {
                        let primerU = result.decision.primerBolusU
                        if result.decision.primerUseTempBasal {
                            // Retractable temp basal: deliver roughly the primer over a short window
                            // as a raise above scheduled basal, additive only. It never fires while
                            // the base engine is suspending or reducing, so a protective low or zero
                            // temp always wins; it never lowers what the base engine planned, and
                            // never shortens its duration. If the meal fades it simply expires.
                            let durationMin: Decimal = 30
                            let currentBasal = profile.currentBasal ?? 0
                            let extraRate = Decimal(primerU) * (60 / durationMin)
                            let primerRate = currentBasal + extraRate
                            // 2026-10-08 (AAPS a33752c9aa, audit item 10): when the base engine
                            // returns no rate it leaves the running temp in place, which can be a
                            // protective zero or low temp. The decision reads that running temp, not
                            // only the returned rate, so the primer cannot replace it.
                            let baseRate = Self.effectiveBaseTempRate(det.rate, currentTemp: currentTemp)
                            let running = det.rate == nil && baseRate != nil ? ",running" : ""
                            if let baseRate, baseRate < currentBasal {
                                det.reason += " primer=tbr-skipped(base temp " +
                                    "\(String(format: "%.3f", (baseRate as NSDecimalNumber).doubleValue)) < basal " +
                                    "\(String(format: "%.3f", (currentBasal as NSDecimalNumber).doubleValue))\(running));"
                            } else if let baseRate, baseRate >= primerRate {
                                // The base engine already delivers at or above the primer rate, so
                                // the primer adds nothing. Its rate and duration are left alone:
                                // extending a high base temp would over-deliver.
                                det.reason += " primer=tbr-subsumed(base " +
                                    "\(String(format: "%.3f", (baseRate as NSDecimalNumber).doubleValue)) >= primer " +
                                    "\(String(format: "%.3f", (primerRate as NSDecimalNumber).doubleValue))U/h\(running));"
                            } else {
                                det.rate = primerRate
                                det.duration = max(det.duration ?? 0, durationMin)
                                det.reason += " primer=tbr,\(String(format: "%.3f", primerU))U→" +
                                    "\(String(format: "%.3f", (primerRate as NSDecimalNumber).doubleValue))U/h" +
                                    "×\(det.duration ?? durationMin)m;"
                            }
                        } else {
                            // Bolus route: already folded into the dose above and exempted from the
                            // non-meal cap. When auto-config recommended the temp basal and the user
                            // has overridden to a bolus, say so: the override is always honoured,
                            // but it must be visible in the data, because it is the difference
                            // between a primer the loop can unwind and one it cannot.
                            let routeOverridden = preferences.boostV5PrimerTbrFallback
                                && preferences.boostV5PrimerBolusMode
                            det.reason += " primer=bolus,\(String(format: "%.3f", primerU))U"
                                + (routeOverridden ? ";primerRoute=bolus-USER-OVERRIDE(recommended=tbr)" : "") + ";"
                        }
                    }
                    // Sizing telemetry, emitted whenever the gate opened, including when the state
                    // factors sized the primer to nothing and it rounded away. Without it a reader
                    // cannot tell "the gate never opened" from "the gate opened and correctly sized
                    // to zero", which is the point of the rework.
                    if !result.decision.primerScaleDebug.isEmpty {
                        det.reason += " primerScale[\(result.decision.primerScaleDebug)];"
                    }
                } else if asleep {
                    det.reason += " V6 suppressed (SLEEPING) — base SMB stands;"
                } else if v1LowSuspend {
                    det.reason += " V6 override skipped (V1 low suspend);"
                } else if !boostActive {
                    det.reason += sleepInActive
                        ? " V6 override skipped (Boost inactive: morning lie-in) — base SMB stands;"
                        : " V6 override skipped (Boost inactive: night/sleep period) — base SMB stands;"
                }
                // A tranche hold survives only on cycles where V6 drove the SMB with the tranche on.
                // Any other cycle (asleep, Boost inactive, no SMB allowed, the cumulative cap, or the
                // tranche switched off) is the engine deciding against V6's dose, so the hold goes
                // with it rather than being released later on stale evidence. (AAPS a33752c9aa, #1)
                if !trancheRan, Self.confirmTranche.heldU > 0 {
                    det.reason += " trancheGate=dropped:seam-skipped," +
                        "\(String(format: "%.3f", Self.confirmTranche.heldU));"
                    Self.confirmTranche.reset()
                }
                // AAPS night mode compares against the BASE profile target (pre-TT) and
                // disables on an active low temp target clamped to LIMIT_TEMP_TARGET_BG (72–200).
                let baseTarget = (profile.boostBaseTargetMgdl as NSDecimalNumber?)?.doubleValue
                    ?? (det.current_target as NSDecimalNumber?)?.doubleValue ?? 100
                let activeTt: Double? = (profile.temptargetSet ?? false)
                    ? (profile.minBg as NSDecimalNumber?).map { min(200, max(72, $0.doubleValue)) }
                    : nil
                let night = BoostV5Adapter.nightMode(
                    determination: det,
                    preferences: preferences,
                    baseProfileTargetMgdl: baseTarget,
                    activeTempTargetMgdl: activeTt,
                    sleepInActive: sleepInActive,
                    clock: clock
                )
                if night.suppress {
                    det.units = 0
                    det.reason += " nightMode(SMB suppressed)"
                }
                // AAPS LoopPlugin's check for multiple SMBs, applied last as AAPS applies it after the
                // APS returns: withhold any SMB while the newest bolus is younger than the interval
                // (clamped 1...10 min as stock clamps it). The stock path keeps its own check.
                var smbInterval = Decimal(3)
                if !profile.smbInterval.isNaN { smbInterval = min(10, max(1, profile.smbInterval)) }
                if let units = det.units, units > 0,
                   BoostV1Determination.smbFrequencyExceeded(
                       lastBolusTimeMs: iob.first?.lastBolusTime, now: clock, smbIntervalMin: smbInterval
                   )
                {
                    det.units = 0
                    det.reason += " SMB \(units)U withheld (still in \(smbInterval) min SMB interval);"
                }
            }
            rawDetermination = det
        }

        return rawDetermination
    }

    private func loadJSON(name: String) -> String {
        try! String(contentsOf: Foundation.Bundle.main.url(forResource: "json/\(name)", withExtension: "json")!)
    }

    private func loadFileFromStorage(name: String) -> RawJSON {
        storage.retrieveRaw(name) ?? OpenAPS.defaults(for: name)
    }

    private func loadFileFromStorageAsync(name: String) async -> RawJSON {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.storage.retrieveRaw(name) ?? OpenAPS.defaults(for: name)
                continuation.resume(returning: result)
            }
        }
    }

    static func defaults(for file: String) -> RawJSON {
        let prefix = file.hasSuffix(".json") ? "json/defaults" : "javascript"
        guard let url = Foundation.Bundle.main.url(forResource: "\(prefix)/\(file)", withExtension: "") else {
            return ""
        }
        return (try? String(contentsOf: url)) ?? ""
    }

    func processAndSave(forecastData: [String: [Int]]) {
        let currentDate = Date()
        let context = newContext("processAndSave")

        context.perform {
            for (type, values) in forecastData {
                self.createForecast(type: type, values: values, date: currentDate, context: context)
            }

            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Saving forecasts failed", error: error)
            }
        }
    }

    func createForecast(type: String, values: [Int], date: Date, context: NSManagedObjectContext) {
        let forecast = Forecast(context: context)
        forecast.id = UUID()
        forecast.date = date
        forecast.type = type

        for (index, value) in values.enumerated() {
            let forecastValue = ForecastValue(context: context)
            forecastValue.value = Int32(value)
            forecastValue.index = Int32(index)
            forecastValue.forecast = forecast
        }
    }
}

// Non-Async fetch methods for trio_custom_oref_variables
extension OpenAPS {
    func fetchActiveTempTargets(on context: NSManagedObjectContext) throws -> [TempTargetStored] {
        try CoreDataStack.shared.fetchEntities(
            ofType: TempTargetStored.self,
            onContext: context,
            predicate: NSPredicate.lastActiveTempTarget,
            key: "date",
            ascending: false,
            fetchLimit: 1
        ) as? [TempTargetStored] ?? []
    }

    func fetchActiveOverrides(on context: NSManagedObjectContext) throws -> [OverrideStored] {
        try CoreDataStack.shared.fetchEntities(
            ofType: OverrideStored.self,
            onContext: context,
            predicate: NSPredicate.lastActiveOverride,
            key: "date",
            ascending: false,
            fetchLimit: 1
        ) as? [OverrideStored] ?? []
    }

    func fetchHistoricalTDDData(from date: Date, on context: NSManagedObjectContext) throws -> [[String: Any]] {
        try CoreDataStack.shared.fetchEntities(
            ofType: TDDStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date > %@ AND total > 0", date as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "total"]
        ) as? [[String: Any]] ?? []
    }
}
