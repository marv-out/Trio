@testable import BoostV5Core
import XCTest

/// Periodic re-derivation of the derived knobs (AAPS 2026-08-03, second revision, with the
/// 2026-08-04 clipped-step fix).
///
/// Movement of each knob's driver is tracked and applied to whatever the knob is currently set to,
/// so a user's own offset is preserved rather than overwritten or frozen.
final class RedriveTests: XCTestCase {
    typealias Apply = BoostV5AutoConfigApply
    typealias Knob = BoostAutoConfigKnob

    /// A mutable store standing in for the host's preferences plus the baseline and pending ledgers.
    private final class Store {
        var value: [Knob: Double] = [
            .aggression: 1.0, .hypoCaution: 1.0, .confirmedCapU: 2.5,
            .committedCapU: 0.5, .cumulativeSmbCap60Min: 10.0, .primerCapU: 0.3
        ]
        var baseline: [Knob: Double] = [:]
        var pending: [Knob: Double] = [:]

        @discardableResult func run(
            _ s: BoostV5AutoConfig.Suggestion,
            tbr70: Double = 2.0,
            sev54: Double = 0.2,
            override: Bool = false
        ) -> [Apply.Resolution] {
            Apply.redrive(
                suggestion: s, tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, overrideHypoProtections: override,
                storedValue: { self.value[$0] }, currentDefault: { _ in 0 },
                baselineValue: { self.baseline[$0] }, pendingValue: { self.pending[$0] },
                put: { self.value[$0] = $1 },
                setBaseline: { self.baseline[$0] = $1 },
                setPending: { knob, v in
                    if let v { self.pending[knob] = v } else { self.pending.removeValue(forKey: knob) }
                }
            )
        }
    }

