# Install-time history backfill: what AAPS does, and what Trio would have to do

Status: plan, nothing implemented. Written 2026-09-14 while porting the Boost dev line onto
`boost-in-trio-v0.2`.

## The failure this addresses

A person migrating from another fork onto an empty local database has no insulin history and no
glucose history. AAPS reported the consequences on 2026-07-29 and 30: `tddCalculator` returned 3.1
to 4.1 U/day against a true value near 20, dynamic ISF reached 5550 to 8944 mg/dL/U against a
profile ISF of 100, the insulin requirement computed at or below zero, and the loop delivered
nothing for 3.5 hours while glucose climbed to 276 mg/dL. Nineteen consecutive zero temp basals, no
lows and no alarm. The same emptiness made auto-config decline for insufficient history, so factory
caps were in force at the same time.

AAPS split the response in two. The safety half is `5fc7951452`, the implausible-TDD guard, which
stops a bad TDD from paralysing dosing; that is ported and lives in `DynIsf.tddImplausibleForProfile`.
The data half is `bb03fb844c` and `6739238079`, which try to remove the cause by asking Nightscout
for the missing fortnight. This document is about the data half.

## What AAPS built

`NsClient.requestHistoryBackfill(fromTimestamp)` rewinds only the entries and treatments download
cursors, marks the load as a full sync so the per-type accept preferences do not discard what comes
back, and leaves the upload cursors alone. The bound is persisted so a restart mid-backfill cannot
widen a 14-day request back out to the 100 days that the manual full sync uses.

`BoostHistorySync` is the detection and throttling policy, and it is pure. It reuses the three
numbers the V6 onboarding path already gathers for auto-config, so it costs no extra database work:
days with TDD, CGM row count, and boluses over the last 14 days. The thresholds are auto-config's
own minimums of 7 days and 1500 readings, plus a deliberately slack 50 boluses. Fourteen days is
what the two consumers need, being the 7-day TDD blend and the auto-config lookback; nothing in
Boost looks further back.

Three bounds keep it from running away. At most 3 attempts, a 6-hour cooldown between them, and a
48-hour new-install window anchored on the first time Boost evaluated history on this install. The
window exists because the full-sync flag is what bypasses the accept preferences, and each request
therefore opens a brief period in which records this phone did not create are accepted. That is
correct for a new install and wrong months later, when a long pump break or a sensor swap would
silently reopen it, and when a second uploader on the same Nightscout would have its records land
in it. The anchor is stamped on every install, healthy ones included, because anchoring only when a
gap is first seen would let a user who degrades after months open a fresh window at that moment.

Idempotence comes from the storage layer rather than from the request. AAPS writes through sync
transactions that match before they insert, on Nightscout id, then pump id with type and serial,
then timestamp. An identical re-fetch performs no write at all, which is what stops a repeat from
inflating the very TDD the exercise exists to repair.

## Why this does not port across directly

Trio's shape differs in three ways that matter, and the third is the hard one.

**There are no accept gates to bypass.** Trio has no equivalent of the `NsClientAccept*`
preferences. Carbs and temp targets are fetched from Nightscout on a timer and stored, and a
user-triggered glucose backfill already exists in Nightscout settings. So the mechanism AAPS needed
the full-sync flag for does not exist here, and the part of the 48-hour window that was about
closing that bypass has nothing to close. The second-uploader argument still stands on its own for
glucose.

**The glucose half is already mostly built.** `NightscoutManager.fetchGlucose(since:)` calls
`NightscoutAPI.fetchLastGlucose(sinceDate:)`, and `GlucoseStorage.backfillGlucose` filters against
both `DeletedGlucoseStored` and existing rows within 3.5 minutes before inserting. The existing
caller in `NightscoutConfigStateModel.backfillGlucose` asks for one day. Two gaps: the API caps the
query at `count=1600`, while fourteen days on a five-minute grid is about 4000 readings, so a
14-day request needs paging; and nothing triggers it automatically.

**Trio cannot fetch insulin from Nightscout at all.** `NightscoutAPI` reads entries, carbs and temp
targets. There is no bolus or treatment-insulin fetch, and no code path that writes a
`PumpEventStored` row from a Nightscout record. Trio's TDD comes from
`TDDStorage.calculateTDD(pumpManager:pumpHistory:basalProfile:)`, which uses pump history and infers
uncovered gaps from the basal profile. So on a fresh install the TDD is roughly basal-only rather
than near-zero.

