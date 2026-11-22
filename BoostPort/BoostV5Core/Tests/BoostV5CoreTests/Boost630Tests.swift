@testable import BoostV5Core
import XCTest

/// The dosing changes of Boost 6.3.0 on AAPS 4.0.0 (tag `4.0.0-boost-6.3.0`), one test or more for
/// each, named after the README's "Dosing changes from Boost 6.2.0".
final class Boost630Tests: XCTestCase {
    typealias E = MealHypothesisEngine
    typealias Apply = BoostV5AutoConfigApply
    typealias Knob = BoostAutoConfigKnob

    // MARK: meal state held while rising (AAPS 5600a68cfb)

    func testCommittedHoldsWhileStillRising() {
        // Slowing (accl -10, declining) but still rising 4 mg/dL per 5 min: stays COMMITTED.
        let r = E.step(
            current: MealHypothesisState(state: .committed, ageCycles: 1, committedInSession: true),
            score: 0.4, eventualBg: 180, targetBg: 100, delta: 4, deltaAccl: -10, deltaDeclining: true
        )
        XCTAssertEqual(r.state, .committed)
    }

    func testCommittedBacksOffBelowThreeMgdl() {
        let r = E.step(
            current: MealHypothesisState(state: .committed, ageCycles: 1, committedInSession: true),
            score: 0.4, eventualBg: 180, targetBg: 100, delta: 2.9, deltaAccl: -10, deltaDeclining: true
        )
        XCTAssertEqual(r.state, .recovering)
    }

    func testRecoveringReengagesOnAFastRiseWithoutAcceleration() {
        let s = MealHypothesisState(state: .recovering, ageCycles: 1, committedInSession: true)
        let fast = E.step(
            current: s, score: 0.5, eventualBg: 160, targetBg: 100, delta: 8.5, deltaAccl: 0, deltaDeclining: false
        )
        XCTAssertEqual(fast.state, .committed)
        let notFast = E.step(
            current: s, score: 0.5, eventualBg: 160, targetBg: 100, delta: 7.5, deltaAccl: 0, deltaDeclining: false
        )
        XCTAssertEqual(notFast.state, .recovering)
    }

    // MARK: RECOVERING capped at the committed cap (AAPS 72f8bc93bc)

    func testRecoveringIsCappedAtTheCommittedCap() {
        XCTAssertEqual(SafetyGates.applyStateDoseCap(.recovering, 3.0, committedCapU: 1.2), 1.2, accuracy: 1E-9)
        XCTAssertEqual(SafetyGates.applyStateDoseCap(.observing, 3.0, committedCapU: 1.2), 3.0, accuracy: 1E-9)
    }

    // MARK: V1 low-glucose threshold and suspend tag (AAPS 899f6bbe8e, 10c1c01306)

    func testAcceleratingRiseLowersTheThresholdOnlyWhileRising() {
        // Rising and accelerating: 65.
        XCTAssertEqual(BoostV1Engine.boostAccelLoweredThreshold(80, delta: 4, shortAvgDelta: 2, lgsThreshold: nil), 65)
        // A slowing fall has delta > shortAvg too (deltaAccl > 0) but is not a rise: unchanged.
        XCTAssertEqual(BoostV1Engine.boostAccelLoweredThreshold(80, delta: -1, shortAvgDelta: -3, lgsThreshold: nil), 80)
        // Never below the user's LGS setting.
        XCTAssertEqual(BoostV1Engine.boostAccelLoweredThreshold(80, delta: 4, shortAvgDelta: 2, lgsThreshold: 75), 75)
    }

    func testLowSuspendTagsOnlyZeroTemps() {
        let p = V1Profile(
            maxIob: 5, maxDailyBasal: 1, maxBasal: 4, minBg: 100, maxBg: 100, carbRatio: 10, sens: 50,
            maxDailySafetyMultiplier: 3, currentBasalSafetyMultiplier: 4,
            enableUAM: true, smbInterval: 3, enableSMBWithCOB: true, enableSMBWithTemptarget: false,
            allowSMBWithHighTemptarget: false, enableSMBAlways: true, enableSMBAfterCarbs: true,
            maxSMBBasalMinutes: 15, maxUAMSMBBasalMinutes: 20, bolusIncrement: 0.05, carbsReqThreshold: 1,
            currentBasal: 1, temptargetSet: false, autosensMax: 1.2, lgsThreshold: nil,
            variableSens: 50, insulinDivisor: 75, tdd: 30, dynISFBgCap: 210, dynISFBgCapped: 0,
            sensNormalTarget: 50, normalTarget: 100, dynISFvelocity: 1, insulinPeak: 75,
            boostActive: true, profileSwitch: 100, boostBolus: 2, boostMaxIOB: 8, boostInsulinReq: 90,
            boostScale: 2.2, boostPercentScale: 200, enableBoostPercentScale: true, enableCircadianISF: false,
            recentLowBG: 120
        )
        var zero = V1Result()
        BoostV1Engine.lowTempBasal(-0.5, 30, p, &zero, V1CurrentTemp(duration: 0, rate: 0))
        XCTAssertTrue(zero.reason.contains(BoostV1Engine.lowSuspendTag))
        XCTAssertEqual(zero.rate, 0)
        var low = V1Result()
        BoostV1Engine.lowTempBasal(0.3, 30, p, &low, V1CurrentTemp(duration: 0, rate: 0))
        XCTAssertFalse(low.reason.contains(BoostV1Engine.lowSuspendTag))
    }

