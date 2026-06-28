import CoreData
import Foundation
import GRDB

/// One-time copy of `ContactImageEntryStored` rows from Core Data into GRDB.
/// Same contract as the other migrations: once per install, idempotent, Core Data rows
/// left untouched as a rollback source.
enum ContactImageMigration {
    private static let didMigrateKey = "grdb.didMigrateContactImage"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try ContactImageRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let legacy = try await readLegacyRecords()
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy ContactImageEntryStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for var record in legacy {
                try record.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(legacy.count) ContactImageEntryStored rows into GRDB.")
    }

    private static func readLegacyRecords() async throws -> [ContactImageRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "ContactImageMigration.read"
        return try await context.perform {
            let request = ContactImageEntryStored.fetchRequest()
            let rows = try context.fetch(request)
            return rows.map { row in
                ContactImageRecord(
                    id: row.id,
                    name: row.name,
                    contactId: row.contactId,
                    layout: row.layout,
                    ring: row.ring,
                    primary: row.primary,
                    top: row.top,
                    bottom: row.bottom,
                    hasHighContrast: row.hasHighContrast,
                    ringWidth: row.ringWidth,
                    ringGap: row.ringGap,
                    colorMode: row.colorMode,
                    fontSize: row.fontSize,
                    fontSizeSecondary: row.fontSizeSecondary,
                    fontWeight: row.fontWeight,
                    fontWidth: row.fontWidth
                )
            }
        }
    }
}
