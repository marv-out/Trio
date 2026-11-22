@testable import BoostV5Core
import XCTest

/// Verifies the step + HR activity classification port of AAPS Boost
/// (`HrActivityCalculator` + `OpenAPSBoostPlugin.calculateBoostActivity`).
///
/// Covered: Karvonen zone boundaries (30/40/60/80% HRR); step-only ACTIVE /
/// INACTIVE / normal; HR-fused VIGOROUS / RESISTANCE / STRESS; the resulting
/// profilePercent + targetBg per state; and the `exerciseActive` flag.
final class ActivityClassifierTests: XCTestCase {
    // Default rest=60, max=180 → reserve = 120, so HRR% = (hr - 60) / 120 * 100.
    private let rest = 60
    private let max = 180

    // MARK: - Karvonen zone boundaries

    func testKarvonenZoneBoundaries() {
        // reserve = 120. Boundary BPMs: 30% = 96, 40% = 108, 60% = 132, 80% = 156.
        // Just below boundary → lower zone; at/above boundary → next zone.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 60, rest: rest, max: max), 1) // 0%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 95, rest: rest, max: max), 1) // <30%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 96, rest: rest, max: max), 2) // ==30%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 107, rest: rest, max: max), 2) // <40%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 108, rest: rest, max: max), 3) // ==40%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 131, rest: rest, max: max), 3) // <60%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 132, rest: rest, max: max), 4) // ==60%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 155, rest: rest, max: max), 4) // <80%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 156, rest: rest, max: max), 5) // ==80%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 200, rest: rest, max: max), 5) // >80%
    }

