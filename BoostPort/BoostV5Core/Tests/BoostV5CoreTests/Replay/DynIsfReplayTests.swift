@testable import BoostV5Core
import Foundation
import XCTest

/// Golden-master replay of the DynISF / future_sens maths against real AndroidAPS Boost cycles for
/// ALL captured boost users (see `BoostDecisionRow` / `ReplayCycle`). Each test recomputes a
/// `DynIsf` function from the recorded inputs and asserts the Swift result matches what AndroidAPS
/// actually produced, within rounding tolerance.
///
/// The insulin divisor is a per-profile constant, so the variable-sens / sensNormalTarget checks fit
/// it per user. The deltaAccl and TDD-blend formulas are user-independent and run across all cycles.
///
/// Requires the fixture (gitignored). Without it every test `XCTSkip`s cleanly. Generate with:
///   bash BoostPort/sim/export_boost_decisions.sh
final class DynIsfReplayTests: XCTestCase {
    private static var all: [ReplayCycle]?

    private func fixture() throws -> [ReplayCycle] {
        if let r = Self.all { return r }
        let r = try ReplayFixture.load()
        Self.all = r
        print("Loaded \(r.count) replay cycles across \(Set(r.map(\.userId)).count) users.")
        return r
    }

    // MARK: - delta acceleration (user-independent; no divisor)

    func testDeltaAccelerationMatchesRecorded() throws {
        let rows = try fixture()
        // Restrict to |short| >= 2 and |delta - short| >= 1: when the numerator/denominator are small
        // the recorded value (from full precision) can't be reproduced from the 1-dp console.
        var report = ReplayReport("deltaAccl (|short|>=2, |delta-short|>=1)", tolerance: 1.0, relTolerance: 0.12)
        for row in rows {
            guard let c = row.console,
                  let delta = c.delta, let short = c.shortAvgDelta, let expected = c.deltaAcceleration,
                  abs(short) >= 2.0, abs(delta - short) >= 1.0
            else { continue }
            report.record(
                expected: expected,
                got: DynIsf.deltaAccl(delta: delta, shortAvgDelta: short),
                ctx: "delta=\(delta) short=\(short)"
            )
        }
        report.printSummary()
        XCTAssertGreaterThan(report.checked, 5000, "expected a large delta-accel sample")
        XCTAssertGreaterThanOrEqual(
            report.matchFraction,
            0.95,
            "deltaAccl diverged from recorded on \(report.failures) rows"
        )
    }

    // MARK: - blended TDD (user-independent; v1/v2 weighted blend only)

