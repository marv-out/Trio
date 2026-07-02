import Combine
import CoreData
import Foundation
import JavaScriptCore

final class OpenAPS {
    private let jsWorker = JavaScriptWorker()
    private let processQueue = DispatchQueue(label: "OpenAPS.processQueue", qos: .utility)

    private let storage: FileStorage
    private let tddStorage: TDDStorage

    let jsonConverter = JSONConverter()

    private func newContext(_ name: String) -> NSManagedObjectContext {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = name
        return context
    }

    init(storage: FileStorage, tddStorage: TDDStorage) {
        self.storage = storage
        self.tddStorage = tddStorage
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

    // Hot-path write: persist the determination + its forecast tree to GRDB in one transaction.
    func processDetermination(_ determination: Determination) async {
        // `timestamp` is intentionally left nil here — like the former Core Data path, it is only
        // stamped later by `APSManager.reportEnacted` once the determination is actually enacted.
        let record = OrefDeterminationRecord(
            id: UUID(),
            deliverAt: determination.deliverAt,
            isUploadedToNS: false,
            cob: Int16(Int(determination.cob ?? 0)),
            carbsRequired: Int16(Int(determination.carbsReq ?? 0)),
            reason: determination.reason,
            temp: determination.temp?.rawValue ?? "absolute",
            carbRatio: determination.carbRatio,
            currentTarget: determination.current_target,
            duration: determination.duration,
            eventualBG: determination.eventualBG.map { Decimal($0) },
            expectedDelta: determination.expectedDelta,
            glucose: determination.bg,
            insulinReq: determination.insulinReq,
            insulinSensitivity: determination.isf,
            iob: determination.iob,
            minDelta: determination.minDelta,
            rate: determination.rate,
            reservoir: determination.reservoir,
            sensitivityRatio: determination.sensitivityRatio,
            smbToDeliver: determination.units,
            threshold: determination.threshold
        )

        let now = Date()
        let forecasts: [OrefDeterminationStore.ForecastInput] = determination.predictions.map { predictions in
            ["iob": predictions.iob, "zt": predictions.zt, "cob": predictions.cob, "uam": predictions.uam]
                .compactMap { type, values in
                    values.map { OrefDeterminationStore.ForecastInput(type: type, date: now, values: $0) }
                }
        } ?? []

        do {
            try await OrefDeterminationStore.store(record, forecasts: forecasts)
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to save Determination to GRDB: \(error)")
        }
    }

    // fetch glucose to pass it to the meal function and to determine basal
    func fetchAndProcessGlucose(
        context: NSManagedObjectContext,
        shouldSmoothGlucose: Bool,
        fetchLimit: Int?,
        fetchHours: Decimal = 24
    ) async throws -> String {
        // Time window from `fetchHours` hours ago up to now. determineBasal feeds
        // `maxMealAbsorptionTime + 0.5h` (just enough glucose to cover the longest
        // tracked meal absorption plus a small lead-in); Autosens uses the default
        // 24h because its sensitivity algorithm needs that full window.
        let cutoff = Date().addingTimeInterval(-(Double(truncating: fetchHours as NSNumber) * 3600))
        let timePredicate = NSPredicate(format: "date >= %@", cutoff as NSDate)

        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: timePredicate,
            key: "date",
            ascending: false,
            fetchLimit: fetchLimit,
            batchSize: 48
        )

        // mapping within the context closure, JSON conversion outside
        let algorithmGlucose = try await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            // extracting handler to only create it 1x
            let roundingBehavior = NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )

