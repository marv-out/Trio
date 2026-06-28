# Core Data → GRDB Migration

Staged migration of Trio's persistence layer from Core Data to [GRDB](https://github.com/groue/GRDB.swift).
This document is the source of truth for the migration; update it as each entity moves.

## Why

The recurring Core Data pain points in Trio are concurrency (per-context confinement,
`NSManagedObjectID` passing, cross-context races) and implicit behavior (faulting,
merge policies, inferred migrations). GRDB replaces objects-with-identity by
`Sendable` value types and an explicit, serialized database access model
(`DatabasePool`: concurrent reads, serialized writes), with explicit versioned
schema migrations. See the decision write-up in the PR discussion.

## Strategy: coexistence, one entity at a time

Core Data and GRDB run **side by side**. Each entity lives in *exactly one* store —
never both. We move entities one at a time, lowest-risk first, and never touch the
glucose/pump dosing path until the pattern is proven.

For every entity:

1. Add a GRDB `record` (struct) mirroring the Core Data attributes.
2. Add a schema migration (`registerMigration`) creating its table + indexes.
3. Add a typed store enum with the queries that entity actually needs.
4. Rewrite all read/write call sites onto the store. Drop `NSManagedObjectID`
   passing — value types cross threads freely.
5. Add a one-time, idempotent data migration (Core Data → GRDB), gated by a
   `UserDefaults` flag, leaving the Core Data rows in place as a rollback source.
6. Remove the Core Data entity from the model **only after** the migration is proven
   in the field (a later, separate step).

## Architecture

| File | Role |
|------|------|
| `GRDBStack.swift` | Singleton owning the `DatabasePool`. DB file lives in the App Group container (shared with extensions, like the Core Data store). `bootstrap()` opens it, runs schema migrations, then one-time data migrations. |
| `GRDBMigrations.swift` | `DatabaseMigrator` — versioned, append-only schema migrations. |
| `LoopStat.swift` | First record + its `LoopStatStore` (typed async query API). |
| `LoopStatMigration.swift` | One-time Core Data → GRDB copy for loop stats. |

`GRDBStack.shared.bootstrap()` is called in `TrioApp.deferredInitialization()` right
after `coreDataStack.initializeStack()`.

## Status

### ✅ Step 1 — `LoopStatRecord` (done, this branch)

First entity migrated. Chosen because it is isolated and outside the dosing-decision
path (loop statistics only). Touched:

- **Write:** `APSManager.loopStats(loopStatRecord:)` → `LoopStatStore.save`
- **Read (interval):** `APSManager.calculateLoopInterval` → `LoopStatStore.lastEnd`
- **Read (24h cycle stats):** `APSManager.loopStats(oneDayGlucose:)` → `LoopStatStore.forCycleStats`; `loops(_:)` now takes `[LoopStat]`
- **Read (Stat screen):** `LoopChartSetup.fetchLoopStatRecords` / `getLoopStats` → `LoopStatStore.all`; `NSManagedObjectID` round-trips removed
- **State/UI:** `StatStateModel.loopStatRecords` and `LoopBarChartView` now hold `[LoopStat]`
- **Data migration:** `LoopStatMigration` copies existing rows once

The Core Data `LoopStatRecord` entity is still in the model (read-only, migration source).

### ✅ Step 2 — `StatsData` (removed, not migrated)

Investigation found `StatsData` to be a dead legacy entity: no write site anywhere
(it was part of the old "Stats Upload", scrubbed long ago) and its only reader,
`APSManager.lastLoopForStats()`, had no callers. Rather than port dead code to GRDB,
it was deleted:

- Removed `APSManager.lastLoopForStats()` (dead).
- Removed the `StatsData` entity from the Core Data model (19 → 18 entities).
- The generated `StatsData+CoreDataClass/Properties.swift` are removed from the Trio
  target in Xcode.

Lightweight migration drops the now-empty `ZSTATSDATA` table on existing installs.

### ✅ Step 3 — `TDDStored` (done, this branch)

Total Daily Dose aggregates. Larger than the previous steps: 7 call sites, plus the first
reactive consumer (the Home header shows the current TDD live). Touched:

- **Record/store:** `TDDRecord` + `TDDStore` (save, `aggregate`, `countWithPositiveTotal`,
  `entries`, `mostRecent`, `observeMostRecent`). Decimals stored as TEXT (lossless); the
  weighted-average / sufficiency aggregates are computed in Swift after a windowed fetch
  rather than via SQL `SUM` — the windows are tiny, and this avoids lossy REAL storage.
- **Write:** `TDDStorage.storeTDD` → `TDDStore.save`.
- **Aggregates:** `TDDStorage.calculateWeightedAverage` and `hasSufficientTDD` → `TDDStore`
  (removed `aggregateTDD` NSExpression code and the static Core Data count variant).
