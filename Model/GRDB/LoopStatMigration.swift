import CoreData
import Foundation
import GRDB

/// One-time copy of `LoopStatRecord` rows from the Core Data store into GRDB.
///
/// Runs once per install, gated by a `UserDefaults` flag, and is idempotent: it only writes
/// when the GRDB table is empty, so a half-finished or repeated run cannot duplicate rows.
/// The Core Data rows are left untouched (read-only) — they are the rollback source until the
/// migration is proven in the field.
enum LoopStatMigration {
    private static let didMigrateKey = "grdb.didMigrateLoopStats"

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        // Guard against double-import: if GRDB already has loop stats, just set the flag.
        let existingCount = try await stack.pool.read { db in
            try LoopStat.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let legacy = try await readLegacyRecords()
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy LoopStatRecord rows to migrate.")
            return
        }

        // Single transaction: all rows or none.
        try await stack.pool.write { db in
            for var stat in legacy {
                try stat.insert(db)
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(legacy.count) LoopStatRecord rows into GRDB.")
    }

    /// Reads all `LoopStatRecord` rows from Core Data and maps them to `LoopStat` values.
    /// Mapping happens inside the context; only value types leave it.
    private static func readLegacyRecords() async throws -> [LoopStat] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "LoopStatMigration.read"
        return try await context.perform {
            let request = LoopStatRecord.fetchRequest() as NSFetchRequest<LoopStatRecord>
            request.sortDescriptors = [NSSortDescriptor(key: "start", ascending: true)]
            let rows = try context.fetch(request)
            return rows.map { row in
                LoopStat(
                    id: nil,
                    start: row.start,
                    end: row.end,
                    loopStatus: row.loopStatus,
                    duration: row.duration,
                    interval: row.interval
                )
            }
        }
    }
}
