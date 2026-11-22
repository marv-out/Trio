# Boost-in-Trio

A faithful functional port of the AndroidAPS **"Boost"** algorithm into [Trio](https://github.com/nightscout/Trio) (iOS). It runs as an optional, mode-gated second pass over Trio's existing oref determination — so stock Trio behaviour is preserved unless you explicitly turn Boost **Active**.

> **Branches** (tim2000s/Trio, from 18 November 2026): `main` and `dev` follow nightscout's; `dev` also carries Adaptive Smoothing (PR #1302's branch `adaptive-smoothing`). `boost-in-trio` is `dev` plus Boost, and every Boost change lands there; nightscout `dev` is merged into `dev` and then `dev` into `boost-in-trio`. Earlier branches are kept as `archive/<name>` tags.
> **Source of truth:** the AndroidAPS branch `Boost-V6-mealtime-alpha` (a V5‑dosing build) — the port is verified line‑by‑line against it, not against upstream AndroidAPS.

---

## ⚠️ Safety / disclaimer

This is **experimental, do‑it‑yourself, open‑source software for an automated insulin‑delivery system**. It is **not** a medical device, is **not** approved by any regulator, and carries **no warranty**. It is not affiliated with or endorsed by the Trio or Nightscout projects.

Automated insulin dosing can cause serious harm, including severe hypoglycaemia. **You are solely responsible** for any device you build and run. Do not use this unless you fully understand the algorithm, can read the code, and accept the risk. Start in **Shadow** mode and review the logs before considering **Active**.

---

## What Boost is

Boost is an SMB‑centric dosing layer originally built for AndroidAPS. The port brings three pieces of that algorithm into Trio:

- **Dynamic ISF (V1)** — a TDD/BG‑context sensitivity model (`sensNormalTarget = 1800 / (TDD·ln(normalTarget/divisor+1))`, velocity‑blended `variable_sens`, soft BG caps, optional circadian curve). With Use TDD on, the TDD model owns sensitivity and oref autosens is not applied. With Use TDD off, BG impact on ISF is 0 and the profile ISF is used flat; with Autosens without TDD on (the default), the oref autosens ratio divides the ISF at target and scales basal, the autosens target shift and carb absorption, as in stock oref (AAPS `3d9d471dbb`, `1c6358ac6c`). A separate **`future_sens`** computes a BG‑context‑weighted dosing ISF used only for the insulin‑requirement maths.
- V1 tier engine: AAPS's `DetermineBasalBoost.determine_basal` (ported October 2026 as `BoostV1Engine`): oref1 with Boost's per‑BG ISF in the predictions, `future_sens` for dosing, a target raised when the hypo prediction is low, a 30% maxDelta SMB limit, a 40‑minute low‑glucose suspend test, and eight SMB tiers (carb handling, UAM Boost, UAM High Boost, percent scale, acceleration, enhanced and regular oref1) with the G3 pre‑UAM hold, fast‑carb and post‑rescue scaling, the ML risk scale and tier downgrade, the cumulative 60‑minute cap and a 5× basal high temp while a tier is driving. In Boost active mode it is the determination. V6 replaces its SMB on the cycles V6 runs; its dose bounds V6 in the non‑meal states and the post‑rescue window, and it is what is delivered whenever V6 stands aside (asleep, Boost inactive, night window).
- **V5 meal engine** — a meal‑hypothesis **state machine** (IDLE → OBSERVING → CONFIRMED → COMMITTED → RECOVERING) driven by a continuous meal‑likelihood **signal score**, an **aggression budget**, per‑state **action multipliers**, and an ordered **Phase‑3 safety‑gate** stack. Two LightGBM models (hypo‑risk + meal‑likelihood) feed the score and damping.
- **V6 + environment** — anticipatory pre‑meal target, learned night window / sleep detection, and the activity/HR plumbing that shapes the inputs.

When Active, V5's computed SMB **overrides** the stock determination's SMB on cycles where a microbolus is allowed — exactly as the AndroidAPS build does.

## Modes (the safety gate)

Set under **Settings → Features → Boost (V6)**:

| Mode | Behaviour |
|------|-----------|
| **Off** | Stock Trio only. The entire Boost pass is skipped. |
| **Shadow (log only)** | Runs the full Boost engine and appends *what it would do* to the determination reason. **Does not change dosing** — output is byte‑identical to stock Trio. |
| **Active (doses)** | The V1 tier engine is the determination and V5 drives the SMB on the cycles it runs. |

**Shadow‑safety contract:** with mode `Off` or `Shadow`, the dosing output (units, rate, insulinReq, forecasts) is **byte‑identical to stock Trio** — every dosing‑affecting change is gated on `== .active`. This is verified by audit and is the foundation for evaluating Boost safely before enabling it.

## Architecture

```
BoostPort/BoostV5Core/            ← pure SwiftPM package (no Trio/HealthKit deps), unit-tested
  DynIsf, CircadianISF            ← DynISF V1 + future_sens maths
  BoostV1Engine                   ← V1 tier engine (DetermineBasalBoost), parity-checked against AAPS
  BoostV5Engine, MealHypothesis,  ← V5 state machine + score + budget + gates
  MealSignalScore, AggressionBudget, SafetyGates
  BoostTreeModel, BoostMlFeatureBuilder  ← LightGBM inference + v12 feature/ring-buffer builder
  SleepStateDetector, SleepHistoryTracker, NightMode, ActivityClassifier
  …

Trio/Sources/APS/OpenAPSSwift/Boost/   ← Trio-side glue
  BoostISF                        ← DynISF wiring into the determination
  BoostV1Determination            ← builds the V1 engine's inputs as OpenAPSBoostPlugin does; Boost-active determination
  BoostV5Adapter                  ← assembles V5 inputs, runs the engine, ML features, night mode
  BoostMLModels                   ← loads the bundled models + ring-buffer persistence
  BoostActivityStore / BoostMealTimeStore   ← UserDefaults-backed snapshots/history

Trio/Sources/Services/HealthKit/BoostActivityMonitor.swift  ← steps + HR → sleep/activity state
```