    func testKarvonenZoneClampsReserveToAvoidDivideByZero() {
        // rest == max → reserve coerced to 1; any hr ABOVE rest is a huge HRR → zone 5.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 120, rest: 100, max: 100), 5)
        // hr exactly at rest → HRR 0 → zone 1 (even with the clamp).
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 100, rest: 100, max: 100), 1)
        // At rest exactly with a real reserve, HRR = 0 → zone 1.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 100, rest: 100, max: 200), 1)
    }

    // MARK: - Step-only path (HR integration disabled)

    private func stepOnlyInputs(s5: Int, s15: Int, s30: Int, s60: Int) -> ActivityInputs {
        ActivityInputs(
            steps5: s5, steps15: s15, steps30: s30, steps60: s60,
            avgHeartRate: 0,
            thresholds: ActivityThresholds() // hrIntegrationEnabled defaults false
        )
    }

    func testStepOnlyActiveWhenAnyThresholdExceeded() {
        // steps15 = 900 > default 800 → ACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 900, s30: 0, s60: 0))
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80) // activityPct default
        XCTAssertEqual(r.targetBgMgdl, 150)
        XCTAssertTrue(r.exerciseActive)
    }

    func testStepOnlyActiveViaShortWindow() {
        // steps5 = 500 > default 420 → ACTIVE even with low longer windows.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 500, s15: 0, s30: 0, s60: 0))
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    func testStepOnlyInactiveWhenBelowInactivitySteps() {
        // Not active and steps60 (100) < inactivitySteps (500) → INACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130) // inactivityPct default
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testStepOnlyNormalBetweenThresholds() {
        // Not active, steps60 (600) >= inactivitySteps (500) → normal.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 600))
        XCTAssertEqual(r.state, .normal)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testStepThresholdIsStrictGreaterThan() {
        // steps15 exactly equal to threshold (800) does NOT trigger ACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 800, s30: 0, s60: 800))
        XCTAssertEqual(r.state, .normal)
    }

    // MARK: - HR-fused path (HR integration enabled)

    private func hrThresholds(stress: Bool = false) -> ActivityThresholds {
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = true
        t.hrStressDetection = stress
        return t
    }

    func testHrFusedVigorousAerobic() {
        // Step-active (steps15 = 900) + high HR-fusion steps (≥300) + zone 4 (hr 140) → VIGOROUS.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 140, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .vigorousAerobic)
        // activityPct (80) - 10 = 70, min 50 → 70.
        XCTAssertEqual(r.profilePercent, 70)
        XCTAssertEqual(r.targetBgMgdl, 150)
        XCTAssertTrue(r.exerciseActive)
    }

    func testVigorousProfileFloorAt50() {
        // Low activityPct so activityPct - 10 < 50 → floor at 50.
        var t = hrThresholds()
        t.activityPct = 55
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 160, thresholds: t // zone 5
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .vigorousAerobic)
        XCTAssertEqual(r.profilePercent, 50)
    }

    func testHrFusedModerateAerobicFallsBackToActiveEffect() {
        // Step-active + moderate fusion steps (100..<300) + zone 2 (hr 100) → MODERATE_AEROBIC,
        // which produces the step-only ACTIVE effect.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 100, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    func testHrFusedResistanceFromStepActiveLowFusionSteps() {
        // Step-active via steps5 (500 > 420) but HR-fusion steps15 low (<30) + zone 3 (hr 120)
        // → RESISTANCE: profile unchanged (100), target 160.
        let inputs = ActivityInputs(
            steps5: 500, steps15: 0, steps30: 0, steps60: 0,
            avgHeartRate: 120, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100) // unchanged baseline
        XCTAssertEqual(r.targetBgMgdl, 160)
        XCTAssertTrue(r.exerciseActive)
    }

    func testHrOnlyResistanceWithoutStepActivity() {
        // Not step-active, steps60 (600) >= inactivitySteps, low fusion steps + zone 4 (hr 140)
        // → HR-only RESISTANCE.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 600,
            avgHeartRate: 140, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertEqual(r.targetBgMgdl, 160)
    }

    func testStressIsInertMatchingAAPS() {
        // STRESS is dead code in AAPS (never reaches activityState / never raises target). The port
        // mirrors that: even with hrStressDetection ON, low steps + zone 2-3 must NOT classify STRESS.
        // It falls through identically to the detection-off case. At 100 bpm (zone 2) that is now
        // HR_ELEVATED with the inactivity raise withheld (AAPS 477e649338), where it was INACTIVE.
        let onInputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 100,
            avgHeartRate: 100, thresholds: hrThresholds(stress: true)
        )
        let on = ActivityClassifier.classify(onInputs)
        XCTAssertNotEqual(on.state, .stress)
        XCTAssertEqual(on.state, .hrElevated)
        XCTAssertNil(on.targetBgMgdl) // no 160 target raise
        XCTAssertFalse(on.exerciseActive)

        let offInputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 100,
            avgHeartRate: 100, thresholds: hrThresholds(stress: false)
        )
        let off = ActivityClassifier.classify(offInputs)
        XCTAssertEqual(off.state, on.state) // identical with detection on or off
        XCTAssertEqual(off.profilePercent, 100)
    }

    func testHrEnabledButNoHrSignalUsesStepOnly() {
        // HR integration enabled but avgHeartRate 0 → no fusion; step-active → ACTIVE.
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = true
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 0, thresholds: t
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    // MARK: - 2026-07-21 elevated-HR exercise safety (AAPS 45f17cca5a)

    func testDeadZoneStepsWithZone3HrClassifyAsResistance() {
        // Regression guard for the reported incident. 64 steps sits between the low threshold (30)
        // and the moderate one (100), so at zone 3 it previously matched no fusion branch, fell
        // through to resting, and the inactivity branch then added insulin during exercise. The
        // widened branch must catch it. hr 110 gives (110 - 60) / 120 = 41.7% HRR, zone 3.
        // steps60 = 600 keeps this off the inactivity path so the fusion result is what is tested.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 64, steps30: 0, steps60: 600,
            avgHeartRate: 110, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100) // profile unchanged: no insulin added
        XCTAssertEqual(r.targetBgMgdl, 160)
        XCTAssertTrue(r.exerciseActive)
    }

    func testInactivitySuppressedByElevatedHrHelper() {
        let t = hrThresholds()
        // Zone 3 (110 bpm, 41.7% HRR) and above suppress the inactivity insulin.
        XCTAssertTrue(ActivityClassifier.inactivitySuppressedByElevatedHr(avgHr: 110, thresholds: t))
        XCTAssertTrue(ActivityClassifier.inactivitySuppressedByElevatedHr(avgHr: 160, thresholds: t))
        // Zone 2 (100 bpm, 33.3%) and zone 1 (65 bpm) do not.
        XCTAssertFalse(ActivityClassifier.inactivitySuppressedByElevatedHr(avgHr: 100, thresholds: t))
        XCTAssertFalse(ActivityClassifier.inactivitySuppressedByElevatedHr(avgHr: 65, thresholds: t))
        // No HR signal does not suppress, matching the Kotlin null check.
        XCTAssertFalse(ActivityClassifier.inactivitySuppressedByElevatedHr(avgHr: 0, thresholds: t))
    }

    func testInactivityBranchSuppressedWhenHeartRateIsElevated() {
        // steps60 = 64 is below inactivitySteps (500), so this is the inactivity branch, which
        // raises the profile to 130% and adds insulin. At zone 3 that must not happen.
        let elevated = ActivityInputs(
            steps5: 0, steps15: 64, steps30: 0, steps60: 64,
            avgHeartRate: 110, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(elevated)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertEqual(r.targetBgMgdl, 160)

        // Zone 1 on the same steps still takes the inactivity path, so the guard is not blanket.
        // (Zone 2 used to as well; since AAPS 477e649338 it withholds the raise, tested below.)
        let calm = ActivityInputs(
            steps5: 0, steps15: 64, steps30: 0, steps60: 64,
            avgHeartRate: 65, thresholds: hrThresholds()
        )
        let c = ActivityClassifier.classify(calm)
        XCTAssertEqual(c.state, .inactive)
        XCTAssertEqual(c.profilePercent, 130)
        XCTAssertNil(c.targetBgMgdl)
    }

    func testElevatedHrGuardIsInertWhenHrIntegrationDisabled() {
        // With HR integration off the guard must not fire: step-only behaviour is unchanged.
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = false
        let inputs = ActivityInputs(
            steps5: 0, steps15: 64, steps30: 0, steps60: 64,
            avgHeartRate: 110, thresholds: t
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130)
    }

    // MARK: - 2026-07-31 inactivity sleep exclusions (AAPS 37a79aac83, 483d2fec20)

    func testInactivityFiresWhenAwakeAndOutsideTheNightWindow() {
        // Baseline for the three exclusion tests below: nothing set, so the branch fires.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130)
    }

    func testInactivitySuppressedInsideTheConfiguredNightWindow() {
        var i = stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100)
        i.inNightWindow = true
        let r = ActivityClassifier.classify(i)
        XCTAssertNotEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 100) // no profile raise, so no added insulin
        XCTAssertFalse(r.exerciseActive)
    }

    func testInactivitySuppressedWhileTheDetectorHoldsSleep() {
        var i = stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100)
        i.asleep = true
        XCTAssertEqual(ActivityClassifier.classify(i).profilePercent, 100)
    }

    func testInactivitySuppressedDuringTheMorningLieIn() {
        var i = stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100)
        i.sleepInActive = true
        XCTAssertEqual(ActivityClassifier.classify(i).profilePercent, 100)
    }

    func testNightWindowExclusionNeedsNoSensorSignal() {
        // The point of keying on the clock: it holds with no HR, no detector state and no lie-in.
        var i = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 0,
            avgHeartRate: 0, inNightWindow: true, asleep: false, sleepInActive: false,
            thresholds: ActivityThresholds()
        )
        XCTAssertEqual(ActivityClassifier.classify(i).profilePercent, 100)
        i.inNightWindow = false
        XCTAssertEqual(ActivityClassifier.classify(i).profilePercent, 130)
    }

    func testEqualNightTimesAreAnEmptyWindowNotAWholeDay() {
        // Guards the 2026-07-02 behaviour the Kotlin carried into NightWindow: start == end must
        // not union to cover the day, which would make it permanently night.
        XCTAssertFalse(NightMode.minuteInWindow(now: 300, start: 1320, end: 1320))
        XCTAssertFalse(NightMode.minuteInWindow(now: 1320, start: 1320, end: 1320))
        // And the ordinary wrap still works: 22:00 to 07:00 contains 06:09 but not 12:00.
        XCTAssertTrue(NightMode.minuteInWindow(now: 6 * 60 + 9, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(NightMode.minuteInWindow(now: 12 * 60, start: 22 * 60, end: 7 * 60))
    }

    // MARK: - Step feed unavailable (AAPS StepFeed, 2026-11-20)

    // A locked iPhone cannot read Health, so every step window reads 0. That is no evidence of rest,
    // and the inactivity raise (130%, more insulin) must not fire on it.
    func testNoInactivityRaiseWhenTheStepFeedIsUnavailable() {
        var i = stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 0)
        XCTAssertEqual(ActivityClassifier.classify(i).profilePercent, 130) // the same inputs with a live feed
        i.stepsAvailable = false
        let r = ActivityClassifier.classify(i)
        XCTAssertEqual(r.state, .stepsUnknown)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    // HR-only classification still runs without steps, as in AAPS classifyBoostActivity.
    func testHrOnlyResistanceStillFiresWhenTheStepFeedIsUnavailable() {
        let i = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 0,
            avgHeartRate: 140, stepsAvailable: false, thresholds: hrThresholds()
        )
        XCTAssertEqual(ActivityClassifier.classify(i).state, .resistance)
    }

    // MARK: - exerciseActive flag coverage

    func testExerciseActiveFlagPerState() {
        // resting / normal / inactive → false; exercise states → true.
        XCTAssertFalse(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 600)).exerciseActive) // normal
        XCTAssertFalse(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100)).exerciseActive) // inactive
        XCTAssertTrue(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 900, s30: 0, s60: 0)).exerciseActive) // active
    }
}
