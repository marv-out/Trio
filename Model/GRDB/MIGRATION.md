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

### ✅ Step 7 — `OverrideStored` + `OverrideRunStored` (done, this branch)

The first relationship-bearing family and by far the largest surface (~20 files). Touched:

**Records (`Model/OverrideRecord.swift`)**
- `OverrideRecord` — 22 attrs; the 6 Decimals (`duration`, `end`, `smbMinutes`, `start`,
  `target`, `uamMinutes`) stored as TEXT with a manual `FetchableRecord`/`PersistableRecord`
  (like `TDDRecord`). `id` is a String, `pk` = rowid. `Hashable`/`Identifiable`.
- `OverrideRunRecord` — 7 attrs + `overridePk: Int64?` foreign key replacing the `override`
  to-one relationship (`ON DELETE SET NULL`). The Nightscout `overrideRun.override?.date`
  traversal became `OverrideRunStore.sourceOverrideDate(for:)` (FK lookup).
- `OverrideStore` / `OverrideRunStore`: fetchPresets, fetchActiveConfigurations
  (`lastActiveOverride`), fetchLatestActive, fetchLastCreated, fetch(pk:/id:), store (computes
  `orderPosition = count+1` for presets), copyRunning, update, disable(pks:), delete,
  deleteOlderThan (presets preserved), reorder, markUploaded, fetchNotYetUploaded, saveRun,
  and `observeActive`/`observeRecent`/`observeLatest`/`observeNotYetUploadedCount`.

**Schema v6 + `OverrideMigration`** — `overrideStored` + `overrideRunStored` tables with indexes;
the one-time copy resolves the `override` relationship via legacy `NSManagedObjectID` → new `pk`
(the override `id` is not unique — `copyRunningOverride` duplicates it).

**Identity (replaces NSManagedObjectID passing)** — `OverrideStorage` now deals in
`OverrideRecord`/`OverrideRunRecord` value types; call sites carry `pk` (Int64) or the business
`id`. The "disable active + log a run" composite (previously duplicated in the intents,
RemoteControl, Watch and the state models) is centralized in `BaseOverrideStorage`. `calculateTarget`
and `copyRunningOverride` are now pure value-type functions (no `@MainActor`/viewContext).
Rewrote: `OverridePresetsIntentRequest`, `TrioRemoteControl+Override`, `AppleWatchManager`,
`AdjustmentsStateModel(+Overrides)`, `EditOverrideForm`, `AdjustmentsRootView(+Overrides)`,
`OverrideView`, `SettingsExportStateModel`, `OpenAPS.prepareTrioCustomOrefVariables`.

**Reactivity**: Home `overrideController`/`overrideRunController` FRCs → `OverrideStore.observeActive`
/ `OverrideRunStore.observeRecent` (see `OverrideSetup`); the `HomeRootView` `@FetchRequest`
(`latestOverride`) → `state.overrides.first`; the `HistoryRootView` `@FetchRequest` → a
`History.StateModel` observation; the LiveActivity + Watch Core Data save-notification sinks →
`OverrideStore.observeLatest`; the 2 Nightscout upload FRCs → `observeNotYetUploadedCount`.

**Cleanup parity**: `batchDeleteOlderThan(OverrideStored, days:3, isPresetKey:"isPreset")` and
`(OverrideRunStored, "startDate", 3)` → `OverrideStore.deleteOlderThan` (presets preserved) and
`OverrideRunStore.deleteOlderThan` in `TrioApp`.

**Tests**: `OverrideStorageTests` rewritten against an in-memory GRDB pool (store/fetch/delete +
not-yet-uploaded mapping); `TestAssembly` no longer injects a Core Data context for overrides.

The Core Data `OverrideStored`/`OverrideRunStored` entities stay as the read-only migration source
(the `OverrideStored.EventType` enum is still referenced by the Nightscout mapping).

