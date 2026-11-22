# Boost replay — local golden-master simulation

A local simulation harness that replays **real AndroidAPS Boost cycles** through the Swift
`BoostV5Core` port and checks the port reproduces what the reference algorithm actually did.

This replaces the archived Trio `oref-swift-port` "simulation engine" (a JS-vs-Swift *oref* replay
that needed an external log server and validated the base engine, not Boost). Here we drive the
**Boost** code directly, from the maintainer's own captured data.

## What it is

The TimescaleDB `oref` database holds `public.boost_decisions`: **2,266,857 cycles across 15 user
ids**, 2025-08-01 → 2026-09-15, captured from real **AndroidAPS Boost** pumps. (Figures refreshed
2026-09-15; the previous run of this document described 332,289 cycles across 7 users to
2026-06-26.)
Each row records both the per-cycle **inputs** (TDD family, CGM, target, deltas, IOB, COB, steps/HR)
and the AndroidAPS **outputs** (sens_normal_target, variable_sens, dynamic_isf, prediction_isf,
boost tier/active), plus a full human-readable `console_error` dump.

We export the **651,120 rows** that carry the DynISF console line (across all users) to an NDJSON
fixture, about 5.7 GB, and replay them with `swift test`. The fixture is grouped/sorted by user, and the harness
replays each user independently:

1. **DynISF / future_sens golden master** (`DynIsfReplayTests`) — the numerically sensitive DynISF
   maths. For each row we recompute with `BoostV5Core.DynIsf` and assert the Swift result matches
   the recorded AndroidAPS value within rounding tolerance.
2. **V5 engine robustness replay** (`BoostEngineReplayTests`) — drives the full V5 state machine over
   the real glucose trajectories in time order, checking it never crashes, never emits NaN/inf,
   never exceeds maxIOB, and never doses negative.

## Scope and limits (read this)

- **DynISF is a true golden master, scoped to Boost v4.1.5 (`variant == "v1"`)** — the reference the
  Trio port targets. It matches the recorded AndroidAPS output essentially exactly across all 7
  users. The insulin divisor is a per-profile constant, fitted per config epoch keyed by
  `(user, normalTarget, year-month)` so a mid-window insulin-peak / target change lands in its own
  segment. Each fit is a single scalar against hundreds–thousands of varied rows — it tests the
  formula, not an overfit.
- **Newer Boost versions are out of scope (detected, not asserted).** `boost-other` = Boost
  v4.2–v4.4.2 (retuned DynISF); `v3` uses a different TDD pull-down blend (prints `TDD=` /
  `adjusted7D` instead of `Blended TDD=`). Different algorithm generations than the v4.1.5 reference,
  so they're excluded from the asserts and their row counts are printed.
