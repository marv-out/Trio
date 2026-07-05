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

### 🔧 Step 9 — `CarbEntryStored` (✅ 9a done, this branch) (+ `DeletedGlucoseStored` 9b, planned)

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

#### 9a — `CarbEntryStored` (✅ done, this branch)

Done as planned below, with these notable implementation decisions:
- **Record persistence is manual, not plain `Codable`.** The plan suggested a plain `Codable` record
  (like `ContactImageRecord`), but `CarbEntryStored`'s `Encodable` conformance (the oref/meal JSON with
  `actualDate`/`created_at`/`enteredBy` keys) collides with GRDB's column mapping. So `CarbEntryRecord`
  uses a manual `init(row:)` + `encode(to container:)` (GRDB's `PersistenceContainer` overload, like
  `TempTargetRecord`) for persistence, **and** a separate Swift `Encodable` (`encode(to encoder:)`) for
  the oref JSON. The two `encode` methods have different signatures, so one struct carries both;
  `OpenAPS.fetchAndProcessCarbs` passes `[CarbEntryRecord]` straight to `jsonConverter.convertToJSON`.
- **Nightscout mark-uploaded is split by `areFPUs`** (the TempTarget nil-id class of bug): carb
  treatments match on `id`, FPU treatments on `fpuID`. `NightscoutManager.uploadCarbs(_:areFPUs:)` →
  `markUploadedToNightscout(ids:)` / `markFPUsUploadedToNightscout(fpuIDs:)`. Health/Tidepool match on
  `id` (`markUploadedToHealth/Tidepool(ids:)`).
- **All three upload FRCs moved** (not just Nightscout): the Health (`HealthKitManager`) and Tidepool
  (`TidepoolManager`) `carbsUploadController`s also became `observeNotYetUploadedTo*Count()` cancellables.
- **History meals list** uses a new `CarbEntryStore.observeHistory()` (tracks `carbs > 0`; subscriber
  applies `date >= oneDayAgo`), fed into `History.StateModel.carbEntryStored`. The FPU-vs-carb edit
  resolution (`getCorrespondingCarbEntry`/`getZeroCarbNonFPUEntry`) uses `fetchByFpuID(_:)` + a Swift
  filter; all of `HistoryStateModel+CarbEditing`/`+Carbs`, `CarbEntryEditorView`, `HistoryDeletionTarget`
  moved from `NSManagedObjectID` to `pk: Int64`.
- **Test seams.** `BaseCarbsStorage.storeCarbs(_:areFetchedFromRemote:in:)` and
  `JSONImporter.importCarbHistory(url:now:in:)` take an optional `DatabasePool` (default `nil` = shared),
  mirroring `BaseTDDStorage.hasSufficientTDD(in:)`, so `CarbsStorageTests`/`JSONImporterTests` exercise
  the FPU split + dedupe against an in-memory pool. Delete-cascade and the not-yet-uploaded fetches are
  tested at the `CarbEntryStore` level directly. `TestAssembly` drops the Core Data `contextProvider`.

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

### ✅ Step 10 — `OrefDetermination` + `Forecast` + `ForecastValue` (done, this branch)

Implemented as planned below. Notable implementation decisions:
- **Hot-path write is one transaction.** `OrefDeterminationStore.store(_:forecasts:)` inserts the
  determination, reads back its `pk`, then inserts each `ForecastRecord`/`ForecastValueRecord` in a
  single `write` — so `OpenAPS.processDetermination` never persists a dosing decision half-way. The
  bolus-preview path uses `ForecastStore.storeOrphan` (nil FK).
- **`timestamp` stays nil at creation.** Like the former Core Data path, `processDetermination` does
  not set `timestamp`; it is stamped later by `APSManager.reportEnacted` (`updateEnacted(pk:enacted:)`,
  which also clears `isUploadedToNS`).
- **Two determination observations + a shared "latest" one.** `observeEnacted()` (Home enacted
  display, subscriber applies the `timestamp >= halfHourAgo` staleness) and `observeForCobIobCharts()`
  (bounded to the newest 500 rows, subscriber applies `deliverAt >= oneDayAgo`). The six
  `coreDataPublisher.filteredByEntityName("OrefDetermination")` sinks (IOB, LiveActivity, Watch,
  Garmin, ContactImage, Treatments) → `observeLatest()`; the Nightscout upload FRC →
  `observeNotYetUploadedCount()` (wired in `wireUploadControllers`). `IOBService.currentIOB` stays
  synchronous via `OrefDeterminationStore.fetchLatestSync()`.
- **DTO builder.** `getOrefDeterminationNotYetUploadedToNightscout` collapsed into
  `BaseDeterminationStorage.buildDeterminationDTO(from:)` (four `ForecastStore.fetchValues` calls).
  The `eventualBG as? Int` → `nil` quirk and `received: enacted` mapping are preserved verbatim.
- **Cascade delete.** `deleteOlderThan` on the determination (90d) and forecast (2d) stores cascade to
  children via `ON DELETE CASCADE`; the old parent/child `ForecastValue` batch-delete helper is gone.
- **Tests.** `DeterminationStorageTests` rewritten against an in-memory GRDB pool (fetchLast,
  forecast-hierarchy fetch, enacted/suggested not-yet-uploaded splits, cascade delete, Decimal
  round-trip); `JSONImporterTests` determination cases run through `importOrefDetermination(…, in: pool)`;
  `TestAssembly` drops the Core Data `contextProvider` for `DeterminationStorage`.

The Core Data `OrefDetermination`/`Forecast`/`ForecastValue` entities stay as the read-only migration
source (`Determination+helper`/`Forecast+helper` fetch helpers are now dead but left for the final CD
cleanup step).

<details><summary>Original plan (for reference)</summary>


The **first hot-path family** and the deepest relationship graph so far: a two-level tree
`OrefDetermination —(1:n forecasts)→ Forecast —(1:n forecastValues)→ ForecastValue`. Unlike
Override/TempTarget (one relationship), this needs **two** foreign keys, and it is written **every
loop cycle** by `determineBasal` and read reactively by the Home forecast/COB/IOB charts. Mirror
Steps 7–8 for the record/store/observation/FK patterns; the deltas below are what makes the
determination family different. Full call-site map (line-level) lives in the PR notes (~22 files).