### ✅ Step 8 — `TempTargetStored` + `TempTargetRunStored` (done, this branch)

Same family shape as Override (relationship + presets + runs), so this **mirrors Step 7** — the
`OverrideRecord.swift` / `OverrideStorage.swift` / Override call-site diff was the template; the
transformation is largely the same. Records/stores (`TempTargetRecord` + `TempTargetRunRecord`,
`TempTargetStore`/`TempTargetRunStore`), schema **v7** + `TempTargetMigration` (registered in
`GRDBStack.bootstrap()` after `OverrideMigration`, gated by `grdb.didMigrateTempTarget`), and ~19
call-site files moved to GRDB value types (intents, RemoteControl, Watch, LiveActivity, Nightscout,
OpenAPS, Home/History/Adjustments state + views, SettingsExport, TrioApp cleanup, tests). The
deltas below are what makes Temp Targets *different* from Override.

**Notable deviations from the original Core Data behavior (intentional, mirroring Step 7):**
- The Nightscout `NightscoutTreatment` for temp targets / runs now carries the source `id`
  (string UUID) so `markUploaded(ids:)` can match — the old Core Data path matched on a `nil` `id`
  and effectively never marked rows uploaded. `disableAllActiveTempTargets` no longer resets
  `isUploadedToNS` on cancel (the run entry covers the Nightscout cancel), matching Override.
- `TrioApp` gained `TempTargetStore.deleteOlderThan(days: 3)` + the run equivalent (presets
  preserved). The pre-GRDB code never pruned temp targets; this adds parity with Override.
- `updateLatestTempTargetConfigurationOfState` keeps the original (pre-existing) `if !isOverrideEnabled`
  guard verbatim rather than "fixing" it to `isTempTargetEnabled` — out of migration scope.
- Same two follow-up fixes as the Override commit: the Adjustments preset list is a live
  `observePresets()` feed (edits reflect immediately), and the delete-preset confirmation dialog was
  moved out of the preset `ForEach` onto the stable body (its own `isConfirmDeleteTempTargetPresented`
  flag) so a list re-render can't dismiss it mid-confirmation.

**Records (`Model/GRDB/TempTargetRecord.swift`)**
- `TempTargetRecord` — attrs: `id` (**UUID**, stored as TEXT like `OverrideRunRecord.id` — *not* a
  String like Override), `name`, `date`, `enabled`, `isPreset`, `isUploadedToNS`, `orderPosition`,
  `enteredBy` (String), and **3 Decimals** as TEXT: `duration`, `target`, `halfBasalTarget`. No
  percentage/smb/isf/cr fields. Manual `FetchableRecord`/`MutablePersistableRecord` (use
  `MutablePersistableRecord` so `didInsert` sets `pk` — see the Override note below).
- `TempTargetRunRecord` — `id` (UUID), `name`, `startDate`, `endDate`, `isUploadedToNS`,
  `target` (Decimal), `tempTargetPk: Int64?` foreign key (replaces the `tempTarget` to-one).
- ⚠️ **`MutablePersistableRecord`, not `PersistableRecord`.** Step 7 found that `PersistableRecord`'s
  `didInsert` is non-mutating, so `pk` is never set after insert; the store returns records whose
  `pk` is read by callers, so the record must be `MutablePersistableRecord`. (TDD/MealPreset got away
  with `PersistableRecord` only because they never read `pk` back.)

**Schema v7 + `TempTargetMigration`** — `tempTargetStored` + `tempTargetRunStored` tables; indexes on
`date`, `isPreset`, `enabled`, run `startDate`, and `tempTargetPk` (FK `ON DELETE SET NULL`). The
one-time copy resolves the `tempTarget` relationship via legacy `NSManagedObjectID` → new `pk` (the
`id` is **not** unique — `copyRunningTempTarget` duplicates it, same as Override). Register in
`GRDBStack.bootstrap()` after `OverrideMigration`, gated by `grdb.didMigrateTempTarget`.