    private func suggestion(
        aggression: Double = 1.0, hypoCaution: Double = 1.0,
        confirmedCapU: Double = 2.5, committedCapU: Double = 0.5, primerCapU: Double = 0.3
    ) -> BoostV5AutoConfig.Suggestion {
        BoostV5AutoConfig.Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmedCapU, committedCapU: committedCapU,
            cumulativeSmbCap60MinU: BoostV5AutoConfig.cumulativeCap60Min(
                confirmedCapU: confirmedCapU, committedCapU: committedCapU
            ),
            bolusCapU: 10, fastCarbConfirm: true,
            aggressiveEarlyConfirm: false, velocityBudgetFloor: false,
            primerCapU: primerCapU, primerFrac: committedCapU > 0 ? primerCapU / committedCapU : 0,
            primerTbrFallback: false, rationale: []
        )
    }

    func testFirstRunRecordsBaselinesAndWritesNoTrackedKnob() {
        let store = Store()
        let out = store.run(suggestion(committedCapU: 2.0))
        for knob in Apply.redriveKnobs {
            XCTAssertNotNil(store.baseline[knob], "\(knob) baseline")
            XCTAssertTrue(out.contains { $0.knob == knob && $0.outcome == .baselineRecorded })
        }
        // The tracked knobs are untouched.
        XCTAssertEqual(store.value[.committedCapU], 0.5)
        XCTAssertEqual(store.value[.aggression], 1.0)
    }

    func testComputedKnobsCanStillBeWrittenOnTheFirstRun() {
        // They are recomputed from the operative caps rather than tracked, so a cumulative cap that
        // has drifted out of step with the caps it bounds is corrected immediately. "The first run
        // changes nothing" is not true, and AAPS says so having shipped that claim.
        let store = Store()
        store.value[.cumulativeSmbCap60Min] = 1.0 // out of step with 2.5 + 2 x 0.5
        store.run(suggestion())
        XCTAssertEqual(store.value[.cumulativeSmbCap60Min]!, 3.5, accuracy: 1E-9)
    }

    func testTheUsersOwnOffsetSurvivesAMoveInTheDriver() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.24)) // baseline recorded
        store.value[.committedCapU] = 1.8 // the user raised it by 45%
        store.run(suggestion(committedCapU: 1.488)) // the derivation moved up 20%
        // 1.8 x 1.2 = 2.16: the driver's movement applied, the offset intact.
        XCTAssertEqual(store.value[.committedCapU]!, 2.16, accuracy: 0.01)
    }

    func testRatioOfCurrentToDerivedIsInvariant() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        store.value[.committedCapU] = 1.5 // offset of 1.5x
        store.run(suggestion(committedCapU: 1.2))
        XCTAssertEqual(store.value[.committedCapU]! / 1.2, 1.5, accuracy: 0.02)
    }

    func testAMoveInsideTheDeadbandIsNotWrittenAndAccumulates() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        // A 5% move on a 1.0 cap is 0.05, inside the 0.07 band.
        let first = store.run(suggestion(committedCapU: 1.05))
        XCTAssertEqual(store.value[.committedCapU], 0.5) // unchanged
        XCTAssertTrue(first.contains { $0.knob == .committedCapU && $0.outcome == .insideDeadband })
        // The baseline did not advance, so the movement is still available next time.
        XCTAssertEqual(store.baseline[.committedCapU]!, 1.0, accuracy: 1E-9)
    }

    func testOffsetKnobsMustRepeatBeforeTheyAreWritten() {
        let store = Store()
        store.run(suggestion(aggression: 1.0))
        let held = store.run(suggestion(aggression: 0.92))
        XCTAssertTrue(held.contains { $0.knob == .aggression && $0.outcome == .awaitingConfirmation })
        XCTAssertEqual(store.value[.aggression], 1.0) // not yet written
        let written = store.run(suggestion(aggression: 0.92))
        XCTAssertTrue(written.contains { $0.knob == .aggression && $0.outcome == .redriven })
        XCTAssertEqual(store.value[.aggression]!, 0.92, accuracy: 1E-9)
    }

    func testAFlappingOffsetKnobIsNeverWritten() {
        // The confirmation has to be consecutive, or a knob alternating either side of a threshold
        // accumulates a match across the gap and eventually writes the flap.
        let store = Store()
        store.run(suggestion(aggression: 1.0))
        store.run(suggestion(aggression: 0.92)) // held
        store.run(suggestion(aggression: 1.0)) // back again, clears the pending value
        store.run(suggestion(aggression: 0.92)) // held once more, not written
        XCTAssertEqual(store.value[.aggression], 1.0)
    }

    func testARaiseIsHeldWhileTimeBelowRangeIsHigh() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        let out = store.run(suggestion(committedCapU: 1.5), tbr70: 9.0)
        XCTAssertTrue(out.contains { $0.knob == .committedCapU && $0.outcome == .suggestedNotAppliedTbr })
        XCTAssertEqual(store.value[.committedCapU], 0.5)
    }

    /// The run-now dialog's override lifts both guards for that run, so the same raise is written.
    func testTheOverrideLetsAHeldRaiseThrough() {
        for (tbr70, sev54) in [(9.0, 0.2), (2.0, 3.0)] {
            let store = Store()
            store.run(suggestion(committedCapU: 1.0))
            let out = store.run(suggestion(committedCapU: 1.5), tbr70: tbr70, sev54: sev54, override: true)
            XCTAssertFalse(out.contains { $0.outcome == .suggestedNotAppliedTbr })
            XCTAssertGreaterThan(store.value[.committedCapU]!, 0.5)
        }
        XCTAssertTrue(Apply.raiseGuardTripped(tbrBelow70Pct: 4.1, timeBelow54Pct: 0))
        XCTAssertTrue(Apply.raiseGuardTripped(tbrBelow70Pct: 0, timeBelow54Pct: 1.0))
        XCTAssertFalse(Apply.raiseGuardTripped(tbrBelow70Pct: 4.0, timeBelow54Pct: 0.9))
        XCTAssertFalse(Apply.raiseGuardTripped(tbrBelow70Pct: 9, timeBelow54Pct: 3, overridden: true))
    }

    func testATighteningIsNeverHeldByTheRaiseGuard() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        store.run(suggestion(committedCapU: 0.6), tbr70: 9.0)
        XCTAssertLessThan(store.value[.committedCapU]!, 1.0)
    }

    func testAClippedStepKeepsItsRemainderAndConverges() {
        // The case that motivated the 2026-08-04 fix: diluting U200 insulin to U100 roughly doubles
        // the dose in units, so the derived cap doubles in a single step. Under the old logic the
        // cap moved a quarter once, advanced its baseline to the doubled value, saw no further
        // movement and sat about 40% below where it belonged.
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        var seen: [Double] = []
        for _ in 0 ..< 6 {
            store.run(suggestion(committedCapU: 2.0))
            seen.append(store.value[.committedCapU]!)
        }
        XCTAssertEqual(seen[0], 1.25, accuracy: 0.01)
        XCTAssertEqual(seen[1], 1.56, accuracy: 0.01)
        XCTAssertEqual(seen[2], 1.95, accuracy: 0.01)
        // It settles within the knob's own deadband of the target rather than exactly on it, which
        // is what the design promises: the last step is below the measured noise floor.
        XCTAssertEqual(seen.last!, 2.0, accuracy: Apply.redriveDeadband[.committedCapU]!)
    }

    func testOneStepIsBoundedToAQuarter() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        store.run(suggestion(committedCapU: 10.0))
        XCTAssertEqual(store.value[.committedCapU]!, 1.25, accuracy: 1E-9)
    }

    // AAPS Boost 6.3.3 (9bb6404df2, RedriveCommittedCapCeilingTest): auto-config uses the committed
    // cap's whole range, up to 5.0 U, and the primer keeps its own 2.5 U maximum.
    private func derived(tdd: Double) -> BoostV5AutoConfig.Suggestion {
        BoostV5AutoConfig.compute(.init(
            daysWithData: 28, bgReadingCount: 6000, tddMedianU: tdd,
            manualBolusesU: Array(repeating: 4.0, count: 20), smbAmountsU: Array(repeating: 0.3, count: 200),
            tbrBelow70Pct: 1.0, timeBelow54Pct: 0.2, meanGlucoseMgdl: 130, currentMaxBolusU: 2.5
        ))!
    }

    func testOnboardingDerivesTheCommittedCapUpToTheSettingsMaximum() {
        XCTAssertEqual(BoostV5AutoConfig.committedCapMaxU, 5.0)
        XCTAssertEqual(derived(tdd: 80).committedCapU, 2.0)
        XCTAssertEqual(derived(tdd: 160).committedCapU, 4.0)
        XCTAssertEqual(derived(tdd: 240).committedCapU, 5.0)
    }

    func testThePrimerStaysWithinItsOwnMaximumWhenTheCommittedCapIsAboveIt() {
        let s = derived(tdd: 200) // committed cap 5.0; any fraction above 0.5 would pass 2.5
        XCTAssertEqual(s.committedCapU, 5.0)
        XCTAssertEqual(s.primerCapU, BoostV5AutoConfig.primerCapMaxU)
    }

    func testReDerivationRaisesTheCommittedCapPast2_5AndStopsAt5() {
        let store = Store()
        store.value[.committedCapU] = 2.5
        store.run(derived(tdd: 100)) // baseline: derived 2.5
        for _ in 0 ..< 3 { store.run(derived(tdd: 160)) } // derived 4.0
        XCTAssertGreaterThan(store.value[.committedCapU]!, 2.5)
        for _ in 0 ..< 6 { store.run(derived(tdd: 400)) } // derived 5.0, and movement that would carry it further
        XCTAssertLessThanOrEqual(store.value[.committedCapU]!, 5.0 + 1E-9)
    }

    func testReDerivationHoldsACommittedCapItWouldCarryPast5To5() {
        // The Kotlin coerces every knob to its range; Trio clamps the committed cap explicitly.
        let store = Store()
        store.value[.committedCapU] = 4.8
        store.run(derived(tdd: 160)) // baseline: derived 4.0
        store.run(derived(tdd: 240)) // derived 5.0: 4.8 x 1.25 = 6.0, inside the 25% step
        XCTAssertEqual(store.value[.committedCapU]!, 5.0, accuracy: 1E-9)
    }

    func testReDerivationHoldsThePrimerToItsOwnMaximum() {
        let store = Store()
        store.value[.committedCapU] = 4.0
        store.value.removeValue(forKey: .primerCapU) // never written, so auto-config owns it
        store.run(derived(tdd: 160)) // 4.0 x 0.75 = 3.0 before the primer's 2.5 U maximum
        XCTAssertEqual(store.value[.primerCapU]!, BoostV5AutoConfig.primerCapMaxU, accuracy: 1E-9)
    }

    func testThePrimerFollowsARisingCommittedCapAtThePolicyFractionNotTheClampedRatio() {
        let s = derived(tdd: 200) // committed 5.0, primer held to 2.5: the ratio is no longer the fraction
        let start = (2.5 * s.primerFrac * 100).rounded() / 100
        let store = Store()
        store.value[.committedCapU] = 2.5
        store.value[.primerCapU] = start
        store.run(derived(tdd: 100)) // baseline: derived committed cap 2.5
        store.run(s) // the committed cap rises by the step limit
        let cap = store.value[.committedCapU]!
        XCTAssertGreaterThan(cap, 2.5)
        XCTAssertGreaterThanOrEqual(store.value[.primerCapU]!, start)
        XCTAssertEqual(store.value[.primerCapU]!, min(cap * s.primerFrac, BoostV5AutoConfig.primerCapMaxU), accuracy: 0.011)
    }

    func testThePrimerCeilingFollowsTheCommittedCap() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.value[.primerCapU] = 0.6
        store.run(suggestion(committedCapU: 1.0, primerCapU: 0.6)) // baselines
        store.run(suggestion(committedCapU: 1.2, primerCapU: 0.72))
        // The cap moved to 1.2, so the ceiling follows at the same fraction of it.
        XCTAssertEqual(store.value[.primerCapU]!, store.value[.committedCapU]! * 0.6, accuracy: 0.01)
    }

    func testTheCumulativeCapFollowsTheOperativeCapsNotTheDerivation() {
        let store = Store()
        store.value[.confirmedCapU] = 2.0 // the user's own, below the derived 4.65
        store.run(suggestion(confirmedCapU: 4.65))
        // 2.0 + 2 x 0.5 = 3.0, sized from what actually governs dosing.
        XCTAssertEqual(store.value[.cumulativeSmbCap60Min]!, 3.0, accuracy: 1E-9)
    }
}

