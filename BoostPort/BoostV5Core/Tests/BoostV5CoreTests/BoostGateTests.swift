@testable import BoostV5Core
import XCTest

/// The overnight Boost gate (AAPS 47a815aedf, Kotlin V6StandDownTest), the boundary-exit hold and
/// the pre-meal and learner guards (AAPS a33752c9aa #8 and #18, Kotlin SeamSafetyGatesTest), and the
/// classification's reach past the gate and its HR evidence for rest (#11 and #12, Kotlin
/// ActivityGateClassificationTest and the HrActivityCalculatorTest additions).
final class BoostGateTests: XCTestCase {
    // MARK: - The gate (V6StandDownTest)

    func testFieldCaseNightModeOffInsideWindowSleepingClosesGate() {
        // 05:30 local, night mode off, detector SLEEPING, inside the default window.
        XCTAssertFalse(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: true, v6Active: true, detectorSleeping: true))
    }

    func testInsideWindowGateClosedWhateverDetectorOrToggleSay() {
        XCTAssertFalse(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: true, v6Active: true, detectorSleeping: false))
        XCTAssertFalse(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: true, v6Active: false, detectorSleeping: false))
    }

    func testOutsideWindowV6SleepingClosesGate() {
        XCTAssertFalse(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: false, v6Active: true, detectorSleeping: true))
    }

    func testOutsideWindowNonV6SleepingKeepsToggleGovernedBehaviour() {
        XCTAssertTrue(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: false, v6Active: false, detectorSleeping: true))
        XCTAssertFalse(BoostGate.isOpen(nightSleepPeriod: true, inNightWindow: false, v6Active: false, detectorSleeping: true))
    }

    func testDaytimeAwakeGateOpen() {
        XCTAssertTrue(BoostGate.isOpen(nightSleepPeriod: false, inNightWindow: false, v6Active: true, detectorSleeping: false))
    }

    func testInNightWindowIsAClockFact() {
        XCTAssertTrue(BoostGate.inNightWindow(nowMinuteOfDay: 5 * 60 + 30, startMinute: 1320, endMinute: 420))
        XCTAssertFalse(BoostGate.inNightWindow(nowMinuteOfDay: 420, startMinute: 1320, endMinute: 420))
        XCTAssertFalse(BoostGate.inNightWindow(nowMinuteOfDay: 3 * 60, startMinute: 420, endMinute: 420))
    }

    // MARK: - Boundary-exit hold (#18)

    private let min = 60000.0
    private let exitAt = 1_000_000_000.0

    func testBoundaryExitNextCycleStillAsleep() {
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt + 5 * min, lastBoundaryExitMs: exitAt,
            holdMin: BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10)
        )
        XCTAssertTrue(s.boundaryHold)
        XCTAssertTrue(s.detectorAsleep)
        // The inactivity raise is excluded through the classifier's `asleep` input.
        let r = ActivityClassifier.classify(ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 0, avgHeartRate: 0,
            asleep: s.detectorAsleep, thresholds: ActivityThresholds()
        ))
        XCTAssertNotEqual(r.state, .inactive)
    }

    func testBoundaryExitGateStaysClosedForSleepDrivenNightModeAndForV6() {
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt + 5 * min, lastBoundaryExitMs: exitAt,
            holdMin: BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10)
        )
        XCTAssertFalse(BoostGate.isOpen(
            nightSleepPeriod: s.nightSleepPeriod,
            inNightWindow: false,
            v6Active: false,
            detectorSleeping: s.detectorSleeping
        ))
        XCTAssertFalse(BoostGate.isOpen(
            nightSleepPeriod: s.nightSleepPeriod,
            inNightWindow: false,
            v6Active: true,
            detectorSleeping: s.detectorSleeping
        ))
    }

    func testBoundaryExitHoldLapsesAfterHysteresisPlusOneCycle() {
        XCTAssertEqual(BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10), 15)
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt + 15 * min, lastBoundaryExitMs: exitAt,
            holdMin: BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10)
        )
        XCTAssertFalse(s.boundaryHold)
        XCTAssertFalse(s.detectorAsleep)
        XCTAssertFalse(s.nightSleepPeriod)
    }

    func testBoundaryExitWithNightModeOffKeepsToggleGovernedPeriod() {
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: false, autoBySleep: true,
            nowMs: exitAt + 5 * min, lastBoundaryExitMs: exitAt,
            holdMin: BoostGate.boundaryExitHoldMin(sleepHysteresisMin: 10)
        )
        XCTAssertFalse(s.nightSleepPeriod)
        XCTAssertTrue(s.detectorAsleep) // inactivity still excluded
    }

    func testNoBoundaryExitRecordedSignalsAreDetectorsOwn() {
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt, lastBoundaryExitMs: nil, holdMin: 15
        )
        XCTAssertFalse(s.detectorSleeping)
        XCTAssertFalse(s.detectorAsleep)
        let p = BoostGate.sleepSignals(
            state: .preSleep, nightSleepPeriodRaw: true, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt, lastBoundaryExitMs: nil, holdMin: 15
        )
        XCTAssertTrue(p.detectorAsleep)
        XCTAssertFalse(p.detectorSleeping)
        XCTAssertTrue(p.nightSleepPeriod)
    }

    func testBoundaryExitInTheFutureIsNotHeld() {
        // A clock that steps backwards must not open an indefinite hold.
        let s = BoostGate.sleepSignals(
            state: .awake, nightSleepPeriodRaw: false, nightModeEnabled: true, autoBySleep: true,
            nowMs: exitAt - 5 * min, lastBoundaryExitMs: exitAt, holdMin: 15
        )
        XCTAssertFalse(s.boundaryHold)
    }

    // MARK: - Pre-meal target and learner (#8)

    func testPreMealTargetAppliesOnlyOutsideNightAwakeNoTtOutsidePostRescue() {
        XCTAssertNil(
            MealTimeLearner
                .preMealTargetBlock(inNightWindow: false, sleepState: .awake, tempTargetActive: false, postRescueWindow: false)
        )
    }

    func testPreMealTargetBlockedReasons() {
        XCTAssertEqual(
            MealTimeLearner
                .preMealTargetBlock(inNightWindow: true, sleepState: .awake, tempTargetActive: false, postRescueWindow: false),
            "night window"
        )
        XCTAssertEqual(
            MealTimeLearner
                .preMealTargetBlock(
                    inNightWindow: false,
                    sleepState: .sleeping,
                    tempTargetActive: false,
                    postRescueWindow: false
                ),
            "asleep"
        )
        XCTAssertEqual(
            MealTimeLearner
                .preMealTargetBlock(
                    inNightWindow: false,
                    sleepState: .preSleep,
                    tempTargetActive: false,
                    postRescueWindow: false
                ),
            "asleep"
        )
        XCTAssertEqual(
            MealTimeLearner
                .preMealTargetBlock(inNightWindow: false, sleepState: .awake, tempTargetActive: true, postRescueWindow: false),
            "temp target"
        )
        XCTAssertEqual(
            MealTimeLearner
                .preMealTargetBlock(inNightWindow: false, sleepState: .awake, tempTargetActive: false, postRescueWindow: true),
            "post-rescue"
        )
    }

    func testLearnerRecordsOnlyDaytimeSessionsWithDetectorAwake() {
        XCTAssertTrue(MealTimeLearner.sessionRecordable(inNightWindow: false, sleepState: .awake))
        XCTAssertFalse(MealTimeLearner.sessionRecordable(inNightWindow: true, sleepState: .awake))
        XCTAssertFalse(MealTimeLearner.sessionRecordable(inNightWindow: false, sleepState: .sleeping))
        XCTAssertFalse(MealTimeLearner.sessionRecordable(inNightWindow: false, sleepState: .preSleep))
    }

    // MARK: - Classification past the gate (#11) and HR evidence of rest (#12, 477e649338)

    private func inputs(
        raiseGateOpen: Bool,
        stepsActive: Bool = false,
        avgHr: Double = 0,
        hrIntegrationEnabled: Bool = false
    ) -> ActivityInputs {
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = hrIntegrationEnabled
        t.inactivitySteps = 400
        // Default thresholds: steps15 900 > 800 is ACTIVE; steps60 40 < 400 is the inactivity branch.
        return ActivityInputs(
            steps5: 0, steps15: stepsActive ? 900 : 0, steps30: 0, steps60: stepsActive ? 0 : 40,
            avgHeartRate: avgHr, raiseGateOpen: raiseGateOpen, thresholds: t
        )
    }

    func testGateClosedExerciseKeepsReducedProfileAndRaisedTarget() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: false, stepsActive: true))
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    func testGateClosedVigorousAerobicStillReducesProfileFurther() {
        // zone 4 (140 bpm at rest 60, max 180) with high steps
        let r = ActivityClassifier
            .classify(inputs(raiseGateOpen: false, stepsActive: true, avgHr: 140, hrIntegrationEnabled: true))
        XCTAssertEqual(r.state, .vigorousAerobic)
        XCTAssertEqual(r.profilePercent, 70)
    }

    func testGateClosedInactiveRaiseWithheld() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: false))
        XCTAssertNotEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 100)
    }

    func testGateOpenInactiveRaiseUnchangedForStepOnlyUsers() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: true))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130)
    }

    func testHrIntegrationOnNoUsableHrWithholdsRaise() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: true, avgHr: 0, hrIntegrationEnabled: true))
        XCTAssertEqual(r.state, .hrUnavailable)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testHrIntegrationOnZone1AllowsRaise() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: true, avgHr: 65, hrIntegrationEnabled: true))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130)
    }

    func testHrIntegrationOnZone2WithholdsRaiseLeavesTarget() {
        // 100 bpm at rest 60, max 180 is HRR 33%, zone 2: easy cycling with almost no steps.
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: true, avgHr: 100, hrIntegrationEnabled: true))
        XCTAssertEqual(r.state, .hrElevated)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testInactivityRaiseBlockedByHrZoneBoundaries() {
        let t = ActivityThresholds() // rest 60, max 180
        XCTAssertTrue(ActivityClassifier.inactivityRaiseBlockedByHr(avgHr: 100, thresholds: t))
        XCTAssertTrue(ActivityClassifier.inactivityRaiseBlockedByHr(avgHr: 110, thresholds: t))
        XCTAssertTrue(ActivityClassifier.inactivityRaiseBlockedByHr(avgHr: 160, thresholds: t))
        XCTAssertFalse(ActivityClassifier.inactivityRaiseBlockedByHr(avgHr: 65, thresholds: t))
        // No usable HR (none in the window, or frozen, which the host passes as 0) fails closed.
        XCTAssertTrue(ActivityClassifier.inactivityRaiseBlockedByHr(avgHr: 0, thresholds: t))
    }

    func testHrIntegrationOffRaiseStaysStepOnly() {
        let r = ActivityClassifier.classify(inputs(raiseGateOpen: true, avgHr: 100, hrIntegrationEnabled: false))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130)
    }
}
