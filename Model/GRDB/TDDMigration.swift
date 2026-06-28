import CoreData
import Foundation
import GRDB

/// One-time copy of `TDDStored` rows from Core Data into GRDB.
///
/// Same contract as `LoopStatMigration`: runs once per install (UserDefaults flag),
/// idempotent (only writes when the GRDB table is empty), Core Data rows left untouched
/// as a rollback source.
enum TDDMigration {
    private static let didMigrateKey = "grdb.didMigrateTDD"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try TDDRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let legacy = try await readLegacyRecords()
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy TDDStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for var record in legacy {
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(legacy.count) TDDStored rows into GRDB.")
    }

    private static func readLegacyRecords() async throws -> [TDDRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "TDDMigration.read"
        return try await context.perform {
            let request = TDDStored.fetchRequest() as NSFetchRequest<TDDStored>
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let rows = try context.fetch(request)
            return rows.map { row in
                TDDRecord(
                    id: row.id?.uuidString,
                    date: row.date,
                    total: row.total?.decimalValue,
                    bolus: row.bolus?.decimalValue,
                    tempBasal: row.tempBasal?.decimalValue,
                    scheduledBasal: row.scheduledBasal?.decimalValue,
                    weightedAverage: row.weightedAverage?.decimalValue
                )
            }
        }
    }
}
