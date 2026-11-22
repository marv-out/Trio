# Boost → Trio port — architecture & phased plan (Swift-oref / dev branch)

Repo: tim2000s/Trio (origin) on branch **dev** (tracks upstream nightscout/Trio `dev`), which has
**oref reimplemented in Swift** (`Trio/Sources/APS/OpenAPSSwift/`). The Boost port targets that Swift
code, NOT the old JS determine-basal. This supersedes the earlier JS-fork sketch.

Two deliverables from one core (Tim, 2026-06-24):
1. **Active** — Trio doses with Boost (V1 tiers + V5) + all shadow observers.
2. **Shadow-only** — Boost runs alongside stock Trio, logging what it *would* do. Zero dosing risk.
Stretch: plugin-style engine selector (Boost as a selectable algorithm).

---

## How Trio's Swift oref runs (grounded in dev)

`OpenAPS.swift` (`Trio/Sources/APS/OpenAPS/OpenAPS.swift`) gathers inputs and calls
`OpenAPSSwift.determineBasal(glucose, currentTemp, iob, profile, autosens, meal, microBolusAllowed,
reservoir, pumpHistory, preferences, basalProfile, trioCustomOrefVariables, clock)`
(`OpenAPSSwift/OpenAPSSwift.swift:45`). That decodes JSON to typed models via `JSONBridge`, then calls
the heart:

`DeterminationGenerator.generate(profile, preferences, currentTemp, iobData, mealData, autosensData,
reservoirData, glucose, microBolusAllowed, trioCustomOrefVariables, currentTime) throws -> Determination?`
(`OpenAPSSwift/DetermineBasal/DetermineBasalGenerator.swift`, an `enum`, ~585 lines).

Supporting modules already exist and are reusable: `DosingEngine`, `DynamicISF`, `GlucoseStatus`,
`ForecastGenerator`, `Isf`, `IobGenerator`, `MealGenerator`, `Profile`, `Determination` model, and
Core Data `OrefDetermination`.

**Why this is the best target yet:** it's native Swift, modular, and structurally close to AAPS's
native-Kotlin Boost. Porting `DetermineBasalBoost.kt` / `DetermineBasalBoostV5.kt` → Swift is a
near 1:1 transcription, not a paradigm shift (unlike Kotlin→JS).

---

## Core design: one Boost generator, two wirings

**`BoostDeterminationGenerator.generate(...)`** — new enum in `OpenAPSSwift/DetermineBasal/`, SAME
signature as `DeterminationGenerator.generate`, implementing Boost's V1 tiers + the V5
observe→confirm→commit state machine. Reuses Trio's existing DynISF/Isf/GlucoseStatus/Forecast
helpers (so it inherits Trio's sensitivity + prediction stack, like Boost inherits AAPS's). Direct
port of the AAPS Kotlin logic.

**V5 cross-cycle state** persists in Swift between runs (Core Data — add a `BoostV5State` entity, or a
lightweight file/UserDefaults blob). Mirrors AAPS `V5StateStore`.

**Harness — second pass.** In `OpenAPSSwift.determineBasal` (or its `OpenAPS.swift` caller), after the
stock `DeterminationGenerator.generate`, branch on a `boostMode` setting:
- **off** → stock Trio (unchanged).
- **shadow** → ALSO run `BoostDeterminationGenerator.generate` on the same typed inputs; attach its
  would-be SMB + V5 state + activity factors to telemetry / Nightscout devicestatus (`boostV5_*`,
  `boostActivityLoad_*`); the stock determination still drives dosing. Runs alongside the live loop.
- **active** → return the Boost determination as THE determination; it drives dosing.
The 3-way `boostMode` is the lightweight "plugin like AAPS" — a selectable engine. (A full plugin
framework is a later option; this gives the practical equivalent and de-risks via shadow.)

**Inputs fed to Boost (Swift-side):**
- **Activity / HR / steps** — new `HealthKitActivityManager`: read HR + steps from HealthKit. On iOS a
  worn Apple Watch writes both continuously, no companion app — the reliable, native replacement for
  the Android Garmin/Wear work. Computes the activity-load + intraday factors (port of
  `DailyStepHistoryTracker`/`WearStepSource`), passes them in + logs the shadow. Trio already has
  `Trio/Sources/Services/HealthKit/HealthKitManager.swift` to extend.
- **ML hypo/meal** — Swift on-device inference (LightGBM→CoreML) feeding mlHypoRisk/mlMealLikely.
  Later phase.

---

## Phases (each compiles + runs before the next)

1. **Shadow harness (foundation).** Add `boostMode` (off/shadow/active) setting. Stub
   `BoostDeterminationGenerator` that delegates to `DeterminationGenerator` and tags a `boostV5_*`
   placeholder. Wire the second pass for `shadow`. Add files to the Xcode project; build; confirm NS
   shows `boostV5_*` and Trio dosing is identical to stock. **← start here.**
2. **V1 tiers** in `BoostDeterminationGenerator` (UAM boost tiers, percent-scale, cumulative-SMB cap,
   fast-carb handling, post-rescue guards) — port from `DetermineBasalBoost.kt`. Shadow-compare.
3. **V5 state machine** (meal score → states, aggression budget, deceleration brake) + Core Data
   state — port from `DetermineBasalBoostV5.kt` / `MealHypothesis.kt` / `AggressionBudget.kt`.
4. **HealthKit activity shadow** — HR + steps, activity-load + intraday factors, NS telemetry.
5. **ML inference** — hypo/meal scores feeding the budget throttle.
6. **Active mode + selector UI** — `boostMode = active` drives dosing; settings UI to pick the engine.

## Notes
- Build/test via Xcode (`xcodebuild` present); iOS loop is the gating cadence — verify per phase.
- Keep `BoostDeterminationGenerator` reusing Trio's helper modules so it tracks upstream oref changes.
- Shadow first, always: active is the same generator with output switched to dosing.
- Port reference (AAPS, Kotlin): `OpenAPSBoostPlugin.kt`, `DetermineBasalBoost.kt`,
  `openAPSBoostV5/*` (MealHypothesis, AggressionBudget, DetermineBasalBoostV5), `DailyStepHistoryTracker`,
  `WearStepSource`, `BoostRiskModel`.
