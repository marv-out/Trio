@testable import BoostV5Core
import XCTest

final class ActivityLoadTrackerTests: XCTestCase {
    private typealias T = ActivityLoadTracker
    private typealias Day = ActivityLoadTracker.DailyStepTotal

    private func day(_ idx: Int, _ steps: Int, _ src: String = "hc") -> Day {
        Day(dayIndex: idx, steps: steps, source: src)
    }

    // MARK: - record / trim

    func testRecordTrimsBeyondWindow() {
        // Record days 0..40 sequentially; only the most recent 28 completed
        // days should survive (window anchored at newest+1).
        var h = T.StepHistory()
        for i in 0 ... 40 {
            h = T.record(h, day: day(i, 1000 + i))
        }
        XCTAssertEqual(h.days.count, T.Const.windowDays, "should trim to windowDays")
        // Newest day = 40, today = 41, cutoff = 41 - 28 = 13.
        XCTAssertEqual(h.days.first?.dayIndex, 13)
        XCTAssertEqual(h.days.last?.dayIndex, 40)
        // Stored as sorted-ascending by dayIndex.
        let indices = h.days.map(\.dayIndex)
        XCTAssertEqual(indices, Array(13 ... 40))
    }

    func testRecordReplacesSameDay() {
        var h = T.StepHistory()
        h = T.record(h, day: day(5, 1000))
        h = T.record(h, day: day(5, 9999, "watch"))
        XCTAssertEqual(h.days.count, 1)
        XCTAssertEqual(h.steps(forDay: 5), 9999)
        XCTAssertEqual(h.days.first?.source, "watch")
    }

    func testRecordCustomWindow() {
        var h = T.StepHistory()
        for i in 0 ... 20 { h = T.record(h, day: day(i, 500), windowDays: 5) }
        XCTAssertEqual(h.days.count, 5)
        XCTAssertEqual(h.days.first?.dayIndex, 16) // newest 20, today 21, cutoff 16
    }

    // MARK: - cold start

    func testColdStartFewerThanMinDaysGivesNilResult() {
        var h = T.StepHistory()
        // Only 5 completed days before today (need >= 7 after excluding recent 2).
        for i in 0 ..< 5 { h = T.record(h, day: day(i, 5000)) }
        let todayIndex = 10
        XCTAssertNil(T.baseline(h, todayIndex: todayIndex))
        let r = T.compute(h, todayIndex: todayIndex)
        XCTAssertNil(r.baselineSteps)
        XCTAssertNil(r.recentLoad)
        XCTAssertNil(r.ratio)
        XCTAssertNil(r.wouldDeltaIsfPct)
    }

    func testExactlyMinDaysAfterExclusionProducesBaseline() {
        // Need 7 qualifying days with dayIndex < todayIndex - 2.
        // Use today = 100; qualifying days are indices < 98.
        var h = T.StepHistory(days: [])
        var days: [Day] = []
        for i in 90 ... 96 { days.append(day(i, 5000)) } // 7 days, all < 98
        h = T.StepHistory(days: days)
        XCTAssertEqual(T.baseline(h, todayIndex: 100), 5000)
    }

    // MARK: - median baseline over [-9 .. -2]

    func testMedianBaselineExcludesRecentTwoDays() {
        // todayIndex = 12. Window for baseline: dayIndex < 10 (excludeRecent=2).
        // Provide days 2..11. Days 10,11 excluded. Qualifying: 2..9 (8 days).
        // Give qualifying days values whose sorted median (count/2 -> index 4)
        // is deterministic; make recent (excluded) days huge to prove exclusion.
        var days: [Day] = []
        let qualifying = [100, 200, 300, 400, 500, 600, 700, 800] // days 2..9
        for (offset, v) in qualifying.enumerated() {
            days.append(day(2 + offset, v))
        }
        days.append(day(10, 999_999)) // excluded (recent)
        days.append(day(11, 999_999)) // excluded (recent)
        let h = T.StepHistory(days: days)
        // sorted 8 values, index 8/2 = 4 -> 500.
        XCTAssertEqual(T.baseline(h, todayIndex: 12), 500)
    }