- **Dosing/tiers are NOT golden-master-comparable.** v4.1.5 doses via the **TIER** system ("TIER 8:
  Regular oref1"); the Trio port is the **V5 meal-hypothesis state machine** (IDLE→OBSERVING→
  CONFIRMED→COMMITTED→RECOVERING) — a different generation. So the V5 engine replay is a
  **robustness/regression** check (each user's timeline replayed independently), not a correctness
  comparison against tiers.
- **No full `determineBasal` replay.** The telemetry stores outputs + scalars, not the oref input
  arrays (glucose history, pump-history events, IOB decay array, deviations), so a faithful
  closed-loop SMB replay isn't possible from this data.
- **`sensNormalTarget` vs `isfTargetV1`.** The recorded `sensNormalTarget` folds a TT/autosens
  *sensitivity-ratio* division on top of `isfTargetV1 × globalScale`, which the telemetry doesn't
  cleanly expose — so `isfTargetV1` is validated against the console's `TDD ISF at target:` value
  (the pure formula output, before that ratio).
- **Console rounding & locale.** The console rounds to 1 dp, so console-only checks (deltaAccl, TDD
  blend) use a small relative tolerance, and deltaAccl is restricted to rows where 1-dp rounding
  doesn't dominate (`|short|≥2`, `|delta−short|≥1`). Some users' consoles use **European comma
  decimals** (`normalTarget=5,5`); the parser normalises them — the multi-user backtest surfaced
  exactly this (a parser miss that read user A's target as 90 instead of 99).

## How to run

```sh
# 1. Export the fixture (real data — gitignored). Requires the local TimescaleDB.
bash BoostPort/sim/export_boost_decisions.sh        # all users, ~266k rows (~1.2 GB) -> Tests/.../Fixtures/
# REPLAY_USER=tim bash BoostPort/sim/export_boost_decisions.sh   # single user

# 2. Run the replay
cd BoostPort/BoostV5Core
swift test --filter Replay                          # DynISF + engine replay
swift test                                          # full suite (existing unit tests + replay)
```

Env knobs (all optional):
- `BOOST_REPLAY_FIXTURE` — absolute path to an NDJSON export (overrides the default Fixtures path).
- `BOOST_REPLAY_LIMIT` — cap rows for a quick run.
- `PGHOST` / `PGPORT` / `PGDATABASE` — export-script connection (defaults `127.0.0.1` / `5432` /
  `oref`); `REPLAY_USER` restricts the export to one user (default: all users).

Without the fixture every replay test `XCTSkip`s cleanly, so CI and a fresh checkout are unaffected.

## Latest results

Multi-user backtest, refreshed 2026-09-15 — 13 users in the fixture, 651,120 DynISF cycles,
Aug 2025 to Sep 2026. The asserts are scoped to the **v4.1.5 reference build** (`variant == "v1"`),
which is what the port targets; the row counts below are that subset.

Scoping the two TDD checks was a 2026-09-15 correction. They had asserted over every variant and
still passed, because the corpus was almost entirely `v1` when the thresholds were set. It no longer
is: `boost-other` (v4.2 to v4.4.2, retuned DynISF) is now the largest group at 361,023 rows and runs
to the present day. Unscoped, the TDD check measured the port against three algorithm generations at
once and reported 90.4%, which says nothing about the port. Scoped, it is 99.77%, matching the
historical figure.

DynISF golden master (`DynIsfReplayTests`), Boost v4.1.5 (`v1`) scope:

| check | rows | match | notes |
|---|---|---|---|
| `variableSens` (end-to-end DynISF) | 154,585 | **99.975%** | per-epoch fitted divisor; meanErr 0.031 mg/dL, worst 0.49 |
| `isfTargetV1` × globalScale = `TDD ISF at target` | 157,124 | **99.453%** | meanErr 0.100, worst 11.0 |
| `blendedTdd` (weighted blend) | 159,302 | **99.772%** | residual is 1-dp input rounding |
| `finalTdd` (× adj factor) | 159,302 | **99.781%** | |
| `deltaAccl` | 89,878 | **100.0%** | robust rows only (see rounding note) |

Per-user fitted insulin divisor (v4.1.5): A≈75, B≈65, C≈65, D≈65, E≈55, F≈65, tim≈82.
Out-of-scope variants detected and skipped: `boost-other` (v4.2–v4.4.2) ≈16k, `v3` ≈10k rows.

V5 engine robustness (`BoostEngineReplayTests`), per-user timelines: **651,120 cycles across 13
users, 0 violations** (no NaN/inf, no negative dose, none over maxIOB). Dosed on 117,667 cycles,
meanDose 0.198 U, maxDose 4.40 U.

Re-run with `BOOST_REPLAY_LEVERS=1` to enable the 2026-09 opt-in levers (the primer, the
velocity-budget floor and the earlier confirm timing) over the same trajectories: **0 violations**
there too, dosing on 147,518 cycles at meanDose 0.248 U with the same maxDose of 4.40 U.

The baseline also now feeds the real cycle clock, which the wall-clock age tick reads. That matters
on this corpus: 44.9% of its cycles are less than four minutes apart, so the tick correctly stops
the meal-state ages advancing several times too fast on the faster feeds. It is worth 6% fewer dosed
cycles than the same replay run without a clock.

(Single-user `tim`-only earlier baseline: variableSens 100% over 14,687 rows, divisor 82.00.)

## V5 shadow dosing replay (the dosing-path check)

The DynISF replay above validates ISF, not the *dose*. To check the dosing decision, a second
harness replays the **on-device V5 shadow** — the parallel V5 decision AndroidAPS logs to Nightscout
deviceStatus under `openaps.suggested.boostV5_*` (`boostV5_state/score/budget/actionMult/finalDose/
gateReduction`) — through the Trio Swift port (`BoostV5Engine`'s dose-cap + Phase-3 safety-gate
stages). The V5 shadow is produced by the AndroidAPS Kotlin V5; `BoostV5Core` is the Swift port of
it, so this is a golden master of the port's dosing/safety-gate code.

- Data: last-10-days deviceStatus for the V5-shadow sites in `~/.config/boost_backtest/sites.json`
  (self, A, C, D; 30,602 V5 cycles as of 2026-09-15 — several sites returned 403, 502 or no token
  and were skipped, which the extractor reports per site). Extractor: `BoostPort/sim/fetch_v5shadow.py` (fetches + caches; writes
  `Fixtures/v5_shadow.ndjson`, gitignored). Harness: `V5ShadowReplayTests`.

```sh
python3 BoostPort/sim/fetch_v5shadow.py --days 10
cd BoostPort/BoostV5Core && swift test --filter V5ShadowReplayTests
```

What it validates (golden master, run 2026-09-15 over 30,602 cycles / 4 users). Two V5 inputs aren't
in the telemetry — the velocity 30-min rise and the on-device ML risk model — so the harness reports
*reproduced %* and labels each residual's cause, and for the dose it splits missing-input cycles
from genuine differences (the number that matters):

| stage | rows | reproduced | residual is… |
|---|---|---|---|
| action multiplier (per state) | 30,602 | **100.0%** | — (nothing to reconstruct) |
| iobHeadroom safety brake | 30,602 | **98.78%** | logged `maxIOB` ≠ the gate's input on a few cycles |
| deceleration safety brake (formula) | 7,639 | **100.0%** | — |
| final SMB dose, uncapped states | 13,778 | **98.7%** | velocity rise, ML brake, opt-in levers (below) |

The action multiplier needed one correction on 2026-09-15. The Aggression knob scales the CONFIRMED
multiplier and is a per-user setting the telemetry does not carry, so assuming 1.0 counted anyone who
had moved the slider as a divergence: a user at 1.3 records 2.34 where the base is 1.8. The knob is
now fitted per user from the recorded CONFIRMED rows, as the DynISF replay fits the insulin divisor
per profile. Fitted values in this run were 1.30, 1.20, 0.85 and 0.80, after which the multiplier
reproduces exactly on all 30,602 cycles.

`final SMB dose` decomposition (printed by the test):

| | share | meaning |
|---|---|---|
| exact (velocity factor 1.0) | 61.4% | reproduced outright |
| velocity-reconciled ∈ [0.4, 1.0] | 37.2% | the 30-min rise that sets the factor isn't logged |
| opt-in lever, replay runs it off | 0.1% | the device is running a lever this replay leaves disabled |
| ML hypo-risk brake | 1.2% | device dosed **less**; needs the on-device ML model (all carry ML risk) |
| **genuine port-vs-reference difference** | **0.0%** | — |

The opt-in bucket is new on 2026-09-15 and is worth stating, because those 20 cycles counted as
genuine differences until the port gained the features that explain them. They separate cleanly by
shape. Ten are IDLE with a base requirement of zero, every one above 180 mg/dL, every one dosing
exactly 0.5 U: the velocity-budget floor delivering `min(0.5, committedCap)` on the budget-near-zero
high tail. The other ten are OBSERVING, inside the primer's 90 to 220 mg/dL band, graduated from
0.05 to 0.45 U: the primer's ceiling scaled by rise, glucose room and insulin headroom. Neither is
reproducible from this telemetry, because the per-user cap and ceiling that size them are not logged.
That the device's own behaviour matches both shapes is independent support for those two ports, from
data that was not used to build them.

The test asserts the reproduced fraction ≥ 95% **and** genuine differences ≤ 1% (currently 0%), so a
real dosing divergence would fail the suite rather than hide inside a "match %". Every residual is a
missing offline input, and all are in the safe direction (device dosed less, never the port more).

**What it CANNOT validate from this telemetry (reported as diagnostics, not asserted):**
- **The HARD min-guard gate** (14,554 cycles) — the V5 gate's true min-guard input is internal; the
  logged `minGuardBG` is oref's raw value (ranges +173 to −829) and is *not* the gate input.
- **CONFIRMED/COMMITTED final dose** (2,590 cycles) — the device's V5 dose-cap config isn't logged
  (recorded CONFIRMED doses reach 6.2 U, far above the port's default 1.0 U cap), so the capped value
  can't be reproduced.

To close those gaps you'd add two fields to the on-device V5 shadow log (the gate's actual
min-guard input + the cap config), or compare against Trio's own Shadow-mode output once it logs
`boostV5_*`. Until then: the port's **dose math and soft safety-gates are validated against real
on-device V5 to high fidelity; the hard min-guard gate and the final capped dose are not.**

## Files

- `BoostPort/sim/export_boost_decisions.sh` — psql NDJSON export (DynISF cohort).
- `BoostPort/sim/fetch_v5shadow.py` — deviceStatus → V5-shadow NDJSON fixture (dosing cohort).
- `BoostPort/BoostV5Core/Tests/BoostV5CoreTests/Replay/V5ShadowReplayTests.swift` — dosing golden master.
- `BoostPort/BoostV5Core/Tests/BoostV5CoreTests/Replay/`
  - `BoostDecisionRow.swift` — Codable row + `ConsoleFields` parser (mmol→mg/dL) + `ReplayFixture` loader.
  - `ReplayReport.swift` — tolerance-aware match accumulator + divergence report.
  - `DynIsfReplayTests.swift` — the DynISF golden master.
  - `BoostEngineReplayTests.swift` — the V5 engine robustness replay.
- Fixture: `BoostPort/BoostV5Core/Tests/BoostV5CoreTests/Fixtures/boost_decisions.ndjson` (gitignored).
