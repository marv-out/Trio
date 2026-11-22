# REVIEW.md

The checks a change to this repository is reviewed against before it is committed. This is the
Boost-in-Trio port: Trio with the AndroidAPS Boost algorithm run as a mode-gated second pass over
the oref determination, and with Adaptive Smoothing (the UKF port) in the glucose path. Each item
is written so that a reviewer can test a diff against it and name the item a finding breaks.
Findings are labelled important (fix before commit), nit (optional) or pre-existing (present before
this change; record it, do not block on it).

The tiers and the checks each tier requires are set in the global instructions and summarised here
for this repository. The incident record is spread across CLAUDE.md (mistakes 1 to 7, smoothing),
`BoostPort/docs/AUDIT.md`, `BoostPort/AUDIT_2026-06-28.md` and the commit messages of the Boost
line; the table at the end maps each incident to what now catches it.

## Tiers in this repository

High: anything that can change a dose, a safety limit or whether the loop runs.
`BoostPort/BoostV5Core/Sources/**` (the V5/V6 engine, DynISF, safety gates, caps, tranche, primer,
auto-config, sleep detector, night mode and activity classifier), `Trio/Sources/APS/**` (the
override seam in `OpenAPS/OpenAPS.swift`, `APSManager.swift` including `performBolus` and the
auto-config wiring, `OpenAPSSwift/**` including `DetermineBasal/` and `Boost/`,
`FetchGlucoseManager.swift` and `Storage/GlucoseStorage.swift`, since the smoothed value is what
the algorithm reads when smoothing is on), `GlucoseSmoothing/**`, `trio-oref/**`,
`AlgorithmPackage/**`, `Trio/Resources/boost/*.json` (the two bundled models),
`Trio/Sources/Services/HealthKit/BoostActivityMonitor.swift` (it feeds the gate and the inactivity
raise), `Trio/Sources/Models/Preferences.swift` where a default or decode clamp of a dosing key
changes, `DeviceDataManager.swift` (it syncs Max Bolus to the drivers), the pump and CGM
submodules (`OmnipodKit`, `MinimedKit`, `DanaKit`, `MedtrumKit`, `RileyLinkKit`, `AccuChekKit`,
`RoundWhiteDiscKit`, `CGMBLEKit`, `G7SensorKit`, `LibreTransmitter`, `LibreLoop`, `EversenseKit`,
`dexcom-share-client-swift`, `LoopKit`, `LoopAlgorithm`) including a change of pinned commit, and
any `Trio.xcodeproj/project.pbxproj` change that adds or drops a source in those paths. Before
commit: `cd BoostPort/BoostV5Core && swift test`, `swift test --package-path GlucoseSmoothing` for
the smoothing path, `swift test --package-path AlgorithmPackage`, a full simulator build of the
`Trio` scheme, the checklist, a replay against real history when behaviour changes (items 23 to 25)
and a fresh-context review of the diff. Before an installable build is handed over: the full
simulator build and the hosted `Trio Tests` scheme, with the previous build named as the way back.

Medium: code that runs on the device without changing a dose. Settings views under
`Trio/Sources/Modules/**`, reason-string telemetry, Nightscout upload, the watch app, complications
and Live Activity. Unit tests where they exist, the checklist, and the full simulator build.

Low: `BOOST.md`, `BoostPort/docs/**`, `BoostPort/ARCHITECTURE.md`, `BoostPort/sim/**`, the replay
test harnesses under `Tests/BoostV5CoreTests/Replay/`, READMEs and CLAUDE.md. The analysis
checklist in the global instructions and items 23 to 27 below.

## Dosing path

1. Every dosing-affecting change is gated on `boostMode == .active`. With the mode `Off` or
   `Shadow` the determination (units, rate, insulinReq, forecasts) is byte-identical to stock
   Trio. No test asserts this; the reviewer checks each new branch for the gate.
2. New dosing logic ships default off or shadow-only, reaches Active only after its shadow output
   has been looked at, and in shadow is computed from the Boost-flavoured determination rather
   than the stock one, so the logged would-be dose predicts what Active would do.