That last point cuts both ways and is worth measuring before building anything. Basal-only TDD on a
person whose true split is about half basal lands near 0.5 of the truth, which is **above** the 0.35
floor the implausible-TDD guard uses. The guard would not fire, dynamic ISF would be derived from a
TDD roughly half the real one, and the resulting ISF would be about twice the appropriate value.
That is a milder failure than the AAPS one and in the same direction: under-delivery. It is also
invisible, because nothing reports it.

## Proposed approach

Four stages, in this order. Stages 1 and 2 are worth doing regardless of what is decided about
stage 3.

**Stage 1, measure before building.** Add the detection arithmetic without any request. Port
`BoostHistorySync`'s thresholds as a pure type in `BoostV5Core`, feed it the numbers
`maybeAutoConfigureBoostV5` already computes, and record the verdict in the determination reason.
This answers the question the plan turns on: how often does a real Trio install actually sit below
the thresholds, and where does its inferred TDD fall relative to its profile-implied TDD. No network
call, no writes, no dosing effect.

**Stage 2, glucose backfill.** Extend `NightscoutAPI.fetchLastGlucose` to page, either by lowering
the ceiling and walking the window or by adding an explicit date range, then have the detector
trigger `backfillGlucose` over 14 days under AAPS's bounds: 3 attempts, 6-hour cooldown, and the
48-hour install window. Idempotence is already there in the 3.5-minute filter, and the deleted-value
filter means a reading someone removed does not come back. The risk here is low and confined to
glucose rows.

**Stage 3, insulin, which needs a decision.** Three options, and they are not equally safe.

| Option | What it means | Risk |
|---|---|---|
| Leave it | Rely on the implausible-TDD guard alone | The basal-only case above, which the guard may not catch |
| Import into pump history | Fetch Nightscout boluses, write `PumpEventStored` rows | Contaminates the record IOB is computed from, and double-counts when the pump later reports the same dose |
| Separate imported-TDD store | A distinct store, consulted only by the Boost TDD blend and auto-config, never merged into pump history | Two TDD sources to keep straight, but the pump-history record stays untouched |

Writing Nightscout boluses into `PumpEventStored` is the option to avoid. Trio's pump history is the
input to IOB as well as to TDD, and a duplicate bolus there is an over-estimate of insulin on board,
which is an insulin-withholding error at exactly the wrong moment. The matching that makes AAPS's
version safe relies on pump id, type and serial being carried through Nightscout, which is not
something to assume for records another fork uploaded.

The separate store is the better trade. It keeps the repair where the damage is, namely the TDD
blend and auto-config's history check, and it leaves IOB alone. It also makes the import visible:
the store can be shown, and cleared, without touching pump history.

**Stage 4, tighten the guard if stage 1 justifies it.** If stage 1 shows fresh installs landing
between 0.35 and 0.6 of profile-implied TDD, the floor is in the wrong place for Trio, because
Trio's basal inference lifts the number into a range the AAPS threshold was not chosen against. That
is a number to set from measurement rather than from the AAPS value.

## What would need writing

- `BoostHistorySync` equivalent in `BoostV5Core`: pure, with the thresholds, attempt count, cooldown
  and install window, unit-tested the way the rest of the core is.
- Persistence for the attempt count, last-attempt time and first-seen anchor. UserDefaults alongside
  the existing Boost stores is consistent with `BoostActivityStore` and `BoostMealTimeStore`.
- Paging in `NightscoutAPI.fetchLastGlucose`, or a date-bounded sibling.
- A trigger point. `maybeAutoConfigureBoostV5` already runs on active cycles, already has the three
  numbers, and is already wrapped so a failure is logged and swallowed, which makes it the natural
  host. Nothing may block the dose path: the request posts and returns.

## Open questions

- Is a Nightscout backfill wanted at all, or is the implausible-TDD guard plus a documented note in
  onboarding the proportionate response for Trio?
- If the insulin half goes ahead, does the separate imported-TDD store carry enough to be useful, or
  does the Boost blend need the 4h and 8h-to-4h splits that Trio does not currently expose? That
  limitation is already recorded at the top of `BoostISF.swift` and is unrelated to this work, but
  it bounds how much an import can buy.
- Should the glucose backfill be offered to any new Trio install rather than only to Boost users?
  Nothing about the gap is Boost-specific; Boost is only where it currently shows up.
