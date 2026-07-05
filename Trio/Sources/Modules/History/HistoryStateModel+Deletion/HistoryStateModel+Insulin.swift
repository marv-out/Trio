import Foundation

extension History.StateModel {
    // Insulin deletion from history
    /// - **Parameter**: the GRDB `pk` of the pump event to delete (value-type identity, no
    /// `NSManagedObjectID` round-trip).
    func invokeInsulinDeletionTask(_ pk: Int64) {
        Task {
            do {
                try await invokeInsulinDeletion(pk)
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to delete insulin entry: \(error)")
            }
        }
    }

    func invokeInsulinDeletion(_ pk: Int64) async throws {
        do {
            let authenticated = try await unlockmanager.unlock()

            guard authenticated else {
                debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Authentication Error")
                return
            }

            /// Set variables that control the CustomProgressView to true AFTER the authentication and BEFORE the actual determineBasalSync
            /// We definitely need to set the variables BEFORE the actual sync
            /// otherwise the determineBasalSync gets executed first, sets waitForSuggestion to false and afterwards waitForSuggestion is set in this function to true, leading to an endless animation
            /// But we also want it AFTER the authentication
            /// otherwise the animation would pop up even before the authentication prompt appears to the user
            await MainActor.run {
                insulinEntryDeleted = true
                waitForSuggestion = true
            }

            // Delete from remote service(s) (i.e. Nightscout, Apple Health, Tidepool)
            await deleteInsulinFromServices(with: pk)

            // Delete from GRDB (cascades to the bolus / temp-basal child)
            try await PumpEventStore.delete(pk: pk)

            // Perform a determine basal sync to update iob
            try await apsManager.determineBasalSync()
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Error while Insulin Deletion Task: \(error)"
            )
            await MainActor.run {
                insulinEntryDeleted = false
                waitForSuggestion = false
            }
        }
    }

    func deleteInsulinFromServices(with pk: Int64) async {
        do {
            guard let details = try await PumpEventStore.fetch(pk: pk) else {
                debug(.default, "Could not find the pump event to delete")
                return
            }

            if let id = details.event.id, let timestamp = details.timestamp,
               let bolus = details.bolus, let bolusAmount = bolus.amount
            {
                provider.deleteInsulinFromNightscout(withID: id)
                provider.deleteInsulinFromHealth(withSyncID: id)
                provider.deleteInsulinFromTidepool(withSyncId: id, amount: bolusAmount, at: timestamp)
            }
        } catch {
            debug(.default, "Failed to resolve the treatment object for deletion: \(error)")
        }
    }
}