            return glucoseResults.map { glucose -> AlgorithmGlucose in
                let glucoseValue: Int16
                if shouldSmoothGlucose {
                    if !glucose.isManual, let smoothedGlucose = glucose.smoothedGlucose, smoothedGlucose != 0 {
                        glucoseValue = smoothedGlucose.rounding(accordingToBehavior: roundingBehavior).int16Value
                    } else {
                        // use the raw value = finger prick, so manual readings are always included for algorithm decision making
                        // cf. https://github.com/nightscout/Trio/issues/1054
                        glucoseValue = glucose.glucose
                    }
                } else {
                    glucoseValue = glucose.glucose
                }
                return AlgorithmGlucose(
                    date: glucose.date,
                    direction: glucose.direction,
                    glucose: glucoseValue,
                    id: glucose.id,
                    isManual: glucose.isManual
                )
            }
        }

        return jsonConverter.convertToJSON(algorithmGlucose)
    }

    private func fetchAndProcessCarbs(
        additionalCarbs: Decimal? = nil,
        carbsDate: Date? = nil
    ) async throws -> String {
        let carbResults = try await CarbEntryStore.fetchForMealCalc()

        var jsonArray = jsonConverter.convertToJSON(carbResults)

        if let additionalCarbs = additionalCarbs {
            let formattedDate = carbsDate.map { ISO8601DateFormatter().string(from: $0) } ?? ISO8601DateFormatter()
                .string(from: Date())

            let additionalEntry = [
                "carbs": Double(additionalCarbs),
                "actualDate": formattedDate,
                "id": UUID().uuidString,
                "note": NSNull(),
                "protein": 0,
                "created_at": formattedDate,
                "isFPU": false,
                "fat": 0,
                "enteredBy": "Trio"
            ] as [String: Any]

            // Assuming jsonArray is a String, convert it to a list of dictionaries first
            if let jsonData = jsonArray.data(using: .utf8) {
                var jsonList = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]]
                jsonList?.append(additionalEntry)

                // Convert back to JSON string
                if let updatedJsonData = try? JSONSerialization
                    .data(withJSONObject: jsonList ?? [], options: .prettyPrinted)
                {
                    jsonArray = String(data: updatedJsonData, encoding: .utf8) ?? jsonArray
                }
            }
        }

        return jsonArray
    }

    private func fetchPumpHistoryObjectIDs(on context: NSManagedObjectContext) async throws -> [NSManagedObjectID]? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.pumpHistoryLast1440Minutes,
            key: "timestamp",
            ascending: false,
            batchSize: 50,
            relationshipKeyPathsForPrefetching: ["bolus", "tempBasal"]
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
    ) async throws -> String {
        // Return an empty JSON object if the list of object IDs is empty
        guard !pumpHistoryObjectIDs.isEmpty else { return "{}" }

        // Addresses https://github.com/nightscout/Trio/issues/898
        //
        // On a cold start (new user, fresh onboarding, or pump disconnected > 24h),
        // the oldest event in pump history can be a resume with no preceding pump
        // activity. oref interprets this as the end of a suspend that never started,
        // which drives negative IOB and can cause excessive insulin delivery.
        let orphanedResumes = try await fetchOrphanedResumes(on: context)

        // Execute all operations on the background context
        return await context.perform {
            // Load and map pump events to DTOs
            var dtos = self.loadAndMapPumpEvents(pumpHistoryObjectIDs, orphanedResumes: orphanedResumes, on: context)

            // Optionally add the IOB as a DTO
            if let simulatedBolusAmount = simulatedBolusAmount {
                let simulatedBolusDTO = self.createSimulatedBolusDTO(simulatedBolusAmount: simulatedBolusAmount)
                dtos.insert(simulatedBolusDTO, at: 0)
            }

            // Convert the DTOs to JSON
            return self.jsonConverter.convertToJSON(dtos)
        }
    }

    private func loadAndMapPumpEvents(
        _ pumpHistoryObjectIDs: [NSManagedObjectID],
        orphanedResumes: [NSManagedObjectID],
        on context: NSManagedObjectContext
    ) -> [PumpEventDTO] {
        OpenAPS.loadAndMapPumpEvents(pumpHistoryObjectIDs, orphanedResumes: orphanedResumes, from: context)
    }

    /// Fetches and parses pump events, expose this as static and not private for testing
    static func loadAndMapPumpEvents(
        _ pumpHistoryObjectIDs: [NSManagedObjectID],
        orphanedResumes: [NSManagedObjectID],
        from context: NSManagedObjectContext
    ) -> [PumpEventDTO] {
        let orphanedSet = Set(orphanedResumes)
        let filteredObjectIds = pumpHistoryObjectIDs.filter { !orphanedSet.contains($0) }
        // Load the pump events from the object IDs
        let pumpHistory: [PumpEventStored] = filteredObjectIds
            .compactMap { context.object(with: $0) as? PumpEventStored }

        // Create the DTOs
        let dtos: [PumpEventDTO] = pumpHistory.flatMap { event -> [PumpEventDTO] in
            var eventDTOs: [PumpEventDTO] = []
            if let bolusDTO = event.toBolusDTOEnum() {
                eventDTOs.append(bolusDTO)
            }
            if let tempBasalDurationDTO = event.toTempBasalDurationDTOEnum() {
                eventDTOs.append(tempBasalDurationDTO)
            }
            if let tempBasalDTO = event.toTempBasalDTOEnum() {
                eventDTOs.append(tempBasalDTO)
            }
            if let pumpSuspendDTO = event.toPumpSuspendDTO() {
                eventDTOs.append(pumpSuspendDTO)
            }
            if let pumpResumeDTO = event.toPumpResumeDTO() {
                eventDTOs.append(pumpResumeDTO)
            }
            if let rewindDTO = event.toRewindDTO() {
                eventDTOs.append(rewindDTO)
            }
            if let primeDTO = event.toPrimeDTO() {
                eventDTOs.append(primeDTO)
            }
            return eventDTOs
        }
        return dtos
    }

    private func createSimulatedBolusDTO(simulatedBolusAmount: Decimal) -> PumpEventDTO {
        let oneSecondAgo = Calendar.current
            .date(
                byAdding: .second,
                value: -1,
                to: Date()
            )! // adding -1s to the current Date ensures that oref actually uses the mock entry to calculate iob and not guard it away
        let dateFormatted = PumpEventStored.dateFormatter.string(from: oneSecondAgo)

        let bolusDTO = BolusDTO(
            id: UUID().uuidString,
            timestamp: dateFormatted,
            amount: Double(simulatedBolusAmount),
            isExternal: false,
            isSMB: true,
            duration: 0,
            _type: "Bolus"
        )
        return .bolus(bolusDTO)
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
        currentTemp: TempBasal,
        shouldSmoothGlucose: Bool,
        useSwiftOref: Bool,
        clock: Date = Date(),
        simulatedCarbsAmount: Decimal? = nil,
        simulatedBolusAmount: Decimal? = nil,
        simulatedCarbsDate: Date? = nil,
        simulation: Bool = false
    ) async throws -> Determination? {
        debug(.openAPS, "Start determineBasal")

        let context = newContext("determineBasal")

        // temp_basal
        let tempBasal = currentTemp.rawJSON

        // Perform asynchronous calls in parallel
        async let pumpHistoryObjectIDs = fetchPumpHistoryObjectIDs(on: context) ?? []
        async let carbs = fetchAndProcessCarbs(
            additionalCarbs: simulatedCarbsAmount ?? 0,
            carbsDate: simulatedCarbsDate
        )

        var preferences = await storage.retrieveAsync(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()
        let glucoseFetchHours = preferences.maxMealAbsorptionTime + 0.5 // MMAT + half hour buffer
        async let glucose = fetchAndProcessGlucose(
            context: context,
            shouldSmoothGlucose: shouldSmoothGlucose,
            fetchLimit: nil,
            fetchHours: glucoseFetchHours
        )

        async let prepareTrioCustomOrefVariables = prepareTrioCustomOrefVariables(on: context)
        async let profileAsync = loadFileFromStorageAsync(name: Settings.profile)
        async let basalAsync = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let autosenseAsync = loadFileFromStorageAsync(name: Settings.autosense)
        async let reservoirAsync = loadFileFromStorageAsync(name: Monitor.reservoir)
        async let hasSufficientTddForDynamic = tddStorage.hasSufficientTDD()

        // Await the results of asynchronous tasks
        let (
            pumpHistoryJSON,
            carbsAsJSON,
            glucoseAsJSON,
            trioCustomOrefVariables,
            profile,
            basalProfile,
            autosens,
            reservoir,
            hasSufficientTdd
        ) = await (
            try parsePumpHistory(on: context, await pumpHistoryObjectIDs, simulatedBolusAmount: simulatedBolusAmount),
            try carbs,
            try glucose,
            try prepareTrioCustomOrefVariables,
            profileAsync,
            basalAsync,
            autosenseAsync,
            reservoirAsync,
            try hasSufficientTddForDynamic
        )

        // Meal calculation
        let meal = try await self.meal(
            pumphistory: pumpHistoryJSON,
            profile: profile,
            basalProfile: basalProfile,
            clock: clock,
            carbs: carbsAsJSON,
            glucose: glucoseAsJSON,
            useSwiftOref: useSwiftOref
        )

        // IOB calculation
        let iob = try await self.iob(
            pumphistory: pumpHistoryJSON,
            profile: profile,
            clock: clock,
            autosens: autosens.isEmpty ? .null : autosens,
            useSwiftOref: useSwiftOref
        )

        // TODO: refactor this to core data
        if !simulation {
            storage.save(iob, as: Monitor.iob)
        }

        if !hasSufficientTdd, preferences.useNewFormula || (preferences.useNewFormula && preferences.sigmoid) {
            debug(.openAPS, "Insufficient TDD for dynamic formula; disabling for determine basal run.")
            preferences.useNewFormula = false
            preferences.sigmoid = false
        }

        // Determine basal
        let orefDetermination = try await determineBasal(
            glucose: glucoseAsJSON,
            currentTemp: tempBasal,
            iob: iob,
            profile: profile,
            autosens: autosens.isEmpty ? .null : autosens,
            meal: meal,
            microBolusAllowed: true,
            reservoir: reservoir,
            pumpHistory: pumpHistoryJSON,
            preferences: preferences,
            basalProfile: basalProfile,
            trioCustomOrefVariables: trioCustomOrefVariables,
            useSwiftOref: useSwiftOref
        )

        debug(.openAPS, "\(simulation ? "[SIMULATION]" : "") OREF DETERMINATION: \(orefDetermination)")

        if var determination = Determination(from: orefDetermination), let deliverAt = determination.deliverAt {
            // set both timestamp and deliverAt to the SAME date; this will be updated for timestamp once it is enacted
            // AAPS does it the same way! we'll follow their example!
            determination.timestamp = deliverAt

            if !simulation {
                // save the determination + its forecasts to GRDB asynchronously
                await processDetermination(determination)
            }

            return determination
        } else {
            debug(
                .openAPS,
                "\(DebuggingIdentifiers.failed) No determination data. orefDetermination: \(orefDetermination), Determination(from: orefDetermination): \(String(describing: Determination(from: orefDetermination))), deliverAt: \(String(describing: Determination(from: orefDetermination)?.deliverAt))"
            )
            throw APSError.apsError(message: "No determination data.")
        }
    }

    func prepareTrioCustomOrefVariables(on context: NSManagedObjectContext) async throws -> RawJSON {
        // TDD and Overrides now live in GRDB — fetch before the Core Data perform block (which is
        // synchronous). Override records are value types, safe to capture in the block.
        let tenDaysAgo = Date().addingTimeInterval(-10.days.timeInterval)
        let twoHoursAgo = Date().addingTimeInterval(-2.hours.timeInterval)
        let tddEntries = try await TDDStore.entries(since: tenDaysAgo, positiveTotalOnly: true)
        let activeOverrides = try await OverrideStore.fetchActiveConfigurations()

        return try await context.perform {
            // Retrieve user preferences
            let userPreferences = self.storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            let weightPercentage = userPreferences?.weightPercentage ?? 1.0
            let maxSMBBasalMinutes = userPreferences?.maxSMBBasalMinutes ?? 30
            let maxUAMBasalMinutes = userPreferences?.maxUAMSMBBasalMinutes ?? 30

            // The last active Override (pre-fetched from GRDB above).
            let isOverrideActive = activeOverrides.first?.enabled ?? false
            let overridePercentage = Decimal(activeOverrides.first?.percentage ?? 100)
            let isOverrideIndefinite = activeOverrides.first?.indefinite ?? true
            let disableSMBs = activeOverrides.first?.smbIsOff ?? false
            let overrideTargetBG = activeOverrides.first?.target ?? 0

            // Calculate averages for Total Daily Dose (TDD) from the pre-fetched GRDB entries
            let totalTDD = tddEntries.compactMap(\.total).reduce(0, +)
            let totalDaysCount = max(tddEntries.count, 1)

            // Recent TDD data for the past two hours
            let recentTDDData = tddEntries.filter { ($0.date ?? Date()) >= twoHoursAgo }
            let recentDataCount = max(recentTDDData.count, 1)
            let recentTotalTDD = recentTDDData.compactMap(\.total).reduce(0, +)

            let currentTDD = tddEntries.last?.total ?? 0
            let averageTDDLastTwoHours = recentTotalTDD / Decimal(recentDataCount)
            let averageTDDLastTenDays = totalTDD / Decimal(totalDaysCount)
            let weightedTDD = weightPercentage * averageTDDLastTwoHours + (1 - weightPercentage) * averageTDDLastTenDays

            let glucose = try self.fetchGlucose(on: context)

            // Prepare Trio's custom oref variables
            let trioCustomOrefVariablesData = TrioCustomOrefVariables(
                average_total_data: currentTDD > 0 ? averageTDDLastTenDays : 0,
                weightedAverage: currentTDD > 0 ? weightedTDD : 1,
                currentTDD: currentTDD,
                past2hoursAverage: currentTDD > 0 ? averageTDDLastTwoHours : 0,
                date: Date(),
                overridePercentage: overridePercentage,
                useOverride: isOverrideActive,
                duration: activeOverrides.first?.duration ?? 0,
                unlimited: isOverrideIndefinite,
                overrideTarget: overrideTargetBG,
                smbIsOff: disableSMBs,
                advancedSettings: activeOverrides.first?.advancedSettings ?? false,
                isfAndCr: activeOverrides.first?.isfAndCr ?? false,
                isf: activeOverrides.first?.isf ?? false,
                cr: activeOverrides.first?.cr ?? false,
                smbIsScheduledOff: activeOverrides.first?.smbIsScheduledOff ?? false,
                start: activeOverrides.first?.start ?? 0,
                end: activeOverrides.first?.end ?? 0,
                smbMinutes: activeOverrides.first?.smbMinutes ?? maxSMBBasalMinutes,
                uamMinutes: activeOverrides.first?.uamMinutes ?? maxUAMBasalMinutes
            )

            // Save and return contents of Trio's custom oref variables
            self.storage.save(trioCustomOrefVariablesData, as: OpenAPS.Monitor.trio_custom_oref_variables)
            return self.loadFileFromStorage(name: Monitor.trio_custom_oref_variables)
        }
    }

    func autosense(shouldSmoothGlucose: Bool, useSwiftOref: Bool) async throws -> Autosens? {
        debug(.openAPS, "Start autosens")

        let context = newContext("autosense")

        // Perform asynchronous calls in parallel
        async let pumpHistoryObjectIDs = fetchPumpHistoryObjectIDs(on: context) ?? []
        async let carbs = fetchAndProcessCarbs()
        async let glucose = fetchAndProcessGlucose(context: context, shouldSmoothGlucose: shouldSmoothGlucose, fetchLimit: nil)
        async let getProfile = loadFileFromStorageAsync(name: Settings.profile)
        async let getBasalProfile = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let getTempTargets = loadFileFromStorageAsync(name: Settings.tempTargets)

        // Await the results of asynchronous tasks
        let (pumpHistoryJSON, carbsAsJSON, glucoseAsJSON, profile, basalProfile, tempTargets) = await (
            try parsePumpHistory(on: context, await pumpHistoryObjectIDs),
            try carbs,
            try glucose,
            getProfile,
            getBasalProfile,
            getTempTargets
        )

        // Autosense
        let autosenseResult = try await autosense(
            glucose: glucoseAsJSON,
            pumpHistory: pumpHistoryJSON,
            basalprofile: basalProfile,
            profile: profile,
            carbs: carbsAsJSON,
            temptargets: tempTargets,
            useSwiftOref: useSwiftOref
        )

        debug(.openAPS, "AUTOSENS: \(autosenseResult)")
        if var autosens = Autosens(from: autosenseResult) {
            autosens.timestamp = Date()
            await storage.saveAsync(autosens, as: Settings.autosense)

            return autosens
        } else {
            return nil
        }
    }

    func createProfiles(useSwiftOref: Bool) async throws {
        debug(.openAPS, "Start creating pump profile and user profile")

        // Load required settings and profiles asynchronously
        async let getPumpSettings = loadFileFromStorageAsync(name: Settings.settings)
        async let getBGTargets = loadFileFromStorageAsync(name: Settings.bgTargets)
        async let getBasalProfile = loadFileFromStorageAsync(name: Settings.basalProfile)
        async let getISF = loadFileFromStorageAsync(name: Settings.insulinSensitivities)
        async let getCR = loadFileFromStorageAsync(name: Settings.carbRatios)
        async let getTempTargets = loadFileFromStorageAsync(name: Settings.tempTargets)
        async let getModel = loadFileFromStorageAsync(name: Settings.model)
        async let getTrioSettingDefaults = loadFileFromStorageAsync(name: Trio.settings)

        let (pumpSettings, bgTargets, basalProfile, isf, cr, tempTargets, model, trioSettings) = await (
            getPumpSettings,
            getBGTargets,
            getBasalProfile,
            getISF,
            getCR,
            getTempTargets,
            getModel,
            getTrioSettingDefaults
        )

        // Retrieve user preferences, or set defaults if not available
        let preferences = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()
        let defaultHalfBasalTarget = preferences.halfBasalExerciseTarget
        var adjustedPreferences = preferences

        // Check for active Temp Targets and adjust HBT if necessary (Temp Targets now live in GRDB,
        // so this value-type fetch happens up front instead of inside a Core Data perform block).
        if let activeTempTarget = try await TempTargetStore.fetchLatestActive(),
           activeTempTarget.enabled,
           let targetValue = activeTempTarget.target
        {
            // Compute effective HBT - handles both custom HBT and standard TT (where HBT might need adjustment)
            let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
                tempTargetHalfBasalTarget: activeTempTarget.halfBasalTarget,
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
                ))
                debug(
                    .openAPS,
                    "TempTarget: target=\(targetValue), HBT=\(defaultHalfBasalTarget), effectiveHBT=\(effectiveHBT), percentage=\(percentage)%, adjustmentType=Custom"
                )
            }
        }
        // Overwrite the lowTTlowersSens if autosensMax does not support it
        if preferences.lowTemptargetLowersSensitivity, preferences.autosensMax <= 1 {
            adjustedPreferences.lowTemptargetLowersSensitivity = false
            debug(.openAPS, "Setting lowTTlowersSens to false due to insufficient autosensMax: \(preferences.autosensMax)")
        }

        let clock = Date()
        do {
            let pumpProfile = try await makeProfile(
                preferences: adjustedPreferences,
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: isf,
                carbRatio: cr,
                tempTargets: tempTargets,
                model: model,
                autotune: RawJSON.null,
                trioSettings: trioSettings,
                useSwiftOref: useSwiftOref,
                clock: clock
            )

            let profile = try await makeProfile(
                preferences: adjustedPreferences,
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: isf,
                carbRatio: cr,
                tempTargets: tempTargets,
                model: model,
                autotune: RawJSON.null,
                trioSettings: trioSettings,
                useSwiftOref: useSwiftOref,
                clock: clock
            )

            // Save the profiles
            await storage.saveAsync(pumpProfile, as: Settings.pumpProfile)
            await storage.saveAsync(profile, as: Settings.profile)
        } catch {
            debug(
                .apsManager,
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to create pump profile and normal profile: \(error)"
            )
            throw error
        }
    }

    private func iob(pumphistory: JSON, profile: JSON, clock: JSON, autosens: JSON, useSwiftOref: Bool) async throws -> RawJSON {
        // FIXME: For now we'll just remove duplicate suspends here (ISSUE-399)
        var pumphistory = pumphistory
        if let pumpHistoryArray = try? JSONBridge.pumpHistory(from: pumphistory) {
            pumphistory = pumpHistoryArray.removingDuplicateSuspendResumeEvents().rawJSON
        }

        if useSwiftOref {
            let swiftResult = OpenAPSSwift
                .iob(pumphistory: pumphistory, profile: profile, clock: clock, autosens: autosens)
            return try swiftResult.returnOrThrow()
        } else {
            let jsResult = await iobJavascript(pumphistory: pumphistory, profile: profile, clock: clock, autosens: autosens)
            return try jsResult.returnOrThrow()
        }
    }

    func iobJavascript(pumphistory: JSON, profile: JSON, clock: JSON, autosens: JSON) async -> OrefFunctionResult {
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                jsWorker.inCommonContext { worker in
                    worker.evaluateBatch(scripts: [
                        Script(name: Prepare.log),
                        Script(name: Bundle.iob),
                        Script(name: Prepare.iob)
                    ])
                    let result = worker.call(function: Function.generate, with: [
                        pumphistory,
                        profile,
                        clock,
                        autosens
                    ])
                    continuation.resume(returning: result)
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func meal(
        pumphistory: JSON,
        profile: JSON,
        basalProfile: JSON,
        clock: JSON,
        carbs: JSON,
        glucose: JSON,
        useSwiftOref: Bool
    ) async throws -> RawJSON {
        if useSwiftOref {
            let swiftResult = OpenAPSSwift
                .meal(
                    pumphistory: pumphistory,
                    profile: profile,
                    basalProfile: basalProfile,
                    clock: clock,
                    carbs: carbs,
                    glucose: glucose
                )
            return try swiftResult.returnOrThrow()
        } else {
            let jsResult = await mealJavascript(
                pumphistory: pumphistory,
                profile: profile,
                basalProfile: basalProfile,
                clock: clock,
                carbs: carbs,
                glucose: glucose
            )
            return try jsResult.returnOrThrow()
        }
    }

    private func mealJavascript(
        pumphistory: JSON,
        profile: JSON,
        basalProfile: JSON,
        clock: JSON,
        carbs: JSON,
        glucose: JSON
    ) async -> OrefFunctionResult {
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                jsWorker.inCommonContext { worker in
                    worker.evaluateBatch(scripts: [
                        Script(name: Prepare.log),
                        Script(name: Bundle.meal),
                        Script(name: Prepare.meal)
                    ])
                    let result = worker.call(function: Function.generate, with: [
                        pumphistory,
                        profile,
                        clock,
                        glucose,
                        basalProfile,
                        carbs
                    ])
                    continuation.resume(returning: result)
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func autosense(
        glucose: JSON,
        pumpHistory: JSON,
        basalprofile: JSON,
        profile: JSON,
        carbs: JSON,
        temptargets: JSON,
        useSwiftOref: Bool
    ) async throws -> RawJSON {
        if useSwiftOref {
            let swiftResult = OpenAPSSwift
                .autosense(
                    glucose: glucose,
                    pumpHistory: pumpHistory,
                    basalProfile: basalprofile,
                    profile: profile,
                    carbs: carbs,
                    tempTargets: temptargets,
                    clock: Date()
                )
            return try swiftResult.returnOrThrow()
        } else {
            let jsResult = await autosenseJavascript(
                glucose: glucose,
                pumpHistory: pumpHistory,
                basalprofile: basalprofile,
                profile: profile,
                carbs: carbs,
                temptargets: temptargets
            )
            return try jsResult.returnOrThrow()
        }
    }

    private func autosenseJavascript(
        glucose: JSON,
        pumpHistory: JSON,
        basalprofile: JSON,
        profile: JSON,
        carbs: JSON,
        temptargets: JSON
    ) async -> OrefFunctionResult {
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                jsWorker.inCommonContext { worker in
                    worker.evaluateBatch(scripts: [
                        Script(name: Prepare.log),
                        Script(name: Bundle.autosens),
                        Script(name: Prepare.autosens)
                    ])
                    let result = worker.call(function: Function.generate, with: [
                        glucose,
                        pumpHistory,
                        basalprofile,
                        profile,
                        carbs,
                        temptargets
                    ])
                    continuation.resume(returning: result)
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func determineBasal(
        glucose: JSON,
        currentTemp: JSON,
        iob: JSON,
        profile: JSON,
        autosens: JSON,
        meal: JSON,
        microBolusAllowed: Bool,
        reservoir: JSON,
        pumpHistory: JSON,
        preferences: JSON,
        basalProfile: JSON,
        trioCustomOrefVariables: JSON,
        useSwiftOref: Bool
    ) async throws -> RawJSON {
        let clock = Date()

        if useSwiftOref {
            let swiftResult = OpenAPSSwift.determineBasal(
                glucose: glucose,
                currentTemp: currentTemp,
                iob: iob,
                profile: profile,
                autosens: autosens,
                meal: meal,
                microBolusAllowed: microBolusAllowed,
                reservoir: reservoir,
                pumpHistory: pumpHistory,
                preferences: preferences,
                basalProfile: basalProfile,
                trioCustomOrefVariables: trioCustomOrefVariables,
                clock: clock
            )
            return try swiftResult.returnOrThrow()
        } else {
            let jsResult = await determineBasalJavascript(
                glucose: glucose,
                currentTemp: currentTemp,
                iob: iob,
                profile: profile,
                autosens: autosens,
                meal: meal,
                microBolusAllowed: microBolusAllowed,
                reservoir: reservoir,
                pumpHistory: pumpHistory,
                preferences: preferences,
                basalProfile: basalProfile,
                trioCustomOrefVariables: trioCustomOrefVariables,
                clock: clock
            )
            return try jsResult.returnOrThrow()
        }
    }

    private func determineBasalJavascript(
        glucose: JSON,
        currentTemp: JSON,
        iob: JSON,
        profile: JSON,
        autosens: JSON,
        meal: JSON,
        microBolusAllowed: Bool,
        reservoir: JSON,
        pumpHistory: JSON,
        preferences: JSON,
        basalProfile: JSON,
        trioCustomOrefVariables: JSON,
        clock: Date
    ) async -> OrefFunctionResult {
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                jsWorker.inCommonContext { worker in
                    worker.evaluateBatch(scripts: [
                        Script(name: Prepare.log),
                        Script(name: Prepare.determineBasal),
                        Script(name: Bundle.basalSetTemp),
                        Script(name: Bundle.getLastGlucose),
                        Script(name: Bundle.determineBasal)
                    ])

                    let result = worker.call(function: Function.generate, with: [
                        iob,
                        currentTemp,
                        glucose,
                        profile,
                        autosens,
                        meal,
                        microBolusAllowed,
                        reservoir,
                        clock,
                        pumpHistory,
                        preferences,
                        basalProfile,
                        trioCustomOrefVariables
                    ])

                    continuation.resume(returning: result)
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func exportDefaultPreferences() -> RawJSON {
        dispatchPrecondition(condition: .onQueue(processQueue))
        return jsWorker.inCommonContext { worker in
            worker.evaluateBatch(scripts: [
                Script(name: Prepare.log),
                Script(name: Bundle.profile),
                Script(name: Prepare.profile)
            ])
            return worker.call(function: Function.exportDefaults, with: [])
        }
    }

    // use `internal` protection to expose to unit tests
    func makeProfileJavascript(
        preferences: JSON,
        pumpSettings: JSON,
        bgTargets: JSON,
        basalProfile: JSON,
        isf: JSON,
        carbRatio: JSON,
        tempTargets: JSON,
        model: JSON,
        autotune: JSON,
        trioSettings: JSON
    ) async -> OrefFunctionResult {
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                jsWorker.inCommonContext { worker in
                    worker.evaluateBatch(scripts: [
                        Script(name: Prepare.log),
                        Script(name: Bundle.profile),
                        Script(name: Prepare.profile)
                    ])
                    let result = worker.call(function: Function.generate, with: [
                        pumpSettings,
                        bgTargets,
                        isf,
                        basalProfile,
                        preferences,
                        carbRatio,
                        tempTargets,
                        model,
                        autotune,
                        trioSettings
                    ])
                    continuation.resume(returning: result)
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func makeProfile(
        preferences: JSON,
        pumpSettings: JSON,
        bgTargets: JSON,
        basalProfile: JSON,
        isf: JSON,
        carbRatio: JSON,
        tempTargets: JSON,
        model: JSON,
        autotune: JSON,
        trioSettings: JSON,
        useSwiftOref: Bool,
        clock: Date
    ) async throws -> RawJSON {
        if useSwiftOref {
            let swiftResult = OpenAPSSwift.makeProfile(
                preferences: preferences,
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: isf,
                carbRatio: carbRatio,
                tempTargets: tempTargets,
                model: model,
                trioSettings: trioSettings,
                clock: clock
            )
            return try swiftResult.returnOrThrow()
        } else {
            let jsResult = await makeProfileJavascript(
                preferences: preferences,
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: isf,
                carbRatio: carbRatio,
                tempTargets: tempTargets,
                model: model,
                autotune: autotune,
                trioSettings: trioSettings
            )
            return try jsResult.returnOrThrow()
        }
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

    /// The bolus-preview path: persists *orphan* forecasts (no determination) to GRDB.
    func processAndSave(forecastData: [String: [Int]]) {
        let currentDate = Date()
        let forecasts = forecastData.map { type, values in
            OrefDeterminationStore.ForecastInput(type: type, date: currentDate, values: values)
        }

        Task {
            do {
                try await ForecastStore.storeOrphan(forecasts: forecasts)
            } catch {
                debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to save orphan forecasts: \(error)")
            }
        }
    }
}

// Non-Async fetch methods for trio_custom_oref_variables
extension OpenAPS {
    func fetchGlucose(on context: NSManagedObjectContext) throws -> [GlucoseStored] {
        let results = try CoreDataStack.shared.fetchEntities(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgo,
            key: "date",
            ascending: false,
            fetchLimit: 4
        )

        return try context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return glucoseResults
        }
    }
}
