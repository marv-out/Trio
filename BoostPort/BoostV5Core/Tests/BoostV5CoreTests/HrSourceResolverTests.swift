@testable import BoostV5Core
import XCTest

/// HR source visibility (Swift port, 2026-06-28). HrSourceResolver classifies HealthKit HR source
/// tags and names the live feed without changing any consumer. Mirrors AAPS `HrSourceResolverTest`.
final class HrSourceResolverTests: XCTestCase {
    private typealias R = HrSourceResolver
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func minsAgo(_ m: Int) -> Date { now.addingTimeInterval(-Double(m) * 60) }
    private func read(_ device: String, _ m: Int) -> R.Reading { R.Reading(device: device, timestamp: minsAgo(m)) }

    func testCanonicalClassifies() {
        XCTAssertEqual(R.canonical("Garmin"), "garmin")
        XCTAssertEqual(R.canonical("Tim's Apple Watch"), "appleWatch")
        XCTAssertEqual(R.canonical("com.withings.wiscale2"), "hk:wiscale2")
    }

    func testWornOutranksOtherHK() {
        XCTAssertLessThan(R.tier("appleWatch"), R.tier("hk:wiscale2"))
        XCTAssertLessThan(R.tier("garmin"), R.tier("hk:wiscale2"))
    }

    func testPicksFreshWornOverFreshHK() {
        let r = R.resolve([read("Apple Watch", 1), read("Apple Watch", 3), read("com.withings.wiscale2", 2)], now: now)
        XCTAssertEqual(r.active, "appleWatch")
        XCTAssertTrue(r.anyFresh)
    }

    func testSilentDeathNoFresh() {
        let r = R.resolve([read("Garmin", 25), read("Apple Watch", 40)], now: now)
        XCTAssertNil(r.active)
        XCTAssertFalse(r.anyFresh)
        XCTAssertTrue(r.note.contains("garmin(-,1,25m)"))
    }

    func testFallsBackToHKWhenOnlyHKFresh() {
        let r = R.resolve([read("Garmin", 30), read("com.withings.wiscale2", 2)], now: now)
        XCTAssertEqual(r.active, "hk:wiscale2")
    }

    func testEmptyIsNone() {
        let r = R.resolve([], now: now)
        XCTAssertNil(r.active)
        XCTAssertEqual(r.note, "none")
    }

    func testNoteBestTrustFirst() {
        let r = R.resolve([read("Garmin", 1), read("Garmin", 2), read("com.withings.wiscale2", 20)], now: now)
        XCTAssertTrue(r.note.hasPrefix("garmin(f,2,"))
        XCTAssertTrue(r.note.contains("hk:wiscale2(-,1,20m)"))
    }
}