    func testMedianUsesLowerMiddleNotAverage() {
        // 8 qualifying values -> index 4. Distinct values prove no averaging.
        var days: [Day] = []
        let vals = [10, 20, 30, 40, 50, 60, 70, 80]
        for (i, v) in vals.enumerated() { days.append(day(i, v)) }
        let h = T.StepHistory(days: days)
        // todayIndex large enough that all 8 qualify; exclude none affect.
        XCTAssertEqual(T.baseline(h, todayIndex: 100), 50) // vals[8/2] = vals[4]
    }

    // MARK: - activity: high recent load -> +15% capped

    func testHighRecentLoadCapsAtPlus15() {
        // baseline from older days; recent two days >> baseline so ratio >= 2.
        var days: [Day] = []
        for i in 0 ..< 10 { days.append(day(i, 1000)) } // baseline days
        // todayIndex = 15. yesterday = 14, dayBefore = 13. Make them very high.
        days.append(day(13, 100_000))
        days.append(day(14, 100_000))
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 15)
        XCTAssertEqual(r.baselineSteps, 1000)
        XCTAssertNotNil(r.ratio)
        XCTAssertGreaterThanOrEqual(r.ratio!, 2.0)
        XCTAssertEqual(r.wouldDeltaIsfPct!, T.Const.activityMaxIsfPct, accuracy: 1E-9)
        XCTAssertEqual(r.wouldDeltaIsfPct!, 15.0, accuracy: 1E-9)
    }

    func testRatioExactlyTwoGivesPlus15() {
        // weightedLoad = baseline * 2 exactly: set y = y2 = 2*baseline.
        var days: [Day] = []
        for i in 0 ..< 8 { days.append(day(i, 1000)) } // median baseline 1000
        days.append(day(8, 2000))
        days.append(day(9, 2000))
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 10)
        XCTAssertEqual(r.baselineSteps, 1000)
        XCTAssertEqual(r.ratio!, 2.0, accuracy: 1E-9)
        XCTAssertEqual(r.wouldDeltaIsfPct!, 15.0, accuracy: 1E-9)
    }

    // MARK: - inactivity: low recent -> -8% capped & floored

    func testLowRecentLoadCapsAtMinus8() {
        var days: [Day] = []
        for i in 0 ..< 10 { days.append(day(i, 10000)) } // baseline 10000
        // recent two days at floor (<= 40% baseline): 0 steps -> ratio 0 < 0.4.
        days.append(day(13, 0))
        days.append(day(14, 0))
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 15)
        XCTAssertEqual(r.baselineSteps, 10000)
        XCTAssertLessThan(r.ratio!, T.Const.inactivityRatioFull)
        XCTAssertEqual(r.wouldDeltaIsfPct!, -T.Const.inactivityMaxIsfPct, accuracy: 1E-9)
        XCTAssertEqual(r.wouldDeltaIsfPct!, -8.0, accuracy: 1E-9)
    }

    func testRatioAtFloorPointFourGivesMinus8() {
        // weightedLoad = 0.4 * baseline exactly: y = y2 = 0.4 * baseline.
        var days: [Day] = []
        for i in 0 ..< 8 { days.append(day(i, 10000)) } // baseline 10000
        days.append(day(8, 4000))
        days.append(day(9, 4000))
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 10)
        XCTAssertEqual(r.ratio!, 0.4, accuracy: 1E-9)
        XCTAssertEqual(r.wouldDeltaIsfPct!, -8.0, accuracy: 1E-9)
    }

    // MARK: - ratio == 1 -> 0 delta

    func testRatioOneGivesZeroDelta() {
        var days: [Day] = []
        for i in 0 ..< 8 { days.append(day(i, 5000)) } // baseline 5000
        days.append(day(8, 5000)) // y2
        days.append(day(9, 5000)) // y
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 10)
        XCTAssertEqual(r.ratio!, 1.0, accuracy: 1E-9)
        XCTAssertEqual(r.wouldDeltaIsfPct!, 0.0, accuracy: 1E-9)
    }

    func testDecayWeightingFrontLoadsYesterday() {
        // baseline 1000. yesterday=2000, dayBefore=1000.
        // weightedLoad = (2000*1.0 + 1000*0.5)/1.5 = 2500/1.5 = 1666.67.
        var days: [Day] = []
        for i in 0 ..< 8 { days.append(day(i, 1000)) }
        days.append(day(8, 1000)) // dayBefore (todayIndex-2)
        days.append(day(9, 2000)) // yesterday (todayIndex-1)
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 10)
        XCTAssertEqual(r.recentLoad!, 2500.0 / 1.5, accuracy: 1E-6)
        XCTAssertEqual(r.ratio!, (2500.0 / 1.5) / 1000.0, accuracy: 1E-6)
    }

    func testMissingDayBeforeFallsBackToBaseline() {
        // Only yesterday present among the recent two; dayBefore missing -> baseline.
        var days: [Day] = []
        for i in 0 ..< 8 { days.append(day(i, 1000)) }
        // no day at index 8 (todayIndex-2); yesterday at 9.
        days.append(day(9, 1000))
        let h = T.StepHistory(days: days)
        let r = T.compute(h, todayIndex: 10)
        // y=1000, y2 -> baseline 1000 -> weightedLoad = 1000, ratio 1.0.
        XCTAssertEqual(r.recentLoad!, 1000.0, accuracy: 1E-9)
        XCTAssertEqual(r.ratio!, 1.0, accuracy: 1E-9)
    }

    // MARK: - intraday raise-only

    func testIntradayNilBaselineGivesNil() {
        XCTAssertNil(T.intradayLoad(stepsToday: 5000, baseline: nil, hourOfDay: 12))
        XCTAssertNil(T.intradayLoad(stepsToday: 5000, baseline: 0, hourOfDay: 12))
    }

    func testIntradayBelowPaceReturnsZero() {
        // baseline 10000, hour 12 -> diurnal fraction 0.44 -> expected 4400.
        // stepsToday 1000 << expected -> ratio < 1 -> raise-only clamps to 0.
        let pct = T.intradayLoad(stepsToday: 1000, baseline: 10000, hourOfDay: 12)
        XCTAssertEqual(pct!, 0.0, accuracy: 1E-9)
    }

    func testIntradayAbovePaceRaisesCapped() {
        // baseline 10000, hour 12 -> expected 4400. stepsToday huge -> ratio >= 2 -> +15 cap.
        let pct = T.intradayLoad(stepsToday: 100_000, baseline: 10000, hourOfDay: 12)
        XCTAssertEqual(pct!, 15.0, accuracy: 1E-9)
    }

    func testIntradayUsesFractionFloorOvernight() {
        // hour 0 -> fraction 0.0 coerced to 0.02 floor. expected = baseline*0.02 = 200.
        // stepsToday 200 -> ratio exactly 1 -> 0; stepsToday 400 -> ratio 2 -> +15.
        let base = 10000.0
        XCTAssertEqual(T.intradayLoad(stepsToday: 200, baseline: base, hourOfDay: 0)!, 0.0, accuracy: 1E-9)
        XCTAssertEqual(T.intradayLoad(stepsToday: 400, baseline: base, hourOfDay: 0)!, 15.0, accuracy: 1E-9)
    }

    func testIntradayHourCoercion() {
        // Out-of-range hours coerce to [0,23]; should not crash and behave like bounds.
        let high = T.intradayLoad(stepsToday: 100_000, baseline: 10000, hourOfDay: 99)
        let low = T.intradayLoad(stepsToday: 100_000, baseline: 10000, hourOfDay: -5)
        XCTAssertNotNil(high)
        XCTAssertNotNil(low)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let h = T.StepHistory(days: [
            day(10, 5000, "hc"),
            day(11, 6000, "watch"),
            day(12, 0, "")
        ])
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(T.StepHistory.self, from: data)
        XCTAssertEqual(decoded, h)
        XCTAssertEqual(decoded.days.count, 3)
        XCTAssertEqual(decoded.steps(forDay: 11), 6000)
        XCTAssertEqual(decoded.days[1].source, "watch")
    }

    func testDailyStepTotalCodableRoundTrip() throws {
        let d = day(7, 1234, "src")
        let data = try JSONEncoder().encode(d)
        let decoded = try JSONDecoder().decode(T.DailyStepTotal.self, from: data)
        XCTAssertEqual(decoded, d)
    }
}