3. The commit message of a high-tier change states its direction (adds insulin, removes insulin,
   or neither), as the October 2026 port commits do. A change that adds insulin or removes a limit
   names the AAPS commit it matches and the evidence for it.
4. Safety limits only tighten unless a removal is matched to AAPS and justified in the commit: the
   minGuardBG hard gate, the non-finite-input hard gate in `SafetyGates.applyPhase3`, the composed
   floor's fail-closed TBR gate (TBR<63 below 2.0% and TBR<70 below 3.5%, at least 1000 readings),
   the auto-config TBR raise-guard (no cap raise applied above 4% time below 70), the post-rescue
   caps and rebound guard, the non-meal cap at the base dose, the rolling 60-minute cumulative SMB
   cap, the tranche ceiling and the overnight gate. A statistic or a learned value never overrides
   one of them.
5. The override honours the user's SMB-off levers through
   `DosingEngine.smbHardDisabledByUserLevers`, and the automatic SMB still passes the Max Bolus
   clamp in `APSManager.performBolus`.
6. A claim that a safety property is absent is scoped to the layer that was read. Max Bolus for
   automatic boluses is enforced in `performBolus` and, independently, in some pump drivers
   (OmnipodKit's `OmniPumpManager.enactBolus` refuses an amount above `state.maxBolusUnits` at the
   pinned commit), and the drivers differ from one another. Read the submodule at its pinned
   commit before saying a driver lacks a check.
7. The bolus-calculator what-if path (`simulation: true`) writes no Boost state and skips the V5
   second pass. A new store write or ring-buffer push is checked against that flag.
8. Boost state is read and written through the atomic `mutateState`, never a separate load and
   save, so an overlapping scheduled loop and post-bolus determination cannot both act on the same
   state.
9. A new dosing preference is clamped to its slider range on decode in `Preferences.swift`, so an
   imported or corrupted settings file cannot feed an out-of-range or zero divisor to the engine.
   Auto-config may seed a cap only while the per-knob user-touched flag is unset.
10. A window meant as a duration is expressed in wall-clock time, not in invocations or cycles,
    since the loop cadence varies between one and five minutes. The ML lag buffer is the exception:
    its six lags stay at five-minute spacing, which is what the model was trained on, and entries
    older than 35 minutes expire.
11. No training or fitting runs on the device in the dose path. The two LightGBM models in
    `Trio/Resources/boost/` stay byte-identical to the AAPS export, and a model update changes the
    feature builder and the model in the same commit. The learned aggregates (`SleepHistoryTracker`,
    `MealTimeLearner`) stay bounded as they are; the learned wake may only move later.
12. The sleep detector and the activity snapshot are advanced from the loop, not only from
    HealthKit callbacks, and a missing, sparse or frozen heart rate is read as no signal. The
    inactivity raise, which adds insulin, needs the gate open, heart rate in zone 1 when heart-rate
    integration is on, and the person neither asleep nor inside the night window nor in a lie-in.
13. Parity is measured against the AAPS build the developer runs, named by branch or commit in the
    commit message, not against upstream AndroidAPS. A deliberate divergence from the Kotlin goes
    in its own commit after the faithful port and is recorded in the differences section of
    `BOOST.md`.

## Adaptive Smoothing

14. The smoother is the single persistent `sharedSmoother`; nothing constructs a fresh
    `UnscentedKalmanFilter()` per cycle. Guard: `no-fresh-ukf.sh`, a PreToolUse hook that
    blocks the edit. The copy under `.codex/hooks/ukf/` is tracked; the one under `.claude/hooks/ukf/`
    is git-excluded, so a Claude session in a fresh clone does not have it. `UkfPersistenceTests`
    covers the core's carried state.
15. Input to the smoother is newest-first, bucketed to five minutes and covers 34 h (limit 500).
    Guard: `UkfOrderingRegressionTest` for the order.
16. A change in the smoothing path is proven by the full-history rolling-window replay across
    Swift, Kotlin and Python in the private `trio-ukf-backtest` repository before parity is
    claimed. Per-call golden vectors and `UkfPythonParityTests` are necessary and not sufficient.