⚠️ **Hot path.** `OpenAPS.processDetermination` runs at the end of every `determineBasal`. The GRDB
write must stay a single fast transaction and must not block the dosing decision. This is the first
entity where a slow/incorrect migration has loop-timing consequences — treat reads/writes here as
performance-sensitive and verify on-device loop cadence before merging.

#### Records (`Model/GRDB/OrefDeterminationRecord.swift`)

- `OrefDeterminationRecord` — ~31 attrs. The **~24 Decimals** (`bolus`, `carbRatio`, `currentTarget`,
  `duration`, `eventualBG`, `expectedDelta`, `glucose`, `insulinForManualBolus`, `insulinReq`,
  `insulinSensitivity`, `iob`, `manualBolusErrorString`, `minDelta`, `rate`, `reservoir`,
  `scheduledBasal`, `sensitivityRatio`, `smbToDeliver`, `tempBasal`, `threshold`) stored as **TEXT**
  with a manual `FetchableRecord`/`MutablePersistableRecord` (like `TDDRecord`/`OverrideRecord`).
  `cob`/`carbsRequired` are `Int16`; `enacted`/`received`/`isUploadedToNS` are `Bool`;
  `deliverAt`/`timestamp`/`timestampEnacted` are `Date?`; `id` is a `UUID` (TEXT); `reason`/`temp`
  are `String?`. `pk` = rowid. `Hashable`/`Identifiable`. **`MutablePersistableRecord`** (the store
  returns the inserted record so callers read `pk` back — see the Step 8 note).
- `ForecastRecord` — `id` (UUID), `type` (String: `iob`/`zt`/`cob`/`uam`), `date` (Date), and
  `orefDeterminationPk: Int64?` foreign key replacing the `orefDetermination` to-one. **Nullable** FK:
  `OpenAPS.processAndSave`/`createForecast` create *orphan* forecasts (no determination — the
  Treatments bolus preview), so the FK must allow `nil`. `ON DELETE CASCADE`.
- `ForecastValueRecord` — `index` (Int32), `value` (Int32), `forecastPk: Int64?` foreign key replacing
  the `forecast` to-one. `ON DELETE CASCADE`.
- ⚠️ **Cascade, not nullify.** Core Data declares both relationships `Nullify`, but the actual
  lifecycle deletes children with the parent (`TrioApp` batch-deletes `ForecastValue` via its parent
  `Forecast`, and forecasts/values are conceptually owned by their determination). `ON DELETE CASCADE`
  on both FKs is the correct GRDB equivalent and removes the need for the parent/child batch-delete
  helper: deleting an `OrefDetermination` wipes its `Forecast`s and (transitively) their
  `ForecastValue`s; the 2-day forecast prune wipes values too.

#### Schema v9 + `OrefDeterminationMigration`

