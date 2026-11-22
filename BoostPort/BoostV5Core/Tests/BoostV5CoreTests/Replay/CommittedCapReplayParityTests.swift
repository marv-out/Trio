@testable import BoostV5Core
import Foundation
import XCTest

/// Trio's committed cap derivation on the cohort windows of boost-experiments 2026-11-committed-cap-5.
///
/// tim2000s/trio-boost-v1-parity scripts/committed_cap_dump.py writes each trailing 14- and 28-day
/// window (median TDD, SMB amounts) with the study's value, max(SMB p75, TDD/40) in [0.25, 5.0] U.
/// This runs BoostV5AutoConfig.compute on each and requires the same committed cap, then reports the
/// largest per user. Point COMMITTED_CAP_PARITY_FILE at the file; without it the test skips. The file
/// is patient history and stays outside the repository.
final class CommittedCapReplayParityTests: XCTestCase {
    func testCommittedCapMatchesTheStudyOnEveryWindow() throws {
        guard let path = ProcessInfo.processInfo.environment["COMMITTED_CAP_PARITY_FILE"] else {
            throw XCTSkip("no committed cap parity file")
        }
        var largest: [String: Double] = [:]
        var mismatches = 0
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            // Only the committed cap is read; the other inputs are set so compute runs and nothing else matters.
            let p = BoostV5AutoConfig.PriorDosing(
                daysWithData: 14, bgReadingCount: 100_000, tddMedianU: (o["tdd_median"] as! NSNumber).doubleValue,
                manualBolusesU: [], smbAmountsU: (o["smbs"] as! [NSNumber]).map(\.doubleValue),
                tbrBelow70Pct: 0, timeBelow54Pct: 0, meanGlucoseMgdl: 140, currentMaxBolusU: 10
            )
            let cap = try XCTUnwrap(BoostV5AutoConfig.compute(p)).committedCapU
            let want = (o["derived_633"] as! NSNumber).doubleValue
            if abs(cap - want) > 1E-9 { mismatches += 1
                print("mismatch \(o["user"]!) \(o["lookback_d"]!) d: Trio \(cap), study \(want)") }
            let u = o["user"] as! String
            largest[u] = max(largest[u] ?? 0, cap)
        }
        XCTAssertEqual(mismatches, 0)
        print(
            "CommittedCapReplayParity: \(lines.count) windows, \(largest.count) users, largest per user:",
            largest.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        )
    }
}
