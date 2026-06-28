import CoreData
import Foundation
import GRDB

/// One-time copy of `OpenAPS_Battery` rows from Core Data into GRDB.
/// Same contract as the other migrations: once per install, idempotent, Core Data rows
/// left untouched as a rollback source.
enum BatteryMigration {
    private static let didMigrateKey = "grdb.didMigrateBattery"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try BatteryRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let legacy = try await readLegacyRecords()
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy OpenAPS_Battery rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for var record in legacy {
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(legacy.count) OpenAPS_Battery rows into GRDB.")
    }

    private static func readLegacyRecords() async throws -> [BatteryRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "BatteryMigration.read"
        return try await context.perform {
            let request = OpenAPS_Battery.fetchRequest() as NSFetchRequest<OpenAPS_Battery>
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let rows = try context.fetch(request)
            return rows.map { row in
                BatteryRecord(
                    id: row.id,
                    date: row.date,
                    percent: row.percent,
                    voltage: row.voltage?.doubleValue,
                    status: row.status,
                    display: row.display
                )
            }
        }
    }
}