**Predicates differ from Override:**
- `lastActiveTempTarget` = `date >= oneDayAgo AND enabled == true` — **no `indefinite`** (Temp
  Targets have none).
- `tempTargetsForMainChart` = active **OR** *future-scheduled* (`date >= now AND enabled == false`).
  The Home chart FRC uses this broader predicate, so `TempTargetStore.observeForMainChart()` must
  track both active and future-scheduled rows (subscriber applies the date rules; keep the tracked
  region deterministic — no `Date()` inside it).

**Scheduled Temp Targets (no Override analog).** `fetchScheduledTempTargets()` (`date > now`),
`fetchScheduledTempTarget(for:)` (`date == targetDate`), and `existsTempTarget(with:)` (`date ==`,
used by `FetchTreatmentsManager` to dedupe NS imports). `Adjustments.StateModel` keeps a separate
`scheduledTempTargets` array + `setupScheduledTempTargetsArray` (→ `observeScheduled()`), and the
`saveScheduledTempTarget` → `enableScheduledTempTarget(for date:)` flow re-fetches by exact date.

**FileStorage coexistence (leave untouched).** `BaseTempTargetsStorage` *also* persists to a JSON
`FileStorage` (`recent()`, `current()`, `presets()`, `saveTempTargetsToStorage`) — these are **not**
Core Data and stay as-is. Mutating call sites call `saveTempTargetsToStorage(...)` *in addition* to
the Core Data write; keep those calls. Only the `TempTargetStored`/`TempTargetRunStored` Core Data
paths move to GRDB.

**Half-basal-target quirks (preserve exactly).** `storeTempTarget` nulls `halfBasalTarget` then sets
it only if it differs from `settingsManager.preferences.halfBasalExerciseTarget`.
`copyRunningTempTarget` keeps `halfBasalTarget` only if `!= 160` (the HBT default; `TempTarget.cancel`
also uses `160`). Carry these into the store/storage layer verbatim.

**Store API** (`TempTargetStore` / `TempTargetRunStore`): fetchPresets (orderPosition),
fetchActiveConfigurations(limit:) (`lastActiveTempTarget`), fetchForMainChart, fetchScheduled,
fetchScheduled(for:), exists(date:), store (computed `orderPosition` for presets), copyRunning,
update, disable(pks:), delete, deleteOlderThan (presets preserved), reorder, markUploaded(ids:[UUID]),
fetchNotYetUploaded, saveRun, and observations: `observeForMainChart`, `observePresets`,
`observeScheduled`, `observeLatest`, `observeNotYetUploadedCount`. For the Nightscout run upload, the
run needs the source temp target's `enteredBy`/`name`/`date` — add a FK lookup helper returning the
source `TempTargetRecord` (Override only needed `date`).

**Identity / centralization (as in Step 7).** `TempTargetsStorage` deals in records; drop
`[NSManagedObjectID]`. Centralize `disableAllActiveTempTargets(except:createRunEntry:)`,
`enactTempTarget(pk:)`, `cancelTempTarget(pk:)`, `saveTempTargetRun(for:)` in the storage.
`copyRunningTempTarget` becomes a pure value-type function. The generic `fetchTempTargetObjects` /
`fetchFunction` objectID-unpacking helper in `AdjustmentsStateModel+TempTargets` goes away (fetches
return records). `PendingPresetActivation.tempTarget(objectID:)` → `.tempTarget(pk: Int64, …)`.

**Reactivity / call sites** (mirror Step 7 — ~19 files):
- `HomeStateModel` `tempTargetController`/`tempTargetRunController` FRCs → `observeForMainChart` /
  `TempTargetRunStore.observeRecent` (see a new `TempTargetSetup`). `tempTargetStored` →
  `[TempTargetRecord]`, `tempTargetRunStored` → `[TempTargetRunRecord]`.