Three tables: `orefDeterminationStored` (index on `deliverAt`, `timestamp`, `enacted`,
`isUploadedToNS`), `forecastStored` (index on `date`, `type`, `orefDeterminationPk`),
`forecastValueStored` (index on `forecastPk`, `index`). Both FKs `ON DELETE CASCADE`. Register in
`GRDBStack.bootstrap()` after `CarbEntryMigration`, gated by `grdb.didMigrateOrefDetermination`.
The one-time copy resolves the two relationships by legacy `NSManagedObjectID` → new `pk`, two levels
deep (determination → its forecasts → each forecast's values), exactly as `OverrideMigration` did one
level. Orphan forecasts (no `orefDetermination`) copy with `orefDeterminationPk = nil`.

#### Store API (`OrefDeterminationStore` / `ForecastStore`)

`OrefDeterminationStore`: `fetchLast(within:enactedOnly:)` (replaces `fetchLastDeterminationObjectID`
+ the `enactedDetermination`/`predicateFor30MinAgoForDetermination` predicates — returns the record,
no `objectID`), `fetchEnacted()` (`enacted == true AND timestamp >= halfHourAgo`, limit 1),
`fetchForCobIobCharts()` (`deliverAt >= oneDayAgo`), `store(_:)` (returns record with `pk`),
`updateEnacted(pk:enacted:)` (sets `timestamp = now`, `enacted`, `isUploadedToNS = false` — the
`reportEnacted` mutation), `markUploaded(ids:)`, `fetchEnactedNotYetUploaded()` /
`fetchSuggestedNotYetUploaded()`, `deleteOlderThan(days:)`, and observations `observeEnacted()`,
`observeForCobIobCharts()`, `observeNotYetUploadedCount()`.

`ForecastStore`: `store(forecasts:for determinationPk:)` (inserts forecasts + their values in one
transaction, linking via the two FKs), `storeOrphan(forecasts:)` (the bolus-preview path, `nil` FK),
`fetchHierarchy(for determinationPk:)` (returns `[(ForecastRecord, [ForecastValueRecord])]`, values
sorted by `index`, capped at the first 36 — **replaces the entire `fetchForecastHierarchy` →
`fetchForecastObjects` → `existingObject` objectID dance + the `relationshipKeyPathsForPrefetching`
N+1 workaround**), `fetchValues(type:for determinationPk:)` (replaces `parseForecastValues`, returns
`[Int]`), `deleteOlderThan(days:)`.

#### Identity / hot-path write (replaces `NSManagedObjectID` passing)

`OpenAPS.processDetermination` builds value types and writes in one transaction: insert the
`OrefDeterminationRecord` → read back its `pk` → insert each `ForecastRecord` with
`orefDeterminationPk` → insert each `ForecastValueRecord` with `forecastPk`. `APSManager.reportEnacted`
→ `OrefDeterminationStore.fetchLast(within: 30.minutes)` + `updateEnacted(pk:)` (drops the
`existingObject(with:)` round-trip). `OpenAPS.processAndSave`/`createForecast` →
`ForecastStore.storeOrphan`. The whole `DeterminationStorage` protocol drops `NSManagedObjectID` /
`in context:` params and deals in records / `pk`s; `getForecastIDs`/`getForecastValueIDs`/
`fetchForecastObjects` collapse into `ForecastStore.fetchHierarchy`.

#### Reactivity / call sites (~22 files)

- `HomeStateModel`: `enactedDeterminationController` FRC → `observeEnacted()`; `determinationController`
  FRC (`determinationsForCobIobCharts`) → `observeForCobIobCharts()` (see `DeterminationSetup`).
  `determinationsFromPersistence`/`enactedAndNonEnactedDeterminations` → `[OrefDeterminationRecord]`.
- **Forecast preprocessing** (`ForecastSetup.preprocessForecastData`/`updateForecastData`): replace the
  objectID hierarchy + `viewContext.existingObject` materialization + the `SELF IN %@` prefetch with a
  single `ForecastStore.fetchHierarchy(for: latestDeterminationPk)`. `preprocessedData` becomes
  `[(id: UUID, forecast: ForecastRecord, forecastValue: ForecastValueRecord)]`; `ForecastView` holds
  records. The min/max envelope math is unchanged.
- `Treatments`: `determinationController` FRC (`predicateFor30MinAgoForDetermination`) → store
  fetch/observe; `determination: [OrefDeterminationRecord]`, `preprocessedData` → records.
  `ForecastChart` reads `eventualBG`/`predictionsForChart` off records.
- `MainChartView`: `findDetermination(in:)` + `selectedCOBValue`/`selectedIOBValue` →
  `[OrefDeterminationRecord]`.
- `Nightscout`: `determinationUploadController` FRC → `observeNotYetUploadedCount()`;
  `getOrefDeterminationNotYetUploadedToNightscout` + `parseForecastValues` →
  `OrefDeterminationStore` + `ForecastStore.fetchValues`; `updateOrefDeterminationAsUploaded` →
  `markUploaded(ids:)`; `lastEnactedDetermination`/`lastSuggestedDetermination` carry records.
- `coreDataPublisher.filteredByEntityName("OrefDetermination")` sinks in `GarminManager`,
  `AppleWatchManager`, `LiveActivityManager`, `CalendarManager`, `ContactImageManager`, `IOBService`
  → `OrefDeterminationStore.observeEnacted()` (or a dedicated latest observation). `GarminManager`'s
  `fetchDeterminations30Min` + `object(with:)` and `LiveActivity DataManager.fetchAndMapDetermination`
  (reads `cob`/`currentTarget`/`deliverAt`) → store fetches.
- `BolusCalculationManager`, `AutosensSettingsStateModel`, `StateIntentRequest` (all use
  `fetchLastDeterminationObjectID`) → `OrefDeterminationStore.fetchLast(...)`.
- `JSONImporter.importOrefDetermination` + `Determination.store(in:)` → record inserts via the stores
  (mirror the Carb `makeCarbEntryRecord` seam); update `JSONImporterTests`.

#### Preserve exactly (intentional quirks)

- `Determination.eventualBG` is built via `orefDetermination.eventualBG as? Int` on an
  `NSDecimalNumber?`, which currently always yields `nil`. **Do not "fix"** — carry the behavior
  (map to `nil`/the same cast result) to stay in migration scope.
- `received: orefDetermination.enacted` in the Nightscout `Determination` DTO (the comment notes it's
  "actually part of NS") — keep the mapping verbatim.
- `getOrefDeterminationNotYetUploadedToNightscout` builds `Predictions` from the four forecast types
  via separate fetches — keep the same four-type assembly (now one `fetchHierarchy` + group-by-type,
  or four `fetchValues`).

#### Cleanup parity / tests

`TrioApp`: `batchDeleteOlderThan(OrefDetermination, deliverAt, 90)` → `OrefDeterminationStore.deleteOlderThan(days: 90)`
(cascades to forecasts + values); `batchDeleteOlderThan(Forecast, date, 2)` +
`batchDeleteOlderThan(parent: Forecast, child: ForecastValue, 2)` → `ForecastStore.deleteOlderThan(days: 2)`
(the single store call cascades to values — the parent/child helper is no longer needed). Rewrite
`DeterminationStorageTests` against an in-memory pool (the forecast-hierarchy fetch and the
not-yet-uploaded enacted/suggested splits are the important cases); `TestAssembly` drops the Core Data
`contextProvider` for `DeterminationStorage`.

#### Open risk

This is the first **cross-process hot-path** entity that extensions read (LiveActivity / widgets /
Watch via `coreDataPublisher`). GRDB `ValueObservation` across processes needs explicit handling
(`DatabaseRegionObservation` + Darwin notifications) — verify the LiveActivity/widget read path before
merging (see the "Cross-process" open item below). Consider landing the in-app path first and the
extension observations as a follow-up if cross-process observation isn't yet proven.

</details>

### ✅ Step 11 — `PumpEventStored` + `BolusStored` + `TempBasalStored` (done, this branch)

Implemented as planned below. Notable implementation decisions:
- **Records + `PumpEventDetails` (`Model/GRDB/PumpEventRecord.swift`).** `PumpEventRecord` (`id` String
  unique, no Decimals — manual `Row`/`PersistenceContainer` for uniformity), `BolusRecord` (`amount`
  Decimal as TEXT), `TempBasalRecord` (`rate` Decimal as TEXT, `duration` Int16). The FK lives on the
  children (`pumpEventPk`, `ON DELETE CASCADE`). `PumpEventDetails` (event + optional bolus/tempBasal)
  is the read shape and carries the ported oref-JSON DTO helpers; the `EventType`/`TempType` enums, the
  `dateFormatter`, and the `*DTO`/`PumpEventDTO` structs stay on `PumpEventStored`.
- **Schema v10** — `pumpEventStored` (unique `id`, composite unique `(timestamp, type)` = the dedup
  backstop, plus `timestamp`/`type`/three-upload-flag indexes), `bolusStored`/`tempBasalStored` (FK
  index, `ON DELETE CASCADE`). One-time `PumpEventMigration` resolves the two 1:1 relationships parent-
  first (children via the CD relationship, no objectID map needed). Registered after
  `OrefDeterminationMigration`, gated `grdb.didMigratePumpEvent`.
- **Dedup / partial-bolus preserved verbatim.** `BasePumpHistoryStorage.storePumpEvents` keeps the
  `(timestamp, type)` dedup, the partial-bolus smaller-value `updateBolusAmount` (which re-clears all
  three upload flags), and the restrict-to-now clamp. It threads an optional `in pool:` seam for tests.
  ⚠️ **Dedup runs in SQLite, not against a Swift `Date` key** (`PumpEventStore.fetchExisting(timestamp:
  type:)`): GRDB stores timestamps as millisecond text, so a raw incoming `Date` with sub-millisecond
  components does not equal the round-tripped value in Swift — an in-memory key let a re-reported
  (mutable) temp basal slip past every loop cycle, hit the composite unique index, and abort the whole
  dosing write (the loop stalled). The SQL equality binds the `Date` the same way it was persisted, so
  it matches; each insert commits before the next event, so in-batch duplicates are caught too.
- **oref read path.** `fetchPumpHistoryObjectIDs`/`parsePumpHistory`/`loadAndMapPumpEvents`/
  `fetchOrphanedResumes` now operate on `[PumpEventDetails]`; `OpenAPS.loadAndMapPumpEvents(_:orphanedResumes:)`
  is static (`Set<Int64>`) and keeps the exact DTO ordering. The **#898 orphaned-resume filter** is
  preserved, keyed by `pk` (store returns lightweight `(pk, type, timestamp)` suspend/resume rows for
  the last 48h). `createSimulatedBolusDTO` unchanged.
- **Reactivity.** `observeForChart()` (Home insulin chart + History list; newest 1000, subscriber
  applies `oneDayAgo`), `observeLastBolus()` (Home/Treatments last bolus + AppleWatch; newest 100
  non-external, subscriber applies 20-min), `observeNotYetUploadedCount(channel:)` (the 3 upload
  triggers). Garmin reads temp basal via a store fetch on its existing determination trigger.
- **Uploads.** All three channels match on the event `id`; `markUploaded(channel:ids:)`. Health/Tidepool
  keep their predecessor-temp-basal delivered-units math (now off `PumpEventDetails`, no context).
- **Tests.** `PumpHistoryStorageTests` rewritten against an in-memory pool (store, dedup, partial-bolus
  update + flag re-clear, not-yet-uploaded + mark); `JSONImporterTests` pump cases run through
  `importPumpHistory(url:now:in:)`; `TestAssembly` drops the Core Data `contextProvider`.

The Core Data `PumpEventStored`/`BolusStored`/`TempBasalStored` entities stay as the read-only migration
source (`PumpEvent+helper` fetch helpers are now dead but left for the final CD cleanup step).

<details><summary>Original plan (for reference)</summary>

The **dosing path — highest risk of the whole migration.** Every bolus and temp basal the pump
delivers is recorded here, this table feeds the oref algorithm's `pumphistory` **every loop cycle**,
and it drives three upload channels (Nightscout / Apple Health / Tidepool) plus IOB/TDD math. A wrong
migration here can mis-dose. Treat reads/writes as safety-critical and verify on-device dosing +
IOB + all three uploads before merging.

Relationship shape (inverse of the determination family): `PumpEventStored` is the **parent** with two
**optional 1:1** children — `bolus` (`BolusStored`) and `tempBasal` (`TempBasalStored`), each with an
inverse to-one `pumpEvent`. A pump event carries *either* a bolus *or* a temp basal *or* neither
(suspend/resume/rewind/prime/alarm/siteChange). Mirror Steps 7–10 for the record/store/observation/FK
patterns; the deltas below are what makes the pump family different. Full call-site map (line-level)
lives in the PR notes (~24 non-test files).

⚠️ **Uniqueness constraints (must carry over).** The Core Data model declares two uniqueness
constraints on `PumpEventStored`: `id`, and the composite `(timestamp, type)`. These back the batched
de-duplication in `storePumpEvents` (which keys on `(timestamp, type)`) and are a race-safe backstop.
In GRDB they become a **unique index on `id`** and a **composite unique index on `(timestamp, type)`**.

#### Records (`Model/GRDB/PumpEventRecord.swift`)

- `PumpEventRecord` — `id` (**String**, the business UUID-string, unique — *not* a UUID column like
  the other records), `timestamp` (Date?), `type` (String?, the `EventType` raw value), `note`
  (String?), and the **three** upload flags `isUploadedToNS` / `isUploadedToHealth` /
  `isUploadedToTidepool`. **No Decimals** on the parent → a plain `Codable` GRDB record works (like
  `ContactImageRecord`). `pk` = rowid. `Hashable`/`Identifiable`. **`MutablePersistableRecord`** (the
  composite insert reads `pk` back to link children — see the Step 8 note).
- `BolusRecord` — `amount` (**Decimal**, stored as TEXT, lossless — like `TDDRecord`), `isSMB` (Bool),
  `isExternal` (Bool), and `pumpEventPk: Int64?` foreign key replacing the `pumpEvent` to-one.
  `ON DELETE CASCADE`. Manual `FetchableRecord`/`MutablePersistableRecord` for the Decimal.
- `TempBasalRecord` — `duration` (Int16), `rate` (**Decimal**, TEXT), `tempType` (String?), and
  `pumpEventPk: Int64?` foreign key. `ON DELETE CASCADE`. Manual persistence for the Decimal.
- ⚠️ **FK direction + cascade.** The FK lives on the **child** (`bolus`/`tempBasal` carry
  `pumpEventPk`), mirroring `OverrideRunRecord.overridePk`. `ON DELETE CASCADE` (not SET NULL) — a
  bolus/temp basal has no meaning without its event, and `TrioApp` already batch-deletes the children
  with the parent. Deleting a `PumpEventRecord` wipes its child.
- **Composite value type for parent→child reads.** Most consumers read `event.bolus?.amount` /
  `event.tempBasal?.rate`. Expose a `PumpEventDetails` struct (`event: PumpEventRecord`,
  `bolus: BolusRecord?`, `tempBasal: TempBasalRecord?`) that the store returns from its joined
  fetches, so call sites keep the same shape without an `NSManagedObject` graph.
- **Port the oref-JSON DTO helpers.** `toBolusDTOEnum()` / `toTempBasalDTOEnum()` /
  `toTempBasalDurationDTOEnum()` / `toPumpSuspendDTO()` / `toPumpResumeDTO()` / `toRewindDTO()` /
  `toPrimeDTO()` (currently on `PumpEventStored`, in `PumpEvent+helper.swift`) move onto
  `PumpEventDetails` (they need event + child), exactly like the Carb `Encodable` port in Step 9a.
  `OpenAPS.loadAndMapPumpEvents` then maps `[PumpEventDetails]` → `[PumpEventDTO]` → JSON. Keep the
  `EventType`/`TempType` enums and the `PumpEventDTO`/`*DTO` structs where they are (still used).

#### Schema v10 + `PumpEventMigration`

Three tables: `pumpEventStored` (unique index on `id`; composite unique index on `(timestamp, type)`;
index on `timestamp` and on each of the three `isUploadedTo*` flags; index on `type`), `bolusStored`
(index on `pumpEventPk`), `tempBasalStored` (index on `pumpEventPk`). Both FKs `ON DELETE CASCADE`.
Register in `GRDBStack.bootstrap()` after `OrefDeterminationMigration`, gated by
`grdb.didMigratePumpEvent`. The one-time copy resolves both 1:1 relationships by legacy
`NSManagedObjectID` → new `pk` (parent first, then children with `pumpEventPk`), exactly as
`OverrideMigration` did — but the `id` string uniqueness lets a straight copy dedupe naturally.

#### Store API (`PumpEventStore`)

Reads return `PumpEventDetails` (event joined with its bolus/tempBasal, resolved via the FK):
- `fetchHistory(within: 24h, limit: 288)` — `pumpHistoryLast24h`, newest first (Home insulin chart, History).
- `fetchForOref(within: 1440min)` + `fetchForOrphanedResumeDetection(within: 48h)` — the oref read
  path (see below). Return details / lightweight `(pk, type, timestamp)` rows respectively.
- `fetchRecentTempBasal()` — `recentPumpHistory` (`type == tempBasal AND timestamp >= 20min`, limit 1;
  `APSManager.fetchCurrentTempBasal`).
- `fetchLastBolus()` — `lastPumpBolus` (`timestamp >= 20min AND bolus.isExternal == false`, limit 1) —
  ⚠️ the "not external" filter is on the **child**, so this needs the join.
- `fetchForStats(...)` — bolus / temp-basal / suspend-resume windows (`pumpHistoryForStats` = 3 months;
  the Stat setups filter on `pumpEvent.timestamp` and on `(timestamp, type)` for suspend/resume).
- `fetchNotYetUploaded(channel:)` for the 3 channels (`pumpEventsNotYetUploadedTo{NS,Health,Tidepool}`).
- `fetchTotalRecentBolusAmount(since:)` — `BolusSafetyValidator` (sum of `bolus.amount` for
  `type == bolus AND timestamp > date`).
- Writes/dedup primitives used by `BasePumpHistoryStorage.storePumpEvents` (the dedup + partial-bolus
  update + external-insulin logic stays in the storage layer, operating on records):
  `fetchByTimestamps(_:)` (batched dedup), `insert(event:bolus:tempBasal:)` (composite insert in one
  transaction, links children to the event `pk`), `updateBolusAmount(pk:amount:isSMB:)` (the
  smaller-value partial-bolus update, which also re-clears the three upload flags).
- `markUploaded(channel:ids:[String])` — match on the event `id` (all three channels match on `id`).
- `deleteOlderThan(days: 90)` — cascades to bolus/tempBasal (the parent/child batch-delete helper is gone).
- Observations: `observeForChart()` (Home insulin chart), `observeLastBolus()`
  (Home/Treatments last-bolus, AppleWatch active-bolus), `observeNotYetUploadedCount(channel:)`
  (Nightscout upload trigger), and a shared "changed" signal for the Watch/Garmin sinks.

#### Identity / hot-path (replaces `NSManagedObjectID` passing)

- **oref read path** (`OpenAPS.fetchPumpHistoryObjectIDs` → `parsePumpHistory` → `loadAndMapPumpEvents`
  + `fetchOrphanedResumes`): the objectID list + `context.object(with:)` materialization → a single
  `PumpEventStore.fetchForOref` returning `[PumpEventDetails]`. **Preserve the cold-start
  orphaned-resume filter exactly** (Trio issue #898: an orphaned oldest `resume` drives negative IOB →
  over-delivery) — key it by `pk` instead of `objectID`. Keep `createSimulatedBolusDTO` and the DTO
  ordering in `loadAndMapPumpEvents` (bolus → tempBasalDuration → tempBasal → suspend → resume →
  rewind → prime).
- `APSManager.fetchCurrentTempBasal` → `fetchRecentTempBasal()` (reads `duration`/`rate` off the record;
  the delta/`max(0, duration - delta)` math is unchanged).
- `BasePumpHistoryStorage` deals in records; `storePumpEvents`/`storeExternalInsulinEvent` go through
  the store's composite insert. `getPumpHistory` / `getPumpHistoryNotYetUploadedTo{NS,Health,Tidepool}`
  map `[PumpEventDetails]` (the big `NightscoutTreatment` switch in `getPumpHistoryNotYetUploadedToNightscout`
  is unchanged apart from reading off records; `determineBolusEventType` takes a `PumpEventDetails`).

#### Reactivity / call sites (~24 files)

- `HomeStateModel`: `insulinController` FRC → `observeForChart()` (see `PumpHistorySetup`);
  `lastBolusController` FRC → `observeLastBolus()`. `insulinFromPersistence`/`tempBasals`/
  `suspendAndResumeEvents` → `[PumpEventDetails]` (the `$0.tempBasal != nil` / `$0.type ==` filters
  read off the record); `lastPumpBolus` → `PumpEventDetails?`.
- `InsulinView` (`insulinData: [PumpEventStored]`) → `[PumpEventDetails]` (`insulin.bolus?.amount`,
  `insulin.timestamp`).
- `History`: `HistoryRootView` `@FetchRequest` (`pumpEventStored`) → a `History.StateModel`
  observation feeding `[PumpEventDetails]`; `HistoryRootView+Treatments` (`filteredPumpEvents`,
  `treatmentView`) reads off records; `HistoryDeletionTarget.insulin(PumpEventStored)` →
  `.insulin(PumpEventDetails)` (dedup on `pk`); `HistoryStateModel+Insulin` deletion moves from
  `NSManagedObjectID` + `existingObject` to `pk` (fetch the record, read `id`/`timestamp`/`bolus.amount`
  for the remote-service deletes, then `PumpEventStore.delete(pk:)`).
- `Treatments`: `lastBolusController` FRC → `observeLastBolus()`; `lastPumpBolus` → `PumpEventDetails?`.
- `Stat` (`BolusStatsSetup`, `TDDSetup`): fetch `BolusStored`/`TempBasalStored`/suspend-resume
  `PumpEventStored` directly → `PumpEventStore.fetchForStats` returning the joined details (the hourly
  grouping reads `bolus.pumpEvent?.timestamp` → `details.event.timestamp`, `bolus.amount`, etc.).
- `Nightscout`: `pumpEventUploadController` FRC → `observeNotYetUploadedCount(.nightscout)` (wire in
  `wireUploadControllers`, drop the `performFetch`); `updatePumpEventStoredsAsUploaded` →
  `markUploaded(.nightscout, ids:)`.
- `HealthKitManager` / `TidepoolManager`: `getPumpHistoryNotYetUploadedTo{Health,Tidepool}` consumers +
  the direct `PumpEventStored WHERE tempBasal != nil` temp-basal fetches → store fetches;
  `updateInsulinAsUploaded` → `markUploaded(.health/.tidepool, ids:)`. Preserve HealthKit's
  predecessor-temp-basal delivered-units math (reads `tempBasal.rate`).
- `BolusSafetyValidator.fetchTotalRecentBolusAmount` → `PumpEventStore.fetchTotalRecentBolusAmount(since:)`.
- `AppleWatchManager`: `coreDataPublisher.filteredByEntityName("PumpEventStored")` → `observeLastBolus()`
  (or the shared changed-signal); `fetchLastBolus` + `getActiveBolusAmount` (`bolus?.amount`) → store fetch.
- `GarminManager`: the temp-basal fetch feeding `tbrValue` (`tempBasal?.rate`) → store fetch (the
  determination sink already moved in Step 10).
- `JSONImporter.importPumpHistory` + `PumpHistoryEvent.store(in:)` → record inserts via the store
  (mirror the Carb `makeCarbEntryRecord` seam: `importPumpHistory(url:now:in: pool)`), preserving the
  `combineTempBasalAndDuration` / `checkForInconsistencies` dedup; update `JSONImporterTests`.

#### Preserve exactly (intentional quirks)

- **De-duplication** on `(timestamp, type)` including the **partial-bolus smaller-value update**
  (a cancelled/partial bolus overwrites the stored amount with the smaller value and re-clears all
  three upload flags), and the per-batch in-memory dedup map.
- **Restrict-to-now timestamp clamp** (`event.date > Date() ? Date() : event.date`) for boluses and
  external insulin.
- **Cold-start orphaned-resume filter** in the oref path (issue #898).
- **`lastPumpBolus` excludes external insulin** (`bolus.isExternal == false`).
- **Upload-flag matching key:** all three channels match on the event `id` (String). HealthKit and
  Tidepool re-fetch temp-basal events (`tempBasal != nil`, last 24h) to compute delivered units.

#### Cleanup parity / tests

`TrioApp`: `batchDeleteOlderThan(PumpEventStored, timestamp, 90)` +
`batchDeleteOlderThan(parent: PumpEventStored, child: BolusStored, 90)` +
`(parent: PumpEventStored, child: TempBasalStored, 90)` → a single
`PumpEventStore.deleteOlderThan(days: 90)` (cascades to both children). Rewrite `PumpHistoryStorageTests`
(if present) and the pump cases in `JSONImporterTests` against an in-memory pool — the dedup +
partial-bolus update, the orphaned-resume filter (`OpenAPS.loadAndMapPumpEvents` is already static for
testing), and the three not-yet-uploaded fetches are the important cases. `TestAssembly` drops the
Core Data `contextProvider` for `PumpHistoryStorage`.

#### Open risk

- **Dosing safety.** This is the table oref reads to compute IOB and the current temp basal. Verify
  on-device that boluses/temp basals still record, IOB matches pre-migration, and the oref
  `pumphistory` JSON is byte-identical for the same events (diff the DTO output). The orphaned-resume
  edge case (#898) must be re-tested from a cold start.
- **Cross-process** (same open item as Step 10): Health/Tidepool/Watch upload managers run in-app, but
  confirm nothing in an extension reads these tables directly.
- **Observation fan-out (learned from Step 10 field logs).** Independent `ValueObservation`s each
  re-run their query on every write; the pump table changes on every loop cycle *and* on every pump
  status callback. Prefer **one shared `.share()`/`.multicast` publisher** for the "pump events
  changed" signal that the Watch/Garmin/chart sinks subscribe to, rather than N independent
  observations — and carry the same consolidation into the later `GlucoseStored` step.

</details>

### 🔧 Step 12 — `GlucoseStored` + `DeletedGlucoseStored` (planned, not yet implemented)

The **highest read/write-volume entity** and the last one to migrate. A new reading arrives every ~5
minutes and is read by the live charts, every algorithm run, three upload channels, and a fan of
"latest glucose" consumers (Live Activity, Watch, Garmin, Calendar, notifications, contact image).
Both entities are **standalone** (verified against the `.xcdatamodel`: zero relationships), so this is
structurally simple — no FKs, no tree — but the **surface is the broadest of the migration** (~25 files)
and the reactivity fan-out is the real design problem. `DeletedGlucoseStored` (the deferred 9b) is
folded in here: it is a tiny tombstone the glucose delete path writes and the backfill dedup reads, so
it ships with glucose. Mirror Steps 7–11 for the record/store/observation patterns; the deltas below are
what makes glucose different. Full call-site map (line-level) lives in the PR notes.

⚠️ **Cross-process risk — RESOLVED (measured, not assumed).** The long-standing open item ("widgets /
Live Activities read the store") does **not** apply to glucose: extensions never read Core Data
directly. The Core Data store lives in the app's private Documents directory (not the App Group), and
the widget / Live Activity / Watch / Garmin surfaces all receive glucose via a **push model**
(ActivityKit `ContentState`, WatchConnectivity, ConnectIQ) fed by in-app managers. Every
`GlucoseStored` reader is in-process. So no `DatabaseRegionObservation` + Darwin-notification
cross-process observation is needed — the in-app `ValueObservation` pattern from Steps 3/10/11 is
sufficient. (GRDB's file *does* live in the App Group container, which is harmless here and leaves the
door open if an extension ever needs direct reads.)

#### Records (`Model/GRDB/GlucoseRecord.swift`)

- `GlucoseRecord` — `id` (UUID, stored as TEXT), `date` (Date?), `glucose` (Int16), `direction`
  (String?), `isManual` (Bool), the **one Decimal** `smoothedGlucose` stored as TEXT (lossless, like
  `TDDRecord`), and the three upload flags `isUploadedToNS` / `isUploadedToHealth` /
  `isUploadedToTidepool`. `pk` = rowid. `Hashable`/`Identifiable`. **`MutablePersistableRecord`** (the
  smoothing pass reads `pk` back to update `smoothedGlucose`). Because of the single Decimal, use a
  manual `init(row:)` + `encode(to container:)` (like `TDDRecord`/`BolusRecord`), not plain `Codable`.
  Port the `directionEnum` helper (`BloodGlucose.Direction(rawValue: direction)`) onto the record — the
  chart/history/current-glucose views read it for the trend arrow.
- `DeletedGlucoseRecord` — `date` (Date, non-optional), `glucose` (Int16), `isManualGlucoseEntry`
  (Bool). `pk` = rowid. No Decimals → plain `Codable` GRDB record works (like `ContactImageRecord`).
  `MutablePersistableRecord`.

#### Schema v11 + `GlucoseMigration` (+ `DeletedGlucoseMigration`)

Two tables: `glucoseStored` (indexes on `date`, `isManual`, and each of the three `isUploadedTo*`
flags — mirroring the Core Data fetch indexes) and `deletedGlucoseStored` (index on `date`). Both are
straight row-for-row copies (no relationships). Register in `GRDBStack.bootstrap()` after
`PumpEventMigration`, gated `grdb.didMigrateGlucose` / `grdb.didMigrateDeletedGlucose` (two flags, or
one migration file covering both tables — prefer two files for symmetry with the entity split).

#### Store API (`GlucoseStore` / `DeletedGlucoseStore`)

`GlucoseStore`:
- `store(_:)` / `batchInsert(_:)` — replaces `storeGlucoseRegular` **and** the `NSBatchInsertRequest`
  path with inserts in one `write`. ⚠️ **Ingest dedup (Step 11 lesson).** `storeGlucose` and
  `backfillGlucose` filter incoming readings via `filterGlucoseValues` against existing rows using a
  **time buffer** (1s for store, 3.5 min for backfill) — this is proximity matching, not exact-date
  equality, so it is *less* fragile than the pump `(timestamp,type)` case, but the comparison must still
  run against the DB-stored (millisecond) dates, not raw sub-millisecond `Date`s. Provide
  `existingDates(from:to:)` (like `CarbEntryStore.existingDates`) and keep the buffer filter in Swift;
  do **not** reintroduce an exact-date in-memory key.
- `addManualGlucose(_:)` — the manual-entry insert (`isManual = true`).
- `fetchLatest(within: 20min)` (`fetchLatestGlucose` / the `alarm` path — keep a synchronous
  `fetchLatestSync()` for the `alarm` computed property, mirroring `OrefDeterminationStore.fetchLatestSync()`).
- `fetchForChart()` (Home/Treatments/History, `date >= oneDayAgo`, ascending — see the Step 11 ordering
  note), `fetchForStats(from:)` (the day/week/month/total windows), `fetchForAlgorithm(from:limit:)`
  (the oref window; returns records so `fetchAndProcessGlucose` maps them), `fetchForSmoothing(limit: 350)`
  (newest non-manual, chronological) + `updateSmoothed(_ pairs: [(pk: Int64, value: Decimal)])`.
- `fetchNotYetUploaded(channel:manualOnly:)` for the 3 channels (+ the manual-only Health/Tidepool
  variants), `markUploaded(channel:ids:[UUID])` (all three channels match on `id` — Tidepool's
  `syncIdentifier` *is* the `id`).
- `delete(pk:)` — deletes the reading **and** inserts a `DeletedGlucoseRecord` tombstone in one
  transaction (the current `deleteGlucose` behavior).
- `deleteOlderThan(days: 90)`.
- Observations: **one shared `observeLatestChanged()`** (`.share()`/multicast) that the six latest-glucose
  consumers subscribe to (see fan-out below); `observeForChart()` (Home/Treatments/History); and
  `observeNotYetUploadedCount(channel:)` for the 3 upload triggers.

`DeletedGlucoseStore`: `store(_:)`, `existingDates(from:to:)` / `existsAround(date:buffer:)` (the backfill
tombstone dedup), `deleteOlderThan(days: 90)`. **No upload path** — the Nightscout *remote* delete is
done synchronously in the delete flow by the manager reading the live `GlucoseStored` `id`/`date` before
deletion (`deleteGlucoseFromNightscout(withID:withDate:)` / `deleteGlucoseFromHealth(withSyncID:)`), not
via the tombstone. The tombstone exists **only** to stop a deleted reading from being re-ingested by a
later backfill.

#### Identity / call sites (~25 files)

- **Storage.** `BaseGlucoseStorage` drops `makeContext`/`contextProvider` and deals in records:
  `storeGlucose`/`backfillGlucose` (dedup via GRDB), `addManualGlucose`, the 5 not-yet-uploaded getters
  (`getGlucoseNotYetUploadedTo{NS,Health,Tidepool}` + the two manual variants → `fetchNotYetUploaded`),
  `deleteGlucose` → `delete(pk:)`, `fetchLatestGlucose`/`alarm`. `storeCGMState` (JSON `FileStorage`,
  **not** Core Data) stays as-is. Keep `updatePublisher` as the "changed" signal for any non-observation
  subscriber.
- **Ingest.** `FetchGlucoseManager.glucoseStoreAndHeartDecision` (store/backfill), and the exponential-
  smoothing pass: `fetchGlucose` (350 newest non-manual) + `applyExponentialSmoothingAndStore` →
  `GlucoseStore.fetchForSmoothing` + `updateSmoothed` (drop the objectID materialization). CGM plugin
  (`PluginSource`) unchanged apart from the storage calls.
- **oref read.** `OpenAPS.fetchAndProcessGlucose` pre-fetches `[GlucoseRecord]` via the store (already
  async), then maps to `AlgorithmGlucose`. **Preserve the smoothing selection exactly:** smoothed value
  only for non-manual readings with a non-zero `smoothedGlucose`, else the raw value; manual readings
  always use the raw value (Trio issue #1054).
- **Reactivity — charts.** `HomeStateModel.glucoseController` FRC → `observeForChart()` (see a new
  `GlucoseSetup`); `glucoseFromPersistence`/`latestTwoGlucoseValues` → `[GlucoseRecord]`.
  `TreatmentsStateModel.glucoseController` likewise. The chart views (`GlucoseChartView`,
  `SelectionPopoverView`, `CurrentGlucoseView`, `CarbView`, `InsulinView`, `MainChartHelper.timeToNearestGlucose`)
  move to `[GlucoseRecord]` (reads `glucose`/`date`/`isManual`/`smoothedGlucose`/`directionEnum`).
- **Reactivity — the fan-out (the central risk).** The **five** `coreDataPublisher.filteredByEntityName("GlucoseStored")`
  sinks — `LiveActivityManager`, `AppleWatchManager`, `GarminManager` (500 ms debounce),
  `CalendarManager`, `UserNotificationsManager` — plus the `ContactImageManager` fetch-on-trigger, all
  want "latest glucose changed". Subscribe them to **one shared `GlucoseStore.observeLatestChanged()`**
  (`.share()`), not six independent `ValueObservation`s that each re-run on every 5-minute write. Their
  fetch bodies (`DataManager.fetchAndMapGlucose`, `AppleWatchManager.fetchGlucose`, `GarminManager.fetchGlucose`,
  `CalendarManager.fetchGlucose`, `ContactImageManager.fetchGlucose`) → store fetches returning records
  (drop the objectID → `context.object(with:)` materialization).
- **Reads.** `BolusCalculationManager` (`glucose`, limit 288) and `StateIntentRequest` (limit 2) →
  store fetches.
- **History.** `HistoryRootView` `@FetchRequest` (`glucoseStored`, descending) → a `History.StateModel`
  observation; `HistoryRootView+Glucose` list reads off records; `HistoryDeletionTarget.glucose(GlucoseStored)`
  → `.glucose(GlucoseRecord)` (dedup on `pk`); `HistoryStateModel+Glucose.deleteGlucoseFromServices`
  reads `id`/`date` for the remote-service deletes, then `GlucoseStore.delete(pk:)`.
- **Stat.** `StatStateModel.setupGlucoseArray`/`fetchGlucose` + `GlucoseStatsSetup` (distribution /
  percentile structs hold `[GlucoseRecord]`) → `GlucoseStore.fetchForStats`.
- **Uploads.** NS/Health/Tidepool `glucoseUploadController` FRCs → `observeNotYetUploadedCount(channel:)`
  (wire in each manager's controller setup, drop the `performFetch`); `updateGlucoseAsUploaded` →
  `markUploaded(channel:ids:)`. The `BloodGlucose`/`StoredGlucoseSample` DTO mapping and the manual→`mbg`
  Nightscout mapping are unchanged apart from reading off records.

#### Preserve exactly (intentional quirks)

- The smoothed-vs-raw selection in `fetchAndProcessGlucose` (#1054), `clampToMinimum`,
  `filterTooFrequentGlucose`, the 3.5-min backfill buffer, and the `DeletedGlucoseStored` tombstone dedup.
- `directionEnum` mapping and the "HIGH at 400" current-glucose display.
- Manual readings upload to Nightscout as `mbg` (type `"mbg"`), CGM readings as `sgv`.
- The batch-insert `updateSubject.send()` signal (regular saves relied on Core Data notifications; GRDB
  observation replaces that, but keep `updatePublisher` for any remaining plain subscriber).

#### Cleanup parity / tests

`TrioApp`: `batchDeleteOlderThan(GlucoseStored, date, 90)` + `batchDeleteOlderThan(DeletedGlucoseStored,
date, 90)` → `GlucoseStore.deleteOlderThan(days: 90)` + `DeletedGlucoseStore.deleteOlderThan(days: 90)`.
Rewrite `GlucoseStorageTests` against an in-memory pool (store/backfill dedup incl. the tombstone, the
5 not-yet-uploaded fetches incl. manual variants, delete-writes-tombstone, smoothing update, Decimal
round-trip); route `JSONImporter.importGlucoseHistory` through an `in pool:` seam + `makeGlucoseRecord`
and update the `JSONImporterTests` glucose cases. `TestAssembly` drops the Core Data `contextProvider`
for `GlucoseStorage`.

#### Open risk

- **Observation fan-out.** The dominant concern given the write frequency. Land the single shared
  latest-glucose observation and verify on device that the chart, Live Activity, Watch, Garmin, calendar,
  and notifications all update within the expected latency and that CPU/battery from re-running queries is
  acceptable.
- **Ingest dedup precision** (Step 11 lesson): keep the buffer-based dedup against DB-stored dates; never
  key on exact sub-millisecond `Date` equality.
- **Last entity.** After glucose is proven in the field, the **CD cleanup step** (remove the migrated
  entities from the model, delete the generated classes + dead helpers, and remove
  `eraseDatabaseOnSchemaChange`) can run.

### ⏳ After the determination family

1. ~~`OrefDetermination` + `Forecast` + `ForecastValue` — relationship graph, hot path.~~ **✅ done (Step 10).**
2. ~~`PumpEventStored` + `BolusStored` + `TempBasalStored` — dosing path, highest risk.~~ **✅ done (Step 11).**
3. `GlucoseStored` (+ `DeletedGlucoseStored` 9b) — highest read volume; uses `ValueObservation` for the
   live charts. **Planned: see Step 12 above.** (The last entity; the CD cleanup step follows.)

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
- **Cross-process.** ✅ Investigated for the glucose step (Step 12) and found **not to apply**: Core
  Data lives in the app's private Documents directory (not the App Group), and widgets / Live Activities
  / Watch / Garmin receive data via a push model (ActivityKit / WatchConnectivity / ConnectIQ) fed by
  in-app managers — no extension reads the store directly. So in-app `ValueObservation` is sufficient for
  every entity migrated so far. `DatabasePool` over the App-Group file with WAL still supports true
  cross-process reads should an extension ever need them (then `DatabaseRegionObservation` + Darwin
  notifications would be required).
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
