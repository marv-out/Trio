# Boost-in-Trio — test record

Authoritative record of the `BoostV5Core` unit-test suite for the `Boost-in-Trio-v0.1`
branch. `BoostV5Core` is the pure (no Trio/HealthKit deps) package that holds the
dosing-critical logic, so it is unit-testable in isolation and deterministic.

## How to reproduce

```sh
cd BoostPort/BoostV5Core
swift test --enable-test-discovery
```

The full app is additionally compiled via `xcodebuild` against the Trio workspace
(`-scheme Trio`, iOS Simulator, `CODE_SIGNING_ALLOWED=NO`) — every commit on this branch
was confirmed to build with **exit 0** before landing.

## Last run

- **Date:** 2026-06-24
- **Result:** **193 tests, 0 failures** across 16 suites.
- **Trio app build:** `xcodebuild` exit 0.

| Suite | Tests | Result |
|-------|------:|:------:|
| ActivityClassifierTests | 15 | ✅ |
| ActivityLoadTrackerTests | 21 | ✅ |
| AggressionBudgetTests | 7 | ✅ |
| BoostMlFeatureBuilderTests | 6 | ✅ |
| BoostTreeModelTests | 4 | ✅ |
| BoostV5EngineTests | 7 | ✅ |
| CircadianISFTests | 6 | ✅ |
| DynIsfTests | 19 | ✅ |
| IsfShadowEmaTests | 14 | ✅ |
| MealHypothesisTests | 16 | ✅ |
| MealSignalScoreTests | 9 | ✅ |
| MealTimeLearnerTests | 14 | ✅ |
| NightModeTests | 10 | ✅ |
| PostExerciseRecoveryTests | 14 | ✅ |
| SleepHistoryTrackerTests | 10 | ✅ |
| SleepStateDetectorTests | 21 | ✅ |
| **Total** | **193** | **0 failures** |

## Coverage notes

The suite asserts the dosing-relevant constants and behaviour against the AndroidAPS
`Boost-V6-mealtime-alpha` source — e.g. DynISF/`future_sens` formulas and soft caps, the
V5 state-machine thresholds and transitions, signal-score weights, aggression-budget
floors and the hypo-caution inversion, the Phase-3 safety gates (incl. that none fail
open), the v12 ML feature builder + 6-cycle ring buffer (push/lag/serialize), the
drought-based sleep detector (drought + transmission-resume), SleepHistoryTracker
(circular mean, p10/median, 28-day trim, learned-vs-configured fallback), and the
night-mode gate logic.

Suite/count growth tracked the port: 175 (3rd-pass) → 176 → 177 → 183 (v12 ML feature
builder) → 193 (SleepHistoryTracker), all green.