`BoostV5Core` is a pure package compiled **into** the Trio target (deterministic, unit‑testable in isolation). The glue layer adapts Trio's models and HealthKit to the core, and the second pass lives in `OpenAPSSwift.determineBasal`.

## Enabling it

1. **Settings → Features → Boost (V6)** → pick **Shadow** first.
2. Review the determination `reason` (and Nightscout devicestatus) — Boost logs its hypothesis state, score, and would‑be SMB each cycle.
3. Tune the V6 knobs and DynISF if needed (see below).
4. Only switch to **Active** once you understand the shadow behaviour and accept the risk.

For sleep/night features to work, grant **Health** read access (steps + heart rate) when prompted; until then they are silently inert.

## Settings

Under **Settings → Features**, the Boost sections are:

- **Boost (V6)** — mode (Off / Shadow / Active).
- **Boost V6 Tuning** — Aggression, Hypo Caution, Sensitivity, Confirmed/Committed dose caps, fast‑carb confirm.
- **Boost Dynamic ISF** — Use TDD, Autosens without TDD (shown with Use TDD off), Circadian ISF, normal target, BG cap, velocity % (shown with Use TDD on; set to 0 when Use TDD is switched off and to 100 when it is switched on), adjustment factor %.
- **Boost Night Mode** — overnight SMB suppression: window, BG offset, disable‑with‑COB / low‑TT, auto‑by‑sleep.
- **Boost V6 Pre‑Meal** — anticipatory lower‑only target before learned meal times.
- **Boost Exercise — Steps / Heart Rate / Post‑Exercise** — activity classification inputs (see *Deferred* below).

Glucose‑valued settings respect your mmol/L vs mg/dL display unit.

Each setting shows its description under its title, as AAPS Boost does. The texts are the AAPS
Boost 6.3.2 preference summaries, with Health Connect and Wear OS replaced by Apple Health and night
times given in hours. The primer has one switch, Force primer as bolus, as in AAPS; the temp-basal
route behind it is auto-config's and no longer appears on the screen. The re-evaluation still treats a
temp-basal route it did not record writing as the person's, which now covers only values set before
the switch was removed.

## Auto‑configuration (first activation)

The first time Boost is switched to **Active**, it **seeds the V6 knobs from your own recent dosing
history** (last 14 days) instead of dropping you onto generic defaults — the same principle, and the
**same pure calculator**, as the AndroidAPS build (`BoostV5AutoConfig`, in `BoostV5Core`, shared by
both platforms and verified in numeric parity). Because it reads only dosing history + glycaemia, it
works from **standard oref** — you don't need to have come from a Boost install.

**How it behaves (the guard‑rails):**
- Runs in the background on Active cycles, with **per‑knob resolution** (`boostV5AutoConfigResolved`, mirrors AAPS b2c0705e5e): each knob is attempted until it has either been **applied once** or been **skipped because you tuned it** — both mark it resolved and it is never revisited. Knobs added to auto‑config in a later update still get derived on existing installs. The legacy global one‑shot flag (`boostV5AutoConfigDone`) migrates on first run: knobs you moved off factory default stay untouched forever; knobs still at stock become derivable again.
- **Suggestion‑only.** Aggression / Hypo‑Caution / fast‑carb only ever move in the *protective* direction, and seed only while still **at a factory default** — *any* factory default that setting ever shipped with (the cap defaults changed on 2026‑06‑26, so a value carried over from an older build still counts as untouched; a value merely *persisted at* a default — e.g. a settings import — never blocks a suggestion). The two **dosing caps** and the cumulative cap are additionally gated on an explicit **per‑knob “user‑touched” flag** — set only when you move that cap's slider (`onEditingChanged`, never programmatically) — so auto‑config can seed a cap (and raise it for a genuine new user) but **never overrides a cap you set yourself**, even one you set to the default value.
- Needs **≥ 7 days of data and ≥ 1500 CGM readings**, or it does nothing and **retries on a later cycle**.
- **Never raises aggression** above neutral on day one; safety knobs only ever *tighten*.
- **Wrapped so any failure is logged and swallowed** — it can never block or alter the dose path.

**How it determines each setting (the exact rules — identical to AndroidAPS):** it gathers, over the
last 14 days, your **true TDD** (from `TDDStorage.calculateTDD`, with a **5–200 U/day sanity guard** and
a conservative **bolus‑only fallback** if pump TDD is unavailable/implausible), your **meal‑bolus and SMB
sizes** (split from pump history), your **time‑below‑range** (% < 70 and % < 54 mg/dL), and your existing
**max‑IOB / max‑bolus**. Then:

| Setting (range) | Rule |
|---|---|
| **HypoCaution** (1.0–2.0) | `clamp(1.0 + max(0, TBR<70% − 4)/4 + max(0, TBR<54% − 1)×0.5, 1.0, 2.0)` |
| **Aggression** (0.7–1.6) | `0.85` if hypo‑prone (TBR<54% > 1.5 **or** TBR<70% > 6%); `0.92` if TBR<70% > 4%; else **1.0**. Never above 1.0. |
| **Confirmed cap** (0–7.5 U) | `clamp(max(p90 meal boluses, p95 SMBs), 1.5, 7.5)` — the meal‑bolus p90 only participates with **≥ 10 manual boluses** in the window (a percentile of a handful of boluses is noise, not a habit); below that the cap comes from the SMB p95 alone. |
| **Committed cap** (0–5.0 U) | `clamp(max(p75 SMBs, TDD/40), 0.25, 5.0)` — whichever of the two terms is larger, so above 2.5 U only for a median TDD above 100 U or an SMB 75th percentile above 2.5 U. Re-derivation scales the current cap, including one set by hand, with the derivation, at most 25% a run and never above 5.0 U. |
| **Cumulative SMB cap / 60 min** | `clamp(Confirmed + 2×Committed, 1.0, 10.0)` — one confirm shot plus two holds per hour, clamped only to the preference range. Computed from the **final operative** per‑shot caps (kept‑or‑derived), so a kept user value sizes the hourly budget, not a derivation that never applied. Written to `boostCumulativeSmbCap60Min`; the active override enforces it as the rolling‑60‑min anti‑stacking cap. |
| **Bolus cap** | carried from your pump's max bolus (clamped). Boost max IOB is not auto-configured: at its 12 U default Boost uses your max IOB. |
| **Fast‑carb confirm** | **off** if hypo‑prone, otherwise on. |