- `HomeRootView` `latestTempTarget` `@FetchRequest` (uses the **narrower** `lastActiveTempTarget`) →
  ⚠️ do **not** just use `state.tempTargetStored.first` (that list includes future-scheduled rows).
  Derive the active one (`enabled && date <= now`) or expose a dedicated active value. Update
  `cancelTempTarget(withID:)` → `withPk:` and the `.objectID` cancel sites + `tempTargetString`
  (Decimals are now `Decimal?`, drop `.decimalValue`).
- `TempTargets.swift` chart: `[TempTargetRecord]`/`[TempTargetRunRecord]`, drop `viewContext` +
  the `MainChartHelper.calculateDuration/Target(objectID:…)` calls (read `duration`/`target` off the
  record; `duration` minutes → seconds `*60`).
- `History`: `tempTargetRunStored` `@FetchRequest` → `History.StateModel` observation;
  `HistoryRootView+Adjustments` temp-target `AdjustmentItem.id` `objectID` → `tempTarget.id` (UUID).
- `Adjustments`: `tempTargetPresets`/`scheduledTempTargets`/`currentActiveTempTarget` → records;
  `reorderTempTargets` → `TempTargetStore.reorder`; `EditTempTargetForm` (`@ObservedObject
  tempTarget: TempTargetStored` → value `TempTargetRecord`, save via `TempTargetStore.update`).
- `Nightscout`: 2 upload FRCs → `observeNotYetUploadedCount`; `updateTempTargets/RunsAsUploaded` →
  `markUploaded(ids:)`. Mapping stays `NightscoutTreatment(.nsTempTarget)` (targetTop/Bottom = target).
- `TempPresetsIntentRequest`, `TrioRemoteControl+TempTarget`, `AppleWatchManager` (TT presets +
  observer + activate/cancel handlers), `OpenAPS.fetchActiveTempTargets` (pre-fetch before the CD
  perform block), `LiveActivity` `DataManager.fetchAndMapTempTarget` + the `LiveActivityManager`
  TempTargetStored observer (→ `observeLatest`), `SettingsExportStateModel` preset export.

**Cleanup parity / tests.** `TrioApp` `batchDeleteOlderThan(TempTargetStored, isPresetKey:)` /
`(TempTargetRunStored, "startDate")` → store `deleteOlderThan`. Rewrite any `TempTargetStorageTests`
against an in-memory pool; `TestAssembly` drops the Core Data `contextProvider` for the TT storage
(but keeps the `FileStorage`/`Broadcaster`/`SettingsManager` injections).

### 🔧 Step 9 — `CarbEntryStored` (+ `DeletedGlucoseStored`) (planned, not yet implemented)

**No relationships** — both entities are standalone (verified against the `.xcdatamodel`: zero
to-one/to-many). So this is *simpler than Override/TempTarget* structurally (no foreign key, no
preset/run split), but the **surface is larger** (~3 upload channels, FPU equivalents, History
editing, JSON import, Stats, meal calc). Still mirror Steps 7–8 for the record/store/observation
patterns; the deltas below are what makes Carbs different. Full call-site map (line-level) lives in
the PR notes (~30 non-test files).

⚠️ **Recommend splitting the work**: do **CarbEntryStored first (9a)**, ship/verify, then
**DeletedGlucoseStored (9b)** — they share nothing. `DeletedGlucoseStored` is tiny but lives entirely
inside the glucose-deletion path (`GlucoseStorage`), so it could also reasonably be folded into the
later `GlucoseStored` step instead. Pick one; don't block carbs on it.

#### 9a — `CarbEntryStored`

