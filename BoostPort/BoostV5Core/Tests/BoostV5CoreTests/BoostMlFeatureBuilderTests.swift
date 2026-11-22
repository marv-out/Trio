@testable import BoostV5Core
import XCTest

final class BoostMlFeatureBuilderTests: XCTestCase {
    typealias B = BoostMlFeatureBuilder

    private func snap(_ ts: Double, _ cgm: Double) -> B.CycleSnapshot {
        B.CycleSnapshot(
            ts: ts, cgmMgdl: cgm, iobIob: 1.0, iobActivity: 0.01,
            sugEventualBG: cgm + 10, recentSmbUnits60m: 0.5, sugMinDelta: -1.0
        )
    }

    // MARK: - Ring-buffer staleness (AAPS 2026-08-14)

    private func snapAtMinute(_ minute: Double, _ cgm: Double) -> B.CycleSnapshot {
        snap(minute * 60000, cgm)
    }

    // MARK: - Lag resampling (AAPS 2026-08-01)

    func testASecondPushInsideTheLagIntervalReplacesRatherThanAppends() {
        // At a one-minute sensor cadence the engine runs five times as often, but the six lags were
        // trained on five-minute spacing. The lag count is part of the model, so the input is
        // resampled: one slot per interval, holding the freshest reading within it.
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        for minute in 1 ... 4 { ring.push(snapAtMinute(Double(minute), 100 + Double(minute))) }
        XCTAssertEqual(ring.snapshots.count, 1)
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 104, "the freshest reading in the interval")
    }

    func testAPushAtTheIntervalOpensANewSlot() {
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(5, 105))
        XCTAssertEqual(ring.snapshots.count, 2)
        XCTAssertEqual(ring.lagged(1)?.cgmMgdl, 100)
    }

    func testTheSpacingToleranceAdmitsASlightlyEarlyCycle() {
        // Cycles do not land exactly on the interval, so half a minute of tolerance keeps a
        // five-minute feed opening a new slot every cycle rather than overwriting every other one.
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(4.9, 105))
        XCTAssertEqual(ring.snapshots.count, 2)
    }

    func testAContinuousOneMinuteFeedAccumulatesTheFullLookback() {
        // Trio anchors each slot on the timestamp that opened its interval. The Kotlin assigns the
        // replacement whole, which moves the anchor forward every minute so the spacing never
        // reaches the interval: one slot is replaced indefinitely, no second slot opens, and every
        // lag falls back to the current cycle. That is the opposite of what the resampling is for.
        var ring = B.RingBuffer()
        for minute in 0 ... 40 { ring.push(snapAtMinute(Double(minute), 100 + Double(minute))) }
        XCTAssertEqual(ring.snapshots.count, B.lookback)
        let span = (ring.lagged(0)!.ts - ring.lagged(B.lookback - 1)!.ts) / 60000
        XCTAssertEqual(span, 25, accuracy: 0.001, "six slots five minutes apart")
        // Each slot holds the freshest reading from its own interval. The newest slot opened at
        // minute 40 and the feed stops there, so it holds that reading; the one before it spans
        // minutes 35 to 39 and holds the last of those.
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 140)
        XCTAssertEqual(ring.lagged(1)?.cgmMgdl, 139)
    }

    func testTheSlotKeepsTheTimestampThatOpenedItsInterval() {
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(3, 103))
        XCTAssertEqual(ring.snapshots.count, 1)
        XCTAssertEqual(ring.lagged(0)?.ts, 0, "anchored on the opening timestamp")
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 103, "holding the freshest reading")
        // So the next interval still opens on time rather than being pushed out by the replacement.
        ring.push(snapAtMinute(5, 105))
        XCTAssertEqual(ring.snapshots.count, 2)
    }

    func testAFiveMinuteFeedAccumulatesTheFullLookback() {
        // The cadence the model was trained on, and the one the shipped loop trigger produces.
        var ring = B.RingBuffer()
        for step in 0 ... 8 { ring.push(snapAtMinute(Double(step) * 5, 100 + Double(step))) }
        XCTAssertEqual(ring.snapshots.count, B.lookback)
        let span = (ring.lagged(0)!.ts - ring.lagged(B.lookback - 1)!.ts) / 60000
        XCTAssertEqual(span, 25, accuracy: 0.001, "six slots five minutes apart")
    }

    func testRingBufferDropsSnapshotsOlderThanTheLookbackWindow() {
        var ring = B.RingBuffer()
        // Five contiguous cycles on the five-minute grid, then a two-hour break.
        for i in 0 ..< 5 { ring.push(snapAtMinute(Double(i) * 5, 100 + Double(i))) }
        XCTAssertEqual(ring.snapshots.count, 5)
        ring.push(snapAtMinute(140, 200)) // 2 h after the last one

        // Only the new cycle survives: the pre-gap snapshots are not the preceding five cycles.
        XCTAssertEqual(ring.snapshots.count, 1)
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 200)
        XCTAssertNil(ring.lagged(1))
    }

    func testRingBufferKeepsHistoryAcrossAnOrdinaryLateReading() {
        var ring = B.RingBuffer()
        for i in 0 ..< 5 { ring.push(snapAtMinute(Double(i) * 5, 100 + Double(i))) }
        // A cycle 8 minutes after the last rather than 5. The slack in the window is there so a
        // late reading does not discard usable history.
        ring.push(snapAtMinute(28, 200))
        XCTAssertEqual(ring.snapshots.count, 6)
        XCTAssertEqual(ring.lagged(5)?.cgmMgdl, 100)
    }

    func testRingBufferBoundaryIsThirtyFiveMinutes() {
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(35, 200)) // exactly 35 min: the older entry is not yet stale
        XCTAssertEqual(ring.snapshots.count, 2)

        var ring2 = B.RingBuffer()
        ring2.push(snapAtMinute(0, 100))
        ring2.push(snapAtMinute(35.001, 200)) // just past it
        XCTAssertEqual(ring2.snapshots.count, 1)
    }

    func testRingBufferDropsOnlyTheEntriesOutsideTheWindow() {
        var ring = B.RingBuffer()
        // Two old cycles, a gap, then three recent ones. Only the old pair should go.
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(5, 101))
        ring.push(snapAtMinute(50, 102))
        ring.push(snapAtMinute(55, 103))
        ring.push(snapAtMinute(60, 104))
        XCTAssertEqual(ring.snapshots.count, 3)
        XCTAssertEqual(ring.lagged(2)?.cgmMgdl, 102)
        XCTAssertNil(ring.lagged(3))
    }

    func testRingBufferLaggedAndCap() {
        var ring = B.RingBuffer()
        // Five-minute spacing, which is what the lookback window models. Pushing at millisecond
        // spacing would now resample into a single slot (see the lag-spacing tests below).
        for i in 0 ..< 8 { ring.push(snap(Double(i) * B.lagSpacingMs, 100 + Double(i))) }
        // Capped at 6 entries — oldest dropped.
        XCTAssertEqual(ring.snapshots.count, B.lookback)
        // lag0 = most recent (cgm 107), lag5 = 6th from end (cgm 102).
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 107)
        XCTAssertEqual(ring.lagged(5)?.cgmMgdl, 102)
        // Beyond the buffer → nil.
        XCTAssertNil(ring.lagged(6))
    }

    func testBuildStaticAndLagMapping() {
        var ring = B.RingBuffer()
        ring.push(snap(0, 100)) // lag1 after current push
        let current = snap(B.lagSpacingMs, 120)
        ring.push(current) // lag0
        let names = ["cgm_mgdl", "bg_above_target", "cgm_mgdl_lag0", "cgm_mgdl_lag1", "sug_minDelta_lag0"]
        let statics: [String: Double] = ["cgm_mgdl": 120, "bg_above_target": 20]
        let v = B.build(featureNames: names, current: current, ring: ring, staticValues: statics)
        XCTAssertEqual(v[0], 120) // static cgm_mgdl
        XCTAssertEqual(v[1], 20) // static bg_above_target
        XCTAssertEqual(v[2], 120) // lag0 = current
        XCTAssertEqual(v[3], 100) // lag1 = previous
        XCTAssertEqual(v[4], -1.0) // sug_minDelta_lag0
    }

    func testBuildColdStartLagFallsBackToCurrent() {
        var ring = B.RingBuffer()
        let current = snap(0, 90)
        ring.push(current) // only one entry
        let names = ["cgm_mgdl_lag0", "cgm_mgdl_lag3"]
        let v = B.build(featureNames: names, current: current, ring: ring, staticValues: [:])
        XCTAssertEqual(v[0], 90) // lag0 present
        XCTAssertEqual(v[1], 90) // lag3 missing → falls back to current
    }

    func testMissingStaticDefaultsToZero() {
        let v = B.build(
            featureNames: ["not_a_known_feature"], current: snap(0, 100),
            ring: B.RingBuffer(), staticValues: [:]
        )
        XCTAssertEqual(v[0], 0.0)
    }

    func testSerializeRoundTrip() {
        var ring = B.RingBuffer()
        ring.push(snap(0, 110))
        ring.push(snap(B.lagSpacingMs, 120))
        let restored = B.deserialize(B.serialize(ring))
        XCTAssertEqual(restored.snapshots.count, 2)
        XCTAssertEqual(restored.lagged(0)?.cgmMgdl, 120)
        XCTAssertEqual(restored.lagged(1)?.cgmMgdl, 110)
    }

    func testDeserializeEmptyAndCorrupt() {
        XCTAssertEqual(B.deserialize("").snapshots.count, 0)
        XCTAssertEqual(B.deserialize("{not json").snapshots.count, 0)
    }
}