**TBR raise‑guard:** a dose‑cap **raise** (Confirmed / Committed / Cumulative going *up* from the
current value) is **not auto‑applied when 14‑day time‑below‑70 exceeds 4%** — it is surfaced as a
suggestion in the notification instead (set it manually if desired). Lowerings and all non‑cap
tightenings always apply.

Run now, and the override (November 2026, Trio and AAPS). Advanced Boost has a "Run auto-config now"
action. It runs the weekly re-derivation immediately (28-day window, which restarts the 7-day clock)
with Boost Active, once first set-up has resolved every knob and at least 24 hours after the last run
of either kind, and lists what each setting did. The 24 hours is there because each run moves a cap
at most a quarter of the way and some changes wait for two runs to agree, so repeated presses would
otherwise step a cap up within minutes. Its dialog has an
"Override hypo protections" switch, off each time the dialog opens. With it on, that one run does not
apply the raise guard (time below 70 mg/dL over 4.0%, or below 54 mg/dL at 1.0% or more) to the dose
caps, aggression, hypo caution, the cumulative cap, the primer, or the two insulin-adding switches. The
deadband, the confirmation filter and every value's own bounds still apply. Scheduled runs never take
the override. A run where the override lifts a guard keeps its votes (values waiting to repeat, and
the two switches' verdicts) in a ledger of their own, and any other run clears that ledger, so an
overridden vote is confirmed only by the very next run being overridden too. This can add insulin, and only when the person chooses it.

A well‑controlled user lands on a fully neutral config (Aggression 1.0, HypoCaution 1.0, fast‑carb on);
a low‑prone user gets gentler aggression, more hypo damping, tighter caps, and fast‑carb off — all in the
conservative direction.

**Testing.** The derivation was validated against **12 real users from a research database** (an
OpenAPS/Trio cohort and an AndroidAPS cohort, 400–720 days each): each user's real history produced their
knobs, which were then run through the Boost engine over the user's own logged cycles and probed for
danger — **no dangerous dosing** (dose‑into‑low ≤ 0.2% of cycles, blocked by the hard *minGuardBG ≥ 80*
gate; protective knobs *reduced* lows 15–24% for hypo‑prone users; never more aggressive than the
engine's default). The calculator itself ships unit tests in `BoostV5Core` (clamps, percentile
interpolation, hypo‑prone vs neutral, big‑meal cap coverage, the cumulative‑cap invariant), and a
2026‑06‑26 adversarial review specifically hardened the cap‑seeding (the user‑touched flag above) and the
active‑override safety envelope. See the AndroidAPS `BOOST.md` §3 for the full write‑up.

## Overnight behaviour

This mirrors the running AndroidAPS build:

1. A **drought‑based sleep detector** (HR + steps + clock, with HR‑drought and transmission‑resume handling) decides SLEEPING — robust to the sparse overnight HR HealthKit typically provides. Since 2026‑10‑08 (AAPS `5a1c852a57`) a transmission‑resume burst in the core night wakes the detector only with at least 20 steps (15‑min bucket or 60‑min cumulative growth), because watches that upload HR in batches produce such a burst every 15 to 30 minutes with nobody awake. Within 90 minutes of the scheduled wake the burst alone still wakes.
2. While asleep, **V6 stops overriding the SMB** and the de‑aggressed base dose stands.
3. The Boost gate closes inside the configured night window whatever the night‑mode toggle says, and whenever the detector reads SLEEPING (AAPS `47a815aedf`). The detector can close the gate but cannot reopen it inside the window, and carbs on board do not reopen it. With the gate closed there is no V6 dosing and the base oref SMB stands. Before this change a user with night mode off had the gate open all night. For one hysteresis period plus one cycle (15 minutes) after the detector leaves SLEEPING by its clock boundary, the gate and the inactivity exclusion still treat the user as asleep (AAPS `a33752c9aa` #18).
4. **Night mode** suppresses SMB on top of that within the night window.
5. A **SleepHistoryTracker** learns your habitual night window and resting HR over ~28 days (≥7 sessions) and feeds them to the detector; below that threshold it uses the configured values.
6. The V6 pre‑meal target applies only outside the configured night window, with the detector neither SLEEPING nor PRE_SLEEP, with no temp target and outside the post‑rescue window; a suppressed target is logged as `V6 pre-meal SUPPRESSED (<why>)`. The meal‑time learner records a session only when it starts outside the window with the detector AWAKE, and learned sessions that fall inside the window are dropped from the stored history (AAPS `a33752c9aa` #8).

The activity classifier runs whatever the gate says, so exercise inside the night window keeps its reduced profile and raised target. Only the inactivity raise, which adds insulin, needs the gate open (AAPS `a33752c9aa` #11). With heart‑rate integration on, the raise also needs heart rate in zone 1: zone 2 and above (easy cycling or rowing with almost no steps) withholds it as HR_ELEVATED (AAPS `477e649338`), and no usable heart rate, whether none in the window or a frozen value, withholds it as HR_UNAVAILABLE (AAPS `a33752c9aa` #12). Neither changes the target or starts exercise handling.

The sleep detector is advanced on the loop cadence (not only on HealthKit callbacks) so it cannot go stale overnight.

## Faithfulness, and what is intentionally different

**Verified faithful to `Boost-V6-mealtime-alpha`:** the V5 engine (every state‑machine threshold, signal‑score weight, aggression budget, and safety gate), the DynISF/`future_sens` maths, the **v12 hypo‑risk model** (53‑feature vector + 6‑cycle lag ring buffer; model JSON byte‑identical) and the 8‑feature meal model, the drought sleep detector, SleepHistoryTracker, and night mode.

**Intentionally different / deferred:**
- **Activity‑load (festival) telemetry** — ported but **not wired** (shadow‑only logging; zero dosing effect). Deferred.
- **Exercise / post‑exercise** modifiers — **now wired live** (2026‑07, AAPS `2a9d096d8b`): `exerciseActive` / `inPostExerciseWindow` from the activity classifier feed the V6 meal‑score exercise damping, the fast‑confirm `!exercising` gate, and the AggressionBudget post‑exercise damper. (STRESS is never classified in Trio, matching AAPS dead‑code parity.)
- **Composed Phase‑3 brake floor** (2026‑07, AAPS `e0f18ddd0e` + `730b3dcb2c`) — ported as the **default‑OFF** "Phase‑3 composed brake floor" Advanced toggle. When ON (and V6 is the active doser), floors the delivered dose at F=0.25 of the hypo‑damped budget on meal‑session high cycles, so the multiplicative brake stack (median 0.037) can't round a mid‑meal dose to zero. The per‑user TBR gate is now **ENFORCED in code** (2026‑07‑08, AAPS `9110ef2520` + `8b492a08e7`): the floor engages only while trailing‑14d **TBR<63 < 2.0% AND TBR<70 < 3.5%**, fail‑closed (a hypo‑prone user can't get the insulin‑adding floor even if toggled on). Trio computes those from an hourly‑throttled 14d BG scan in `APSManager` (fed to `BoostComposedFloorGate`) and ANDs it into `composedFloorActive`. Toggle OFF is bit‑identical to before.
- **Degraded‑HR sleep fallback + steps‑alone wake** (2026‑07‑08, AAPS `dea9d300ff`) — the sleep detector now treats an *intermittent* HR feed (< 3 fresh samples/15 min, not just fully dead) as unreliable so a degraded overnight feed still reaches SLEEPING on the clock (entry reason "time"); stray samples no longer reset the drought clock. Wake adds a **steps‑alone rule** (≥ 250 cumulative steps, reason "steps") that fires only when HR is unreliable, while the gentle HR+steps rule is time‑gated to ±90 min of scheduled wake. Fixes the 3‑night stuck‑in‑PRE_SLEEP failure. Wake‑learner trains on "steps" too.
- **V6 meal state and dose seam, October 2026** (AAPS `82f47416c5`, `c237a4d081`, `6ab6cf9e3d`, `a33752c9aa` items 1 and 10). An announced meal (carbs on board, or a manual, wizard or external bolus within 120 minutes) confirms into COMMITTED rather than the 1.8x CONFIRMED shot, and receives no OBSERVING primer. One confirm per meal: the session lock survives the RECOVERING to IDLE exit and any reset, and is released 90 minutes after the last CONFIRMED or COMMITTED cycle or after 30 minutes of unbroken non‑positive deltas; inside it a rise re‑engages COMMITTED through the slow path only. A meal state whose clock anchor is more than 30 minutes old is reset, OBSERVING peaks expire after 30 minutes, and the sustained‑score early confirm needs a four‑minute run rather than two invocations. The primer is sized after Phase 3, never fires when a hard gate did, is scaled by the mlHypoRisk damper, and in bolus mode only the primer itself escapes the V1 bound. The confirm‑tranche release is dropped outside COMMITTED, on a hard gate, in the post‑rescue window and on any cycle where the override did not run, and is clamped to the maxIOB and CONFIRMED‑cap headroom; the primer temp‑basal route reads the running temp when the base engine returns no rate. The meal‑state reset triggers are wired from what Trio holds: the pump's suspend state from pump history, and a change in the insulin‑scaling override, which is the analogue of an AAPS percentage profile switch. Three differences from AAPS, each a modelling choice: `loopSuspended` stays false, since Trio has no timed loop suspension and a loop that stops running is caught by the staleness reset; an edit to the stored profile schedule is not detected as a switch, because schedule values change at every block boundary; and, since the V1 port, the tranche ceiling is min(Boost max IOB, max IOB) as in AAPS. AAPS `a33752c9aa` item 9 (V1's tier SMB capped at base oref when V6 returns no decision) is N/A: it guards V6 throwing, and Trio's V6 engine is a non‑throwing pure function, so the case cannot arise.
- V1 tier engine, October 2026. `BoostV1Engine` is a line‑for‑line port of `DetermineBasalBoost.determine_basal` at AAPS `origin/dev` `579fc0cd19`. Its parity was checked against the real Kotlin engine on 60,000 generated cycles (tim2000s/trio-boost-v1-parity), every RT field to 1e‑9 and every prediction series exactly, with no mismatch; every tier was reached at least 359 times. The inputs are built as `OpenAPSBoostPlugin` builds them: the override‑adjusted profile ISF scaled by the activity profile %, `variable_sens` and `sensNormalTarget` from the Boost ISF, the profile targets with an override target and the V6 pre‑meal target, the oref autosens ratio where it applies, the 60‑ and 45‑minute glucose lows, the SMB volume and age from pump history, the post‑exercise recovery scale on the bolus cap and the boost scale, and the Boost gate. The V1 settings (bolus cap, insulinReq %, boost scale, percent scale and its switch, Boost with a high temp target) are not shown in the settings screens; auto‑config carries the user's max bolus into the bolus cap, as AAPS does, and the rest keep AAPS's defaults. The port also hid Boost max IOB, on the belief that AAPS's V6 screen does not show it; it does (as an essential), and the hidden 1 U default stopped daytime SMBs (the Boost max IOB entry below). The ML models run inside V1 with its own insulinReq and target, and V6 reads their scores from it, as AAPS's V6 reads `rT.mlHypoRisk`. The composed post‑rescue rebound guard and its tight‑ramp trial arm moved from the V6 seam into V1, where AAPS applies them. Two Trio levers remain: the master SMB switch and the scheduled SMB‑off window remove the engine's microbolus permission. Not ported with it: the activity classifier's target change (`targetBgMgdl`) still does not reach the targets, as before the port, and the flat‑CGM flag is always false (Libre 1 only in AAPS).
- Boost 6.3.0 on AAPS 4.0.0, November 2026. Synced to tag `4.0.0-boost-6.3.0` (granular history on `boost-public-candidate-4.0.0` in the 4.0 checkout); the next re-sync starts there. Ported, all gated on Boost active: COMMITTED held until the rise is below 3 mg/dL per 5 min, and RECOVERING re-entering COMMITTED above 8; the primer opened by a sustained rise (short average at least 3) instead of acceleration, and withheld once the session has committed; RECOVERING capped at the committed cap; the budget floor divided by Hypo Caution above 1.0; the V6 rapid-rise check on the largest of the latest change and the two averages; aggressive early confirm also held by the 14-day TBR gate; V1's accelerating-rise threshold needing a rise and never going below the LGS setting; V1's low zero temps tagged `lowSuspend=1; ` and the V6 override skipped on such a cycle; the 15 and 20 minute ceilings on the SMB basal minutes (replaced in 6.3.2, next entry); percent scale on by default for new installs, a stored value kept; re-derivation holding every insulin-adding move under the TBR guard, never raising aggression above 1.0, keeping a cumulative cap or primer the user set (a written ledger in `BoostRedriveStore`) and holding a larger primer under the guard; the weekly re-evaluation of the primer route and of the two insulin-adding switches; the sleep pre-window hold with its two wake routes and steps alone ending sleep in the 90 minutes before night end; the lie-in starting at the learned night end and ended by a genuine wake (until the lie-in hold was ported, entry below, only a wake in the 90 minutes before night end could count in Trio); learned sleep times converted at each session's own UTC offset. Not yet ported: the per-person tranche threshold derived from 45 days of confirm episodes (it needs the V6 state history, which Trio keeps only in determination reasons), the insulin-need watch (a notification, no dosing), the hourly retry limit on unfinished onboarding, wake step growth measured on watch and phone separately (Trio takes the largest per-source HealthKit day total), and the two smoother changes (a backwards step of up to 5 minutes no longer resetting learning, and the persistent bucketing anchor), which wait for the three-way rolling replay this repository requires. Shadow-only additions (the V13 hypo model, the four-column hypo shadow, the VWA-TDD shadow and the two bedtime estimates), the device-age telemetry and the Health Connect, Wear and step-sensor mechanics are N/A. One difference remains: the percent-scale default reaches no existing install, because Trio stores the whole preferences struct, so every install already holds the old `false` and has no setting to change it.
- Boost max IOB defaults to 12 U and uses max IOB below that, 17 November 2026, agreed for both apps (AAPS's change is made separately in its own repository). Boost max IOB is shown on the Boost screen, beside Aggression and Hypo Caution, from 0.1 to 12 U. Boost uses min(Boost max IOB, max IOB), read from the profile on every cycle, and passes that reduced value to V1 as AAPS passes `boost_maxIOB`. At the default of 12 U, the setting's maximum, Boost therefore uses max IOB, follows a change to it, stops at 12 U (as AAPS does) and is 0 in a dosing mode that sets max IOB to 0. A lower value is the person's own limit. The value feeds the V1 tier guards (`iob < boostMaxIOB`), their clamps and the spike override, and V6's ceiling, its headroom brake, the primer's headroom factor (1 − IOB/ceiling) and the confirm-tranche ceiling. Auto-config no longer writes it, in onboarding or the weekly re-derivation, since a written copy would read as the person's value and stop following. The default is the maximum rather than a 0 meaning "follow" so that the way back is safe: an older build reads the stored value raw, and its decode clamp would turn 0 into 0.1 U, where 12 stays bounded by max IOB. Why: the port kept the setting hidden at AAPS's 1.0 U default until onboarding copied max IOB into it, which needs seven days of Trio's own history and never happened on a one-minute CGM (fixed separately). In a non-meal state the seam delivers min(V6, V1), and V6 was clamped to 1.0 U minus IOB, so from 1 U on board every daytime cycle with the Boost gate open delivered 0 U; between 0.5 and 1 U the brake scaled it to 85, 60 or 40%. Migration differs from AAPS: no Trio user could have chosen a value, so every stored value from before this change (the factory 1.0, an onboarding copy, or an imported value) is set to 12 once, marked by `boostMaxIOBMigrated` in the stored preferences. AAPS, which has had the setting on screen, resets only its factory 1.0 and auto-config's copies. Direction: adds insulin wherever the old ceiling was below the current max IOB. Max IOB, the per-shot caps and the rolling 60-minute SMB cap still bound every dose, and V1's own max IOB clamps bound a set value above a later-lowered max IOB. Evidence for keeping a separate limit rather than using max IOB outright (boost-experiments `3759ff4` to `f0d0fc1`, AAPS logs): with the cap lifted, 13.7% (12.2 to 15.1) of capped runs would have gone below 70 even after a zero temp (a figure that still includes one person's runs held at 1.0 U by the AAPS Simple Mode bug), while Boost's excess lows against oref are at low IOB (below 30% of max IOB) and not shown near the ceiling, where the intervals are wide. No factor below 100% is used, because no IOB fraction marks where Boost's lows rise.
- Boost 6.3.2 on AAPS 4.0.0, 8 November 2026. Synced to tag `4.0.0-boost-6.3.2`; 6.3.1 changed only AAPS preference handling of the night mode offset, which Trio stores in mg/dL without unit detection, so it had nothing to port. Ported: the SMB basal minutes become starting values. The 6.3.0 clamp to 15 and 20 minutes is removed, and the first cycle with Boost active lowers each of the two settings that is above 15 (standard) or 20 (UAM) to that value, once, with an alert; afterwards either setting is the person's to change, including above the starting values. This differs from AAPS, which writes a seed only where nothing is stored. Trio stores the whole preferences struct, so nothing is ever unstored, and Trio's 6.3.0 clamp acted at read time where the AAPS ceiling rewrote the settings, so an AAPS install reaches 6.3.2 at or below the seeds and a Trio install does not. Lowering once reproduces the AAPS state and doses no more than the clamp did; its cost is that a value above the seeds set by hand before Boost was first active is lowered once. Review before pushing found two more: re-derivation now waits until onboarding has resolved every knob, as AAPS does, so a switch it writes is not later taken by onboarding as set by the person; and the weekly primer-route re-evaluation moves a temp-basal route back to the bolus only where auto-config recorded writing the temp basal, because Trio, unlike AAPS, has a settings toggle for the route, so an unrecorded value may be the person's. A once-only flag (`boost.smbBasalMinutesSeeded` in UserDefaults) stands in for AAPS's stored-key check. Two cases add insulin against `111c3f47a`, both matching AAPS 6.3.2 where a value is the person's: a setting raised by hand after the first active cycle, and an override preset with its own SMB minutes, which the clamp held and which now reaches V1 as set. Shadow mode sizes its would-be dose at the unseeded values until Boost is first active, and the seeded values stay when Boost is switched off. The V6 pre-meal target being shown in the profile's units needed no change, since Trio's slider already converts it. N/A, as AAPS framework: the reset of SMB minutes on import from AAPS without Boost, the Boost overview as start screen with its stale-result marker and tab-row setting, and the blank watch complications out of contact.
- The morning lie-in held in the sleep detector, 12 November 2026 (AAPS `3111f79ee2`, committed in July as V7-shadow only and so skipped by the port, and live in 6.3.2, which passes the sleep-in hours and steps to the detector). SLEEPING is now held from night end (the learned one where later) for the sleep-in hours, and the hard boundary exit moves to the end of that window. Inside it three routes end sleep: 60-min step growth at the sleep-in steps setting with no HR needed, the HR plus steps wake (until now trusted only in the 90 minutes before night end), and an HR burst after a drought without steps. All three train the wake learner. The two step routes also stand the lie-in failsafe down for the rest of the morning; the burst does not, so after a burst alone Boost stays off until the 60-min steps reach the setting, as in AAPS. Every steps-alone route, including the pre-window one, now uses the sleep-in steps setting in place of the fixed 250 (equal at the default). Also ported, from the same unified threshold (AAPS `68ec1e2603`, July, part of the 6.2.0 squash and missed by the October port): PRE_SLEEP ends at once on 60-min step growth at that setting, so someone up early, outside the configured night window, is no longer held under night-mode SMB rules until the clock (inside the window the clock still holds them); it gives no wake reason, so the learner does not train on it. Direction: before this, Boost stayed off through the lie-in until 60-min steps reached the setting, whatever the detector saw; now an HR plus steps wake ends it sooner, which can add insulin earlier in the morning, matching AAPS. On a morning with no wake signal Boost stays off as before, now through the detector as well as the failsafe. A sleep-in long enough that the lie-in reaches back to the candidacy start (13.5 h or more with a 22:00 to 07:00 night, against an 18 h maximum) breaks the hold window, so sleep ends as boundary every cycle or two; AAPS behaves the same, and dosing stays held by the night window clock and the failsafe. Not ported: the wake HR sustain count scaled to the loop's cadence. This entry also listed AAPS clearing the step samples and HR streak on a hysteresis wake, as affecting only later wake evidence while AWAKE; the 6.3.3 replay showed it also decides whether a return to sleep within the hour ends again, and Trio follows AAPS from 18 November (6.3.3 entry). The Boost version, 6.3.2, is now a constant (`BoostVersion.synced`) shown under the Trio version in Settings and written in the startup log, since APP_VERSION is upstream Trio's.
- Boost 6.3.3 on AAPS 4.0.0, 18 November 2026. Synced to `boost-6.3.3-pr` at `9bb6404df2` in tim2000s/Boost (local to the AAPS session when ported; no tag yet). Ported: the committed cap's setting now runs from 0 to 5.0 U (`bb9ea37fc5`), and auto-config uses the same range (`9bb6404df2`, which replaced the 2.5 U auto ceiling of `bb9ea37fc5` the same day). The derivation is the larger of the 75th-percentile SMB and TDD/40, so it passes 2.5 U only for a median TDD above 100 U or an SMB 75th percentile above 2.5 U. The weekly re-derivation scales the cap with the derivation whoever set it, as it did below 2.5 U, at most 25% a run; Trio clamps it to 5.0 U explicitly, since its re-derivation has no per-setting range clamp (the Kotlin's coerceIn). The primer, a fraction of the committed cap, is now held to its own 2.5 U maximum, and onboarding and re-derivation size it from the policy fraction (`primerFrac`) rather than primer over cap, which stops being the fraction once the primer is held and would lower the primer while the cap rose. The default stays 0.5 U. Also ported: the sleep detector without a heart-rate feed (`ecaad5ec6b`). With no valid HR in HealthKit in the last 24 h, rechecked at most every 30 min, sleep candidacy and the pre-window hold start at night start rather than 90 min before it, PRE_SLEEP cannot start candidacy before night start, and the learned night start may move later but not earlier. Before this, someone without a watch qualified on the no-HR clock fallback as soon as candidacy opened, the hold kept it, and the evening meal ran as SLEEPING with V6 and the tiers off; the learned start then drifted towards those early onsets. A failed HealthKit query, which is what a locked phone returns, keeps the last answer, and the answer starts as "feed present", so a person with a feed is unchanged. Already in Trio from 17 November (entry above): Boost max IOB at 12 U following max IOB (`1a74a5600c`), with Trio's own one-time migration. N/A: the night insulin-need shadow (`dd5831280e`), since Trio has no insulin-need watch; and the light AAPS overview (`ddf28a0535`), which is AAPS interface. Direction: the committed cap change adds insulin for a person with a median TDD above 100 U or an SMB 75th percentile above 2.5 U, where auto-config can now set a per-cycle hold of up to 5.0 U nobody chose, and for a cap set above 2.5 U, which re-derivation can now raise; max bolus, max IOB and the 10 U 60-minute cap still bound every dose. Backtested on 18 November: over 502 trailing 14- and 28-day windows from 17 AAPS users, Trio's own auto-config gives the cap the AAPS study does on every window, and none passes 2.5 U (largest 1.60 U); Trio users are not in the data, so a median TDD above 100 U rests on the unit tests. The sleep change adds insulin for a person without an HR feed before night start, where Boost was off and is now on as in the daytime: over the whole 90 min, or with night mode's sleep detection on, only from 90 to 60 min before night start, since PRE_SLEEP closes the Boost gate for the last hour as in AAPS. One difference from AAPS: Trio counts any heart-rate sample in HealthKit as a feed, where AAPS hears heart rate only from a watch, so a scale or camera app that writes one reading a day keeps the early window; that is the behaviour before this change, never more insulin than it. Replayed against the Kotlin at `ecaad5ec6b` on the AAPS no-HR study's 26 user-periods (`SleepNoHrReplayParityTests`, harness in `trio-boost-v1-parity`), Trio matched on every cycle after one fix: a wake on step evidence now starts the step history and HR streak empty, as the Kotlin's does, so the steps that woke someone cannot end a return to sleep within the hour without new movement. Before the fix Trio was awake where AAPS slept on 331 of 550,467 cycle-scenarios and never the reverse, so the fix holds less insulin at night on those cycles.
- The step feed's availability, 20 November 2026 (AAPS `StepFeed`, in 6.2.0 as `36a81e3f0f` and missed by the October port). HealthKit cannot be read while the iPhone is locked, and the step queries failed to 0, so a locked phone read as a person sitting still. With HR integration off, the default, that was classified INACTIVE outside the night window and the profile went to 130%. A failed step read now makes the feed unavailable (`errorNoData`, HealthKit's answer for a window with no samples, is still 0 steps), and with the feed unavailable the INACTIVE branch does not run: the state is `stepsUnknown` and the profile stays at 100%, as AAPS's "steps-unknown". HR-only resistance and stress still run. One difference from AAPS: AAPS also stands the steps-based lie-in failsafe down when the feed is unavailable, and Trio does not. On Android a dark feed is a pedometer that has not reported since boot, which is rare; on an iPhone it is every morning the phone lies locked in bed, and standing the failsafe down then would let Boost dose through the lie-in whenever the detector reads awake. The failsafe only withholds Boost, so keeping it is the cautious side. Direction: removes insulin, the 30% raise, while the phone is locked during the day with HR integration off; with it on, missing HR already withheld the raise. Not replayed: the history has no record of when the phone was locked, so the unit tests carry it. Still open, as before this change: HealthKit hides a denied read, so a person who refused step access or has Motion & Fitness off gets `errorNoData`, reads as 0 steps with the feed available, and can still be classified INACTIVE all day with HR integration off (AAPS's liveness test would catch it; `freshStepSources` could). And locking the phone during exercise ends the exercise state, as a dark feed does in AAPS.
- **Flat‑CGM (`sensorQualityOk`) gate** — AndroidAPS only ever engages this for Libre 1; Trio's glucose layer carries no sensor‑type, so it is inert (matches non‑Libre‑1 behaviour).
- **Boost time‑window, TDD sensitivity adjustment (24 h / 7 d), TT‑sensitivity on ISF** — present in AndroidAPS but **disabled** in the reference build, so they are not ported (Trio matches at defaults). `future_sens` therefore runs as always‑in‑window. The ISF result's own ratio is therefore 1.0, so under Boost the sensitivity ratio is the oref autosens ratio when Use TDD is off and Autosens without TDD is on, and 1.0 otherwise. A temp target that would set Boost's TT ratio still blocks the autosens division of ISF, as in AAPS. Use TDD itself is ported.
- **TDD blend** — Trio uses its single blended TDD; the AndroidAPS weighted‑8h pull‑down blend is not reproduced.

**Consciously N/A (AndroidAPS‑platform‑specific or NS‑telemetry‑only — no Trio dosing analog):**
- **Recovery temp‑target auto‑cancel matched to Boost's own start time** (`637e4dd3fd`) — AAPS inserts a post‑exercise recovery temp target and, after a hypo rebound, cancelled any ACTIVITY target, including one the user had set. Trio's Boost never writes or cancels a temp target: the recovery target is carried in the post‑exercise state only. There is no cancel to restrict.
- **Step‑source availability guard** (`fb3312a1e1`, F1/F9) — keys on Android `TYPE_STEP_COUNTER previousStepCount == -1` (hardware sensor dark since boot); Trio reads HealthKit (no such state). The behavioral intent — don't assert a lie‑in on absent step data — is already covered: `BoostV5Adapter.sleepInActive` requires a fresh (≤30 min) snapshot. The INACTIVE‑branch guard affects only the classifier's `profilePercent`, which Trio never wires to dosing (shadow telemetry).
- **Intraday step banking** (`606c311d56`) — guards an Android in‑memory phone‑counter that can reset before local midnight; HealthKit stores absolute per‑source samples that are stable once a day closes, so there is no resettable counter to bank. Its intent (a completed day is never revised *down*) is covered by the hold‑higher `merge` (revise‑up‑only) ported from `ecec9075b5`.
- **HR pipeline hardening** (`729788d733`, F4/F5/F6) — the wear watchdog re‑registers an Android `Sensor.TYPE_HEART_RATE` listener (N/A; Trio HR is HealthKit‑managed); the HR‑feed dark tracker, step‑feed‑edge breadcrumb, 5‑min HR max/min, and minGuardBG source attribution are NS RT / diagnostic telemetry, which the port defers by policy (reason‑tag design, not per‑field NS RT emission). No dosing effect.
- **Pure NS `boostV5_*` RT fields** (`6067ec9a6d`, `2554b7f963`, `e0f18ddd0e` shadow field) — the underlying *behaviors* (confirm‑gate refactor, cumulative‑cap enforcement, composed‑floor computation) are ported; only the every‑cycle NS RT visibility fields are not (Trio surfaces state via the compact reason tag).
- **Simple Mode pref masking** (`4dba4d534b`, `1629141b38`) — Simple Mode is an AndroidAPS preference‑masking layer with no Trio equivalent; the follow‑up raw‑read bypass across the shadow + HealthConnect ingest paths is likewise N/A (Trio has no Simple Mode, and reads activity/HR from HealthKit rather than HealthConnect).

## Testing

Two layers: deterministic **unit tests** of the pure core, and **backtests** that replay the port
over large volumes of real captured data and golden‑master it against the AndroidAPS reference.

### Unit tests

`BoostV5Core` ships ~190 unit tests (state machine, gates, DynISF, ML feature builder + ring buffer, sleep detector, history tracker, night mode). Run them with:

```sh
cd BoostPort/BoostV5Core && swift test
```

The full app is built with `xcodebuild` against the Trio workspace as usual.

### Backtests against real captured data

The port is replayed locally over real device data and checked, cycle‑by‑cycle, against what the
AndroidAPS Boost reference actually computed. Volume matters here — these run over **hundreds of
thousands of real cycles across multiple users**, not synthetic fixtures. All run via `swift test`;
fixtures are gitignored (real glucose/insulin data) and the suites `XCTSkip` cleanly without them.
Full method, results and limits: [`BoostPort/docs/REPLAY.md`](BoostPort/docs/REPLAY.md).

**1. DynISF golden master** (`Tests/BoostV5CoreTests/Replay/DynIsfReplayTests.swift`) — replays the
DynISF/`future_sens` maths over **651,120 cycles across 13 users** (Aug 2025 to Sep 2026, asserts
scoped to the v4.1.5 reference build) captured from the
AndroidAPS **Boost v4.1.5** reference (`boost_decisions` in the local TimescaleDB, exported by
[`BoostPort/sim/export_boost_decisions.sh`](BoostPort/sim/export_boost_decisions.sh)). Per‑profile
divisor fit; out‑of‑scope variants (v4.2–v4.4.2, v3) detected and excluded:

| check | rows | match |
|------|------|-------|
| `variableSens` (end‑to‑end ISF) | 154,585 | **99.98%** |
| `isfTargetV1 × globalScale` | 135,147 | **99.97%** |
| `blendedTdd` / `finalTdd` | 159,302 | **99.78%** |
| `deltaAccl` | 38,021 | **100.0%** |

**2. Engine robustness** (`BoostEngineReplayTests.swift`) — drives the full V5 state machine over the
same **651,120 real glucose trajectories** (per‑user timelines): **0 violations** — no NaN/inf, no
negative dose, none over maxIOB.

**3. Dosing‑delivery golden master** (`V5ShadowReplayTests.swift`) — the dosing‑path check. Replays
the **on‑device V5 shadow** (`openaps.suggested.boostV5_*` in Nightscout deviceStatus, produced by
the AndroidAPS Kotlin V5) through the Swift port's dose‑cap + Phase‑3 safety‑gate stages over
**30,602 cycles across 4 users** (rolling last 10 days; fixture built by
[`BoostPort/sim/fetch_v5shadow.py`](BoostPort/sim/fetch_v5shadow.py)):

Reproducibility note: a few V5 inputs aren't in the telemetry (the velocity 30‑min rise; the
on‑device ML risk model), so the figures below are *as close as the logged data allows* — the
test reports exactly which residuals are missing‑input vs a genuine difference, rather than a bare
"match %". The one stage needing no reconstruction (action multiplier) is exact.

