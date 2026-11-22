@testable import BoostV5Core
import XCTest

/// Implausible-TDD guard for dynamic ISF (AAPS `DynIsfTddGuardTest`, 2026-07-30).
///
/// Field case: a cross-fork migration onto a fresh database reported a TDD of 3.1 to 4.1 U/day
/// against a true value near 20. Dynamic ISF reached 5550 to 8944 mg/dL/U against a profile ISF of
/// 100, the insulin requirement computed at or below zero, and the loop delivered nothing for 3.5 h
/// while glucose climbed to 276 mg/dL: 19 consecutive zero temp basals, no lows and no alarm. The
/// previous `tdd > 0` test passed throughout, so the guard is anchored on the TDD the profile
/// implies through the 1800 rule instead.
final class DynIsfTddGuardTests: XCTestCase {
    func testFieldCaseIsCaught() {
        // Profile ISF 100 implies a TDD of 18.0, so the floor is 6.3.
        XCTAssertTrue(DynIsf.tddImplausibleForProfile(tdd: 4.0, profileSens: 100))
        XCTAssertTrue(DynIsf.tddImplausibleForProfile(tdd: 3.1, profileSens: 100))
    }

    func testHealthyTddForTheSameProfilePasses() {
        // Their true TDD was near 20, and it corrected to 20.2 once history filled in.
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 20.2, profileSens: 100))
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 6.4, profileSens: 100))
    }

    func testFloorIsSelfScalingAgainstTheOwnProfile() {
        // Aggressive profile ISF 30 implies 60, floor 21.
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 25, profileSens: 30))
        XCTAssertTrue(DynIsf.tddImplausibleForProfile(tdd: 15, profileSens: 30))
        // Insensitive profile ISF 300 implies 6, floor 2.1, so a genuinely small TDD is not flagged.
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 4.0, profileSens: 300))
        // The same TDD of 4.0 is implausible on a profile ISF of 100 and ordinary on one of 300,
        // which is the distinction the previous `tdd > 0` test could not make.
    }

    func testFailsOpenWithNoUsableProfileReference() {
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 0.1, profileSens: 0))
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 0.1, profileSens: -5))
    }

    func testBoundaryIsExactlyTheImpliedFraction() {
        XCTAssertFalse(DynIsf.tddImplausibleForProfile(tdd: 6.3, profileSens: 100))
        XCTAssertTrue(DynIsf.tddImplausibleForProfile(tdd: 6.29, profileSens: 100))
    }

    func testDerivedIsfWouldHaveExplodedWithoutTheGuard() {
        // Shows the magnitude the guard prevents. At the field TDD of 3.6 U/day, with the shipped
        // normal target of 99 mg/dL and insulin divisor of 75, the V1 formula returns 594 mg/dL/U
        // against a configured profile ISF of 100, which is what drove the insulin requirement to
        // zero. The AAPS report quotes a larger multiple because their divisor and target differ;
        // the direction and order of magnitude are the same.
        let exploded = DynIsf.isfTargetV1(tdd: 3.6, normalTarget: 99, insulinDivisor: 75)
        XCTAssertEqual(exploded, 594.13, accuracy: 0.01)
        XCTAssertGreaterThan(exploded, 100 * 5)
        XCTAssertTrue(DynIsf.tddImplausibleForProfile(tdd: 3.6, profileSens: 100))
    }
}
