@testable import BoostV5Core
import Foundation
import XCTest

final class SleepStateDetectorTests: XCTestCase {
    typealias D = SleepStateDetector

    // Night window: 22:00 (1320) → 07:00 (420), preSleepLead 60m → preSleep window [1260, 1320).
    // `avgHeartRate` > 0 synthesises one FRESH reading at nowMs (so avgHr != nil → drought inert,
    // matching the legacy HR-path tests); 0 means no HR samples at all (drives the drought path).
    // Pass `hrReadings` explicitly to drive drought / transmission-resume scenarios directly.
    private func makeInputs(
        avgHeartRate: Double = 60,
        hrReadings: [SleepHrReading]? = nil,
        restingHeartRate: Double = 60,
        steps15min: Int = 0,
        nowMinuteOfDay: Int,
        nightStartMinute: Int = 1320,
        nightEndMinute: Int = 420,
        preSleepLeadMin: Int = 60,
        sleepHysteresisMin: Int = 10,
        wakeHrHysteresisMin: Int = 5,
        droughtThresholdMin: Int = 30,
        freshHrWindowMin: Int = 10,
        mlMealLikely: Double? = nil,
        nowMs: Double,
        autoBySleep: Bool = true,
        stepsToday: Int = -1,
        sleepInStepsThreshold: Int = 0,
        sleepInWindowMin: Int = 0
    ) -> SleepDetectorInputs {
        let readings = hrReadings ?? (
            avgHeartRate > 0
                ? [SleepHrReading(timestampMs: nowMs, beatsPerMinute: avgHeartRate, durationMs: 1000)]
                : []
        )
        return SleepDetectorInputs(
            hrReadings: readings,
            hrWindowMinutes: 5,
            restingHeartRate: restingHeartRate,
            steps15min: steps15min,
            nowMinuteOfDay: nowMinuteOfDay,
            nightStartMinute: nightStartMinute,
            nightEndMinute: nightEndMinute,
            preSleepLeadMin: preSleepLeadMin,
            sleepHysteresisMin: sleepHysteresisMin,
            wakeHrHysteresisMin: wakeHrHysteresisMin,
            droughtThresholdMin: droughtThresholdMin,
            freshHrWindowMin: freshHrWindowMin,
            mlMealLikely: mlMealLikely,
            nowMs: nowMs,
            autoBySleep: autoBySleep,
            stepsToday: stepsToday,
            sleepInStepsThreshold: sleepInStepsThreshold,
            sleepInWindowMin: sleepInWindowMin
        )
    }

    private let minute = 60000.0

    // MARK: Lie-in hold (AAPS 3111f79ee2, live in Boost 6.3.2) and the PRE_SLEEP activity exit

    /// Four fresh samples a cycle, so the feed is live and no drought is established.
    private func liveHr(_ at: Double, bpm: Double = 55) -> [SleepHrReading] {
        (1 ... 4).map { SleepHrReading(timestampMs: at - Double($0) * minute, beatsPerMinute: bpm, durationMs: 60000) }
    }

    /// One cycle with a 200-step threshold and a 2 h lie-in after the 07:00 night end, as in the Kotlin
    /// SleepLumpWakeTest.cycleLieIn.
    private func lieInCycle(
        _ s: SleepDetectorState, now: Double, minuteOfDay: Int, bpm: Double = 55, stepsToday: Int, steps15: Int = 0
    ) -> SleepDetectorState {
        D.step(makeInputs(
            hrReadings: liveHr(now, bpm: bpm), steps15min: steps15, nowMinuteOfDay: minuteOfDay, nowMs: now,
            stepsToday: stepsToday, sleepInStepsThreshold: 200, sleepInWindowMin: 120
        ), s)
    }

    private let lieInT0 = 1_000_000_000_000.0
    private func asleepAtNightEnd() -> SleepDetectorState {
        SleepDetectorState(state: .sleeping, enteredAtMs: lieInT0 - 4 * 3_600_000, lastFreshHrSampleMs: lieInT0 - minute)
    }

    func testLieInHoldsSleepingPastNightEndWhenStepsStayLow() {
        var s = asleepAtNightEnd()
        for c in 0 ..< 6 { // 07:05 to 07:30
            s = lieInCycle(s, now: lieInT0 + Double(c) * 5 * minute, minuteOfDay: 425 + c * 5, stepsToday: 100)
            XCTAssertEqual(s.state, .sleeping, "cycle \(c)")
        }
    }