| dosing stage | rows | reproduced | residual is… |
|------|------|------|------|
| action multiplier (per state) | 30,602 | **100.0%** | — (per‑user Aggression knob fitted) |
| iobHeadroom safety brake | 30,602 | **98.8%** | logged `maxIOB` ≠ the gate's input on a few cycles |
| deceleration safety brake | 5,691 | **96.5%** | `deltaAccl` logged at 1–2 dp (formula itself exact) |
| final SMB dose (uncapped states) | 13,778 | **98.7%** | see decomposition below |

The dose row decomposes — and the genuine‑difference count is the number that matters:

| | share | meaning |
|---|---|---|
| exact (velocity factor 1.0) | 61.4% | reproduced outright |
| velocity‑reconciled | 37.2% | a velocity factor ∈ [0.4, 1.0] reproduces it — the 30‑min rise that sets it **isn't logged** |
| opt‑in lever | 0.1% | the device runs a lever this replay leaves off (velocity‑budget floor, primer) |
| ML hypo‑risk brake | 1.2% | device dosed **less**; the post‑action brake needs the on‑device ML model (all such cycles carry ML risk) |
| **genuine port‑vs‑reference difference** | **0.0%** | — |

**What dosing delivery this confirms:** **98.7%** of uncapped doses reproduce within the inputs we
have, and **0%** are a genuine port difference — every residual is an input the offline replay
can't supply (velocity rise, ML risk model) or a lever the replay runs disabled, and all of them
make the *device* dose less, never the port more. The soft safety‑brakes and per‑state action
multiplier reproduce the on‑device AndroidAPS V5 directly, and the engine emits no out‑of‑bounds
dose across 651k trajectories.