/// Wall-clock cadence invariance for the meal-state ages and the ML null streak
/// (AAPS 0b1587f6b6 and cac09593ee).
final class CadenceInvarianceTests: XCTestCase {
    private let t0: Double = 1_700_000_000_000
    private func mins(_ m: Double) -> Double { t0 + m * 60000 }

    private func observing(lastAgeMs: Double) -> MealHypothesisState {
        MealHypothesisState(state: .observing, ageCycles: 0, lastAgeMs: lastAgeMs)
    }

    /// A cycle that keeps the state in OBSERVING: a modest rise, nothing that confirms or resets.
    private func step(_ current: MealHypothesisState, nowMs: Double) -> MealHypothesisState {
        MealHypothesisEngine.step(
            current: current, score: 0.5, eventualBg: 140, targetBg: 100,
            delta: 3, deltaAccl: 5, deltaDeclining: false, nowMs: nowMs
        )
    }

    func testTheAgeAdvancesOnceEveryFourMinutes() {
        var s = observing(lastAgeMs: t0)
        s = step(s, nowMs: mins(1))
        XCTAssertEqual(s.ageCycles, 0, "a one-minute cycle does not advance the age")
        s = step(s, nowMs: mins(2))
        XCTAssertEqual(s.ageCycles, 0)
        s = step(s, nowMs: mins(4))
        XCTAssertEqual(s.ageCycles, 1)
    }

