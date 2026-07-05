import CoreData
import Foundation
import GRDB

/// One-time copy of `DeletedGlucoseStored` tombstones from Core Data into GRDB.
///
/// A companion to `GlucoseMigration` (see `MIGRATION.md`, Step 12), kept as a separate file for symmetry
/// with the entity split and gated by its own `UserDefaults` flag. Standalone, no relationships — a
/// straight row-for-row copy. The tombstones stop a later CGM backfill from re-ingesting a reading the
/// user deleted, so they must survive the migration alongside the glucose rows.
enum DeletedGlucoseMigration {
    private static let didMigrateKey = "grdb.didMigrateDeletedGlucose"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try DeletedGlucoseRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "DeletedGlucoseMigration.read"

        let records = try await context.perform { () -> [DeletedGlucoseRecord] in
            // The generated `DeletedGlucoseStored.fetchRequest()` is mistyped as `<GlucoseStored>`, so
            // build the request by entity name directly.
            let request = NSFetchRequest<DeletedGlucoseStored>(entityName: "DeletedGlucoseStored")
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            return try context.fetch(request).map { stored in
                DeletedGlucoseRecord(
                    date: stored.date,
                    glucose: stored.glucose,
                    isManualGlucoseEntry: stored.isManualGlucoseEntry
                )
            }
        }

        guard !records.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy DeletedGlucoseStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for record in records {
                var record = record
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(records.count) DeletedGlucoseStored rows into GRDB.")
    }
}
