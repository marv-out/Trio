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

        // v2 — TDDStored (Total Daily Dose aggregates). Columns mirror the Core Data
        // attributes 1:1. Only `date` and `total` are ever read; the rest are kept for
        // the historical record. Decimals are stored as TEXT to preserve exact values.
        migrator.registerMigration("v2_tddStored") { db in
            try db.create(table: "tddStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("date", .datetime)
                t.column("total", .text) // Decimal as string
                t.column("bolus", .text)
                t.column("tempBasal", .text)
                t.column("scheduledBasal", .text)
                t.column("weightedAverage", .text)
            }
            // Every TDD query filters/sorts on `date`.
            try db.create(index: "tddStored_on_date", on: "tddStored", columns: ["date"])
        }

        // v3 — ContactImageEntryStored. Standalone, no relationships; all String/Int16/Bool/UUID.
        migrator.registerMigration("v3_contactImageEntryStored") { db in
            try db.create(table: "contactImageEntryStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID
                t.column("name", .text)
                t.column("contactId", .text)
                t.column("layout", .text)
                t.column("ring", .text)
                t.column("primary", .text)
                t.column("top", .text)
                t.column("bottom", .text)
                t.column("hasHighContrast", .boolean)
                t.column("ringWidth", .integer)
                t.column("ringGap", .integer)
                t.column("colorMode", .text)
                t.column("fontSize", .integer)
                t.column("fontSizeSecondary", .integer)
                t.column("fontWeight", .text)
                t.column("fontWidth", .text)
            }
            // Update/lookup is by contactId.
            try db.create(index: "contactImageEntryStored_on_contactId", on: "contactImageEntryStored", columns: ["contactId"])
        }

        // v4 — OpenAPS_Battery (pump battery status). Standalone, no relationships.
        migrator.registerMigration("v4_openAPSBattery") { db in
            try db.create(table: "openAPSBattery") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID
                t.column("date", .datetime)
                t.column("percent", .double)
                t.column("voltage", .double)
                t.column("status", .text)
                t.column("display", .boolean)
            }
            // Every battery query filters/sorts on `date`.
            try db.create(index: "openAPSBattery_on_date", on: "openAPSBattery", columns: ["date"])
        }

        return migrator
    }
}
