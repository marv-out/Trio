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

        // v5 — MealPresetStored (saved meal templates). Decimals as TEXT (lossless).
        migrator.registerMigration("v5_mealPresetStored") { db in
            try db.create(table: "mealPresetStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("dish", .text)
                t.column("carbs", .text)
                t.column("fat", .text)
                t.column("protein", .text)
            }
            // Listed/sorted by dish.
            try db.create(index: "mealPresetStored_on_dish", on: "mealPresetStored", columns: ["dish"])
        }

        // v6 — OverrideStored + OverrideRunStored (profile overrides, presets, and their runs).
        // First relationship-bearing family: the Core Data `override` to-one relationship becomes
        // the `overridePk` foreign key on `overrideRunStored`. The 6 override Decimals and the run
        // `target` are stored as TEXT (lossless), like `TDDRecord`.
        migrator.registerMigration("v6_override") { db in
            try db.create(table: "overrideStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("name", .text)
                t.column("date", .datetime)
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("isPreset", .boolean).notNull().defaults(to: false)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("orderPosition", .integer).notNull().defaults(to: 0)
                t.column("indefinite", .boolean).notNull().defaults(to: false)
                t.column("percentage", .double).notNull().defaults(to: 100)
                t.column("advancedSettings", .boolean).notNull().defaults(to: false)
                t.column("isfAndCr", .boolean).notNull().defaults(to: true)
                t.column("isf", .boolean).notNull().defaults(to: true)
                t.column("cr", .boolean).notNull().defaults(to: true)
                t.column("smbIsOff", .boolean).notNull().defaults(to: false)
                t.column("smbIsScheduledOff", .boolean).notNull().defaults(to: false)
                t.column("duration", .text) // Decimal as string
                t.column("target", .text)
                t.column("smbMinutes", .text)
                t.column("uamMinutes", .text)
                t.column("start", .text)
                t.column("end", .text)
            }
            // Active-override and preset queries filter on these; date sorts the active list.
            try db.create(index: "overrideStored_on_date", on: "overrideStored", columns: ["date"])
            try db.create(index: "overrideStored_on_isPreset", on: "overrideStored", columns: ["isPreset"])
            try db.create(index: "overrideStored_on_enabled", on: "overrideStored", columns: ["enabled"])

            try db.create(table: "overrideRunStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("name", .text)
                t.column("startDate", .datetime)
                t.column("endDate", .datetime)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("target", .text) // Decimal as string
                // Replaces the Core Data `override` to-one relationship. SET NULL on delete so a
                // run survives its source override being cleaned up (it keeps its own dates/name).
                t.column("overridePk", .integer)
                    .references("overrideStored", onDelete: .setNull)
            }
            // Run queries filter/sort on startDate; the FK lookup resolves the source override.
            try db.create(index: "overrideRunStored_on_startDate", on: "overrideRunStored", columns: ["startDate"])
            try db.create(index: "overrideRunStored_on_overridePk", on: "overrideRunStored", columns: ["overridePk"])
        }

        return migrator
    }
}
