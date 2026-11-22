@testable import BoostV5Core
import XCTest

/// Two sleep and activity fixes from the Boost dev line.
///
/// `isHrWindowFrozen` (AAPS 220d747d4d) rejects a stuck sensor value. `clampToConfiguredBand`'s
/// one-sided mode (AAPS 4b06282ba7) keeps the learned wake from lifting sleep protection before
/// the configured night end.
final class FrozenHrAndWakeNudgeTests: XCTestCase {
    private let now: Double = 1_700_000_000_000

    private func readings(_ bpms: [Double], spacingMin: Double = 2) -> [SleepHrReading] {
        bpms.enumerated().map { i, bpm in
            SleepHrReading(
                timestampMs: now - Double(bpms.count - 1 - i) * spacingMin * 60000,
                beatsPerMinute: bpm,
                durationMs: 60000
            )
        }
    }

    // MARK: - Frozen HR

    func testIdenticalReadingsAreFrozen() {
        // The reported case: a value pinned all night, which mis-fired resistance every cycle.
        let r = readings([124, 124, 124, 124, 124])
        XCTAssertTrue(ActivityClassifier.isHrWindowFrozen(readings: r, nowMs: now, windowMinutes: 15))
    }

    func testAnySpreadIsNotFrozen() {
        XCTAssertFalse(ActivityClassifier.isHrWindowFrozen(
            readings: readings([124, 124, 124, 125]), nowMs: now, windowMinutes: 15
        ))
    }

    func testTooFewReadingsAreNotJudged() {
        // Three identical readings cannot be told apart from merely sparse data.
        XCTAssertFalse(ActivityClassifier.isHrWindowFrozen(
            readings: readings([124, 124, 124]), nowMs: now, windowMinutes: 15
        ))
    }

    func testOnlyReadingsInsideTheWindowCount() {
        // Four identical readings, but spaced 10 minutes apart so only two fall inside 15 minutes.
        let r = readings([124, 124, 124, 124], spacingMin: 10)
        XCTAssertFalse(ActivityClassifier.isHrWindowFrozen(readings: r, nowMs: now, windowMinutes: 15))
        // Widen the window and the same readings are judged.
        XCTAssertTrue(ActivityClassifier.isHrWindowFrozen(readings: r, nowMs: now, windowMinutes: 45))
    }

    func testInvalidReadingsAreIgnored() {
        var r = readings([124, 124, 124, 124])
        r[0].isValid = false
        // Three valid identical readings remain, which is below the minimum.
        XCTAssertFalse(ActivityClassifier.isHrWindowFrozen(readings: r, nowMs: now, windowMinutes: 15))
    }

    func testEmptyWindowIsNotFrozen() {
        XCTAssertFalse(ActivityClassifier.isHrWindowFrozen(readings: [], nowMs: now, windowMinutes: 15))
    }

    func testClassifierFallsBackToStepOnlyWhenHrIsTreatedAsUnavailable() {
        // What the monitor does with a frozen window: pass 0. A stuck 124 bpm would otherwise
        // classify resistance on a low step count; with 0 the step-only path runs instead.
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = true
        let stuck = ActivityInputs(
            steps5: 0, steps15: 10, steps30: 0, steps60: 600, avgHeartRate: 124, thresholds: t
        )
        XCTAssertEqual(ActivityClassifier.classify(stuck).state, .resistance)
        let suppressed = ActivityInputs(
            steps5: 0, steps15: 10, steps30: 0, steps60: 600, avgHeartRate: 0, thresholds: t
        )
        XCTAssertEqual(ActivityClassifier.classify(suppressed).state, .normal)
    }

    // MARK: - One-sided wake nudge

    private func clamp(_ learned: Int?, _ configured: Int, allowEarlier: Bool) -> Int {
        SleepHistoryTracker.clampToConfiguredBand(
            learned: learned, configured: configured, allowEarlier: allowEarlier
        )
    }

    func testWakeNudgeCannotMoveTheNightEndEarlier() {
        // The reported case: configured 07:30, learned mean 05:51. Symmetric clamping dragged the
        // night end down to 06:00, lifting protection into the dawn window.
        let configured = 7 * 60 + 30
        let learned = 5 * 60 + 51
        XCTAssertEqual(clamp(learned, configured, allowEarlier: true), 6 * 60) // the old behaviour
        XCTAssertEqual(clamp(learned, configured, allowEarlier: false), configured)
    }

    func testWakeNudgeStillMovesLaterWithinTheBand() {
        let configured = 7 * 60
        XCTAssertEqual(clamp(7 * 60 + 45, configured, allowEarlier: false), 7 * 60 + 45)
        // And is still capped at the 90-minute band.
        XCTAssertEqual(clamp(9 * 60 + 30, configured, allowEarlier: false), 8 * 60 + 30)
    }

    func testNightStartKeepsTheSymmetricBand() {
        // Later-to-bed drift is expected and safe, so the start side is unchanged.
        let configured = 22 * 60
        XCTAssertEqual(clamp(21 * 60, configured, allowEarlier: true), 21 * 60)
        XCTAssertEqual(clamp(19 * 60, configured, allowEarlier: true), 20 * 60 + 30)
    }

    func testNoLearnedValueReturnsTheConfiguredTime() {
        XCTAssertEqual(clamp(nil, 7 * 60, allowEarlier: false), 7 * 60)
    }

    func testClampWrapsAcrossMidnight() {
        // Configured 00:15, learned 23:00 the previous evening: 75 minutes earlier on the circle.
        XCTAssertEqual(clamp(23 * 60, 15, allowEarlier: true), 23 * 60)
        XCTAssertEqual(clamp(23 * 60, 15, allowEarlier: false), 15)
    }
}