**Record (`Model/GRDB/CarbEntryRecord.swift`)**
- Attrs (all map 1:1): `id` (UUID), `date`, `carbs`/`fat`/`protein` (**`Double`, NOT Decimal** — Core
  Data uses `Double` here, so store as `.double` columns directly; **no TEXT/Decimal dance** like the
  previous steps), `note` (String), `isFPU` (Bool), `fpuID` (UUID? — a *grouping key*, not a
  relationship), and **three** upload flags `isUploadedToNS` / `isUploadedToHealth` /
  `isUploadedToTidepool`. `pk` = rowid. Use `MutablePersistableRecord` (set `pk` in `didInsert`,
  per the Step 7 note). Since there are no Decimals, a plain `Codable` GRDB record works (like
  `ContactImageRecord`) — no manual `Row`/`encode`.
- Port `CarbEntryStored: Encodable` (custom `actualDate`/`created_at`/`enteredBy` keys, see
  `CarbEntryStored+helper.swift`) onto the record (or onto a mapper) — check who consumes it before
  dropping it (the meal/oref JSON).

**Schema v8 + `CarbEntryMigration`** — one `carbEntryStored` table; indexes on `date`, `isFPU`,
`fpuID` (the delete-cascade filters on it), and the three `isUploadedTo*` flags (each upload channel
queries one). Register in `GRDBStack.bootstrap()` after `TempTargetMigration`, gated by
`grdb.didMigrateCarbEntry`. One-time straight copy (no relationship to resolve).

**Store API** (`CarbEntryStore`): `store(_:)` (single carb), `batchInsertFPUs(_:)` (the FPU
equivalents — replaces `NSBatchInsertRequest` with a loop of inserts in one `write` transaction),
`fetchCarbsForChart` / `fetchFPUsForChart` (`isFPU` + `date >= oneDayAgo` [+ `carbs > 0` for carbs]),
`fetchForStats` (`carbsForStats`, 3 months), `fetchNotYetUploaded(channel:)` for the 3 channels,
`fetchForMealCalc` (OpenAPS), `delete(pk:)`, `deleteByFpuID(_:)`, `markUploaded(channel:ids:)`,
`deleteOlderThan(days:)`, and observations `observeCarbsForChart` / `observeFPUsForChart` /
`observeNotYetUploadedCount(channel:)`.

**FPU specifics (no Override analog) — preserve exactly.** `storeCarbs` splits a fat/protein entry
into delayed carb-equivalent rows (`processFPU` / `splitIntoCarbEquivalents` — pure functions, leave
them in the storage layer untouched), all sharing one `fpuID`, marked `isFPU = true`, with
Health/Tidepool flags deliberately left unset. Keep that grouping. The `updateSubject.send(())` fired
after the FPU batch insert drives the Home FPU array — either keep `updatePublisher` as the
"something changed" signal **and** add `observeFPUsForChart`, or replace it with the observation
(prefer keeping `updatePublisher`: `AppleWatchManager` + others subscribe to it).

**Delete cascade — preserve.** `deleteCarbsEntryStored(objectID)` → `delete(pk:)`. The existing logic:
if the entry has a `fpuID`, batch-delete **all** rows sharing it (`deleteByFpuID`); otherwise delete
the single carb-only row. Carry both branches over.

**Upload flags — three channels, mind the matching key (TempTarget nil-id class of bug).**
- The Nightscout **carb** treatment carries `id = carbEntry.id` → `markUploaded(.nightscout, ids:)`
  matches on `id`. The Nightscout **FPU** treatment carries `id = carbEntry.fpuID` → its
  `markUploaded` must match on **`fpuID`**, not `id`. Verify the current `updateCarbsAsUploaded`
  (`NightscoutManager`) handles both (it matches `id IN …`); split into id-match (carbs) and
  fpuID-match (FPUs) so FPUs actually get marked.
- HealthKit (`HealthKitManager` ~L372–390) and Tidepool (`TidepoolManager` ~L281–287) currently
  re-find rows **by date** to set their flag. Prefer matching by `id`/`pk` in the GRDB version (more
  robust), but check the existing behavior first.
