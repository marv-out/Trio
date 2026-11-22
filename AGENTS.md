# Trio — project instructions for Codex

## ⭐ Adaptive Smoothing (UKF) MUST maintain functional parity with AndroidAPS

Trio's **Adaptive Smoothing** glucose smoother (the `GlucoseSmoothing` package; `UnscentedKalmanFilter`
in `GlucoseSmoothingCore`) is a port of AndroidAPS's `UnscentedKalmanFilterPlugin`. **It must stay
functionally identical to the AAPS build — in production behaviour, not just per call.**

Functional parity has **three layers, all of which must hold**:

1. **Per-call algorithm** — `smooth()` is bit-exact to the AAPS Kotlin plugin and the Python `V4UKF`
   reference for the same input. Guarded by the golden vectors + `UkfPythonParityTests`.
2. **State persistence** — the filter carries learned state (`learnedR`, innovation windows) *across
   cycles*. AAPS's plugin is a singleton; Trio **must reuse one persistent instance** and never
   construct a fresh `UnscentedKalmanFilter()` per cycle (a fresh instance takes the clean-start reset
   path every time — see mistake #3).
3. **Input window** — Trio feeds the smoother the same period AAPS does: **34 h** (24 h + 10 h max DIA,
   per AAPS `LoadBgDataWorker`), newest-first.

**Before changing anything in the smoothing path, prove parity is preserved.** The definitive check is
a **full-history rolling-window replay**: bounded window each cycle, reused instance, take the newest
point per cycle, run the *same* real trace through all three implementations (Trio Swift, real AAPS
Kotlin, Python V4UKF), and assert bit-exact equivalence at **every data point**. Per-call tests alone
are NOT sufficient — they miss production divergences (mistake #3). Harnesses + method: the private
repo **`tim2000s/trio-ukf-backtest`**.

### Key files
- `GlucoseSmoothing/Sources/GlucoseSmoothingCore/UnscentedKalmanFilter.swift` — the core. Documented
  *"one instance carries the learned state across `smooth` calls"*; carries state, resets on
  `shouldResetLearning` (sensor change / >24 h gap / first call).
- `Trio/Sources/APS/FetchGlucoseManager.swift` — integration: `applyAdaptiveSmoothingAndStore` (reuses
  the lock-guarded static `sharedSmoother`; `resetSharedSmoother()` for tests), and
  `fetchGlucose(context:)` (34 h / limit 500 — **private to smoothing**; every other caller has its
  own `fetchGlucose`).
- AAPS reference: `Boost-AAPS-core/plugins/smoothing/src/main/kotlin/app/aaps/plugins/smoothing/UnscentedKalmanFilterPlugin.kt`;
  Python `V4UKF` in `Boost-AAPS-core/backtesting/scripts/2026-07-ukf-smoothing/repeatable/smoothers.py`.

## Work done (chronological)
- Ported AAPS UKF → `GlucoseSmoothingCore` (pure Swift package), behind the "Smooth Glucose Value"
  toggle (OFF by default). Rebranded user-facing name from "Kalman/UKF" → **Adaptive Smoothing**.
- Made Adaptive the **sole** smoother — removed the double-exponential smoother and the picker.
- Per-call validation: 9 golden vectors + bit-exact Python parity (`UkfPythonParityTests`); then a
  665k-point three-way (Swift/Kotlin/Python, fresh instances) — all bit-exact.
- Found + fixed the production-behaviour bugs below.
- Production validation: **full 332,397-cycle persistent rolling replay at 34 h** — Swift (Trio) ≡
  Kotlin (real AAPS plugin) ≡ Python (V4UKF), 0 mismatches, max ~2.8e-11, step-by-step every point.
- **PR #1302** (`adaptive-smoothing` → nightscout `dev`). Parity fixes (persistence + 34 h) landed;
  **merged `nightscout/dev` in** (2026-07-16, merge `0663151cc` + build-fix `fbd1c5c1a`), resolved 4
  conflicts, and marked **ready for review** — now `mergeable: MERGEABLE`, only gate is maintainer
  review. Backtest write-up: `tim2000s/trio-ukf-backtest`.

## Mistakes made & lessons (do not repeat)
1. **Fed the UKF backwards.** Assumed fetch order was newest-first; `fetchGlucose` returns
   *oldest-first* → the UKF saw negative time-diffs, formed no segment, and copied raw (went inert).
   Fix: reverse before feeding. The core requires **newest-first**; `UkfOrderingRegressionTest` guards
   it.
2. **Smoothed chart line didn't refresh live.** `viewContext` stale cache (no auto-merge +
   `existingObject`). Fix: `viewContext.refresh(_:mergeChanges:)` in `setupGlucoseArray`.
3. **Declared "faithful" on per-call equivalence alone — and missed a real ~15 mg/dL production
   divergence.** Trio built a *fresh* filter every cycle, so learned state never persisted, while AAPS
   persists it. Per-call bit-exact tests could not see this. Fix: reuse a persistent instance.
   **Lesson: parity = the production method (rolling window + persistent state), not single `smooth()`
   calls. Always validate with the full rolling replay across all three implementations.**
4. **Used a 24 h window instead of AAPS's 34 h.** Fix: 34 h predicate; limit 350 → 500 to cover it.
5. **Kotlin full-history run OOM'd.** Mockito mocks retain *every* invocation for verification; over
   332k cycles (millions of logger/pref calls) that exhausts the test JVM heap. Fix:
   `mock<T>(stubOnly = true)`. Also: don't settle for a 30k subset when the full 332k is the ask — it
   is doable.
6. **The `dev` merge silently broke the app build — SwiftPM tests still passed.** dev's glucose refactor
   removed the class-level `private let context` property, so both `applyGlucoseSmoothing` call sites
   failed with `cannot find 'context' in scope`. The `GlucoseSmoothing` package + its tests still built
   fine, hiding it. Fix: create a fresh `CoreDataStack.shared.newTaskContext()` per call (dev's own
   pattern). **Lesson: after merging dev, always do a full sim app build — package tests alone can't see
   an app-target break (same shape as mistake #3).**
7. **`GlucoseSetup.swift` mistake-#2 fix is now superseded by dev.** dev replaced the manual fetch with
   an `NSFetchedResultsController` (`glucoseController`) whose viewContext is fed by CoreDataStack's
   persistent-history merge (`viewContext.mergeChanges(fromContextDidSave:)`) — so the manual
   `viewContext.refresh` hack was dropped in the merge, not lost. Live smoothed-line surfacing now rides
   that path. (Verified wired in code + smoothing runs/persists live; the happy-path live chart tick was
   blocked only in a cross-model **test** container by a dev-side `134501` history-token gap — not this
   PR's code, not a production path.)

## Parity status
- **Per-call algorithm** — ✅ bit-exact (golden vectors + Python parity + full 332k three-way).
- **Cross-cycle persistence** — ✅ reuse a single instance (`sharedSmoother`).
- **34 h window** — ✅ `predicateForThirtyFourHoursAgo`, limit 500.
- **Across-restart persistence** — ✅ core `PersistedState`/`restore(_:)` (unit-tested) +
  `FetchGlucoseManager` UserDefaults save/load. **Build-verified (full sim build) + soak-verified**:
  emulator soak on live Nightscout showed `learnedR` saved (25→20.48), and after a terminate/relaunch
  the value resumed from disk (20.4758→20.4757, not reset to 25) — restart persistence works live.
- **Sensor-change reset** — ✅ core `sensorChangedSinceLastCall` hook wired via
  `notifySensorChange()`, fired from `PluginSource` `.sensorStart`. Build-verified; the reset path
  compiles + runs, though no sensor change occurred during the soak to exercise it end-to-end.
- **Bucketing** — ⛔ intentionally NOT matched (user decision 2026-07-13). AAPS 5-min-buckets its 34 h
  window; Trio smooths **raw**. Identical output to AAPS on identical input; differs only for
  dense/misaligned CGMs (and a very dense CGM caps at the 500-row limit). Documented, deliberate
  divergence — do not "fix" without a decision.

## Build/validation environment notes
- The LoopKit family is now provided via **git submodules** (not `Carthage/Build`). After merging dev,
  run `git submodule sync && git submodule update --init --recursive` (the dev merge added
  `EversenseKit` and moved `MedtrumKit`), then the full sim build succeeds:
  `xcodebuild -workspace Trio.xcworkspace -scheme Trio -destination 'platform=iOS Simulator,id=<sim>'`.
  Verified 2026-07-16 on iPhone 17 sim (Xcode 26.6). The `GlucoseSmoothing` package and the
  backtest harnesses build standalone (SwiftPM). Kotlin harness runs via
  `./gradlew :plugins:smoothing:testFullDebugUnitTest` (JAVA_HOME = Android Studio JBR).
- Validate builds by "** BUILD SUCCEEDED **" + raw exit 0; scheme "Trio Tests" runs TrioTests; do NOT
  pass `CODE_SIGNING_ALLOWED=NO` for hosted tests (strips the keychain entitlement → fatal error).
