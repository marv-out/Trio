import CoreData
import Foundation
import GRDB

/// One-time copy of `OverrideStored` + `OverrideRunStored` rows from Core Data into GRDB.
///
/// The first migration with a relationship: each `OverrideRunStored.override` to-one link is
/// resolved to the new GRDB `overridePk`. The override `id` is *not* unique (`copyRunningOverride`
/// duplicates it), so the link is keyed by the legacy `NSManagedObjectID` → new `pk` instead.
/// Same contract as the other migrations: once per install, idempotent, Core Data rows left in
/// place as a rollback source.
enum OverrideMigration {
    private static let didMigrateKey = "grdb.didMigrateOverride"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try OverrideRecord.fetchCount(db) + OverrideRunRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "OverrideMigration.read"

        // Read overrides (with their objectID) and runs (with their source override's objectID).
        let (overrides, runs) = try await context
            .perform { () -> ([(NSManagedObjectID, OverrideRecord)], [(NSManagedObjectID?, OverrideRunRecord)]) in
                let overrideRequest = OverrideStored.fetchRequest() as NSFetchRequest<OverrideStored>
                overrideRequest.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
                let overrideRows = try context.fetch(overrideRequest)
                let overrides = overrideRows.map { ($0.objectID, mapOverride($0)) }

                let runRequest = OverrideRunStored.fetchRequest() as NSFetchRequest<OverrideRunStored>
                runRequest.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]
                let runRows = try context.fetch(runRequest)
                let runs = runRows.map { ($0.override?.objectID, mapRun($0)) }

                return (overrides, runs)
            }

        guard !overrides.isEmpty || !runs.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy OverrideStored/OverrideRunStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            // Insert overrides first, mapping legacy objectID -> new pk.
            var pkByObjectID: [NSManagedObjectID: Int64] = [:]
            for (objectID, var record) in overrides {
                try record.insert(db)
                if let pk = record.pk { pkByObjectID[objectID] = pk }
            }
            // Insert runs, resolving the relationship to the new foreign key.
            for (overrideObjectID, var run) in runs {
                if let overrideObjectID { run.overridePk = pkByObjectID[overrideObjectID] }
                try run.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(overrides.count) OverrideStored + \(runs.count) OverrideRunStored rows into GRDB.")
    }

    private static func mapOverride(_ row: OverrideStored) -> OverrideRecord {
        OverrideRecord(
            id: row.id,
            name: row.name,
            date: row.date,
            enabled: row.enabled,
            isPreset: row.isPreset,
            isUploadedToNS: row.isUploadedToNS,
            orderPosition: Int(row.orderPosition),
            indefinite: row.indefinite,
            percentage: row.percentage,
            advancedSettings: row.advancedSettings,
            isfAndCr: row.isfAndCr,
            isf: row.isf,
            cr: row.cr,
            smbIsOff: row.smbIsOff,
            smbIsScheduledOff: row.smbIsScheduledOff,
            duration: row.duration?.decimalValue,
            target: row.target?.decimalValue,
            smbMinutes: row.smbMinutes?.decimalValue,
            uamMinutes: row.uamMinutes?.decimalValue,
            start: row.start?.decimalValue,
            end: row.end?.decimalValue
        )
    }

    private static func mapRun(_ row: OverrideRunStored) -> OverrideRunRecord {
        OverrideRunRecord(
            id: row.id,
            name: row.name,
            startDate: row.startDate,
            endDate: row.endDate,
            isUploadedToNS: row.isUploadedToNS,
            target: row.target?.decimalValue,
            overridePk: nil
        )
    }
}
