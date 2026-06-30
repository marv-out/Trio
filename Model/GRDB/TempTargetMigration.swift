import CoreData
import Foundation
import GRDB

/// One-time copy of `TempTargetStored` + `TempTargetRunStored` rows from Core Data into GRDB.
///
/// Same relationship-resolving contract as `OverrideMigration` (Step 7): each
/// `TempTargetRunStored.tempTarget` to-one link is resolved to the new GRDB `tempTargetPk`. The
/// temp-target `id` is *not* unique (`copyRunningTempTarget` duplicates it), so the link is keyed by
/// the legacy `NSManagedObjectID` → new `pk` instead. Once per install, idempotent, Core Data rows
/// left in place as a rollback source.
enum TempTargetMigration {
    private static let didMigrateKey = "grdb.didMigrateTempTarget"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try TempTargetRecord.fetchCount(db) + TempTargetRunRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "TempTargetMigration.read"

        // Read temp targets (with their objectID) and runs (with their source target's objectID).
        let (tempTargets, runs) = try await context
            .perform { () -> ([(NSManagedObjectID, TempTargetRecord)], [(NSManagedObjectID?, TempTargetRunRecord)]) in
                let tempTargetRequest = TempTargetStored.fetchRequest() as NSFetchRequest<TempTargetStored>
                tempTargetRequest.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
                let tempTargetRows = try context.fetch(tempTargetRequest)
                let tempTargets = tempTargetRows.map { ($0.objectID, mapTempTarget($0)) }

                let runRequest = TempTargetRunStored.fetchRequest() as NSFetchRequest<TempTargetRunStored>
                runRequest.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]
                let runRows = try context.fetch(runRequest)
                let runs = runRows.map { ($0.tempTarget?.objectID, mapRun($0)) }

                return (tempTargets, runs)
            }

        guard !tempTargets.isEmpty || !runs.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy TempTargetStored/TempTargetRunStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            // Insert temp targets first, mapping legacy objectID -> new pk.
            var pkByObjectID: [NSManagedObjectID: Int64] = [:]
            for (objectID, var record) in tempTargets {
                try record.insert(db)
                if let pk = record.pk { pkByObjectID[objectID] = pk }
            }
            // Insert runs, resolving the relationship to the new foreign key.
            for (tempTargetObjectID, var run) in runs {
                if let tempTargetObjectID { run.tempTargetPk = pkByObjectID[tempTargetObjectID] }
                try run.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(
            .coreData,
            "Migrated \(tempTargets.count) TempTargetStored + \(runs.count) TempTargetRunStored rows into GRDB."
        )
    }

    private static func mapTempTarget(_ row: TempTargetStored) -> TempTargetRecord {
        TempTargetRecord(
            id: row.id,
            name: row.name,
            date: row.date,
            enabled: row.enabled,
            isPreset: row.isPreset,
            isUploadedToNS: row.isUploadedToNS,
            orderPosition: Int(row.orderPosition),
            enteredBy: row.enteredBy,
            duration: row.duration?.decimalValue,
            target: row.target?.decimalValue,
            halfBasalTarget: row.halfBasalTarget?.decimalValue
        )
    }

    private static func mapRun(_ row: TempTargetRunStored) -> TempTargetRunRecord {
        TempTargetRunRecord(
            id: row.id,
            name: row.name,
            startDate: row.startDate,
            endDate: row.endDate,
            isUploadedToNS: row.isUploadedToNS,
            target: row.target?.decimalValue,
            tempTargetPk: nil
        )
    }
}