- **Reads:** `OpenAPS.prepareTrioCustomOrefVariables` (pre-fetched before the CD perform
  block), Stat `TDDSetup`, LiveActivity `DataManager`, `NightscoutManager`.
- **Reactivity (first ValueObservation):** Home's TDD `NSFetchedResultsController` →
  `TDDStore.observeMostRecent()` (Combine). See `CurrentTDDSetup`.
- **Dead code:** removed the unused duplicate `hasSufficientTDD()` in `DynamicSettingsStateModel`.
- **Data migration:** `TDDMigration` copies existing rows once.
- **Tests:** `DynamicISFEnableTests` rewritten against an in-memory GRDB pool via
  `BaseTDDStorage.hasSufficientTDD(in:)`.

The Core Data `TDDStored` entity stays in the model (read-only, migration source).

### ✅ Step 4 — `ContactImageEntryStored` (done, this branch)

Standalone contact-image config; no live UI (no FRC/@FetchRequest). 16 attributes, all
String/Int16/Bool/UUID — so `ContactImageRecord` is a plain `Codable` GRDB record. Touched:

- `ContactImageRecord` + `ContactImageStore` (fetchAll, insert, updateByContactId, delete).
- `ContactImageStorage`: all four CRUD methods → `ContactImageStore`; mapping to/from the
  `ContactImageEntry` domain model unchanged.
- Domain model `ContactImageEntry.managedObjectID: NSManagedObjectID?` → `storedID: Int64?`
  (GRDB row id); delete call sites in `ContactImageStateModel` updated.
- v3 schema migration; one-time `ContactImageMigration` data copy.

The Core Data `ContactImageEntryStored` entity (codeGenerationType="class") stays as the
read-only migration source.

### ✅ Step 5 — `OpenAPS_Battery` (done, this branch)

Pump battery status. Broadest non-hot-path entity so far. Touched:

- `BatteryRecord` + `BatteryStore` (insert, update, mostRecent, deleteAll, deleteOlderThan,
  observeMostRecent). `voltage` (Core Data Decimal, always nil) stored as `Double?`.
- **Upsert:** `APSManager.pumpManager(_:didUpdate:)` — fetch ≤30-min entry, update or insert.
- **Write:** `DeviceDataManager` simulator battery → `BatteryStore.insert`.
- **Read:** `NightscoutManager.fetchBattery` → `BatteryStore.mostRecent`.
- **Deletes:** full-wipe on pump disconnect (`DeviceDataManager` → `deleteAll`); 90-day
  cleanup (`TrioApp` → `deleteOlderThan`).
- **Reactivity:** Home `batteryController` FRC → `BatteryStore.observeMostRecent()`; `PumpView`
  and `batteryFromPersistence` now hold `[BatteryRecord]`.
- v4 schema migration; one-time `BatteryMigration` data copy.
- The unused `OpenAPSBattery.swift` fetch helper is now dead; left for the final CD cleanup.

The Core Data `OpenAPS_Battery` entity stays as the read-only migration source.

### ✅ Step 6 — `MealPresetStored` (done, this branch)

Saved meal templates. Most invasive UI so far — replaced a SwiftUI `@FetchRequest` and a
`MealPresetStored` Picker selection. Touched:

- `MealPresetRecord` (Decimals as TEXT, `Hashable` to back the Picker) + `MealPresetStore`
  (fetchAll, insert, delete, observeAll); v5 schema; one-time `MealPresetMigration`.
- `Treatments.StateModel`: `selection` → `MealPresetRecord?`; new `carbPresets: [MealPresetRecord]`
  fed by `MealPresetStore.observeAll()` (replaces `@FetchRequest`); `deletePreset` → `MealPresetStore.delete`.
- `MealPresetView`: dropped `@FetchRequest`/`moc`; Picker now binds `state.carbPresets`;
  `savePreset` → `MealPresetStore.insert`. The `as NSDecimalNumber as Decimal` reads still
  compile via Decimal↔NSDecimalNumber bridging, so they were left untouched.
- `SettingsExportStateModel`: meal-preset export → `MealPresetStore.fetchAll`.

The Core Data `MealPresetStored` entity stays as the read-only migration source.

### 🔧 Step 7 — `OverrideStored` + `OverrideRunStored` (planned, not yet implemented)

The first relationship-bearing family and by far the largest surface (~18–20 files). Scoped
for its own focused pass. Full call-site map lives in the PR notes; the design decisions:

**Records**
- `OverrideRecord` — 22 attrs; the 6 Decimals (`duration`, `end`, `smbMinutes`, `start`,
  `target`, `uamMinutes`) stored as TEXT with a manual `FetchableRecord`/`PersistableRecord`
  (like `TDDRecord`). `id` is a String. `pk` = rowid.
