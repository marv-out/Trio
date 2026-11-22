@testable import BoostV5Core
import XCTest

/// A person with no HR feed (AAPS Boost 6.3.3, ecaad5ec6b, SleepNoHrFeedTest). The no-HR fallback
/// qualified as soon as candidacy opened 90 min before nightStart, and the pre-window hold kept it,
/// so an evening at the table was SLEEPING. Without a feed the HR rules do not apply and sleep starts
/// only from nightStart. Night 20:00 to 07:00, no HR readings, no steps, five-minute cycles from 18:00.
final class SleepNoHrFeedTests: XCTestCase {
    private let minute = 60000.0
    private let t0 = 1_000_000_000_000.0
    private let startMin = 18 * 60

    private func minuteAt(_ nowMs: Double) -> Int { (startMin + Int((nowMs - t0) / minute)) % 1440 }

    /// Minute of day of the first SLEEPING cycle between 18:00 and 21:00, or nil.
    private func firstSleepingMinute(hrFeedPresent: Bool) -> Int? {
        var state = SleepDetectorState(state: .awake, enteredAtMs: t0)
        for c in 0 ..< 36 {
            let now = t0 + Double(c * 5) * minute
            state = SleepStateDetector.step(
                SleepDetectorInputs(
                    hrReadings: [], restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: minuteAt(now),
                    nightStartMinute: 20 * 60, nightEndMinute: 7 * 60, preSleepLeadMin: 60,
                    sleepHysteresisMin: 10, wakeHrHysteresisMin: 5, mlMealLikely: nil, nowMs: now,
                    autoBySleep: true, stepsToday: 3000, hrFeedPresent: hrFeedPresent
                ),
                state
            )
            if state.state == .sleeping { return minuteAt(now) }
        }
        return nil
    }

    func testWithoutAnHrFeedSleepDoesNotStartBeforeNightStart() throws {
        let first = try XCTUnwrap(firstSleepingMinute(hrFeedPresent: false))
        XCTAssertGreaterThanOrEqual(first, 20 * 60)
        XCTAssertLessThanOrEqual(first, 20 * 60 + 15) // the 10-min hysteresis after nightStart
    }

    func testWithAnHrFeedInDroughtTheEarlyCandidacyWindowStillApplies() throws {
        // A watch that has gone quiet keeps the 90-min early window, as before.
        XCTAssertLessThan(try XCTUnwrap(firstSleepingMinute(hrFeedPresent: true)), 20 * 60)
    }

    func testWithoutAnHrFeedALearnedEarlyNightStartDoesNotMoveItEarlier() {
        // Sessions that began on the clock fallback near 18:40 against a configured 20:00.
        XCTAssertEqual(
            SleepHistoryTracker.effectiveNightStartMin(
                learned: 18 * 60 + 40,
                configured: 20 * 60,
                bandMin: 90,
                hrFeedPresent: false
            ),
            20 * 60
        )
        // Later than configured is still learned, and with a feed the band stays symmetric.
        XCTAssertEqual(
            SleepHistoryTracker.effectiveNightStartMin(learned: 21 * 60, configured: 20 * 60, bandMin: 90, hrFeedPresent: false),
            21 * 60
        )
        XCTAssertEqual(
            SleepHistoryTracker.effectiveNightStartMin(
                learned: 18 * 60 + 40,
                configured: 20 * 60,
                bandMin: 90,
                hrFeedPresent: true
            ),
            18 * 60 + 40
        )
    }
}

/// A steps wake starts the step history empty (AAPS SleepStateDetector.kt 687), so the steps that
/// woke the person cannot end a return to sleep without new movement. Found by
/// SleepNoHrReplayParityTests: Trio carried the history and woke again on 331 cycles where AAPS slept.
final class SleepStepsWakeResetTests: XCTestCase {
    func testAStepsWakeStartsTheStepHistoryEmpty() {
        let minute = 60000.0, t0 = 1_000_000_000_000.0
        // 02:00, no HR (drought), so the strong steps rule can wake; 300 steps arrive at once.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: t0 - 120 * minute)
        var steps = 0
        for c in 0 ..< 4 {
            if c == 1 { steps = 300 }
            state = SleepStateDetector.step(
                SleepDetectorInputs(
                    hrReadings: [], restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 120 + 5 * c,
                    nightStartMinute: 22 * 60, nightEndMinute: 7 * 60, preSleepLeadMin: 60,
                    sleepHysteresisMin: 10, wakeHrHysteresisMin: 5, mlMealLikely: nil, nowMs: t0 + Double(5 * c) * minute,
                    autoBySleep: true, stepsToday: steps
                ),
                state
            )
            if state.state == .awake { break }
        }
        XCTAssertEqual(state.state, .awake)
        XCTAssertEqual(state.wakeReason, "steps")
        XCTAssertEqual(state.stepSamples, [])
    }
}