The opt‑in bucket separates cleanly by shape and is independent support for two of the 2026‑09
ports, from data not used to build them: ten IDLE cycles above 180 mg/dL dosing exactly 0.5 U with a
base requirement of zero (the velocity‑budget floor's tier hold), and ten OBSERVING cycles inside the
primer's 90–220 mg/dL band graduated from 0.05 to 0.45 U (the primer's scaled ceiling).

**What it does not (honest limits, see REPLAY.md):** the **HARD min‑guard hypo‑gate** (~25% of
cycles) can't be telemetry‑validated — the gate's sanitised input isn't logged (the recorded
`minGuardBG` is oref's raw, unbounded value); and **CONFIRMED/COMMITTED dose caps** are a
configurable Trio setting the shadow doesn't apply, so the capped value isn't reproduced. Closing
both needs a few extra fields in the on‑device shadow log, or Trio's own Shadow mode to emit
`boostV5_*` for a like‑for‑like compare.

**Records:**
- [`BoostPort/docs/REPLAY.md`](BoostPort/docs/REPLAY.md) — backtest method, results, and scope/limits.
- [`BoostPort/docs/TESTS.md`](BoostPort/docs/TESTS.md) — per-suite unit-test results (193 tests, 0 failures).
- [`BoostPort/docs/AUDIT.md`](BoostPort/docs/AUDIT.md) — the adversarial audit passes, findings by severity, and the final verdict.

## Credits & licence

Boost is the work of [@tim2000s](https://github.com/tim2000s). Trio is © the Trio/Nightscout contributors and is licensed under its own terms (see the root `LICENSE`/`README.md`); this port inherits that licence. Built on the work of the OpenAPS, AndroidAPS, Loop, and Trio communities.