    func testLieInReleasesOnStepsAtTheSleepInThreshold() {
        // 220 and 230 steps over the hour: above the 200 setting, below the fixed 250.
        var s = asleepAtNightEnd()
        for (c, steps) in [100, 320, 330].enumerated() {
            s = lieInCycle(s, now: lieInT0 + Double(c) * 5 * minute, minuteOfDay: 425 + c * 5, stepsToday: steps)
            if s.state == .awake { break }
        }
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "steps")
    }

    func testLieInEndsAtTheHardBoundary() {
        // 09:01, past the 07:00 night end plus 2 h
        let s = lieInCycle(asleepAtNightEnd(), now: lieInT0, minuteOfDay: 541, stepsToday: 0)
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "boundary")
    }

    func testHrAndStepsWakeTrustedInTheLieIn() {
        // 08:00, an hour past night end and outside the 90-min grace before it: HR above the 75 bpm
        // wake floor with 120 steps in 15 min, below the 200-step steps-alone threshold.
        var s = asleepAtNightEnd()
        for c in 0 ..< 4 {
            s = lieInCycle(
                s, now: lieInT0 + Double(c) * 5 * minute, minuteOfDay: 480 + c * 5, bpm: 85,
                stepsToday: 100 + c * 40, steps15: 120
            )
            if s.state == .awake { break }
        }
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "hr_steps")
    }

    func testResumeBurstWakesWithoutStepsInTheLieIn() {
        // 08:00, last reliable sample 40 min ago, then a burst of four with no steps.
        let s = SleepDetectorState(
            state: .sleeping,
            enteredAtMs: lieInT0 - 8 * 3_600_000,
            lastFreshHrSampleMs: lieInT0 - 40 * minute
        )
        let r = lieInCycle(s, now: lieInT0, minuteOfDay: 480, stepsToday: 0)
        XCTAssertEqual(r.state, .awake)
        XCTAssertEqual(r.wakeReason, "resume")
    }

    func testNoLieInWithoutAWindowLeavesTheNightEndExit() {
        let s = D.step(makeInputs(
            hrReadings: liveHr(lieInT0), nowMinuteOfDay: 425, nowMs: lieInT0, stepsToday: 0, sleepInStepsThreshold: 200
        ), asleepAtNightEnd())
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "boundary")
    }

    func testPreSleepReleasesToAwakeOnClearActivity() {
        // 05:00, still PRE_SLEEP: 220 steps in the hour clears the 200 setting (not the fixed 250),
        // so AWAKE at once, with no wake reason for the learner.
        var s = SleepDetectorState(state: .preSleep, enteredAtMs: lieInT0 - 6 * 3_600_000)
        s = lieInCycle(s, now: lieInT0, minuteOfDay: 300, bpm: 85, stepsToday: 1000)
        XCTAssertEqual(s.state, .preSleep)
        s = lieInCycle(s, now: lieInT0 + 5 * minute, minuteOfDay: 305, bpm: 85, stepsToday: 1220)
        XCTAssertEqual(s.state, .awake)
        XCTAssertNil(s.wakeReason)
    }

    func testPreWindowStepsWakeUsesTheSleepInSetting() {
        // SLEEPING entered at 21:00, before the 22:00 night start; 220 steps since entry.
        var s = SleepDetectorState(state: .sleeping, enteredAtMs: lieInT0 - minute, lastFreshHrSampleMs: lieInT0 - minute)
        for (c, steps) in [100, 320, 330].enumerated() {
            s = lieInCycle(s, now: lieInT0 + Double(c) * 5 * minute, minuteOfDay: 1260 + c * 5, stepsToday: steps)
            if s.state == .awake { break }
        }
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "pw_steps")
    }

    // MARK: Boost 6.3.0 pre-window hold and steps-alone wake before night end

    func testSleepDetectedBeforeNightStartIsHeldNotEndedAsBoundary() {
        // 21:00, 60 min before the 22:00 night start, inside the 90-min candidacy window.
        let now = 1_700_000_000_000.0
        let s = SleepDetectorState(state: .sleeping, enteredAtMs: now - 10 * minute)
        let r = D.step(makeInputs(avgHeartRate: 55, nowMinuteOfDay: 1260, nowMs: now), s)
        XCTAssertEqual(r.state, .sleeping)
        XCTAssertNil(r.wakeReason)
    }

    func testSleepBeforeTheCandidacyWindowStillEndsAsBoundary() {
        // 20:00 is outside the hold, so the hard exit applies.
        let now = 1_700_000_000_000.0
        let s = SleepDetectorState(state: .sleeping, enteredAtMs: now - 10 * minute)
        let r = D.step(makeInputs(avgHeartRate: 55, nowMinuteOfDay: 1200, nowMs: now), s)
        XCTAssertEqual(r.state, .awake)
        XCTAssertEqual(r.wakeReason, "boundary")
    }

    func testStepsAloneWakeNearNightEndWithLiveHr() {
        // 06:30 with HR live (no drought): 300 steps over the lookback and 120 in the last 15 min
        // wake after the hysteresis; before 6.3.0 steps alone needed an HR drought.
        let t0 = 1_700_000_000_000.0
        // Three fresh samples a cycle, so the feed counts as reliable and no drought is established.
        func live(_ at: Double) -> [SleepHrReading] {
            (0 ..< 3).map { SleepHrReading(timestampMs: at - Double($0) * minute, beatsPerMinute: 55, durationMs: 1000) }
        }
        var s = SleepDetectorState(state: .sleeping, enteredAtMs: t0 - 300 * minute, lastFreshHrSampleMs: t0 - minute)
        s = D.step(makeInputs(hrReadings: live(t0), steps15min: 0, nowMinuteOfDay: 380, nowMs: t0, stepsToday: 100), s)
        s = D.step(makeInputs(
            hrReadings: live(t0 + 5 * minute), steps15min: 120, nowMinuteOfDay: 385, nowMs: t0 + 5 * minute, stepsToday: 400
        ), s)
        XCTAssertEqual(s.state, .sleeping) // candidate started
        s = D.step(makeInputs(
            hrReadings: live(t0 + 11 * minute), steps15min: 120, nowMinuteOfDay: 391, nowMs: t0 + 11 * minute, stepsToday: 420
        ), s)
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "steps")
    }

    // MARK: AWAKE → PRE_SLEEP

    func testAwakeToPreSleepAtLeadWindow() {
        // 21:00 (1260) is the start of the pre-sleep lead window. HR/steps high so sleep candidacy
        // does NOT fire — pure time transition into PRE_SLEEP must still happen.
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 200, nowMinuteOfDay: 1260, nowMs: 0)
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .preSleep)
    }

    func testNoPreSleepBeforeLeadWindow() {
        // 20:59 (1259) is one minute before the lead window opens → still AWAKE.
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 200, nowMinuteOfDay: 1259, nowMs: 0)
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .awake)
    }

    // MARK: PRE_SLEEP → SLEEPING after hysteresis

    func testPreSleepToSleepingAfterHysteresis() {
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        // In outer window (23:00 = 1380), low HR, no steps, no meal.
        let t0 = makeInputs(avgHeartRate: 65, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.state, .preSleep)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)

        // 9 minutes later — not yet past the 10m hysteresis.
        let t9 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 9 * minute)
        state = D.step(t9, state)
        XCTAssertEqual(state.state, .preSleep)

        // 10 minutes later — hysteresis met → SLEEPING.
        let t10 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testSleepHrCapBoundary() {
        // resting 60 → cap = 69.0. avgHr 69 qualifies (≤ cap); 70 does not (> cap).
        XCTAssertTrue(D.qualifiesAsSleepCandidate(69.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: nil))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(70.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: nil))
    }

    func testSleepStepCeilingBlocks() {
        // steps 49 ok, 50 blocks.
        XCTAssertTrue(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 49, mlMealLikely: nil))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 50, mlMealLikely: nil))
    }

    // MARK: meal-likelihood blocks SLEEPING

    func testMealLikelihoodBlocksSleeping() {
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        // Meal likely 0.30 → blocks candidacy (>= threshold). Never starts a candidate window.
        let t0 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, mlMealLikely: 0.30, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertNil(state.sleepCandidateSinceMs)

        let t20 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, mlMealLikely: 0.30, nowMs: 20 * minute)
        state = D.step(t20, state)
        XCTAssertEqual(state.state, .preSleep) // still not asleep

        // Just under threshold (0.29) does NOT block.
        XCTAssertTrue(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: 0.29))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: 0.30))
    }

    func testNoHrDroughtSleepsAfterHysteresis() {
        // No HR samples at all (e.g. no watch) + never saw a fresh sample → fully in drought.
        // In the night window with low steps, the drought qualifier promotes to SLEEPING after
        // hysteresis, matching AAPS's batched-HR / sparse-HR behaviour. Entry reason = "drought".
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)
        let t10 = makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
        XCTAssertEqual(state.sleepEntryReason, "drought")
    }

    func testReliableRecentAwakeHrDoesNotDroughtSleep() {
        // A RELIABLE recent feed (≥ hrReliableMinSamples fresh) at an awake HR: the drought clock is
        // reset (drought not established) and HR is too high to sleep-qualify → no sleep candidate.
        // 2026-07-08 (AAPS dea9d300ff): reliability, not avgHr==nil, drives the drought fallback.
        let now = 1_000_000.0
        let readings = [
            SleepHrReading(timestampMs: now - 2 * minute, beatsPerMinute: 80, durationMs: 1000),
            SleepHrReading(timestampMs: now - 1 * minute, beatsPerMinute: 80, durationMs: 1000),
            SleepHrReading(timestampMs: now, beatsPerMinute: 80, durationMs: 1000)
        ]
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: now)
        let t0 = makeInputs(hrReadings: readings, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: now)
        state = D.step(t0, state)
        XCTAssertNil(state.sleepCandidateSinceMs) // HR 80 > sleepCap 69 → not sleep-qualifying; drought reset
        XCTAssertEqual(state.state, .preSleep)
    }

    func testTransmissionResumeWakeFromDrought() {
        // Asleep via drought; then a burst of 3 fresh samples arrives after the drought → AWAKE
        // immediately (no hysteresis), matching AAPS transmission-resume wake.
        var state = SleepDetectorState(
            state: .sleeping, enteredAtMs: 0, lastFreshHrSampleMs: 0, sleepEntryReason: "drought"
        )
        let now = 2_000_000.0 // well past any drought threshold from lastFresh=0
        let burst = [
            SleepHrReading(timestampMs: now - 2 * minute, beatsPerMinute: 70, durationMs: 1000),
            SleepHrReading(timestampMs: now - 1 * minute, beatsPerMinute: 72, durationMs: 1000),
            SleepHrReading(timestampMs: now, beatsPerMinute: 74, durationMs: 1000)
        ]
        // Still inside the outer window (02:00) so the hard morning exit isn't what wakes it. In the
        // core night the burst now needs steps (AAPS 5a1c852a57); 20 in the 15-min bucket suffice.
        let inputs = makeInputs(hrReadings: burst, steps15min: 20, nowMinuteOfDay: 120, nowMs: now)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    // MARK: SLEEPING → AWAKE on sustained HR + steps

    func testSleepingToAwakeOnHrPlusSteps() {
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        // resting 60 → wakeFloor 75. HR 80 (> 75) and steps 120 (≥ 100), inside outer window (06:00 = 360).
        // 2026-07-03 (5f7a481f28): HR must be SUSTAINED ≥ 2 cycles before wake candidacy can start
        // (a single elevated sample is REM, not wakefulness).
        let t0 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.state, .sleeping)
        XCTAssertNil(state.wakeCandidateSinceMs) // HR streak only 1 → not yet sustained

        // 2nd cycle: HR streak reaches 2 → wake candidacy starts.
        let t1 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 1 * minute)
        state = D.step(t1, state)
        XCTAssertEqual(state.state, .sleeping)
        XCTAssertEqual(state.wakeCandidateSinceMs, 1 * minute)

        // 4m after candidacy — not yet past 5m wake hysteresis.
        let t5 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 5 * minute)
        state = D.step(t5, state)
        XCTAssertEqual(state.state, .sleeping)

        // 5m after candidacy (nowMs 6m) → AWAKE.
        let t6 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 6 * minute)
        state = D.step(t6, state)
        XCTAssertEqual(state.state, .awake)
    }

    func testSleepingHrAloneDoesNotWake() {
        // HR high but steps low → no wake; counter never starts.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 90, restingHeartRate: 60, steps15min: 10, nowMinuteOfDay: 360, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertNil(state.wakeCandidateSinceMs)
        let t20 = makeInputs(avgHeartRate: 90, restingHeartRate: 60, steps15min: 10, nowMinuteOfDay: 360, nowMs: 20 * minute)
        state = D.step(t20, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testWakeCandidateResetsWhenConditionDrops() {
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        // Two sustained-HR cycles to build the streak and start wake candidacy.
        state = D.step(makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0), state)
        let t1 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 1 * minute)
        state = D.step(t1, state)
        XCTAssertEqual(state.wakeCandidateSinceMs, 1 * minute)
        // steps drop → candidate resets.
        let t2 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 2 * minute)
        state = D.step(t2, state)
        XCTAssertNil(state.wakeCandidateSinceMs)
        XCTAssertEqual(state.state, .sleeping)
    }

    // MARK: clock-window exit

    func testSleepingHardExitOnWindowLeave() {
        // 08:00 (480) is past nightEnd (420) → outside outer window → hard AWAKE exit regardless of HR/steps.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 60, steps15min: 0, nowMinuteOfDay: 480, nowMs: 0)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    func testPreSleepExitsWhenLeavingWindowWithoutSleeping() {
        // From PRE_SLEEP, jump to mid-morning (480) outside both windows → AWAKE.
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 0, nowMinuteOfDay: 480, nowMs: 0)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    // MARK: midnight wrap

    func testMidnightWrapInWindow() {
        // Window 1320→420 wraps midnight. 02:00 (120) is inside; 12:00 (720) is outside.
        XCTAssertTrue(D.minuteInWrappedRange(120, 1320, 420))
        XCTAssertFalse(D.minuteInWrappedRange(720, 1320, 420))
        // Boundaries: start inclusive, end exclusive.
        XCTAssertTrue(D.minuteInWrappedRange(1320, 1320, 420))
        XCTAssertFalse(D.minuteInWrappedRange(420, 1320, 420))
        // Non-wrapping window for comparison.
        XCTAssertTrue(D.minuteInWrappedRange(500, 480, 600))
        XCTAssertFalse(D.minuteInWrappedRange(600, 480, 600))
    }

    func testSleepConfirmedAcrossMidnight() {
        // Candidate starts at 23:55 (1435) and confirms at 00:05 (5) — across the midnight boundary.
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 62, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1435, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)
        let t10 = makeInputs(avgHeartRate: 62, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 5, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testPreSleepWindowWrapsMidnight() {
        // nightStart 30 (00:30), lead 60 → preSleepStart = 1410 (23:30). 23:45 (1425) is in pre-sleep.
        let inputs = makeInputs(
            avgHeartRate: 90, steps15min: 200,
            nowMinuteOfDay: 1425, nightStartMinute: 30, nightEndMinute: 420,
            nowMs: 0
        )
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .preSleep)
    }

    // MARK: autoBySleep does NOT gate the detector (matches AAPS — detector always runs;

    // autoBySleep only gates the downstream night-mode extension).

    func testAutoBySleepDisabledStillAdvancesDetector() {
        // Stay-asleep conditions with autoBySleep=false: the detector must HOLD sleeping,
        // not force AWAKE (the old behaviour discarded in-progress state and diverged from AAPS).
        let state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0, autoBySleep: false)
        let out = D.step(inputs, state)
        XCTAssertEqual(out.state, .sleeping)
    }

    // MARK: wake reason (sleep-window collapse fix)

    func testHardExitWakeReasonIsBoundary() {
        // SLEEPING at 12:00 (720), outside the 22:00-07:00 window → hard exit, tagged "boundary"
        // so the learner won't train its wake time on it.
        let state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let out = D.step(makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 720, nowMs: 0), state)
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "boundary")
    }

    func testGenuineWakeReasonIsHrSteps() {
        // resting 60 → wakeFloor 75; HR 80 + steps 120 in window (06:00). HR must sustain ≥ 2 cycles
        // before candidacy, then hold 5m → genuine wake.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        state = D.step(makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0), state)
        // 2nd cycle: streak reaches 2 → candidacy starts at 1m.
        state = D.step(
            makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 1 * minute),
            state
        )
        let out = D.step(
            makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 6 * minute),
            state
        )
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "hr_steps")
    }

    // MARK: lump-tolerant genuine-wake (2026-07-03, AAPS 5f7a481f28)

    func testCumulativeStepLumpWithSustainedHrWakes() {
        // The 2026-07-03 incident: phone 15-min bucket is 0 all night (nightstand), but the wear
        // bridge delivers a cumulative stepsToday LUMP (0 → 1300). With sustained HR, that lump over
        // the trailing lookback is genuine wake evidence even though steps15min never reaches 100.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        // Cycle 1 (streak 1): stepsToday 0 baseline anchor, HR above floor.
        state = D.step(
            makeInputs(avgHeartRate: 82, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 0, stepsToday: 0),
            state
        )
        XCTAssertNil(state.wakeCandidateSinceMs)
        // Cycle 2 (streak 2): stepsToday jumps to 1300 (Δ 1300 ≥ 100 in lookback) → candidacy starts,
        // driven purely by the cumulative lump (steps15min still 0).
        state = D.step(
            makeInputs(
                avgHeartRate: 82,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 5 * minute,
                stepsToday: 1300
            ),
            state
        )
        XCTAssertEqual(state.wakeCandidateSinceMs, 5 * minute)
        // Held past 5m hysteresis → AWAKE (genuine wake).
        let out = D.step(
            makeInputs(
                avgHeartRate: 82,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 10 * minute,
                stepsToday: 1400
            ),
            state
        )
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "hr_steps")
    }

    func testModerateLumpWithoutSustainedHrDoesNotWake() {
        // A MODERATE step lump (below the strong steps-alone bar of 250) with only ONE elevated-HR
        // cycle: the gentle rule needs sustained HR (streak ≥ 2, only reaches 1) and Rule 2 needs
        // ≥ 250 cumulative steps — neither fires, so no wake candidacy. (2026-07-08, AAPS dea9d300ff.)
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        state = D.step(
            makeInputs(avgHeartRate: 55, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 0, stepsToday: 0),
            state
        )
        let out = D.step(
            makeInputs(
                avgHeartRate: 90,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 5 * minute,
                stepsToday: 200 // below WAKE_STEP_STRONG_THRESHOLD (250) → Rule 2 does not fire
            ),
            state
        )
        XCTAssertNil(out.wakeCandidateSinceMs)
        XCTAssertEqual(out.state, .sleeping)
    }

    func testRemHrRiseWithFlatStepsDoesNotWake() {
        // Sustained HR but steps flat (REM) → no step evidence → no wake.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        state = D.step(
            makeInputs(avgHeartRate: 85, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 0, stepsToday: 500),
            state
        )
        let out = D.step(
            makeInputs(
                avgHeartRate: 85,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 5 * minute,
                stepsToday: 500
            ),
            state
        )
        XCTAssertNil(out.wakeCandidateSinceMs) // steps flat → stepsConfirmWake false
        XCTAssertEqual(out.state, .sleeping)
    }

    func testMidnightStepResetIsNotWakeEvidence() {
        // stepGrowth sums only POSITIVE increments, so the local-midnight stepsToday reset (a large
        // negative jump) contributes 0 — a reset must never read as movement.
        let samples = [
            SleepStepSample(tMs: 0, steps: 8000),
            SleepStepSample(tMs: 3 * minute, steps: 20) // midnight reset: 8000 → 20
        ]
        XCTAssertEqual(SleepStateDetector.stepGrowth(samples, nowMs: 3 * minute, lookbackMin: 60), 0)
    }

    func testStepGrowthSumsPositiveIncrementsInWindow() {
        let samples = [
            SleepStepSample(tMs: 0, steps: 100),
            SleepStepSample(tMs: 20 * minute, steps: 250), // +150
            SleepStepSample(tMs: 40 * minute, steps: 300) // +50
        ]
        XCTAssertEqual(SleepStateDetector.stepGrowth(samples, nowMs: 40 * minute, lookbackMin: 60), 200)
    }

    // MARK: degraded-HR fallback + steps-alone wake (2026-07-08, AAPS dea9d300ff)

    func testFlickeringHrFeedReachesSleepingWithReasonTime() {
        // Intermittent feed: one stray HR sample per cycle (< hrReliableMinSamples → unreliable), too
        // high to sleep-qualify, in the night window with low steps. Stray samples don't reset the
        // drought clock → drought established → droughtQualifies → SLEEPING after hysteresis, reason
        // "time" (intermittent, avgHr non-nil). The 3-night stuck-in-PRE_SLEEP fix.
        func stray(_ nowMs: Double) -> SleepDetectorInputs {
            makeInputs(
                hrReadings: [SleepHrReading(timestampMs: nowMs, beatsPerMinute: 80, durationMs: 1000)],
                restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: nowMs
            )
        }
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        state = D.step(stray(0), state)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0) // drought candidate started on the degraded feed
        let out = D.step(stray(10 * minute), state) // held 10m ≥ sleep hysteresis
        XCTAssertEqual(out.state, .sleeping)
        XCTAssertEqual(out.sleepEntryReason, "time")
    }

    func testDeadHrStrongStepsWakesWithReasonSteps() {
        // HR feed dead (no samples → unreliable, drought established); a strong sustained step lump
        // (≥ WAKE_STEP_STRONG_THRESHOLD) wakes on steps alone → reason "steps" (Rule 2).
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0, lastFreshHrSampleMs: 0)
        state = D.step(
            makeInputs(avgHeartRate: 0, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 0, stepsToday: 0),
            state
        )
        XCTAssertNil(state.wakeCandidateSinceMs)
        // stepsToday 0 → 400 (≥ 250) → strong-steps candidacy (drought established, HR dead).
        state = D.step(
            makeInputs(
                avgHeartRate: 0,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 1 * minute,
                stepsToday: 400
            ),
            state
        )
        XCTAssertEqual(state.wakeCandidateSinceMs, 1 * minute)
        let out = D.step(
            makeInputs(
                avgHeartRate: 0,
                restingHeartRate: 60,
                steps15min: 0,
                nowMinuteOfDay: 360,
                nowMs: 6 * minute,
                stepsToday: 500
            ),
            state
        )
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "steps")
    }

    func testLiveHrBlocksStepsOnlyWake() {
        // With a RELIABLE live HR feed (drought NOT established), the strong steps-alone rule must NOT
        // fire — the both-required guard holds. The gentle rule is also inert (HR below wake floor),
        // so a big step lump does NOT wake. Prior fresh sample avoids the transmission-resume path.
        let base = 1_000_000.0
        func live(_ nowMs: Double, steps: Int) -> SleepDetectorInputs {
            makeInputs(hrReadings: [
                SleepHrReading(timestampMs: nowMs - 2 * minute, beatsPerMinute: 65, durationMs: 1000),
                SleepHrReading(timestampMs: nowMs - 1 * minute, beatsPerMinute: 65, durationMs: 1000),
                SleepHrReading(timestampMs: nowMs, beatsPerMinute: 65, durationMs: 1000)
            ], restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 180, nowMs: nowMs, stepsToday: steps)
        }
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: base, lastFreshHrSampleMs: base - 5 * minute)
        state = D.step(live(base, steps: 0), state)
        let out = D.step(live(base + 5 * minute, steps: 500), state) // 500 ≥ 250 but HR live → no steps-only wake
        XCTAssertNil(out.wakeCandidateSinceMs)
        XCTAssertEqual(out.state, .sleeping)
    }

    func testGentleWakeTimeGatedAwayFromScheduledWake() {
        // HR-rise + steps that satisfy the gentle rule, but far from scheduled wake (02:00 vs 07:00) →
        // gentle is time-gated (nearScheduledWake false) and steps-alone is blocked (HR live, drought
        // not established) → no wake. Prior fresh sample avoids the transmission-resume path.
        let base = 1_000_000.0
        func rise(_ nowMs: Double) -> SleepDetectorInputs {
            makeInputs(hrReadings: [
                SleepHrReading(timestampMs: nowMs - 2 * minute, beatsPerMinute: 82, durationMs: 1000),
                SleepHrReading(timestampMs: nowMs - 1 * minute, beatsPerMinute: 82, durationMs: 1000),
                SleepHrReading(timestampMs: nowMs, beatsPerMinute: 82, durationMs: 1000)
            ], restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 120, nowMs: nowMs)
        }
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: base, lastFreshHrSampleMs: base - 5 * minute)
        state = D.step(rise(base), state) // streak → 1
        let out = D.step(rise(base + 5 * minute), state) // streak → 2, HR+steps met, but 02:00 not near wake
        XCTAssertNil(out.wakeCandidateSinceMs)
        XCTAssertEqual(out.state, .sleeping)
    }

    // MARK: serialization round-trip

    func testStateCodableRoundTrip() throws {
        let original = SleepDetectorState(
            state: .sleeping,
            sleepCandidateSinceMs: 12345.0,
            wakeCandidateSinceMs: nil,
            enteredAtMs: 999_999.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SleepDetectorState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStateCodableRoundTripWithNils() throws {
        let original = SleepDetectorState()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SleepDetectorState.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.state, .awake)
        XCTAssertNil(decoded.sleepCandidateSinceMs)
    }

    func testSleepStateRawValues() {
        XCTAssertEqual(SleepState.awake.rawValue, "awake")
        XCTAssertEqual(SleepState.preSleep.rawValue, "preSleep")
        XCTAssertEqual(SleepState.sleeping.rawValue, "sleeping")
    }

    // MARK: Resume burst on a batched HR feed (AAPS 5a1c852a57)

    // Batched feed: a batch every 15 min, sizes 2, 2, 5 in turn, timestamps spread back from 1 min
    // before arrival. Ported from the Kotlin SleepResumeWakeTest fixture.
    private let resumeT0 = 1_000_000_000_000.0

    private func batchedReadings(at now: Double) -> [SleepHrReading] {
        (0 ..< 24).flatMap { k -> [SleepHrReading] in
            let arrive = resumeT0 + Double(k) * 15 * minute
            guard arrive <= now else { return [] }
            let size = k % 3 == 2 ? 5 : 2
            return (1 ... size).map { j in
                SleepHrReading(timestampMs: arrive - Double(j) * minute, beatsPerMinute: 58, durationMs: 60000)
            }
        }.filter { $0.timestampMs > now - 30 * minute && $0.timestampMs <= now }
    }

    /// SLEEPING at 01:00 with the last reliable sample 40 min ago, so the drought is established.
    private func asleepAt0100() -> SleepDetectorState {
        SleepDetectorState(state: .sleeping, enteredAtMs: resumeT0 - 2 * 3_600_000, lastFreshHrSampleMs: resumeT0 - 40 * minute)
    }

    private func resumeCycle(
        _ s: SleepDetectorState, now: Double, minuteOfDay: Int, stepsToday: Int, steps15: Int = 0
    ) -> SleepDetectorState {
        D.step(makeInputs(
            hrReadings: batchedReadings(at: now), restingHeartRate: 60, steps15min: steps15,
            nowMinuteOfDay: minuteOfDay, nowMs: now, stepsToday: stepsToday
        ), s)
    }

    func testBatchedHrOvernightDoesNotWake() {
        var s = asleepAt0100()
        var ignored = 0
        // 01:00 to 05:00 at five-minute cycles, no steps at all
        for c in 0 ... 48 {
            s = resumeCycle(s, now: resumeT0 + Double(c) * 5 * minute, minuteOfDay: 60 + c * 5, stepsToday: 4200)
            XCTAssertEqual(s.state, .sleeping, "cycle \(c)")
            if s.resumeBurstIgnored { ignored += 1 }
        }
        // the fixture does reach the old wake condition (burst after drought) several times
        XCTAssertGreaterThanOrEqual(ignored, 3)
    }

    func testBurstWithStepsMidNightStillWakesAtOnce() {
        var s = asleepAt0100()
        var woke: (Int, String?)?
        for c in 0 ... 48 {
            let minuteOfDay = 60 + c * 5
            let up = minuteOfDay >= 180 // out of bed at 03:00, as a 5-sample batch lands
            s = resumeCycle(
                s, now: resumeT0 + Double(c) * 5 * minute, minuteOfDay: minuteOfDay,
                stepsToday: up ? 4260 : 4200, steps15: up ? 60 : 0
            )
            if s.state == .awake { woke = (minuteOfDay, s.wakeReason)
                break }
        }
        XCTAssertEqual(woke?.0, 180)
        XCTAssertEqual(woke?.1, "resume")
    }

    func testBurstNearScheduledWakeWakesWithoutSteps() {
        var s = asleepAt0100()
        var woke: (Int, String?)?
        // 05:30 onwards: inside sleepScheduleToleranceMin of the 07:00 wake
        for c in 0 ... 24 {
            let minuteOfDay = 330 + c * 5
            s = resumeCycle(s, now: resumeT0 + Double(c) * 5 * minute, minuteOfDay: minuteOfDay, stepsToday: 4200)
            if s.state == .awake { woke = (minuteOfDay, s.wakeReason)
                break }
        }
        XCTAssertEqual(woke?.0, 360) // the first 5-sample batch, 30 min in
        XCTAssertEqual(woke?.1, "resume")
    }

    func testBoundaryExitAtNightEndIsUnaffectedByResumeGate() {
        // At the night end the boundary rule wakes, burst or not, so the step requirement never
        // delays the morning exit. (The Kotlin lie-in exemption has no counterpart here: this
        // detector does not hold SLEEPING past the night end.)
        let now = resumeT0 + 30 * minute
        let s = D.step(makeInputs(
            hrReadings: batchedReadings(at: now), restingHeartRate: 60, steps15min: 0,
            nowMinuteOfDay: 7 * 60, nowMs: now, stepsToday: 4200
        ), asleepAt0100())
        XCTAssertEqual(s.state, .awake)
        XCTAssertEqual(s.wakeReason, "boundary")
    }

    func testResumeBurstIgnoredFlagIsTransient() throws {
        var s = asleepAt0100()
        s.resumeBurstIgnored = true
        let data = try JSONEncoder().encode(s)
        XCTAssertFalse(try JSONDecoder().decode(SleepDetectorState.self, from: data).resumeBurstIgnored)
        // and a quiet cycle clears it
        let next = D.step(makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 60, nowMs: resumeT0), s)
        XCTAssertFalse(next.resumeBurstIgnored)
    }
}
