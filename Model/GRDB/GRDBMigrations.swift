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

        // v7 — TempTargetStored + TempTargetRunStored (temp targets, presets, scheduled, and their
        // runs). Same family shape as v6: the Core Data `tempTarget` to-one relationship becomes the
        // `tempTargetPk` foreign key on `tempTargetRunStored`. `id` is a UUID stored as TEXT; the 3
        // temp-target Decimals (`duration`, `target`, `halfBasalTarget`) and the run `target` are
        // stored as TEXT (lossless), like `TDDRecord`/`OverrideRecord`.
        migrator.registerMigration("v7_tempTarget") { db in
            try db.create(table: "tempTargetStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("name", .text)
                t.column("date", .datetime)
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("isPreset", .boolean).notNull().defaults(to: false)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("orderPosition", .integer).notNull().defaults(to: 0)
                t.column("enteredBy", .text)
                t.column("duration", .text) // Decimal as string
                t.column("target", .text)
                t.column("halfBasalTarget", .text)
            }
            // Active/scheduled/main-chart queries filter on date+enabled; presets sort by isPreset.
            try db.create(index: "tempTargetStored_on_date", on: "tempTargetStored", columns: ["date"])
            try db.create(index: "tempTargetStored_on_isPreset", on: "tempTargetStored", columns: ["isPreset"])
            try db.create(index: "tempTargetStored_on_enabled", on: "tempTargetStored", columns: ["enabled"])

            try db.create(table: "tempTargetRunStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("name", .text)
                t.column("startDate", .datetime)
                t.column("endDate", .datetime)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("target", .text) // Decimal as string
                // Replaces the Core Data `tempTarget` to-one relationship. SET NULL on delete so a
                // run survives its source temp target being cleaned up (it keeps its own dates/name).
                t.column("tempTargetPk", .integer)
                    .references("tempTargetStored", onDelete: .setNull)
            }
            // Run queries filter/sort on startDate; the FK lookup resolves the source temp target.
            try db.create(index: "tempTargetRunStored_on_startDate", on: "tempTargetRunStored", columns: ["startDate"])
            try db.create(index: "tempTargetRunStored_on_tempTargetPk", on: "tempTargetRunStored", columns: ["tempTargetPk"])
        }

        // v8 — CarbEntryStored (carb entries + their FPU carb-equivalents). Standalone, no
        // relationships: `fpuID` is a grouping key (shared by one entry's equivalents), not a
        // foreign key. `carbs`/`fat`/`protein` are Double in Core Data, so they are stored as
        // `.double` columns directly — no Decimal↔TEXT dance.
        migrator.registerMigration("v8_carbEntryStored") { db in
            try db.create(table: "carbEntryStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("date", .datetime)
                t.column("carbs", .double).notNull().defaults(to: 0)
                t.column("fat", .double).notNull().defaults(to: 0)
                t.column("protein", .double).notNull().defaults(to: 0)
                t.column("note", .text)
                t.column("isFPU", .boolean).notNull().defaults(to: false)
                t.column("fpuID", .text) // grouping key for an entry's carb-equivalents (string UUID)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("isUploadedToHealth", .boolean).notNull().defaults(to: false)
                t.column("isUploadedToTidepool", .boolean).notNull().defaults(to: false)
            }
            // Every query filters/sorts on date; isFPU splits carbs vs equivalents; fpuID drives the
            // delete cascade; each upload channel filters on its own flag.
            try db.create(index: "carbEntryStored_on_date", on: "carbEntryStored", columns: ["date"])
            try db.create(index: "carbEntryStored_on_isFPU", on: "carbEntryStored", columns: ["isFPU"])
            try db.create(index: "carbEntryStored_on_fpuID", on: "carbEntryStored", columns: ["fpuID"])
            try db.create(index: "carbEntryStored_on_isUploadedToNS", on: "carbEntryStored", columns: ["isUploadedToNS"])
            try db.create(
                index: "carbEntryStored_on_isUploadedToHealth",
                on: "carbEntryStored",
                columns: ["isUploadedToHealth"]
            )
            try db.create(
                index: "carbEntryStored_on_isUploadedToTidepool",
                on: "carbEntryStored",
                columns: ["isUploadedToTidepool"]
            )
        }

        // v9 — OrefDetermination + Forecast + ForecastValue (the dosing decision + its forecast
        // curves). The first hot-path family and the deepest relationship graph: a two-level tree
        // `orefDeterminationStored —(1:n)→ forecastStored —(1:n)→ forecastValueStored`. The two
        // Core Data to-one relationships become the `orefDeterminationPk`/`forecastPk` foreign keys.
        // Both FKs are `ON DELETE CASCADE` — Core Data declared them Nullify, but the actual
        // lifecycle deletes children with the parent (the `TrioApp` batch deletes + conceptual
        // ownership), so cascade is the correct GRDB equivalent and removes the parent/child
        // batch-delete helper. The 20 determination Decimals are stored as TEXT (lossless), like
        // `TDDRecord`/`OverrideRecord`. The forecast FK is **nullable**: the bolus-preview path
        // creates orphan forecasts (no determination).
        migrator.registerMigration("v9_orefDetermination") { db in
            try db.create(table: "orefDeterminationStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("deliverAt", .datetime)
                t.column("timestamp", .datetime)
                t.column("timestampEnacted", .datetime)
                t.column("enacted", .boolean).notNull().defaults(to: false)
                t.column("received", .boolean).notNull().defaults(to: false)
                t.column("isUploadedToNS", .boolean).notNull().defaults(to: false)
                t.column("cob", .integer).notNull().defaults(to: 0)
                t.column("carbsRequired", .integer).notNull().defaults(to: 0)
                t.column("reason", .text)
                t.column("temp", .text)
                t.column("bolus", .text) // Decimal as string
                t.column("carbRatio", .text)
                t.column("currentTarget", .text)
                t.column("duration", .text)
                t.column("eventualBG", .text)
                t.column("expectedDelta", .text)
                t.column("glucose", .text)
                t.column("insulinForManualBolus", .text)
                t.column("insulinReq", .text)
                t.column("insulinSensitivity", .text)
                t.column("iob", .text)
                t.column("manualBolusErrorString", .text)
                t.column("minDelta", .text)
                t.column("rate", .text)
                t.column("reservoir", .text)
                t.column("scheduledBasal", .text)
                t.column("sensitivityRatio", .text)
                t.column("smbToDeliver", .text)
                t.column("tempBasal", .text)
                t.column("threshold", .text)
            }
            // Active/recent/chart queries filter/sort on deliverAt+timestamp; enacted and
            // isUploadedToNS drive the enacted-latest and Nightscout-upload fetches.
            try db.create(index: "orefDeterminationStored_on_deliverAt", on: "orefDeterminationStored", columns: ["deliverAt"])
            try db.create(index: "orefDeterminationStored_on_timestamp", on: "orefDeterminationStored", columns: ["timestamp"])
            try db.create(index: "orefDeterminationStored_on_enacted", on: "orefDeterminationStored", columns: ["enacted"])
            try db.create(
                index: "orefDeterminationStored_on_isUploadedToNS",
                on: "orefDeterminationStored",
                columns: ["isUploadedToNS"]
            )

            try db.create(table: "forecastStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text) // original Core Data UUID (string form)
                t.column("type", .text) // iob / zt / cob / uam
                t.column("date", .datetime)
                // Replaces the Core Data `orefDetermination` to-one relationship. Nullable: the
                // bolus-preview path creates orphan forecasts. CASCADE so forecasts die with their
                // determination.
                t.column("orefDeterminationPk", .integer)
                    .references("orefDeterminationStored", onDelete: .cascade)
            }
            try db.create(index: "forecastStored_on_date", on: "forecastStored", columns: ["date"])
            try db.create(index: "forecastStored_on_type", on: "forecastStored", columns: ["type"])
            try db.create(
                index: "forecastStored_on_orefDeterminationPk",
                on: "forecastStored",
                columns: ["orefDeterminationPk"]
            )

            try db.create(table: "forecastValueStored") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("index", .integer).notNull().defaults(to: 0)
                t.column("value", .integer).notNull().defaults(to: 0)
                // Replaces the Core Data `forecast` to-one relationship. CASCADE so values die with
                // their forecast (and transitively with their determination).
                t.column("forecastPk", .integer)
                    .references("forecastStored", onDelete: .cascade)
            }
            try db.create(
                index: "forecastValueStored_on_forecastPk",
                on: "forecastValueStored",
                columns: ["forecastPk"]
            )
            try db.create(index: "forecastValueStored_on_index", on: "forecastValueStored", columns: ["index"])
        }

        return migrator
    }
}
