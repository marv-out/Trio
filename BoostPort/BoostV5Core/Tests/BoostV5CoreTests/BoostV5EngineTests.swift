@testable import BoostV5Core
import XCTest

/// End-to-end V5 decision engine: the full decide() pipeline (score → state → budget → multiplier
/// → velocity → caps → safety gates), matching the AAPS DetermineBasalBoostV5.decide() behaviour.
final class BoostV5EngineTests: XCTestCase {
    private func baseInputs(
        state _: MealHypothesisState,
        deltaHistory: [Double] = [3, 4, 5],
        delta: Double = 5, deltaAccl: Double = 5, bg: Double = 150, eventualBg: Double = 150,
        minGuardBg: Double = 100, iob: Double = 0.3, maxIob: Double = 5, baseInsulinReq: Double = 1.0,
        cumulativeRise30min: Double = 60, recentLowBg: Double = 120, mlMealLikely: Double? = 0.5,
        fastConfirm: Bool = false
    ) -> V5Inputs {
        V5Inputs(
            delta: delta, shortAvgDelta: delta, deltaAccl: deltaAccl, bg: bg, eventualBg: eventualBg,
            targetBg: 100, maxDelta: abs(delta), minGuardBg: minGuardBg, minGuardThreshold: 80,
            deltaHistory: deltaHistory, iob: iob, maxIob: maxIob, baseInsulinReq: baseInsulinReq,
            roundSmbTo: 0.05, enableSmbPreChecks: true, mlHypoRisk: nil, mlMealLikely: mlMealLikely,
            recentLowBg: recentLowBg, cumulativeRise30min: cumulativeRise30min, hour: 13,
            exerciseActive: false, inPostExerciseWindow: false, fastCarbConfirmEnabled: fastConfirm
        )
    }

    func testIdleNoMealGivesNoDoseEvenWithReq() {
        // IDLE: action mult 1.0 → dose ≈ baseInsulinReq, but the state machine stays IDLE on a flat trace.
        let i = baseInputs(
            state: MealHypothesisState(),
            delta: 0,
            deltaAccl: 0,
            eventualBg: 95,
            cumulativeRise30min: 0,
            mlMealLikely: 0.0
        )
        let d = BoostV5Engine.decide(i, persisted: V5PersistedState())
        XCTAssertEqual(d.mealHypothesis, .idle)
    }

    func testConfirmedCommitIsCapped() {
        // Fast-carb path → CONFIRMED with a large baseInsulinReq; the CONFIRMED dose cap must bind.
        let i = baseInputs(
            state: MealHypothesisState(),
            delta: 12,
            deltaAccl: 30,
            eventualBg: 160,
            baseInsulinReq: 3.0,
            mlMealLikely: 0.7,
            fastConfirm: true
        )
        let d = BoostV5Engine.decide(i, persisted: V5PersistedState())
        XCTAssertEqual(d.mealHypothesis, .confirmed)
        XCTAssertLessThanOrEqual(d.finalDose, SafetyGateConstants.maxConfirmedCommitDoseU + 1E-9)
        XCTAssertGreaterThan(d.finalDose, 0.0)
    }

    func testMinGuardHardGateZeroesDose() {
        let i = baseInputs(
            state: MealHypothesisState(state: .confirmed, committedInSession: true),
            minGuardBg: 70
        ) // below threshold 80
        let d = BoostV5Engine.decide(
            i,
            persisted: V5PersistedState(mealHypothesis: MealHypothesisState(state: .confirmed, committedInSession: true))
        )
        XCTAssertEqual(d.finalDose, 0.0)
        XCTAssertEqual(d.phase3.reductions.hardGateFired, "min_guard_bg")
    }

    func testMaxIobClampLimitsDose() {
        // iob 4.9 of maxIob 5.0 → headroom 0.1 caps the dose.
        let i = baseInputs(
            state: MealHypothesisState(),
            delta: 12,
            deltaAccl: 30,
            eventualBg: 160,
            iob: 4.9,
            maxIob: 5.0,
            baseInsulinReq: 3.0,
            mlMealLikely: 0.7,
            fastConfirm: true
        )
        let d = BoostV5Engine.decide(i, persisted: V5PersistedState())
        XCTAssertLessThanOrEqual(d.finalDose, 0.1 + 1E-9)
    }

    func testStatePersistsAcrossCycles() {
        // A fresh CONFIRMED then next cycle should advance to COMMITTED.
        let i1 = baseInputs(
            state: MealHypothesisState(),
            delta: 12,
            deltaAccl: 30,
            eventualBg: 160,
            mlMealLikely: 0.7,
            fastConfirm: true
        )
        let d1 = BoostV5Engine.decide(i1, persisted: V5PersistedState())
        XCTAssertEqual(d1.mealHypothesis, .confirmed)
        let d2 = BoostV5Engine.decide(i1, persisted: d1.newPersistedState)
        XCTAssertEqual(d2.mealHypothesis, .committed)
    }

    func testVelocityScaledDoseFactor() {
        XCTAssertEqual(SafetyGates.velocityScaledDoseFactor(60), 1.0, accuracy: 1E-9) // sharp → full
        XCTAssertEqual(SafetyGates.velocityScaledDoseFactor(25), 0.40, accuracy: 1E-9) // slow → floor
        XCTAssertEqual(SafetyGates.velocityScaledDoseFactor(37.5), 0.70, accuracy: 1E-9) // midpoint
    }

