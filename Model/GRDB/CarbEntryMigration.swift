import CoreData
import Foundation
import GRDB

/// One-time copy of `CarbEntryStored` rows from Core Data into GRDB.
///
/// Simpler than the Override/TempTarget migrations: carbs have no relationships, so this is a
/// straight row-for-row copy (the `fpuID` grouping key is just an attribute and carries over as-is).
/// Same contract as the other migrations: once per install, idempotent, Core Data rows left in
/// place as a rollback source.
enum CarbEntryMigration {
    private static let didMigrateKey = "grdb.didMigrateCarbEntry"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try CarbEntryRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "CarbEntryMigration.read"

        let records = try await context.perform { () -> [CarbEntryRecord] in
            let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            return try context.fetch(request).map(mapCarbEntry)
        }

        guard !records.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy CarbEntryStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for var record in records {
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(records.count) CarbEntryStored rows into GRDB.")
    }

    private static func mapCarbEntry(_ row: CarbEntryStored) -> CarbEntryRecord {
        CarbEntryRecord(
            id: row.id,
            date: row.date,
            carbs: row.carbs,
            fat: row.fat,
            protein: row.protein,
            note: row.note,
            isFPU: row.isFPU,
            fpuID: row.fpuID,
            isUploadedToNS: row.isUploadedToNS,
            isUploadedToHealth: row.isUploadedToHealth,
            isUploadedToTidepool: row.isUploadedToTidepool
        )
    }
}