    func testAFiveMinuteFeedAdvancesEveryCycle() {
        // Four minutes rather than five, deliberately: live five-minute users increment about every
        // 4.85 to 5.0 minutes, so a five-minute tick would intermittently skip and slow the whole
        // existing cohort from ten minutes to fifteen.
        var s = observing(lastAgeMs: t0)
        for cycle in 1 ... 3 {
            s = step(s, nowMs: mins(Double(cycle) * 4.85))
            XCTAssertEqual(s.ageCycles, cycle, "cycle \(cycle)")
        }
    }

    func testAOneMinuteFeedReachesTheConfirmAgeInAboutEightMinutes() {
        // Against two minutes without the tick, and ten for a five-minute user.
        var s = observing(lastAgeMs: t0)
        var minute = 0.0
        while s.ageCycles < 2, minute < 60 {
            minute += 1
            s = step(s, nowMs: mins(minute))
        }
        XCTAssertEqual(minute, 8, accuracy: 0.001)
    }

    func testWithoutAClockTheBehaviourIsUnchanged() {
        // Legacy callers and tests pass no clock, so the age ticks on every call exactly as before.
        var s = MealHypothesisState(state: .observing, ageCycles: 0)
        for cycle in 1 ... 3 {
            s = step(s, nowMs: 0)
            XCTAssertEqual(s.ageCycles, cycle)
        }
    }