    func testVelocityScalingTrimsSlowMeal() {
        // Use a small baseInsulinReq so neither hits the COMMITTED cap (else the cap masks scaling).
        let confirmed = MealHypothesisState(state: .confirmed, committedInSession: true)
        let slow = baseInputs(state: confirmed, baseInsulinReq: 0.2, cumulativeRise30min: 25)
        let fast = baseInputs(state: confirmed, baseInsulinReq: 0.2, cumulativeRise30min: 60)
        let dSlow = BoostV5Engine.decide(slow, persisted: V5PersistedState(mealHypothesis: confirmed))
        let dFast = BoostV5Engine.decide(fast, persisted: V5PersistedState(mealHypothesis: confirmed))
        XCTAssertLessThan(dSlow.insulinToDeliver, dFast.insulinToDeliver)
    }

    // MARK: 2026-07-03 sustained-score early confirm through decide() (AAPS 242a6e179d)

    // OBSERVING one cycle before the standard age gate with the score/offset peaks already met.
    private func observingOneCycleEarly() -> MealHypothesisState {
        MealHypothesisState(
            state: .observing,
            ageCycles: MealHypothesisConstants.confirmMinObservingAge - 1,
            maxScoreInObserving: 0.60,
            maxEventualBgOffsetInObserving: 40.0,
            committedInSession: false
        )
    }

    // Inputs producing a confirm-ready score (≥ 0.55): delta 8, accl 20, ml 0.7, rise 48, hour 13.
    private func scoreReadyInputs() -> V5Inputs {
        baseInputs(
            state: observingOneCycleEarly(), delta: 8, deltaAccl: 20, eventualBg: 160,
            cumulativeRise30min: 48, mlMealLikely: 0.7
        )
    }

    func testDecideThreadsLastCycleScoreIntoEarlyConfirm() {
        let inputs = scoreReadyInputs()
        // Sanity: this cycle's score is confirm-ready.
        let probe = BoostV5Engine.decide(inputs, persisted: V5PersistedState(mealHypothesis: observingOneCycleEarly()))
        XCTAssertGreaterThanOrEqual(probe.score, MealHypothesisConstants.confirmScore)

        // WITHOUT a ready previous score (cold start / low last cycle): legacy timing → holds.
        let cold = BoostV5Engine.decide(
            inputs,
            persisted: V5PersistedState(mealHypothesis: observingOneCycleEarly(), lastCycleScore: nil)
        )
        XCTAssertEqual(cold.mealHypothesis, .observing)
        let lowPrev = BoostV5Engine.decide(
            inputs,
            persisted: V5PersistedState(mealHypothesis: observingOneCycleEarly(), lastCycleScore: 0.40)
        )
        XCTAssertEqual(lowPrev.mealHypothesis, .observing)

        // WITH a ready previous score: the age gate opens one cycle early → CONFIRMED.
        let early = BoostV5Engine.decide(
            inputs,
            persisted: V5PersistedState(mealHypothesis: observingOneCycleEarly(), lastCycleScore: 0.60)
        )
        XCTAssertEqual(early.mealHypothesis, .confirmed)
    }

    func testDecidePersistsThisCyclesScoreForNextCycle() {
        let d = BoostV5Engine.decide(scoreReadyInputs(), persisted: V5PersistedState())
        XCTAssertEqual(d.newPersistedState.lastCycleScore, d.score)
    }

    func testLastCycleScoreIsNotSerialized() throws {
        // Mirrors the AAPS idiom (in-memory cache only): a JSON round-trip must DROP
        // lastCycleScore so a process restart fails safe to legacy confirm timing.
        let state = V5PersistedState(
            mealHypothesis: observingOneCycleEarly(),
            mlMealLikelyNullStreak: 2,
            lastRunMs: 123_456.0,
            lastCycleScore: 0.61
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("lastCycleScore"))
        let decoded = try JSONDecoder().decode(V5PersistedState.self, from: data)
        XCTAssertNil(decoded.lastCycleScore)
        // The serialized fields still round-trip.
        XCTAssertEqual(decoded.mealHypothesis, state.mealHypothesis)
        XCTAssertEqual(decoded.mlMealLikelyNullStreak, 2)
        XCTAssertEqual(decoded.lastRunMs, 123_456.0)
    }

    func testStoreCacheCarriesLastCycleScoreAcrossCycles() {
        // BoostV5Store's in-memory cache (AAPS V5StateStore idiom) must carry the
        // non-serialized lastCycleScore between mutateState cycles within a process,
        // while a FRESH store instance (≈ app restart) loses it.
        let suite = "boost-v5-store-cache-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoostV5Store(defaults: defaults)
        store.mutateState { state in state.lastCycleScore = 0.58 }
        let sameProcess = store.mutateState { state in state.lastCycleScore }
        XCTAssertEqual(sameProcess, 0.58)

        let restarted = BoostV5Store(defaults: defaults)
        let afterRestart = restarted.mutateState { state in state.lastCycleScore }
        XCTAssertNil(afterRestart)
    }
}