## Builds and merges

17. A new source file under `Trio/Sources/APS/OpenAPSSwift/Boost/` or `BoostPort/BoostV5Core/` is
    added to `Trio.xcodeproj/project.pbxproj` (the Boost directory uses explicit file references),
    and no file carries `import BoostV5Core`, because the core is compiled into the Trio target.
18. Build success is read from `** BUILD SUCCEEDED **` and xcodebuild's own exit code, never
    through a pipe. Package tests passing is not an app build: a change touching the app target is
    built with the full simulator build before commit, and a commit message says so when it was
    not.
19. After merging nightscout `dev` or `main`: `git submodule sync && git submodule update --init
    --recursive`, the full simulator build, `swift test --package-path AlgorithmPackage`, and the
    hosted `Trio Tests` scheme.
20. Hosted tests run without `CODE_SIGNING_ALLOWED=NO`, which strips the keychain entitlement.

## Repository and publishing

21. `origin` (the fork) is public and the Boost branch tracks it, so every push publishes. Files
    are staged by explicit path, and every staged file passes
    `~/StudioProjects/Boost-AAPS-core/backtesting/scripts/tooling/anonymise_check.py`. Cohort
    names, emails, tokens, Nightscout URLs and site hosts never appear; the developer's own name
    may.
22. Replay fixtures (`BoostPort/**/Fixtures/*.ndjson`) and soak data hold real glucose and insulin
    records and stay git-ignored; a simulator seed patch carrying a Nightscout URL or secret is
    applied for a build and reverted, never committed.

## Analysis and replay

23. The replay suites run with `swift test -c release`; in debug they take long enough over the
    fixture to look hung.
24. Each replay assertion is scoped to the reference build it validates and its per-user settings
    (the insulin divisor per profile, the Aggression knob per user) are fitted from the record, not
    assumed. A residual is classified as a missing input, an opt-in lever or a genuine
    port-against-reference difference before it is called a port defect.
25. A port-against-AAPS soak names what differs before it compares totals: the Boost and SMB
    settings in force on each side, the loop interval, treatments and temp targets not
    downloaded, and the absence of step and heart-rate data in the simulator. Auto-config values
    derived from the soak's own history are an artefact of the soak, not a setting.
26. Nightscout devicestatus records a decision whether or not it was delivered and holds some loops
    twice; it is deduplicated before counting and is not read as delivered insulin.
27. Absolute insulin figures are not pooled across the developer's insulin concentration changes
    (4 August 2026 12:25 and 17 October 2026 16:18), and cross-user unit comparisons are flagged.

## Incident record and what catches each