- 3 upload FRCs (`NightscoutManager.carbEntryUploadController` `isUploadedToNS==false`,
  `HealthKitManager` `isUploadedToHealth==false`, `TidepoolManager` `isUploadedToTidepool==false`) →
  `observeNotYetUploadedCount(channel:)`.

**Reactivity / call sites (~mirror Step 8):**
- `HomeStateModel` `carbsController` / `fpuController` FRCs → `observeCarbsForChart` /
  `observeFPUsForChart` (new `CarbSetup`); `carbsFromPersistence` / `fpusFromPersistence` →
  `[CarbEntryRecord]`. `CarbView` (`carbData`/`fpuData`) → records.
- `History`: `HistoryRootView` `@FetchRequest` (carbs) → a `History.StateModel` observation;
  `CarbEntryEditorView(carbEntry: CarbEntryStored)` → value `CarbEntryRecord` + save via store update;
  `HistoryDeletionTarget.carbs(CarbEntryStored)` → `.carbs(CarbEntryRecord)`; the several
  `existingObject(with:) as? CarbEntryStored` casts in `HistoryStateModel+CarbEditing` /
  `+Carbs` → record fetches by `pk`. Edit-then-update must use `CarbEntryStore.update`.
- `OpenAPS.fetchAndProcessCarbs` (meal calc): pre-fetch via GRDB **before** the CD `perform` block,
  like `fetchActiveTempTargets` in Step 8.
- `Stat` `MealStatsSetup` (carbsForStats) → `CarbEntryStore.fetchForStats`.
- `TrioRemoteControl+Meal`, `AppleWatchManager` (`handleCarbsRequest` / `handleCombinedRequest`
  create `CarbEntryStored`) → go through `storeCarbs` (value types); the `+Meal` recent-carb read →
  store fetch.
- `CarbPresetIntentRequest` already calls `storeCarbs` (no change beyond signature).
- `JSONImporter` (`+Model/JSONImporter.swift`, creates `CarbEntryStored` on import; `CarbsStored` →
  `CarbEntryStored` legacy conversion) → `CarbEntryRecord` inserts. Update `JSONImporterTests`.

**Cleanup parity / tests.** `TrioApp` `batchDeleteOlderThan(CarbEntryStored, days: 90)` →
`CarbEntryStore.deleteOlderThan(days: 90)`. Rewrite `CarbsStorageTests` against an in-memory pool
(the FPU split + delete-cascade + the 3 not-yet-uploaded fetches are the important cases);
`TestAssembly` drops the Core Data `contextProvider` for `CarbsStorage` (keeps `FileStorage` /
`Broadcaster` / `SettingsManager`).

#### 9b — `DeletedGlucoseStored` (optional companion)

Tiny standalone entity (3 attrs: `date`, `glucose` `Int16`, `isManualGlucoseEntry` `Bool`) recording
deleted manual readings so Nightscout can delete them remotely. Written only in `GlucoseStorage`
(manual-glucose delete path, ~L779) and read by the NS deletion upload (FRC ~`GlucoseStorage:88`).
Schema **v9** + `DeletedGlucoseMigration` (gated `grdb.didMigrateDeletedGlucose`); `DeletedGlucoseStore`
with `store`, `fetchNotYetUploaded`/observe, `delete`, `deleteOlderThan(90)`. Touches `GlucoseStorage`
(but **not** `GlucoseStored`, which stays in Core Data) + `TrioApp` cleanup + `GlucoseStorageTests`.
If this entanglement with the glucose path feels risky, defer it to the `GlucoseStored` step.

### ⏳ After Carbs

1. `OrefDetermination` + `Forecast` + `ForecastValue` — relationship graph, hot path.
2. `PumpEventStored` + `BolusStored` + `TempBasalStored` — dosing path, highest risk, last.
3. `GlucoseStored` (+ `DeletedGlucoseStored`, if deferred) — highest read volume; uses
   `ValueObservation` for the live charts.

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
