@testable import BoostV5Core
import XCTest

/// Activity-load source abstraction (Swift port, 2026-06-28). StepSourceResolver selection +
/// ActivityLoadTracker multi-source history, overlap calibration, and scaled bridging. Mirrors the
/// AAPS `StepSourceBridgeTest`. Pure — nothing here doses.
final class StepSourceBridgeTests: XCTestCase {
    private typealias T = ActivityLoadTracker
    private typealias Day = ActivityLoadTracker.DailyStepTotal
    private typealias R = StepSourceResolver

    private func srcHist(_ src: String, _ days: [Int: Int]) -> (String, T.StepHistory) {
        let arr = days.sorted { $0.key < $1.key }.map { Day(dayIndex: $0.key, steps: $0.value, source: src) }
        return (src, T.StepHistory(days: arr))
    }

    private func msh(_ srcDays: (String, T.StepHistory)...) -> T.MultiSourceHistory {
        T.MultiSourceHistory(sources: Dictionary(uniqueKeysWithValues: srcDays))
    }

    // MARK: - Resolver

    func testCanonicalMapsGarminAndHK() {
        XCTAssertEqual(R.canonical("com.garmin.connect.mobile"), "garmin")
        XCTAssertEqual(R.canonical("Apple Watch"), "appleWatch")
        XCTAssertEqual(R.canonical("iPhone"), "iphone")
        XCTAssertEqual(R.canonical("com.withings.wiscale2"), "hk:wiscale2")
    }

    func testTrustOrder() {
        XCTAssertLessThan(R.tier("appleWatch"), R.tier("garmin"))
        XCTAssertLessThan(R.tier("garmin"), R.tier("hk:wiscale2"))
        XCTAssertLessThan(R.tier("hk:wiscale2"), R.tier("iphone"))
    }

    func testResolvePicksHighestTrustFresh() {
        let r = R.resolve([
            R.SourceState(source: "iphone", fresh: true, coverageDays: 20, stepsToday: 5000),
            R.SourceState(source: "appleWatch", fresh: true, coverageDays: 2, stepsToday: 6000),
            R.SourceState(source: "garmin", fresh: false, coverageDays: 20, stepsToday: 9000)
        ])
        XCTAssertEqual(r.active, "appleWatch")
        XCTAssertEqual(r.stepsToday, 6000)
    }

    func testResolveFallsBackWhenNoneFresh() {
        let r = R.resolve([
            R.SourceState(source: "iphone", fresh: false, coverageDays: 20, stepsToday: 5000),
            R.SourceState(source: "garmin", fresh: false, coverageDays: 20, stepsToday: 9000)
        ])
        XCTAssertEqual(r.active, "garmin")
    }

    func testResolveEmpty() {
        XCTAssertNil(R.resolve([]).active)
    }

    // MARK: - Calibration

