@testable import BoostV5Core
import XCTest

final class SleepHistoryTrackerTests: XCTestCase {
    typealias T = SleepHistoryTracker
    private let dayMs = 24.0 * 3_600_000.0

    func testOnSleepStartThenWakeClosesSession() {
        var h = T.History()
        h = T.onSleepStart(h, sleepStartMs: 1000)
        XCTAssertEqual(h.openSleepStartMs, 1000)
        h = T.onWake(h, wakeMs: 1000 + 8 * 3_600_000)
        XCTAssertNil(h.openSleepStartMs)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sessions[0].sleepStartMs, 1000)
    }

    func testOnWakeWithNoOpenSessionIsNoOp() {
        let h = T.History()
        let out = T.onWake(h, wakeMs: 5000)
        XCTAssertEqual(out.sessions.count, 0)
    }

    func testTrimDropsSessionsOlderThanWindow() {
        var h = T.History()
        // An old session well outside the 28-day window, plus a fresh one closing "now".
        let now = 100.0 * dayMs
        h.sessions = [T.Session(sleepStartMs: 10.0 * dayMs, wakeMs: 10.0 * dayMs + 3_600_000)]
        h = T.onSleepStart(h, sleepStartMs: now - 3_600_000)
        h = T.onWake(h, wakeMs: now)
        // The 10-day session is > 28 days before `now` → trimmed; only the fresh one remains.
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sessions[0].wakeMs, now)
    }

    func testAggregateBelowThresholdHasNilNightWindow() {
        var h = T.History()
        for i in 0 ..< 6 { // below the 7-session threshold
            h.sessions.append(T.Session(sleepStartMs: Double(i) * dayMs, wakeMs: Double(i) * dayMs + 3_600_000))
        }
        let a = T.aggregate(h, localOffsetMs: 0)
        XCTAssertNil(a.sleepStartMinAvg)
        XCTAssertNil(a.wakeMinAvg)
        XCTAssertEqual(a.sessionCount, 6)
    }

    func testAggregateAboveThresholdLearnsCircularNightWindow() {
        var h = T.History()
        // 7 sessions: sleep onset ~22:00 (1320), wake ~06:00 (360), across consecutive days.
        // Genuine ("hr_steps") wakes so the wake-time learner trains on them (post-fix: boundary
        // and legacy-nil wakes are excluded from wake learning).
        for i in 0 ..< 7 {
            let base = Double(i) * dayMs
            h.sessions.append(T.Session(
                sleepStartMs: base + 1320 * 60000, wakeMs: base + dayMs + 360 * 60000, wakeReason: "hr_steps"
            ))
        }
        let a = T.aggregate(h, localOffsetMs: 0)
        XCTAssertEqual(a.sessionCount, 7)
        // Circular mean should land near 1320 (22:00) and 360 (06:00) respectively.
        XCTAssertNotNil(a.sleepStartMinAvg)
        XCTAssertNotNil(a.wakeMinAvg)
        XCTAssertEqual(Double(a.sleepStartMinAvg!), 1320, accuracy: 3)
        XCTAssertEqual(Double(a.wakeMinAvg!), 360, accuracy: 3)
    }

    func testCircularMeanWrapsMidnight() {
        // Mean of 23:00 (1380) and 01:00 (60) is midnight (0), not 12:00 (720).
        let m = T.circularMean([1380, 60])
        XCTAssertNotNil(m)
        XCTAssertTrue(m! <= 2 || m! >= 1438, "expected ≈ midnight, got \(m!)")
    }

    func testP10AndMedian() {
        // p10 needs ≥30 samples.
        XCTAssertNil(T.p10(Array(repeating: 60.0, count: 29)))
        let ramp = (1 ... 100).map { Double($0) }
        XCTAssertEqual(T.p10(ramp), 10) // index floor((100-1)*0.10)=9 → value 10
        XCTAssertEqual(T.median([5, 1, 3]), 3) // sorted [1,3,5], size/2 = 1 → 3
    }

    func testRestingHrLearnedFromSleepP10Median() {
        var h = T.History()
        for i in 0 ..< 7 {
            h.sessions.append(T.Session(
                sleepStartMs: Double(i) * dayMs, wakeMs: Double(i) * dayMs + 3_600_000,
                sleepHrP10: 50 + i
            ))
        }
        let a = T.aggregate(h, localOffsetMs: 0)
        XCTAssertEqual(a.restingHrSampleCount, 7)
        XCTAssertEqual(a.restingHrBpm, 53) // median of 50..56
    }

    func testSerializeRoundTrip() {
        var h = T.History()
        h = T.onSleepStart(h, sleepStartMs: 12345)
        h = T.onWake(h, wakeMs: 12345 + 3_600_000, sleepHrBpms: [], daytimeHrBpms: [])
        let restored = T.deserialize(T.serialize(h))
        XCTAssertEqual(restored.sessions.count, 1)
        XCTAssertEqual(restored.sessions[0].sleepStartMs, 12345)
        XCTAssertNil(restored.openSleepStartMs)
    }

    func testDeserializeEmptyIsEmpty() {
        XCTAssertEqual(T.deserialize("").sessions.count, 0)
        XCTAssertEqual(T.deserialize("garbage").sessions.count, 0)
    }

    // MARK: genuine-wake-only learning (sleep-window collapse fix)

    private func wakeSessions(_ n: Int, _ reason: String?) -> T.History {
        let wake0600 = 6.0 * 3_600_000.0
        return T.History(sessions: (0 ..< n).map {
            T.Session(sleepStartMs: Double($0) * dayMs, wakeMs: Double($0) * dayMs + wake0600, wakeReason: reason)
        })
    }

    func testBoundaryAndLegacyWakesDoNotTrainLearnedWake() {
        XCTAssertNil(T.aggregate(wakeSessions(10, "boundary"), localOffsetMs: 0).wakeMinAvg)
        XCTAssertNil(T.aggregate(wakeSessions(10, nil), localOffsetMs: 0).wakeMinAvg) // legacy discarded
    }

    func testGenuineWakesTrainLearnedWakeOnceEnough() {
        XCTAssertNil(T.aggregate(wakeSessions(6, "hr_steps"), localOffsetMs: 0).wakeMinAvg) // <7 genuine
        let agg = T.aggregate(wakeSessions(7, "resume"), localOffsetMs: 0)
        XCTAssertEqual(agg.wakeMinAvg, 360) // 7 genuine wakes at 06:00
    }

    func testWakeReasonRoundTripsThroughSerialize() {
        var h = T.onSleepStart(T.History(), sleepStartMs: 1000)
        h = T.onWake(h, wakeMs: 1000 + 3_600_000, wakeReason: "hr_steps")
        XCTAssertEqual(h.sessions.last?.wakeReason, "hr_steps")
        XCTAssertEqual(T.deserialize(T.serialize(h)).sessions.last?.wakeReason, "hr_steps")
    }
}