    func testAStateChangeRestampsTheAnchor() {
        let s = observing(lastAgeMs: t0)
        let confirmed = MealHypothesisEngine.step(
            current: MealHypothesisState(
                state: .observing, ageCycles: 3, maxScoreInObserving: 1.0,
                maxEventualBgOffsetInObserving: 90, lastAgeMs: t0
            ),
            score: 1.0, eventualBg: 200, targetBg: 100, delta: 8, deltaAccl: 20,
            deltaDeclining: false, nowMs: mins(3)
        )
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertEqual(confirmed.lastAgeMs, mins(3), "the new state's clock starts now")
        XCTAssertEqual(s.lastAgeMs, t0)
    }

    func testTheMlNullStreakCountsElapsedTimeRatherThanInvocations() {
        // The renormalise threshold is three cycles, meant to be about fifteen minutes of a missing
        // model. Ungated that is three minutes on a one-minute feed.
        func inputs(nowMs: Double) -> V5Inputs {
            V5Inputs(
                delta: 1, shortAvgDelta: 1, deltaAccl: 0, bg: 120, eventualBg: 120, targetBg: 100,
                maxDelta: 1, minGuardBg: 120, minGuardThreshold: 80, deltaHistory: [1, 1, 1],
                iob: 0.3, maxIob: 6, baseInsulinReq: 0.5, roundSmbTo: 0.05, enableSmbPreChecks: true,
                mlHypoRisk: nil, mlMealLikely: nil, recentLowBg: 110, cumulativeRise30min: 3,
                hour: 13, exerciseActive: false, inPostExerciseWindow: false, asleep: false,
                nowMs: nowMs
            )
        }
        var persisted = V5PersistedState()
        // Five one-minute cycles advance the streak twice, not five times: the first cycle ticks
        // because nothing is stamped yet, and the fifth ticks four minutes after that stamp.
        for minute in 1 ... 5 {
            persisted = BoostV5Engine.decide(inputs(nowMs: mins(Double(minute))), persisted: persisted)
                .newPersistedState
        }
        XCTAssertEqual(persisted.mlMealLikelyNullStreak, 2)

        // Without a clock the count is one per invocation, as before.
        var ungated = V5PersistedState()
        for _ in 1 ... 5 {
            ungated = BoostV5Engine.decide(inputs(nowMs: 0), persisted: ungated).newPersistedState
        }
        XCTAssertEqual(ungated.mlMealLikelyNullStreak, 5)
    }
}
