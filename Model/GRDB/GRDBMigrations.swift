import Foundation
import GRDB

/// Schema migrations for the GRDB store.
///
/// Unlike Core Data's inferred lightweight migration, GRDB migrations are explicit and
/// versioned: each registered migration runs exactly once, in order, and is recorded in
/// the `grdb_migrations` table. Never edit a shipped migration — add a new one.
extension GRDBStack {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Safety net during development: wipe & rebuild if a migration changes.
        // MUST be removed before this ships to users with real data.
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // v1 — LoopStatRecord (first entity migrated off Core Data).
        // Columns mirror the Core Data entity attributes 1:1 so the data migration is a
        // straight copy. `id` is a synthetic rowid PK (the Core Data entity had none).
        migrator.registerMigration("v1_loopStatRecord") { db in
            try db.create(table: "loopStatRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime)
                t.column("end", .datetime)
                t.column("loopStatus", .text)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("interval", .double).notNull().defaults(to: 0)
            }
            // Mirrors the Core Data fetch index on `start` (used by every stats query).
            try db.create(index: "loopStatRecord_on_start", on: "loopStatRecord", columns: ["start"])
            try db.create(index: "loopStatRecord_on_end", on: "loopStatRecord", columns: ["end"])
        }

        return migrator
    }
}
