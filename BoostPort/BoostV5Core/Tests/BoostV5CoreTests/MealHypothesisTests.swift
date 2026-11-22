@testable import BoostV5Core
import XCTest

final class MealHypothesisTests: XCTestCase {
    typealias E = MealHypothesisEngine
    private func obs(age: Int = 0, committed: Bool = false) -> MealHypothesisState {
        MealHypothesisState(
            state: .observing,
            ageCycles: age,
            maxScoreInObserving: 0.5,
            maxEventualBgOffsetInObserving: 10.0,
            committedInSession: committed
        )
    }

    private func idle() -> MealHypothesisState { MealHypothesisState() }

    // strong fast-carb signals
    let D = 12.0, A = 30.0, S = 0.7

    func testFastConfirmFromObservingOneCycle() {
        let r = E.step(
            current: obs(age: 0),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            asleep: false,
            exerciseActive: false,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(r.state, .confirmed)
        XCTAssertTrue(r.committedInSession)
    }

    func testFastConfirmStraightFromIdle() {
        let r = E.step(
            current: idle(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testNoFireWhileAsleep() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            asleep: true,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireWhileExercising() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            exerciseActive: true,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireWhenScoreLow() {
        let r = E.step(
            current: obs(),
            score: 0.45,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireSlowRise() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: 4.0,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testFix6SingleConfirmGuard() {
        let r = E.step(
            current: obs(age: 1, committed: true),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testDisabledToggleYoungObservingStays() {
        let r = E.step(
            current: obs(age: 0),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    // normal-path transitions
    func testIdleEntersObservingOnScore() {
        let r = E.step(
            current: idle(),
            score: 0.5,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testObservingConfirmsOnAgePlusPeaks() {
        // age 2, score>=0.55, offset (eventualBg-target=50)>=30, not committed → CONFIRMED
        let s = MealHypothesisState(
            state: .observing,
            ageCycles: 2,
            maxScoreInObserving: 0.6,
            maxEventualBgOffsetInObserving: 50.0
        )
        let r = E.step(
            current: s,
            score: 0.6,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .confirmed)
        XCTAssertTrue(r.committedInSession)
    }

    func testConfirmedToCommitted() {
        let r = E.step(
            current: MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true),
            score: 0.6,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .committed)
    }

    func testCommittedBacksOffToRecovering() {
        let r = E.step(
            current: MealHypothesisState(state: .committed, ageCycles: 1, committedInSession: true),
            score: 0.4,
            eventualBg: 150,
            targetBg: 100,
            delta: -2,
            deltaAccl: -10,
            deltaDeclining: true
        )
        XCTAssertEqual(r.state, .recovering)
    }

    func testRecoveringReengagesOnSecondRise() {
        let s = MealHypothesisState(state: .recovering, ageCycles: 1, committedInSession: true)
        let r = E.step(
            current: s,
            score: 0.5,
            eventualBg: 160,
            targetBg: 100,
            delta: 5,
            deltaAccl: 15,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .committed)
    }

    func testRecoveringExitsToIdleOnFall() {
        let s = MealHypothesisState(state: .recovering, ageCycles: 2, committedInSession: true)
        let r = E.step(
            current: s,
            score: 0.1,
            eventualBg: 90,
            targetBg: 100,
            delta: -3,
            deltaAccl: -2,
            deltaDeclining: true
        )
        XCTAssertEqual(r.state, .idle)
        XCTAssertFalse(r.committedInSession)
    }

    func testResetIfNeeded() {
        let (s, did) = E.resetIfNeeded(current: obs(), pumpDisconnected: true)
        XCTAssertTrue(did)
        XCTAssertEqual(s.state, .idle)
    }

    func testDeltaDeclining() {
        XCTAssertTrue(E.deltaDeclining([10, 6, 3]))
        XCTAssertFalse(E.deltaDeclining([3, 6, 10]))
        XCTAssertFalse(E.deltaDeclining([5, 5]))
    }

    // MARK: OBSERVING→CONFIRMED dose-adequacy gate (2026-07-02, mirrors AAPS 4bfd7bea32)

    // An OBSERVING run that already satisfies the score + eventualBG-offset peaks and the age gate, so
    // the ONLY remaining variable is confirmDoseAdequate.
    private func observedReady() -> MealHypothesisState {
        MealHypothesisState(
            state: .observing, ageCycles: 2,
            maxScoreInObserving: 0.60, maxEventualBgOffsetInObserving: 40.0, committedInSession: false
        )
    }

    func testConfirmsWhenShotAdequate() {
        let r = E.step(
            current: observedReady(), score: 0.60, eventualBg: 150, targetBg: 100,
            delta: 6, deltaAccl: 2, deltaDeclining: false, confirmDoseAdequate: true
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testDoesNotConfirmWhenShotInadequateHoldsInObserving() {
        // All other confirm predicates pass; only the dose floor blocks it. Score is above the
        // fall-back threshold, so it holds in OBSERVING rather than dropping to IDLE.
        let r = E.step(
            current: observedReady(), score: 0.60, eventualBg: 150, targetBg: 100,
            delta: 6, deltaAccl: 2, deltaDeclining: false, confirmDoseAdequate: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testDefaultArgPreservesLegacyConfirm() {
        let r = E.step(
            current: observedReady(), score: 0.60, eventualBg: 150, targetBg: 100,
            delta: 6, deltaAccl: 2, deltaDeclining: false
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testFastCarbPathNotGatedByDoseAdequacy() {
        // Sharp, corroborated rise with the toggle on still confirms in one cycle even when
        // confirmDoseAdequate=false — the fast-path is intentionally exempt.
        let r = E.step(
            current: MealHypothesisState(
                state: .observing, ageCycles: 0,
                maxScoreInObserving: 0.5, maxEventualBgOffsetInObserving: 10.0, committedInSession: false
            ),
            score: 0.7, eventualBg: 150, targetBg: 100, delta: 12, deltaAccl: 30,
            deltaDeclining: false, asleep: false, exerciseActive: false,
            fastConfirmEnabled: true, confirmDoseAdequate: false
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    // MARK: post-hypo rescue-carb guard on the fast-carb fast-path (2026-07-02, AAPS 1245d33a9a)

    func testRescueGuardSuppressesFastPathNearHypo() {
        // 60-min low 55 (rescue-carb rebound): guard off → fast path must NOT confirm.
        XCTAssertFalse(E.fastConfirmAllowed(true, recentLowBg: 55))
        let r = E.step(
            current: idle(), score: S, eventualBg: 150, targetBg: 100, delta: D, deltaAccl: A,
            deltaDeclining: false, asleep: false, exerciseActive: false,
            fastConfirmEnabled: E.fastConfirmAllowed(true, recentLowBg: 55)
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testRescueGuardBoundary() {
        // Exactly 80 allows; just below blocks.
        XCTAssertTrue(E.fastConfirmAllowed(true, recentLowBg: MealHypothesisConstants.fastConfirmMinRecentLowMgdl))
        XCTAssertFalse(E.fastConfirmAllowed(true, recentLowBg: MealHypothesisConstants.fastConfirmMinRecentLowMgdl - 0.1))
    }

    func testRescueGuardPassesThroughDisabledToggle() {
        XCTAssertFalse(E.fastConfirmAllowed(false, recentLowBg: 150))
    }

    func testNoRecentLowFastPathFires() {
        let r = E.step(
            current: idle(), score: S, eventualBg: 150, targetBg: 100, delta: D, deltaAccl: A,
            deltaDeclining: false, asleep: false, exerciseActive: false,
            fastConfirmEnabled: E.fastConfirmAllowed(true, recentLowBg: 110)
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    // MARK: fast-carb fast-path 2026-07-03 retune (AAPS d2f9a08108): Δ 8→6, accl 15→10, score 0.60→0.65

    func testRetunedConstants() {
        XCTAssertEqual(MealHypothesisConstants.fastConfirmDelta, 6.0)
        XCTAssertEqual(MealHypothesisConstants.fastConfirmAccl, 10.0)
        XCTAssertEqual(MealHypothesisConstants.fastConfirmScore, 0.65)
    }

    func testRetunedFastPathFiresAtNewBoundary() {
        // Exactly Δ=6, accl=10, score=0.65 — below the OLD thresholds (8/15) but at the new ones.
        let r = E.step(
            current: idle(), score: 0.65, eventualBg: 150, targetBg: 100, delta: 6.0, deltaAccl: 10.0,
            deltaDeclining: false, asleep: false, exerciseActive: false, fastConfirmEnabled: true
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testRetunedFastPathScoreRaisePaysForPhysicsRelaxation() {
        // Score 0.60 satisfied the OLD gate but not the new 0.65 — physics alone must not fire.
        let r = E.step(
            current: idle(), score: 0.60, eventualBg: 150, targetBg: 100, delta: 12.0, deltaAccl: 30.0,
            deltaDeclining: false, asleep: false, exerciseActive: false, fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testRetunedFastPathStillNeedsAllThreeSignals() {
        // Just under each new threshold blocks the path (others comfortably above).
        let underDelta = E.step(
            current: idle(), score: 0.7, eventualBg: 150, targetBg: 100, delta: 5.9, deltaAccl: 30.0,
            deltaDeclining: false, fastConfirmEnabled: true
        )
        XCTAssertNotEqual(underDelta.state, .confirmed)
        let underAccl = E.step(
            current: idle(), score: 0.7, eventualBg: 150, targetBg: 100, delta: 12.0, deltaAccl: 9.9,
            deltaDeclining: false, fastConfirmEnabled: true
        )
        XCTAssertNotEqual(underAccl.state, .confirmed)
    }
}
