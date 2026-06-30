import CoreData
import Foundation
import HealthKit

extension History.StateModel {
    // Carb and FPU deletion from history
    /// - **Parameter**: the GRDB rowid (`pk`) of the carb entry to delete
    func invokeCarbDeletionTask(_ pk: Int64, isFpuOrComplexMeal: Bool = false) {
        Task {
            do {
                /// Set the variables that control the CustomProgressView BEFORE the actual deletion
                /// otherwise the determineBasalSync gets executed first, sets waitForSuggestion to false and afterwards waitForSuggestion is set in this function to true, leading to an endless animation
                await MainActor.run {
                    carbEntryDeleted = true
                    waitForSuggestion = true
                }

                try await deleteCarbs(pk, isFpuOrComplexMeal: isFpuOrComplexMeal)

            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to delete carbs: \(error)")
                await MainActor.run {
                    carbEntryDeleted = false
                    waitForSuggestion = false
                }
            }
        }
    }

    func deleteCarbs(_ pk: Int64, isFpuOrComplexMeal: Bool = false) async throws {
        // Delete from Nightscout/Apple Health/Tidepool
        await deleteFromServices(pk, isFPUDeletion: isFpuOrComplexMeal)

        // Delete carbs from GRDB
        await carbsStorage.deleteCarbsEntryStored(pk)

        // Perform a determine basal sync to update cob
        try await apsManager.determineBasalSync()
    }

    /// Deletes carb and FPU entries from all connected services (Nightscout, HealthKit, Tidepool)
    /// - Parameters:
    ///   - pk: The GRDB rowid of the entry to delete
    ///   - isFPUDeletion: Flag indicating if this is a FPU deletion that requires special handling
    ///     - If true: Will first fetch the corresponding carb entry and then delete both FPU and carb entries
    ///     - If false: Will delete the entry directly as a standard carb deletion
    /// - Note: This function handles three scenarios:
    ///   1. Standard carb deletion (isFPUDeletion = false)
    ///   2. FPU-only deletion (isFPUDeletion = true)
    ///   3. Combined carb+FPU deletion (isFPUDeletion = true)
    func deleteFromServices(_ pk: Int64, isFPUDeletion: Bool = false) async {
        var pkToDelete = pk

        // For FPU deletions, first get the corresponding carb entry
        if isFPUDeletion {
            guard let correspondingEntry = await handleFPUEntry(pk),
                  let entryPk = correspondingEntry.entryPk
            else { return }

            pkToDelete = entryPk
        }

        do {
            guard let carbEntry = try await CarbEntryStore.fetch(pk: pkToDelete) else {
                debugPrint("Carb entry for deletion not found. \(DebuggingIdentifiers.failed)")
                return
            }

            // Delete FPU related entries if they exist
            if let fpuID = carbEntry.fpuID {
                // Delete Fat and Protein entries from Nightscout
                provider.deleteCarbsFromNightscout(withID: fpuID.uuidString)

                // Delete Fat and Protein entries from Apple Health
                let healthObjectsToDelete: [HKSampleType?] = [
                    AppleHealthConfig.healthFatObject,
                    AppleHealthConfig.healthProteinObject
                ]

                for sampleType in healthObjectsToDelete {
                    if let validSampleType = sampleType {
                        provider.deleteMealDataFromHealth(byID: fpuID.uuidString, sampleType: validSampleType)
                    }
                }
            }

            // Delete carb entries if they exist
            if let id = carbEntry.id, let entryDate = carbEntry.date {
                provider.deleteCarbsFromNightscout(withID: id.uuidString)

                // Delete carbs from Apple Health
                if let sampleType = AppleHealthConfig.healthCarbObject {
                    provider.deleteMealDataFromHealth(byID: id.uuidString, sampleType: sampleType)
                }

                provider.deleteCarbsFromTidepool(
                    withSyncId: id,
                    carbs: Decimal(carbEntry.carbs),
                    at: entryDate,
                    enteredBy: CarbsEntry.local
                )
            }
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Error deleting entries: \(error)")
        }
    }
}