- `OverrideRunRecord` — 7 attrs + `overridePk: Int64?` foreign key replacing the
  `override` to-one relationship. The Nightscout `overrideRun.override?.date` traversal
  becomes a join/lookup by `overridePk`.

**Identity (replaces NSManagedObjectID passing)** — the hard part. Intents, RemoteControl
and Watch return `[NSManagedObjectID]` and re-fetch with `existingObject(with:)` across
process boundaries. Replace with the stable business `id` (Override: String, Run: UUID) or
the rowid `pk`; rewrite each call site to carry that instead of an objectID. Affected:
`OverridePresetsIntentRequest`, `TrioRemoteControl+Override`, `AppleWatchManager`,
`AdjustmentsStateModel+Overrides`, `OverrideView`.

**Store API needed**: fetchPresets (sorted by `orderPosition`), fetchActive
(`lastActiveOverride` predicate), fetchLatestActive, lastCreated, store (with computed
`orderPosition = count+1` for presets), copyRunning, delete(by id), reorder (batch
`orderPosition`), enable/disable (update), saveRun (insert run + set `overridePk`),
not-yet-uploaded fetches (Override + Run, with join), preset export, `observeActive` +
`observeRuns` (ValueObservation → replaces the 2 FRCs and the 2 `@FetchRequest`s).

**Reactivity**: Home `overrideController`/`overrideRunController` FRCs and the
`HomeRootView`/`HistoryRootView` `@FetchRequest`s → `ValueObservation` feeding `@Observable`
arrays (pattern from TDD/Battery/MealPreset).

**Cleanup parity**: `batchDeleteOlderThan(OverrideStored, days:3, isPresetKey:"isPreset")`
and `(OverrideRunStored, "startDate", 3)` → GRDB deletes preserving presets.

**MainActor**: `calculateTarget` and `copyRunningOverride` (currently viewContext/@MainActor)
become pure value-type functions.

### ⏳ After Override

1. `TempTargetStored`/`TempTargetRunStored` — same shape as Override (relationship + presets + runs).
2. `CarbEntryStored`, `DeletedGlucoseStored`.
3. `OrefDetermination` + `Forecast` + `ForecastValue` — relationship graph, hot path.
4. `PumpEventStored` + `BolusStored` + `TempBasalStored` — dosing path, highest risk, last.
5. `GlucoseStored` — highest read volume; uses `ValueObservation` for the live charts.

## Cleanup (after all entities migrated & proven)

- Remove the migrated entities from the Core Data model and delete their generated classes
  and the now-dead `OpenAPSBattery.swift` fetch helper.
- Remove `eraseDatabaseOnSchemaChange` (DEBUG-only) before shipping real data.
2. `OverrideStored`/`OverrideRunStored`, `TempTargetStored`/`TempTargetRunStored` — has relationships + presets.
3. `CarbEntryStored`, `DeletedGlucoseStored`.
4. `OrefDetermination` + `Forecast` + `ForecastValue` — relationship graph, hot path.
5. `PumpEventStored` + `BolusStored` + `TempBasalStored` — dosing path, highest risk, last.
6. `GlucoseStored` — highest read volume; uses `ValueObservation` for the live charts.

## Open items (must solve before the hot-path entities)

- **Reactivity.** ✅ Introduced in Step 3: GRDB's `ValueObservation.publisher(in:)` replaces
  the Core Data `NSFetchedResultsController` for live UI (TDD header). The pattern
  (`TDDStore.observeMostRecent()` → Combine → `@MainActor` sink) is the template for the
  glucose/determination charts in later steps.
- **Cross-process.** Widgets / Live Activities read the store. `DatabasePool` over an
  App-Group file with WAL supports this, but observation across processes needs explicit
  handling (`DatabaseRegionObservation` + Darwin notifications). Verify before moving any
  entity an extension reads.
- **Bestandsdaten / rollback.** Each data migration must be proven on real installs of
  varying age before the Core Data entity is removed.

## Manual steps (not done in this branch — need Xcode)

1. **Add the dependency:** Xcode → File → Add Package Dependencies → `https://github.com/groue/GRDB.swift`, "Up to Next Major" `7.0.0`, target **Trio**.
2. **Add the new files to the Trio target:** the `Model/GRDB/*.swift` files must be added to the Trio target in the project (this branch creates the files but cannot edit `project.pbxproj` reliably).
3. **Run swiftformat** (`scripts/swiftformat.sh`) — some rewritten blocks need reindenting.
4. **Build + test**, ideally with a debug `LoopStat` round-trip and a check that existing loop stats appear after first launch.

## Conventions

- Schema migrations are **append-only**. Never edit a shipped migration; add a new one.
- `eraseDatabaseOnSchemaChange` is enabled only under `#if DEBUG` and must be removed before any release that ships real user data.
- Records mirror Core Data attribute names and optionality so call sites and math stay unchanged.
