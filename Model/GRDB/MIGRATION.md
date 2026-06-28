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

### ⏳ Next steps (proposed order, lowest risk first)

1. `StatsData`, `TDDStored` — reporting/aggregate data, no dosing impact.
2. `OpenAPS_Battery`, `ContactImageEntryStored`, `MealPresetStored` — standalone, no relationships.
3. `OverrideStored`/`OverrideRunStored`, `TempTargetStored`/`TempTargetRunStored` — has relationships + presets.
4. `CarbEntryStored`, `DeletedGlucoseStored`.
5. `OrefDetermination` + `Forecast` + `ForecastValue` — relationship graph, hot path.
6. `PumpEventStored` + `BolusStored` + `TempBasalStored` — dosing path, highest risk, last.
7. `GlucoseStored` — highest read volume; needs `ValueObservation` for the live charts.

## Open items (must solve before the hot-path entities)

- **Reactivity.** Today the UI observes Core Data via persistent-history →
  `entityChangePublisher`. GRDB's equivalent is `ValueObservation` (with a Combine
  publisher). `LoopStat` is read on demand, so Step 1 didn't need it; glucose/determination
  charts will. Build a reusable `ValueObservation` → Combine bridge before Step 5–7.
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
