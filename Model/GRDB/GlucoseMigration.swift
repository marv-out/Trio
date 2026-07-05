import CoreData
import Foundation
import GRDB

/// One-time copy of `GlucoseStored` rows from Core Data into GRDB.
///
/// The last (and highest-volume) entity to migrate (see `MIGRATION.md`, Step 12). Standalone, no
/// relationships — a straight row-for-row copy. Same contract as the other migrations: once per install,
/// idempotent, Core Data rows left in place as a rollback source. `smoothedGlucose` (Core Data
/// `NSDecimalNumber?`) maps to the record's `Decimal?` (stored as TEXT).
enum GlucoseMigration {
    private static let didMigrateKey = "grdb.didMigrateGlucose"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try GlucoseRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "GlucoseMigration.read"

        let records = try await context.perform { () -> [GlucoseRecord] in
            let request = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            return try context.fetch(request).map { stored in
                GlucoseRecord(
                    id: stored.id,
                    date: stored.date,
                    glucose: stored.glucose,
                    direction: stored.direction,
                    isManual: stored.isManual,
                    smoothedGlucose: stored.smoothedGlucose?.decimalValue,
                    isUploadedToNS: stored.isUploadedToNS,
                    isUploadedToHealth: stored.isUploadedToHealth,
                    isUploadedToTidepool: stored.isUploadedToTidepool
                )
            }
        }

        guard !records.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy GlucoseStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for record in records {
                var record = record
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(records.count) GlucoseStored rows into GRDB.")
    }
}
