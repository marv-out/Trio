import Foundation

extension History.StateModel {
    /// Initiates the glucose deletion process asynchronously
    /// - Parameter pk: The GRDB primary key of the GlucoseRecord to delete
    func invokeGlucoseDeletionTask(_ pk: Int64) {
        Task {
            await deleteGlucose(pk)
        }
    }

    func deleteGlucose(_ pk: Int64) async {
        // Delete from Apple Health/Nightscout (reads id/date before deleting)
        await deleteGlucoseFromServices(pk)

        // Delete from GRDB (also writes tombstone in one transaction)
        await glucoseStorage.deleteGlucose(pk)
    }

    func deleteGlucoseFromServices(_ pk: Int64) async {
        do {
            guard let record = try await GlucoseStore.fetch(pk: pk) else {
                debugPrint("Data Table State: \(#function) \(DebuggingIdentifiers.failed) glucose not found in GRDB (pk=\(pk))")
                return
            }

            // Delete from Nightscout
            if let id = record.id?.uuidString, let date = record.date {
                provider.deleteGlucoseFromNightscout(withID: id, withDate: date)
            }

            // Delete from Apple Health
            if let id = record.id?.uuidString {
                provider.deleteGlucoseFromHealth(withSyncID: id)
            }

            debugPrint(
                "\(#file) \(#function) \(DebuggingIdentifiers.succeeded) deleted glucose from remote service(s) (Nightscout, Apple Health, Tidepool)"
            )
        } catch {
            debugPrint(
                "\(#file) \(#function) \(DebuggingIdentifiers.failed) error while deleting glucose from remote service(s) (Nightscout, Apple Health, Tidepool) with error: \(error)"
            )
        }
    }
}
