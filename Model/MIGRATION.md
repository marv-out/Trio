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

### ⏳ Next steps (proposed order, lowest risk first)

1. `OpenAPS_Battery` (FRC → ValueObservation; upsert; full-wipe + 90-day cleanup deletes) and
   `MealPresetStored` (SwiftUI `@FetchRequest` → observation) — both have live UI.
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
