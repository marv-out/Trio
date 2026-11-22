@testable import BoostV5Core
import XCTest

final class CircadianISFTests: XCTestCase {
    // MARK: 15:00–22:00 flat region == 1.0

    func testMiddayThroughEveningIsFlatOne() {
        for hour in 15 ... 22 {
            XCTAssertEqual(
                CircadianISF.sensitivity(hourOfDay: hour), 1.0,
                accuracy: 1E-6,
                "hour \(hour) should be flat 1.0"
            )
        }
    }

    // MARK: Dawn hours (3–8) are reduced (<1.0), roughly 0.4–0.6

    func testDawnHoursAreReduced() {
        for hour in 3 ... 8 {
            let value = CircadianISF.sensitivity(hourOfDay: hour)
            XCTAssertLessThan(value, 1.0, "dawn hour \(hour) should be < 1.0")
            XCTAssertGreaterThan(value, 0.4, "dawn hour \(hour) should be > 0.4")
            XCTAssertLessThan(value, 0.85, "dawn hour \(hour) should be in the reduced band")
        }
        // Lowest dawn point is hour 8 (~0.49) and hour 3 (~0.61).
        XCTAssertLessThan(
            CircadianISF.sensitivity(hourOfDay: 8),
            CircadianISF.sensitivity(hourOfDay: 3)
        )
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 8), 0.486704, accuracy: 1E-6)
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 3), 0.6099822, accuracy: 1E-6)
    }

    // MARK: Exact value per hour 0–23 (curve read from Kotlin source)

    func testEveryHourMatchesReference() {
        let expected: [Int: Double] = [
            0: 1.32826,
            1: 1.15869,
            2: 0.81696,
            3: 0.6099822,
            4: 0.6299896,
            5: 0.665337,
            6: 0.7202244,
            7: 0.7988518,
            8: 0.486704,
            9: 0.619303,
            10: 0.80384,
            11: 0.67097,
            12: 0.84188,
            13: 1.06351,
            14: 1.34054,
            15: 1.0,
            16: 1.0,
            17: 1.0,
            18: 1.0,
            19: 1.0,
            20: 1.0,
            21: 1.0,
            22: 1.0,
            23: 1.823875
        ]
        for hour in 0 ... 23 {
            XCTAssertEqual(
                CircadianISF.sensitivity(hourOfDay: hour), expected[hour]!,
                accuracy: 1E-6,
                "hour \(hour) mismatch"
            )
        }
    }

    // MARK: Segment boundary behaviour

    func testSegmentBoundaries() {
        // 0–2h: hour 0 uses n = max(now, 0.5) = 0.5
        let n0 = max(0.0, 0.5)
        let h0 = 0.09130 * pow(n0, 3) - 0.33261 * pow(n0, 2) + 1.4
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 0), h0, accuracy: 1E-9)
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 0), 1.32826, accuracy: 1E-6)

        // 2–3h boundary at hour 2
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 2), 0.81696, accuracy: 1E-6)
        // 3–8h boundary at hour 3
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 3), 0.6099822, accuracy: 1E-6)
        // 8–11h boundary at hour 8
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 8), 0.486704, accuracy: 1E-6)
        // 11–15h boundary at hour 11
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 11), 0.67097, accuracy: 1E-6)
        // 15–22h flat boundary at hour 15
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 15), 1.0, accuracy: 1E-6)
        // 22–24h boundary at hour 22 still flat 1.0 (15...22 matched first)
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 22), 1.0, accuracy: 1E-6)
        // last hour 23 in the 22–24 segment
        XCTAssertEqual(CircadianISF.sensitivity(hourOfDay: 23), 1.823875, accuracy: 1E-6)
    }

    // MARK: Negative hours clamp to 0 (Kotlin max(hourOfDay, 0))

    func testNegativeHourClampsToZero() {
        XCTAssertEqual(
            CircadianISF.sensitivity(hourOfDay: -5),
            CircadianISF.sensitivity(hourOfDay: 0),
            accuracy: 1E-9
        )
    }

    // MARK: apply() multiplies and rounds to 1 dp

    func testApplyMultipliesAndRounds() {
        // Flat region: factor 1.0 -> rounds variableSens to 1 dp.
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 50.0, hourOfDay: 16),
            50.0,
            accuracy: 1E-9
        )
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 50.04, hourOfDay: 16),
            50.0,
            accuracy: 1E-9
        )
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 50.05, hourOfDay: 16),
            50.1,
            accuracy: 1E-9
        ) // HALF_UP

        // Dawn reduction at hour 8: 100 * 0.486704 = 48.6704 -> 48.7
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 100.0, hourOfDay: 8),
            48.7,
            accuracy: 1E-9
        )

        // Hour 23 amplification: 100 * 1.823875 = 182.3875 -> 182.4
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 100.0, hourOfDay: 23),
            182.4,
            accuracy: 1E-9
        )

        // apply == round1(variableSens * sensitivity) for an arbitrary hour
        let raw = 73.0 * CircadianISF.sensitivity(hourOfDay: 5)
        let expected = (raw * 10).rounded(.toNearestOrAwayFromZero) / 10
        XCTAssertEqual(
            CircadianISF.apply(variableSens: 73.0, hourOfDay: 5),
            expected,
            accuracy: 1E-9
        )
    }
}
