@testable import BoostV5Core
import XCTest

/// The dosing change of Boost 6.3.2 (tag `4.0.0-boost-6.3.2`): the SMB basal minutes are starting
/// values written once, after AAPS SmbBasalMinutesSeedTest.
final class Boost632Tests: XCTestCase {
    typealias Apply = BoostV5AutoConfigApply

    func testAFirstRunAtTrioDefaultsGets15And20() {
        let r = Apply.seedSmbBasalMinutes(smb: 30, uam: 30, alreadySeeded: false)
        XCTAssertEqual(r.smb, 15)
        XCTAssertEqual(r.uam, 20)
    }

    func testAFirstRunLowersValuesTheOldClampHeldToTheSeeds() {
        // 6.3.0 in Trio dosed 120 and 60 as 15 and 20 without rewriting them; the seed keeps that dose.
        let r = Apply.seedSmbBasalMinutes(smb: 120, uam: 60, alreadySeeded: false)
        XCTAssertEqual(r.smb, 15)
        XCTAssertEqual(r.uam, 20)
    }

    func testValuesAtOrBelowTheSeedsAreKept() {
        let r = Apply.seedSmbBasalMinutes(smb: 15, uam: 15, alreadySeeded: false)
        XCTAssertNil(r.smb)
        XCTAssertNil(r.uam)
    }

    func testOnlyTheSettingAboveItsSeedIsWritten() {
        let r = Apply.seedSmbBasalMinutes(smb: 15, uam: 30, alreadySeeded: false)
        XCTAssertNil(r.smb)
        XCTAssertEqual(r.uam, 20)
    }

    func testASecondRunWritesNothingSoAValueRaisedAfterwardsStays() {
        let r = Apply.seedSmbBasalMinutes(smb: 120, uam: 60, alreadySeeded: true)
        XCTAssertNil(r.smb)
        XCTAssertNil(r.uam)
    }

    func testNoSeedSitsBelowTrioPickerMinimum() {
        // DecimalPickerSettings.maxSMBBasalMinutes and maxUAMSMBBasalMinutes start at 15.
        XCTAssertGreaterThanOrEqual(Apply.smbBasalMinutesSeeds.smb, 15)
        XCTAssertGreaterThanOrEqual(Apply.smbBasalMinutesSeeds.uam, 15)
    }
}