    // MARK: auto-config re-derivation (AAPS Boost 6.3.0 audits 15 and 22)

    private final class Store {
        var value: [Knob: Double] = [
            .aggression: 1.0, .hypoCaution: 1.0, .confirmedCapU: 2.5,
            .committedCapU: 0.5, .cumulativeSmbCap60Min: 10.0, .primerCapU: 0.3
        ]
        var baseline: [Knob: Double] = [:]
        var pending: [Knob: Double] = [:]
        var written: [Knob: Double] = [:]
        var tuned: Set<Knob> = []

        @discardableResult func run(_ s: BoostV5AutoConfig.Suggestion, tbr70: Double = 2.0) -> [Apply.Resolution] {
            Apply.redrive(
                suggestion: s, tbrBelow70Pct: tbr70, timeBelow54Pct: 0.2,
                storedValue: { self.value[$0] }, currentDefault: { _ in 0 },
                baselineValue: { self.baseline[$0] }, pendingValue: { self.pending[$0] },
                put: { self.value[$0] = $1 },
                setBaseline: { self.baseline[$0] = $1 },
                setPending: { k, v in if let v { self.pending[k] = v } else { self.pending.removeValue(forKey: k) } },
                isUserTuned: { self.tuned.contains($0) },
                lastWritten: { self.written[$0] },
                recordWritten: { self.written[$0] = $1 }
            )
        }
    }

    private func suggestion(
        aggression: Double = 1.0, hypoCaution: Double = 1.0, committedCapU: Double = 0.5, primerCapU: Double = 0.3
    ) -> BoostV5AutoConfig.Suggestion {
        BoostV5AutoConfig.Suggestion(
            aggression: aggression, hypoCaution: hypoCaution, confirmedCapU: 2.5, committedCapU: committedCapU,
            cumulativeSmbCap60MinU: BoostV5AutoConfig.cumulativeCap60Min(confirmedCapU: 2.5, committedCapU: committedCapU),
            bolusCapU: 10, fastCarbConfirm: true, aggressiveEarlyConfirm: false,
            velocityBudgetFloor: false, primerCapU: primerCapU,
            primerFrac: committedCapU > 0 ? primerCapU / committedCapU : 0, primerTbrFallback: false, rationale: []
        )
    }

    func testAggressionIsNotAutoRaisedPastNeutral() {
        let store = Store()
        store.run(suggestion(aggression: 1.0)) // baselines
        store.run(suggestion(aggression: 1.2))
        let out = store.run(suggestion(aggression: 1.2))
        XCTAssertEqual(store.value[.aggression], 1.0)
        XCTAssertEqual(out.first { $0.knob == .aggression }?.outcome, .atNeutralCeiling)
    }

    func testAggressionRaiseStopsAtNeutral() {
        let store = Store()
        store.value[.aggression] = 0.9
        store.run(suggestion(aggression: 0.9))
        store.run(suggestion(aggression: 1.1))
        store.run(suggestion(aggression: 1.1)) // confirmed twice
        XCTAssertEqual(store.value[.aggression]!, 1.0, accuracy: 1E-9)
    }

    func testFallingHypoCautionIsHeldByTheRaiseGuard() {
        let store = Store()
        store.value[.hypoCaution] = 1.5
        store.run(suggestion(hypoCaution: 1.5))
        let out = store.run(suggestion(hypoCaution: 1.2), tbr70: 5.0)
        XCTAssertEqual(store.value[.hypoCaution], 1.5)
        XCTAssertEqual(out.first { $0.knob == .hypoCaution }?.outcome, .suggestedNotAppliedTbr)
    }