    func testCalibrationMedianOverOverlap() {
        let active = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 9000, source: "iphone") })
        let donor = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 14000, source: "appleWatch") })
        let cal = T.calibration(active: active, donor: donor)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!, 9000.0 / 14000.0, accuracy: 1E-6)
    }

    func testCalibrationNilWhenTooLittleOverlap() {
        let active = T.StepHistory(days: [
            Day(dayIndex: 1, steps: 9000, source: "iphone"),
            Day(dayIndex: 2, steps: 9000, source: "iphone")
        ])
        let donor = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 14000, source: "appleWatch") })
        XCTAssertNil(T.calibration(active: active, donor: donor))
    }

    // MARK: - Bridging (headline guarantee)

    func testWatchDiesPhoneTakesOverScaledBridge() {
        // appleWatch logged 14k/day for days 1..20 then died; iPhone logs 9k and owns today (21).
        let multi = msh(
            srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 14000) })),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (16 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "iphone", todayIndex: 21)
        XCTAssertTrue(bridged.calibrated, "≥3 overlap days (16..20) → calibrated")
        // bridged appleWatch days scaled phone-ward: 14000 * (9000/14000) ≈ 9000
        XCTAssertEqual(bridged.history.steps(forDay: 1)!, 9000, accuracy: 50)
        // baseline ≈ phone units, yesterday (9000) ≈ baseline → ratio ~1, NOT inactivity
        let base = T.baseline(bridged.history, todayIndex: 21)
        XCTAssertNotNil(base)
        XCTAssertEqual(base!, 9000, accuracy: 200)
        let f = T.compute(bridged.history, todayIndex: 21)
        XCTAssertEqual(f.wouldDeltaIsfPct ?? 0, 0, accuracy: 1.0)
    }

    func testBridgingGuaranteesCoverageNoWarmupGap() {
        let multi = msh(
            srcHist("appleWatch", [20: 13000]),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        // appleWatch alone is insufficient-history:
        XCTAssertNil(T.baseline(multi.sources["appleWatch"]!, todayIndex: 21))
        // bridged view has full coverage → baseline forms (no warmup)
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertNotNil(T.baseline(bridged.history, todayIndex: 21))
    }

    func testBridgeWithoutOverlapFlaggedRaw() {
        let multi = msh(
            srcHist("appleWatch", [20: 13000]), // 1 day only → no overlap to calibrate
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertFalse(bridged.calibrated)
        XCTAssertEqual(bridged.history.steps(forDay: 1)!, 9000) // raw iPhone value, no scaling
    }

    func testHighestTrustDonorWinsBridgedDay() {
        let multi = msh(
            srcHist("garmin", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 12000) })),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        // active = appleWatch (no days) → every day bridged; garmin (tier 1) beats iphone (tier 3)
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertEqual(bridged.history.days.first { $0.dayIndex == 5 }?.source, "garmin")
    }

    func testActiveDaysNeverOverwritten() {
        let multi = msh(
            srcHist("appleWatch", [10: 15000]),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertEqual(bridged.history.steps(forDay: 10), 15000)
    }

    // MARK: - mergeSource

    func testMergeSourceAddsDaysAndPrunesEmpty() {
        var multi = T.MultiSourceHistory()
        multi = T.mergeSource(
            multi,
            source: "appleWatch",
            totals: [
                Day(dayIndex: 100, steps: 14000, source: "appleWatch"),
                Day(dayIndex: 101, steps: 15000, source: "appleWatch")
            ],
            todayIndex: 102
        )
        XCTAssertEqual(multi.sources["appleWatch"]?.days.map(\.dayIndex), [100, 101])
        // a source whose only days fall outside the window is pruned
        multi = T.mergeSource(
            multi,
            source: "iphone",
            totals: [Day(dayIndex: 1, steps: 9000, source: "iphone")],
            todayIndex: 102
        )
        XCTAssertNil(multi.sources["iphone"])
    }

    // MARK: - Phone-anchored window (2026-07-02, mirrors AAPS a3bb4afc2a)

    func testPhoneAnchoredWindowBridgesAWatchSwapViaThePhone() {
        // iPhone continuous (undercounts) across two non-overlapping watch eras.
        let phone = srcHist("iphone", Dictionary(uniqueKeysWithValues: (0 ... 19).map { ($0, 7000) }))
        let garmin = srcHist("garmin", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 9000) })) // era 1
        let wear = srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (10 ... 19).map { ($0, 14000) })) // era 2
        let multi = msh(phone, garmin, wear)

        // Old logic: anchored on appleWatch, can't calibrate appleWatch↔garmin (no shared day) → raw.
        let old = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 20)
        XCTAssertFalse(old.calibrated)

        // New logic: iPhone overlaps BOTH eras → every day expressed in phone units (~7000), calibrated.
        let r = T.phoneAnchoredWindow(multi, todayIndex: 20)
        XCTAssertTrue(r.calibrated)
        XCTAssertEqual(Set(r.history.days.map(\.dayIndex)), Set(0 ... 19))
        XCTAssertEqual(r.history.steps(forDay: 5)!, 7000) // 9000 × 7000/9000
        XCTAssertEqual(r.history.steps(forDay: 15)!, 7000) // 14000 × 7000/14000
        XCTAssertEqual(Set(r.donorsUsed), ["garmin", "appleWatch"])
        XCTAssertEqual(T.baseline(r.history, todayIndex: 20)!, 7000, accuracy: 1)
    }

    func testPhoneAnchoredWindowPrefersScaledWornOverPhonesOwnDay() {
        // Both iPhone and appleWatch have every day; appleWatch (worn, accurate) drives, scaled to phone.
        let phone = srcHist("iphone", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 6000) }))
        let wear = srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 12000) })) // 0.5
        let r = T.phoneAnchoredWindow(msh(phone, wear), todayIndex: 10)
        XCTAssertTrue(r.calibrated)
        XCTAssertEqual(r.history.steps(forDay: 4)!, 6000) // 12000 × 0.5
        XCTAssertEqual(r.history.days.first { $0.dayIndex == 4 }!.source, "appleWatch") // worn drove it
    }

    func testPhoneAnchoredWindowDuringWarmupHoldsHigherRawWorn() {
        // iPhone has only 2 days (< minOverlapDays) so appleWatch can't be scaled yet. Hold-higher
        // (2026-07-03, AAPS ecec9075b5): even uncalibrated, a higher raw-worn count is HELD over the
        // phone's own lower day — undercount (false inactivity) is the unsafe direction.
        let phone = srcHist("iphone", [8: 7000, 9: 7000])
        let wear = srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 14000) }))
        let r = T.phoneAnchoredWindow(msh(phone, wear), todayIndex: 10)
        XCTAssertFalse(r.calibrated) // raw-worn used (uncalibrated) → not calibrated
        XCTAssertEqual(r.history.steps(forDay: 8)!, 14000) // raw wear 14000 held over phone's 7000
        XCTAssertEqual(r.history.steps(forDay: 0)!, 14000) // phone lacks day 0 → appleWatch raw
        // Yesterday (day 9) held wear over the lower phone count → breadcrumb records the reconcile.
        XCTAssertEqual(r.heldNote, "held appleWatch 14000 over iphone 7000")
    }

    func testMergeRevisesDayUpOnlyNeverDown() {
        // Hold-higher: a completed day recorded at 6224 must not be dragged down by a later lower
        // sync (2227 — the 2026-07-03 undercount). A higher later value DOES revise it up.
        var h = T.merge(T.StepHistory(), totals: [Day(dayIndex: 5, steps: 6224, source: "appleWatch")], todayIndex: 8)
        h = T.merge(h, totals: [Day(dayIndex: 5, steps: 2227, source: "appleWatch")], todayIndex: 8)
        XCTAssertEqual(h.steps(forDay: 5)!, 6224) // lower sync ignored
        h = T.merge(h, totals: [Day(dayIndex: 5, steps: 6500, source: "appleWatch")], todayIndex: 8)
        XCTAssertEqual(h.steps(forDay: 5)!, 6500) // higher sync revises up
    }

    func testPhoneAnchoredWindowRolloverHoldsHigherSource() {
        // The 2026-07-02 case: wear counted 6224 for yesterday but the phone (pocketed) only 3095.
        // Hold-higher records 6224 and the breadcrumb names the reconcile.
        let phone = srcHist("iphone", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 3095) }))
        var wearDays = Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 3000) })
        wearDays[9] = 6224 // yesterday: watch counted far more than the pocketed phone
        let wear = srcHist("appleWatch", wearDays)
        let r = T.phoneAnchoredWindow(msh(phone, wear), todayIndex: 10)
        // ≥ minOverlapDays of overlap → wear scales into phone units; median(3095/3000) ≈ 1.03.
        XCTAssertGreaterThan(r.history.steps(forDay: 9)!, 3095) // held the higher (scaled) worn count
        XCTAssertNotNil(r.heldNote)
        XCTAssertTrue(r.heldNote!.contains("held appleWatch"))
    }

    func testToPhoneUnitsScalesWornTodayCount() {
        let phone = srcHist("iphone", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 7000) }))
        let wear = srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (0 ... 9).map { ($0, 14000) })) // 0.5
        let multi = msh(phone, wear)
        XCTAssertEqual(T.toPhoneUnits(steps: 10000, activeSource: "appleWatch", multi: multi), 5000) // ×0.5
        XCTAssertEqual(T.toPhoneUnits(steps: 7000, activeSource: "iphone", multi: multi), 7000) // unchanged
        // No overlap to calibrate → returned raw.
        let noOverlap = msh(srcHist("iphone", [0: 7000]), wear)
        XCTAssertEqual(T.toPhoneUnits(steps: 10000, activeSource: "appleWatch", multi: noOverlap), 10000)
    }
}
