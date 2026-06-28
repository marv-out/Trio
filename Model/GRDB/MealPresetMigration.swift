import CoreData
import Foundation
import GRDB

/// One-time copy of `MealPresetStored` rows from Core Data into GRDB.
/// Same contract as the other migrations: once per install, idempotent, Core Data rows
/// left untouched as a rollback source.
enum MealPresetMigration {
    private static let didMigrateKey = "grdb.didMigrateMealPreset"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try MealPresetRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let legacy = try await readLegacyRecords()
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy MealPresetStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for var record in legacy {
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(legacy.count) MealPresetStored rows into GRDB.")
    }

    private static func readLegacyRecords() async throws -> [MealPresetRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "MealPresetMigration.read"
        return try await context.perform {
            let request = MealPresetStored.fetchRequest() as NSFetchRequest<MealPresetStored>
            request.sortDescriptors = [NSSortDescriptor(key: "dish", ascending: true)]
            let rows = try context.fetch(request)
            return rows.map { row in
                MealPresetRecord(
                    dish: row.dish,
                    carbs: row.carbs?.decimalValue,
                    fat: row.fat?.decimalValue,
                    protein: row.protein?.decimalValue
                )
            }
        }
    }
}
