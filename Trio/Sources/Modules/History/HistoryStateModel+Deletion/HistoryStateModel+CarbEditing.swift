import Foundation

extension History.StateModel {
    // MARK: - Entry Management

    /// Updates a carb/FPU entry with new values and handles the necessary cleanup and recreation of FPU entries
    /// - Parameters:
    ///   - pk: The GRDB rowid of the entry to update
    ///   - newCarbs: The new carbs value
    ///   - newFat: The new fat value
    ///   - newProtein: The new protein value
    ///   - newNote: The new note text
    ///   - newDate: The new date for the entry
    func updateEntry(
        _ pk: Int64,
        newCarbs: Decimal,
        newFat: Decimal,
        newProtein: Decimal,
        newNote: String,
        newDate: Date
    ) {
        Task {
            do {
                // Get original date from entry to re-create the entry later with the updated values and the same date
                guard let originalEntry = await getOriginalEntryValues(pk) else { return }

                // Deletion logic for carb and FPU entries
                try await deleteOldEntries(
                    pk,
                    originalEntry: originalEntry,
                    newCarbs: newCarbs,
                    newFat: newFat,
                    newProtein: newProtein,
                    newNote: newNote
                )

                try await createNewEntries(
                    originalDate: newDate,
                    newCarbs: newCarbs,
                    newFat: newFat,
                    newProtein: newProtein,
                    newNote: newNote
                )

                await syncWithServices()

                // Perform a determine basal sync to update cob
                try await apsManager.determineBasalSync()

            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) failed to update entry: \(error)")
            }
        }
    }

    private func createNewEntries(
        originalDate: Date,
        newCarbs: Decimal,
        newFat: Decimal,
        newProtein: Decimal,
        newNote: String
    ) async throws {
        let newEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: originalDate,
            carbs: newCarbs,
            fat: newFat,
            protein: newProtein,
            note: newNote,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: newFat > 0 || newProtein > 0 ? UUID().uuidString : nil
        )

        // Handles internally whether to create fake carbs or not based on whether fat > 0 or protein > 0
        try await carbsStorage.storeCarbs([newEntry], areFetchedFromRemote: false)
    }

    /// Deletes the old carb/ FPU entries and creates new ones with updated values
    /// - Parameters:
    ///   - pk: The GRDB rowid of the entry to delete
    ///   - originalEntry: The original entry values and its rowid
    ///   - newCarbs: The new carbs value
    ///   - newFat: The new fat value
    ///   - newProtein: The new protein value
    ///   - newNote: The new note text
    private func deleteOldEntries(
        _ pk: Int64,
        originalEntry: (
            entryValues: (date: Date, carbs: Double, fat: Double, protein: Double)?,
            entryPk: Int64
        ),
        newCarbs _: Decimal,
        newFat _: Decimal,
        newProtein _: Decimal,
        newNote _: String
    ) async throws {
        if ((originalEntry.entryValues?.carbs ?? 0) == 0 && (originalEntry.entryValues?.fat ?? 0) > 0) ||
            ((originalEntry.entryValues?.carbs ?? 0) == 0 && (originalEntry.entryValues?.protein ?? 0) > 0)
        {
            // Delete the zero-carb-entry and all its carb equivalents connected by the same fpuID from remote services and GRDB
            // Use fpuID
            try await deleteCarbs(pk, isFpuOrComplexMeal: true)
        } else if ((originalEntry.entryValues?.carbs ?? 0) > 0 && (originalEntry.entryValues?.fat ?? 0) > 0) ||
            ((originalEntry.entryValues?.carbs ?? 0) > 0 && (originalEntry.entryValues?.protein ?? 0) > 0)
        {
            // Delete carb entry and carb equivalents that are all connected by the same fpuID from remote services and GRDB
            // Use fpuID
            try await deleteCarbs(pk, isFpuOrComplexMeal: true)

        } else {
            // Delete just the carb entry since there are no carb equivalents
            try await deleteCarbs(pk)
        }
    }

    /// Retrieves the original entry values
    /// - Parameter pk: The GRDB rowid of the entry
    /// - Returns: A tuple of the old entry values and its rowid, or nil
    private func getOriginalEntryValues(_ pk: Int64) async
        -> (entryValues: (date: Date, carbs: Double, fat: Double, protein: Double)?, entryPk: Int64)?
    {
        do {
            guard let entry = try await CarbEntryStore.fetch(pk: pk),
                  let entryPk = entry.pk,
                  let entryDate = entry.date
            else { return nil }

            return (
                entryValues: (date: entryDate, carbs: entry.carbs, fat: entry.fat, protein: entry.protein),
                entryPk: entryPk
            )
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to get original entry values with error: \(error)")
            return nil
        }
    }

    /// Synchronizes the FPU/ Carb entry with all remote services in parallel
    private func syncWithServices() async {
        async let nightscoutUpload: () = provider.nightscoutManager.uploadCarbs()
        async let healthKitUpload: () = provider.healthkitManager.uploadCarbs()
        async let tidepoolUpload: () = provider.tidepoolManager.uploadCarbs()

        _ = await [nightscoutUpload, healthKitUpload, tidepoolUpload]
    }

    // MARK: - Entry Loading

    /// Loads the values of a carb or FPU entry from GRDB
    /// - Parameter pk: The GRDB rowid of the entry to load
    /// - Returns: A tuple containing the entry's values, or nil if not found
    func loadEntryValues(from pk: Int64) async
        -> (carbs: Decimal, fat: Decimal, protein: Decimal, note: String, date: Date)?
    {
        do {
            guard let entry = try await CarbEntryStore.fetch(pk: pk),
                  let entryDate = entry.date
            else { return nil }

            return (
                carbs: Decimal(entry.carbs),
                fat: Decimal(entry.fat),
                protein: Decimal(entry.protein),
                note: entry.note ?? "",
                date: entryDate
            )
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to load entry: \(error)")
            return nil
        }
    }

    // MARK: - FPU Entry Handling

    /// Handles the loading of FPU entries based on their type
    /// If the user taps on an FPU entry in the DataTable list, there are two cases:
    /// - the User has entered this FPU entry WITH carbs
    /// - the User has entered this FPU entry WITHOUT carbs
    /// In the first case, we simply need to load the corresponding carb entry. For this case THIS is the entry we want to edit.
    /// In the second case, we need to load the zero-carb entry that actually holds the FPU values (and the carbs). For this case THIS is the entry we want to edit.
    /// - Parameter pk: The GRDB rowid of the FPU entry
    /// - Returns: A tuple containing the entry values and rowid, or nil if not found
    func handleFPUEntry(_ pk: Int64) async
        -> (
            entryValues: (carbs: Decimal, fat: Decimal, protein: Decimal, note: String, date: Date)?,
            entryPk: Int64?
        )?
    {
        // Case 1: FPU entry WITH carbs
        if let correspondingCarbEntryPk = await getCorrespondingCarbEntry(pk) {
            if let values = await loadEntryValues(from: correspondingCarbEntryPk) {
                return (values, correspondingCarbEntryPk)
            }
        }
        // Case 2: FPU entry WITHOUT carbs
        else if let originalEntryPk = await getZeroCarbNonFPUEntry(pk) {
            if let values = await loadEntryValues(from: originalEntryPk) {
                return (values, originalEntryPk)
            }
        }
        return nil
    }

    /// Retrieves the original zero-carb non-FPU entry for a given FPU entry.
    /// This is used when the user has entered a FPU entry WITHOUT carbs.
    /// - Parameter pk: The GRDB rowid of the FPU entry
    /// - Returns: The rowid of the original entry, or nil if not found
    func getZeroCarbNonFPUEntry(_ pk: Int64) async -> Int64? {
        do {
            // Get the fpuID from the selected entry
            guard let selectedEntry = try await CarbEntryStore.fetch(pk: pk),
                  let fpuID = selectedEntry.fpuID
            else { return nil }

            // Fetch the original zero-carb entry (non-FPU) with the same fpuID, within the last 24 hours
            let last24Hours = Date().addingTimeInterval(-60 * 60 * 24)
            let group = try await CarbEntryStore.fetchByFpuID(fpuID)
            let originalEntry = group.first {
                ($0.date ?? .distantPast) >= last24Hours && !$0.isFPU && $0.carbs == 0
            }
            debugPrint("FPU fetch result: \(originalEntry != nil ? "Entry found" : "No entry found")")
            return originalEntry?.pk
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to fetch original FPU entry: \(error)")
            return nil
        }
    }

    /// Retrieves the corresponding carb entry for a given FPU entry.
    /// This is used when the user has entered a carb entry WITH FPUs all at once.
    /// - Parameter pk: The GRDB rowid of the FPU entry
    /// - Returns: The rowid of the corresponding carb entry, or nil if not found
    func getCorrespondingCarbEntry(_ pk: Int64) async -> Int64? {
        do {
            // Get the fpuID from the selected entry
            guard let selectedEntry = try await CarbEntryStore.fetch(pk: pk),
                  let fpuID = selectedEntry.fpuID
            else { return nil }

            // Fetch the corresponding carb entry with the same fpuID, within the last 24 hours
            let last24Hours = Date().addingTimeInterval(-24.hours.timeInterval)
            let group = try await CarbEntryStore.fetchByFpuID(fpuID)
            let correspondingCarbEntry = group.first {
                ($0.date ?? .distantPast) >= last24Hours && !$0.isFPU && ($0.carbs > 0 || $0.fat > 0 || $0.protein > 0)
            }
            debugPrint(
                "Corresponding carb entry fetch result: \(correspondingCarbEntry != nil ? "Entry found" : "No entry found")"
            )
            return correspondingCarbEntry?.pk
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to fetch corresponding carb entry: \(error)")
            return nil
        }
    }
}