    func testAPrimerSetToZeroIsKept() {
        let store = Store()
        store.value[.primerCapU] = 0
        let out = store.run(suggestion(committedCapU: 0.5, primerCapU: 0.3))
        XCTAssertEqual(store.value[.primerCapU], 0)
        XCTAssertEqual(out.first { $0.knob == .primerCapU }?.outcome, .keptUserTuned)
    }

    func testAPrimerTheUserChangedIsKept() {
        let store = Store()
        store.tuned = [.primerCapU]
        store.written[.primerCapU] = 0.3
        store.value[.primerCapU] = 0.45 // edited by hand since auto-config wrote 0.3
        store.run(suggestion(committedCapU: 1.0, primerCapU: 0.6))
        XCTAssertEqual(store.value[.primerCapU], 0.45)
    }

    func testALargerPrimerWaitsForTheRaiseGuard() {
        let store = Store()
        store.value[.committedCapU] = 1.0 // the primer is sized from the operative committed cap
        store.run(suggestion(committedCapU: 1.0, primerCapU: 0.6), tbr70: 5.0)
        XCTAssertEqual(store.value[.primerCapU], 0.3)
        store.run(suggestion(committedCapU: 1.0, primerCapU: 0.6))
        XCTAssertEqual(store.value[.primerCapU]!, 0.6, accuracy: 1E-9)
    }

    func testAUserSetCumulativeCapIsKept() {
        let store = Store()
        store.tuned = [.cumulativeSmbCap60Min]
        store.value[.cumulativeSmbCap60Min] = 4.0 // not the recomputation, no record of a write
        let out = store.run(suggestion())
        XCTAssertEqual(store.value[.cumulativeSmbCap60Min], 4.0)
        XCTAssertEqual(out.first { $0.knob == .cumulativeSmbCap60Min }?.outcome, .keptUserTuned)
    }

    // MARK: weekly re-evaluation of the on/off settings (AAPS audit 16)

    private func route(
        wc: Bool, prev: Bool?, stored: Bool, lastWritten: Bool? = nil, bg: Int = 5000
    ) -> (Apply.SwitchResolution, Bool) {
        var v = stored
        let r = Apply.resolvePrimerRoute(
            wellControlled: wc, bgReadings: bg, previousWellControlled: prev, stored: stored,
            lastWritten: lastWritten, put: { v = $0 }, recordWritten: { _ in }, recordWellControlled: { _ in }
        )
        return (r, v)
    }

    func testPrimerRouteTightensAtOnceAndLoosensAfterTwoWindows() {
        XCTAssertEqual(route(wc: false, prev: nil, stored: false).1, true)
        XCTAssertEqual(route(wc: true, prev: nil, stored: true, lastWritten: true).0.outcome, .awaitingConfirmation)
        XCTAssertEqual(route(wc: true, prev: true, stored: true, lastWritten: true).1, false)
        // A temp basal auto-config has no record of writing may be the person's: never moved to the bolus.
        XCTAssertEqual(route(wc: true, prev: true, stored: true).1, true)
        XCTAssertEqual(route(wc: true, prev: true, stored: true).0.outcome, .keptUserTuned)
        XCTAssertEqual(route(wc: false, prev: nil, stored: false, bg: 100).0.outcome, .insufficientEvidence)
        XCTAssertEqual(route(wc: false, prev: nil, stored: false, lastWritten: true).0.outcome, .keptUserTuned)
    }

    private func sw(
        allows: Bool, guardOn: Bool = false, prev: Bool?, stored: Bool, lastWritten: Bool? = nil, marked: Bool = false
    ) -> (Apply.SwitchResolution, Bool) {
        var v = stored
        let r = Apply.resolveInsulinAddingSwitch(
            allowsOn: allows, raiseGuard: guardOn, bgReadings: 5000, previousAllowsOn: prev, stored: stored,
            defaultValue: false, lastWritten: lastWritten, userMarked: marked,
            put: { v = $0 }, recordWritten: { _ in }, recordVerdict: { _ in }
        )
        return (r, v)
    }

    func testInsulinAddingSwitchOffAtOnceOnOnlyAfterTwoWindows() {
        XCTAssertEqual(sw(allows: false, prev: nil, stored: true, lastWritten: true).1, false)
        XCTAssertEqual(sw(allows: true, prev: nil, stored: false).0.outcome, .awaitingConfirmation)
        XCTAssertEqual(sw(allows: true, prev: true, stored: false).1, true)
        XCTAssertEqual(sw(allows: true, guardOn: true, prev: true, stored: false).0.outcome, .suggestedNotAppliedTbr)
        XCTAssertEqual(sw(allows: false, prev: nil, stored: true, marked: true).1, true)
    }
}