    func testBlendedTddMatchesRecorded() throws {
        let rows = try fixture()
        var blended = ReplayReport("blendedTdd (pre-adjustment)", tolerance: 0.3, relTolerance: 0.015)
        var final = ReplayReport("finalTdd (× adj factor)", tolerance: 0.3, relTolerance: 0.015)
        var outOfScope: [String: Int] = [:]
        for row in rows {
            // Scope to the v4.1.5 reference build, as the variableSens and isfTargetV1 checks below
            // already do. Until 2026-09 this test asserted over every variant and still passed,
            // because the corpus was almost entirely v1. It no longer is: `boost-other`, being
            // v4.2 to v4.4.2 with a retuned DynISF, is now the largest group and runs to the
            // present day. Left unscoped the test measured the port against three different
            // algorithm generations at once and reported 90.4%, which says nothing about the port.
            guard isReferenceBuild(row) else {
                outOfScope[row.variant ?? "?", default: 0] += 1
                continue
            }
            guard let c = row.console,
                  let t7 = c.tdd7d, let t1 = c.tdd1d, let t4 = c.tdd4h, let t84 = c.tdd8to4h
            else { continue }
            let gotBlended = DynIsf.blendedTdd(
                last4h: t4,
                last8to4h: t84,
                tdd7d: t7,
                tdd1d: t1,
                adjustmentFactorPct: 100
            )
            // Only rows that print "Blended TDD=" use the weighted blend the Swift port implements
            // (v1/v2). The v3 variant prints "TDD=" (adjusted7D) instead and uses a different
            // pull-down rule — intentionally out of scope here (see REPLAY.md).
            guard let expB = c.blendedTdd else { continue }
            blended.record(expected: expB, got: gotBlended, ctx: "7D=\(t7) 1D=\(t1) 4H=\(t4) 8-4H=\(t84)")
            if let expF = c.finalTdd, let adj = c.adjFactorPct {
                let gotFinal = DynIsf.blendedTdd(
                    last4h: t4,
                    last8to4h: t84,
                    tdd7d: t7,
                    tdd1d: t1,
                    adjustmentFactorPct: adj
                )
                final.record(expected: expF, got: gotFinal, ctx: "adj=\(adj)%")
            }
        }
        blended.printSummary()
        final.printSummary()
        if !outOfScope.isEmpty {
            print("   out-of-scope variants skipped: "
                + outOfScope.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        XCTAssertGreaterThan(blended.checked, 1000)
        XCTAssertGreaterThanOrEqual(blended.matchFraction, 0.97, "blendedTdd diverged on \(blended.failures) rows")
        XCTAssertGreaterThanOrEqual(final.matchFraction, 0.97, "finalTdd diverged on \(final.failures) rows")
    }

    // MARK: - variable sens (end-to-end DynISF; per-user fitted insulin divisor)

    /// Usable for the divisor fit / variable-sens check: have a recorded Variable sens and
    /// sensNormalTarget, with circadian disabled (no extra overlay).
    private func usableForVarSens(_ row: ReplayCycle) -> ConsoleFields? {
        guard let c = row.console,
              let vs = c.variableSens, vs > 0,
              c.sensNormalTarget != nil,
              (c.circadianEnabled ?? false) == false
        else { return nil }
        return c
    }

    /// getIsfByProfile with the already-soft-capped BG (console `bgCapped`) and useCap:false —
    /// equivalent to production's getIsfByProfile(rawBg, useCap:true), without re-capping.
    private func variableSens(_ c: ConsoleFields, divisor: Double) -> Double {
        DynIsf.getIsfByProfile(
            bg: c.bgCapped, normalTarget: c.normalTarget, insulinDivisor: divisor,
            sensNormalTarget: c.sensNormalTarget!, velocity: c.velocity, bgCap: c.bgCap, useCap: false
        )
    }

    private func meanAbsErr(_ rows: [ConsoleFields], divisor: Double) -> Double {
        guard !rows.isEmpty else { return .infinity }
        var sum = 0.0
        for c in rows { sum += abs(variableSens(c, divisor: divisor) - c.variableSens!) }
        return sum / Double(rows.count)
    }

    /// Fit the single insulin divisor for a user (a per-profile constant): coarse scan, then refine.
    private func fitDivisor(_ rows: [ConsoleFields]) -> Double {
        func best(in range: ClosedRange<Double>, step: Double) -> Double {
            var best = range.lowerBound, bestErr = Double.infinity, d = range.lowerBound
            while d <= range.upperBound {
                let e = meanAbsErr(rows, divisor: d)
                if e < bestErr { bestErr = e
                    best = d }
                d += step
            }
            return best
        }
        let coarse = best(in: 45 ... 120, step: 1.0)
        return best(in: (coarse - 1.5) ... (coarse + 1.5), step: 0.05)
    }

    /// The DynISF golden master is scoped to **Boost v4.1.5** (`variant == "v1"`) — the reference
    /// build the Trio port targets. `boost-other` (Boost v4.2–v4.4.2) and `v3` are newer/different
    /// algorithm variants (retuned DynISF / different TDD pull-down) and are intentionally out of
    /// scope here — see REPLAY.md. The replay still *detects* them (printed below) as a guard.
    private func isReferenceBuild(_ c: ReplayCycle) -> Bool { (c.variant ?? "") == "v1" }

    /// The insulin divisor is constant only within a config epoch — users change their insulin peak /
    /// normal target over time. Key the fit by (user, normalTarget, year-month) so a mid-window
    /// profile change lands in a different segment. Still one scalar fit per segment against hundreds–
    /// thousands of varied rows, so it tests the formula rather than overfitting.
    private func epochKey(_ c: ReplayCycle, _ cf: ConsoleFields) -> String {
        "\(c.userId)|nt\(Int(cf.normalTarget.rounded()))|\(Self.yearMonth(c.tsEpoch))"
    }

    private static func yearMonth(_ epoch: Double?) -> String {
        guard let epoch else { return "?" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: epoch))
        return String(format: "%04d-%02d", d.year ?? 0, d.month ?? 0)
    }

    func testVariableSensMatchesRecordedWithFittedDivisor() throws {
        let cycles = try fixture()
        var groups: [String: [ConsoleFields]] = [:]
        var outOfScope: [String: Int] = [:]
        for cyc in cycles {
            guard let cf = usableForVarSens(cyc) else { continue }
            if isReferenceBuild(cyc) {
                groups[epochKey(cyc, cf), default: []].append(cf)
            } else {
                outOfScope[cyc.variant ?? "?", default: 0] += 1
            }
        }

        var report = ReplayReport("variableSens @ per-epoch fitted divisor (v4.1.5/v1)", tolerance: 0.2)
        var segmentsChecked = 0
        var divisors: [String: Double] = [:] // user -> last divisor seen (for a compact summary)

        for key in groups.keys.sorted() {
            let usable = groups[key]!
            guard usable.count >= 100 else { continue }
            segmentsChecked += 1
            let fitted = fitDivisor(usable)
            divisors[String(key.prefix(while: { $0 != "|" }))] = fitted
            for c in usable {
                report.record(
                    expected: c.variableSens!,
                    got: variableSens(c, divisor: fitted),
                    ctx: "\(key) bgCapped=\(c.bgCapped) sNT=\(c.sensNormalTarget!) v=\(c.velocity)"
                )
            }
        }
        print("── DynISF divisor by user (v4.1.5/v1, last epoch) ───────────────────────────────")
        for u in divisors.keys.sorted() { print(String(format: "   %@: ~%.1f", u, divisors[u]!)) }
        if !outOfScope.isEmpty {
            print(
                "   out-of-scope variants skipped: " + outOfScope.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            )
        }
        report.printSummary()

        XCTAssertGreaterThanOrEqual(segmentsChecked, 5, "expected several config epochs with enough data")
        XCTAssertGreaterThan(report.checked, 50000, "expected a large multi-user v4.1.5 sample")
        // A faithful port reproduces the recorded DynISF output across the vast majority of real
        // v4.1.5 cycles in every config epoch; lower means a formula drift.
        XCTAssertGreaterThanOrEqual(
            report.matchFraction,
            0.99,
            "variableSens diverged on \(report.failures)/\(report.checked) rows"
        )
    }

    // MARK: - sensNormalTarget from TDD (per-user divisor; TT-off rows only)

    /// Validate `isfTargetV1` directly against the console's "TDD ISF at target: X" — which is the
    /// pure isfTargetV1 × globalScale output, BEFORE the TT/autosens sensitivity-ratio division that
    /// the recorded `sensNormalTarget` additionally folds in. This isolates the ISF-at-target formula.
    func testIsfTargetV1MatchesRecorded() throws {
        let cycles = try fixture()
        var byKey: [String: [ReplayCycle]] = [:]
        for c in cycles {
            guard isReferenceBuild(c), let cf = c.console else { continue }
            byKey[epochKey(c, cf), default: []].append(c)
        }

        var report = ReplayReport(
            "isfTargetV1 × globalScale = TDD ISF at target (v4.1.5/v1)",
            tolerance: 0.3,
            relTolerance: 0.015
        )
        for key in byKey.keys.sorted() {
            let group = byKey[key]!
            let usable = group.compactMap(usableForVarSens)
            guard usable.count >= 100 else { continue }
            let divisor = fitDivisor(usable)
            for row in group {
                guard let c = row.console,
                      let expected = c.tddIsfAtTarget, expected > 0,
                      let finalTdd = c.finalTdd, finalTdd > 0
                else { continue }
                let isf = DynIsf.isfTargetV1(tdd: finalTdd, normalTarget: c.normalTarget, insulinDivisor: divisor)
                let got = ((isf * c.globalScale) * 10).rounded() / 10 // AAPS rounds to 0.1
                report.record(
                    expected: expected,
                    got: got,
                    ctx: "\(key) tdd=\(finalTdd) nt=\(c.normalTarget) scale=\(c.globalScale)"
                )
            }
        }
        report.printSummary()
        XCTAssertGreaterThan(report.checked, 10000)
        XCTAssertGreaterThanOrEqual(
            report.matchFraction,
            0.97,
            "isfTargetV1 diverged on \(report.failures)/\(report.checked) rows"
        )
    }
}
