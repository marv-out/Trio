# Boost-in-Trio — audit record

Record of the adversarial code-review passes performed on the Boost→Trio port before it
shipped on `Boost-in-Trio-v0.1`. The goal throughout: verify the port is a **faithful
functional replica** of the AndroidAPS build the developer actually runs, and that stock
Trio dosing is untouched unless Boost is **Active**.

## Method

- **Source of truth:** the AndroidAPS branch `Boost-V6-mealtime-alpha` (a V5-**dosing**
  build). An earlier mistake — auditing against upstream AndroidAPS, where V5 is **shadow**
  — produced wrong conclusions; once re-anchored to the running build, the audits found
  real divergences the earlier passes had missed.
- **Technique:** multiple independent reviewers per pass, each given one slice (e.g. DynISF,
  V5 engine, ML, sleep/night, dosing seam, persistence), told to be adversarial, to report
  findings by severity with `file:line` on both sides, and to verify before claiming.
- **Severity:** 🔴 wrong/missing dose or state corruption · 🟠 high · 🟡 medium · 🟢 verified.
- **Two invariants checked every pass:** (1) **off/shadow byte-identical** to stock Trio;
  (2) the active path faithfully matches the AndroidAPS dosing.

## Passes & outcomes

### 3rd pass → commit `608c9fa`
`future_sens` low-temp leg split (`insulinReqSensitivity`), `deltaAccl` guard, sensNormalTarget
rounding, two dosing constants, +tests. Night-mode `start==end` wrap-branch parity (`8eef216`).

### 4th pass (5 reviewers) → `d91fef7`, `ad72112`
- **F1:** `boostPostExerciseEnabled` default `true`→`false` (AAPS parity).
- **F2:** night-mode low-TT gate was dead-wired; wired to the **base** profile target +
  active TT clamped to `LIMIT_TEMP_TARGET_BG` (72–200).
- **F3:** activity-monitor `refresh()` read-modify-write race → serialized.
- A clock-based "boost window" was prototyped (`7a24410`) then **reverted** (`dfa874a`) — it
  was the wrong mechanism (modelled on the shadow repo), per the re-baseline below.

### Re-baseline vs `Boost-V6-mealtime-alpha` (6 reviewers) — the decisive pass
This caught three criticals the AndroidAPS-anchored passes had missed:

| # | Finding | Resolution |
|---|---------|-----------|
| 🔴 | **Stale ML hypo model** — Trio shipped v9 (8-feature/50-tree); the running build uses **v12** (53-feature/100-tree + 6-cycle lag ring buffer). Every `mlHypoRisk` was from the wrong model. | Ported `BoostMlFeatureBuilder` + ring buffer + persistence; shipped the byte-identical v12 model; feature-count routing; 3dp rounding. `b7417eb` |
| 🔴 | **Stale sleep detector** — Trio had the HR-only generation; the running build is the 374-line **drought-based** detector. On sparse HealthKit HR, Trio could never reach SLEEPING → V5 dosed overnight where the running build suppresses it. | Ported the drought + transmission-resume detector; HR-readings input contract; sleep-gate on the V5 override (`61ae3c3`, `e4a53af`). |
| 🟠→inert | **flat-CGM `sensorQualityOk` gate** absent. | AndroidAPS only engages it for **Libre 1**; Trio's glucose carries no sensor type, so it is inert and matches for any non-Libre-1 CGM. No change needed. |

Plus: night-mode `sleepActive = state != AWAKE` so PRE_SLEEP counts (`05adcda`); ported
**SleepHistoryTracker** (learned night window + resting HR) (`02a6c08`).

### Final critical audit (direct find + 3 reviewers) → `7d72d48`, `5f06719`
- 🔴 **What-if state corruption (the key catch):** the bolus-calculator simulation path ran
  the full Boost V5 pass and **mutated persisted state** (ML ring buffer, V5 hypothesis
  state, meal-time history, `lastRunMs`) on every preview, corrupting the next real cycle.
  Fixed by threading a `simulation` flag and skipping the V5 pass for what-ifs (`5f06719`).
- 🔴→fixed **Loop-refresh cadence:** the sleep detector only advanced on HealthKit callbacks
  (which go quiet overnight), so the snapshot went stale and night-mode suppression silently
  disengaged. The APS loop now drives `refresh()` each cycle (gated to `boostMode != .off`).
- 🟡 shadow `enableSmbPreChecks` parity; `SleepDetectorState` decode robustness.
- The 3 reviewers found **no further** 🔴: simulation fix complete, injection safe (no crash),
  no deadlock, no double-invocation, **off/shadow byte-identical PASS**, active path PASS.

## Config-dependent items (confirmed not applicable)

These AndroidAPS features become divergences only if enabled, and are **inert at defaults**.
The developer confirmed all four are **disabled** in the standard running Boost, so Trio
matches at defaults and they were not ported:

- Boost time-window (`boost_start_time` / `boost_end_time`)
- Tuned sleep timings (pre-sleep lead / sleep / wake hysteresis ≠ 60/10/5)
- Use-TDD + Adjust-Sensitivity (`tdd24h/tdd7d` ratio)
- TT-sensitivity (high-/low-TT raises/lowers sensitivity)

## Deferred (developer's call)

- **Activity-load ("festival") telemetry** — ported but unwired; shadow-only logging, zero
  dosing effect.
- **Exercise / post-exercise** dose modifiers — inputs collected but not fed to dosing,
  pending shadow analysis.

## Final verdict

The port is a **verified faithful functional replica** of `Boost-V6-mealtime-alpha`. The V5
engine, DynISF/`future_sens`, the v12 + meal ML (models byte-identical), the drought sleep
detector, SleepHistoryTracker, and night mode all match the source line-by-line; both
invariants hold (**off/shadow byte-identical to stock Trio**, active path faithful); and the
what-if state-corruption bug — the one issue none of the determine-path audits found — is
fixed. Build green, 193 core tests passing (see `TESTS.md`).

> This is an audit record, not a clinical or safety certification. See `../../BOOST.md` for
> the safety/DIY disclaimer.