| Incident | Caught by |
|---|---|
| UKF fed oldest-first, so the filter copied raw values (CLAUDE.md 1, `cc9254a30`) | Item 15, `UkfOrderingRegressionTest` |
| Fresh UKF per cycle, about 15 mg/dL divergence invisible to per-call tests (CLAUDE.md 3) | Item 14, `no-fresh-ukf.sh` hook; item 16 |
| 24 h smoothing window instead of 34 h (CLAUDE.md 4) | Item 15; nothing automated |
| Smoothed chart line did not refresh (CLAUDE.md 2) | Superseded by dev's fetched-results controller; nothing specific |
| `dev` merge broke the app build while package tests passed (CLAUDE.md 6) | Items 18 and 19 |
| AlgorithmPackage stopped compiling after the dev merge (`bdcf8bacd`) | Item 19 |
| Composed-floor wiring never compiled: missing pbxproj entry, `import BoostV5Core`, argument order, hidden by a piped exit code (`bf4834c8e`) | Items 17 and 18; `ComposedFloorTests` for the gate decision |
| Auto-config file missing from pbxproj and wrongly imported (`8209f6134`) | Item 17 |
| Ported against upstream AAPS rather than the running build: stale v9 hypo model, HR-only sleep detector, a boost window prototyped and reverted (`AUDIT.md`, `9e54a08da`) | Items 11 and 13 |
| What-if previews mutated persisted Boost state (`71b9c9941`) | Item 7; no test |
| Sleep detector advanced only on HealthKit callbacks, so night suppression lapsed (`57d8e1777`) | Item 12; no test |
| Shadow fed the engine a stock determination, biasing would-be doses (`0863f3f1e`) | Item 2; no test |
| Override ignored the user's SMB-off levers; NaN inputs passed the hard gates (`760e33689`) | Items 4 and 5; no test names either |
| Lost update between overlapping loops could re-fire a CONFIRMED SMB (`e72d9ac25` D3) | Item 8 |
| Out-of-range Boost preferences accepted on decode (`e72d9ac25` D6, `760e33689` M1) | Item 9 |
| Auto-config could raise a dosing cap without consent (`f8780ec38`) | Item 9 |
| Boost settings did not persist past the settings screen (`17f4dd164`) | Nothing yet |
| HealthKit access never requested, so activity inputs were silently neutral (`49e2dd1fc`) | Nothing yet |
| V6 override in IDLE out-dosed the base engine (`92f75b34e`) | Item 4, `V6OverrideCapsTests` |
| Inactivity raise during elevated-HR exercise and during sleep (`b1e939fa7`, `3a4a287fd`) | Item 12, `ActivityClassifierTests` |
| Frozen heart rate read as real; learned wake drifted earlier (`d429a6087`) | Items 11 and 12, `FrozenHrAndWakeNudgeTests` |
| ML ring buffer carried pre-gap snapshots across breaks (`9b9b09251`) | Item 10, `BoostMlFeatureBuilderTests` |
| Meal-state ages and ML null streak counted invocations (`2214db21d`); lag slot never advanced on a one-minute feed (`08e41c814`) | Item 10, `RedriveTests`, `BoostMlFeatureBuilderTests` |
| Implausible TDD produced an ISF that stopped dosing for 3.5 h (`7a2dbb477`) | Item 4, `DynIsfTddGuardTests` |
| Boost gate open all night with night mode off (`d355736c0`) | Item 4, `BoostGateTests` |
| Confirm-tranche release landed outside every other cap (`8857f016f`) | Item 4, `ConfirmTrancheTests` |
| A Trio-only basal-minutes clamp held every Boost dose to 0.27 to 0.40 U (`133bdbbfa`) | Items 3 and 13; the `trio-boost-soak` comparison found it |
| Replay harness scope gaps read as port defects (`514069d81`) | Item 24 |
| Flaky settings test from DeviceDataManager rewriting the preferences file (`b3b708c02`) | Nothing specific; found by repeated full-suite runs |
| Soak auto-config derived from the soak's own clamped history (`trio-boost-soak` round 2) | Item 25 |
| Swinject resolver race crash in `HomeRootView.swift` during the soak, unrelated to Boost | Pre-existing; nothing yet |
| An audit called the iOS automatic microbolus unbounded by Max Bolus, having read only the app | Item 6 |
| Upstream's unit-test workflow runs only for the nightscout owner, so the fork has no CI gate; the `trio-fork-compliance` gate is not installed in this checkout | Nothing yet; items 18 to 20 by hand |
| A hidden Boost max IOB at its 1 U default held every daytime Boost SMB to 0 U from 1 U on board until onboarding copied max IOB into it | `BoostV1DeterminationTests`: the default follows max IOB up to 12 U, a set value is a limit in V6 and in V1's tiers, and a pre-change file migrates to 12 once |
| Auto-config read the newest 6,000 or 12,000 glucose readings, so a one-minute CGM showed about 4 days and onboarding never ran | Nothing yet; the reads have no count limit |
| Time-below-range is counted per reading, so a window spanning a 5-minute to 1-minute CGM change weights the 1-minute days five times | Pre-existing; nothing yet |
| Without an HR feed the sleep detector qualified on the clock 90 min before night start and held it, so the evening meal ran as SLEEPING (found on an AAPS user, AAPS `ecaad5ec6b`; the same code was in Trio) | `SleepNoHrFeedTests`; each test fails against a mutant removing its part |
| Re-derivation in Trio does not clamp a knob to its setting's range, as the Kotlin does; the decode clamp on the next read is what holds it | Pre-existing; the committed cap is clamped to 5.0 U (`RedriveTests` testReDerivationHoldsACommittedCapItWouldCarryPast5To5), the other caps nothing yet |
| The primer was sized as primer / committed cap, which stops being the policy fraction once the primer is held to its 2.5 U maximum, so it would fall while the cap rose (AAPS `9bb6404df2`) | `RedriveTests` testThePrimerFollowsARisingCommittedCapAtThePolicyFractionNotTheClampedRatio and testReDerivationHoldsThePrimerToItsOwnMaximum |
| Trio's onboarding sizes the primer from the operative committed cap, where the Kotlin writes the derived primer, so a kept hand-set cap gives a larger primer than AAPS (cap 5.0 U, derived 2.0 U: Trio 2.5 U, AAPS 1.5 U) | Pre-existing; bounded by the 2.5 U primer maximum (`BoostV5AutoConfigTests` testOnboardingSizesThePrimerFromAKeptCapAtThePolicyFraction pins the fraction) |
| Re-derivation's primerAtStart lists cap x fraction without the 2.5 U maximum, so a primer held at 2.5 U with no ledger entry reads as set by the person and is frozen (shared with the Kotlin) | Not a defect: both writers record what they write (APSManager passes BoostRedriveStore.recordWritten), so it needs a lost ledger (a reinstall, or preferences.json imported without the UserDefaults ledger), and freezing then holds less insulin. Left in parity with AAPS, agreed with the AAPS session 18 November |
| A steps wake carried its step history and HR streak into the awake state, where AAPS starts them empty (`SleepStateDetector.kt` 687), so the steps that ended one sleep could end a return to sleep within the hour with no new movement. Trio was awake where AAPS slept on 331 of 550,467 replayed cycle-scenarios, never the reverse; Trio now follows AAPS, agreed with the AAPS session 18 November | `SleepStepsWakeResetTests` (fails against the old code); `SleepNoHrReplayParityTests` with `SLEEP_NOHR_PARITY_DIR` from `trio-boost-v1-parity` `scripts/sleep_no_hr_dump.py`, every cycle against the Kotlin |
| The first committed cap comparison used Python's `round`, which disagreed with Trio on 27 of 502 cohort windows at half-cent values; Trio and the Kotlin both round half up (`Math.round`) | `CommittedCapReplayParityTests` with `COMMITTED_CAP_PARITY_FILE` from `scripts/committed_cap_dump.py`, which rounds as the Kotlin does |
| Upstream's WatchLogIngestTests "Overlapping batches arriving together are stored once" stored 60 of 80 entries once in a full serial Trio Tests run on 18 November and passed in three isolated reruns and in the same day's earlier full run; three concurrent ingests, so probably an upstream race, not Boost code | Pre-existing; nothing yet. It fails the weekly upstream sync gate safe (no push) when it recurs |
| HealthKit cannot be read while the iPhone is locked, and every failed step query read as 0 steps in a snapshot that still counted as fresh. With HR integration off (the default) a locked phone outside the night window was classified INACTIVE and the profile raised to 130%, so a walk with the phone locked in a pocket added insulin. AAPS's `StepFeed` availability guard (6.2.0, `36a81e3f0f`) had never been ported. Reported by the user 20 November | `ActivityClassifierTests` testNoInactivityRaiseWhenTheStepFeedIsUnavailable (fails without the guard: inactive, 130%); `BoostStepReadTests` (hosted) holds that a locked read is unavailable and an empty window is 0 steps (fails when every error reads as data) |
| HealthKit hides a denied read, so with step access refused or Motion & Fitness off every window is `errorNoData`, 0 steps with the feed counted available, and INACTIVE can raise the profile to 130% all day with HR integration off. Found in review of the step-feed change, 20 November | Pre-existing; nothing yet |

A new incident adds a row here naming its check, or "nothing yet".
