@testable import BoostV5Core
import Foundation
import XCTest

/// Robustness replay of the full V5 engine (`BoostV5Engine.decide`) over real glucose
/// trajectories, in chronological order, carrying persisted state forward exactly as the app does.
///
/// NOTE — this is deliberately NOT a golden master. The captured `boost_decisions` data is from
/// AndroidAPS Boost **v4.1.5**, whose dosing uses the TIER system (e.g. "TIER 8: Regular oref1").
/// The Trio port is the **V5 meal-hypothesis state machine** (IDLE→OBSERVING→CONFIRMED→COMMITTED→
/// RECOVERING) — a different algorithm generation — so the recorded tier/dose cannot be compared
/// 1:1. (The DynISF maths ARE shared and are golden-master-verified in `DynIsfReplayTests`.)
///
/// What this DOES test: that the V5 state machine, signal score, aggression budget and Phase-3
/// safety gates run over 25k real cycles without crashing, never emit NaN/inf, never exceed maxIOB,
/// and produce non-negative doses — a strong integration/regression guard. It also prints the
/// resulting state distribution and dose stats for eyeballing.
///
/// Requires the fixture (gitignored); `XCTSkip`s without it.
final class BoostEngineReplayTests: XCTestCase {
    /// Turn the opt-in levers on for this run. They default off, so the baseline replay measures
    /// the shipped configuration; with them on the same trajectories exercise the primer, the
    /// velocity-budget floor and the earlier confirm timing.
    private var levers: Bool { ProcessInfo.processInfo.environment["BOOST_REPLAY_LEVERS"] == "1" }

    func testEngineRunsRobustlyOverRealTrajectories() throws {
        let byUser = try ReplayFixture.loadByUser()
        XCTAssertGreaterThanOrEqual(byUser.count, 5, "expected several users")

        var stateCounts: [MealHypothesis: Int] = [:]
        var doseSum = 0.0, doseMax = 0.0, dosed = 0, totalCycles = 0
        var nonFinite = 0, negative = 0, overMaxIob = 0
        let maxIob = 8.0

        // Replay each user's timeline independently — meal-hypothesis state must never cross users.
        for (_, cycles) in byUser {
            let rows = cycles.filter { $0.tsEpoch != nil }
            guard rows.count > 200 else { continue }
            var persisted = V5PersistedState()
            var bgHistory: [Double] = [] // most-recent last
            var deltaHistory: [Double] = [] // most-recent last
            var prevEpoch: Double?

            for row in rows {
                totalCycles += 1
                let bg = row.cgmMgdl
                let epoch = row.tsEpoch!

                // Derive the glucose-status inputs from the actual CGM sequence (5-min cadence).
                let delta = bgHistory.last.map { bg - $0 } ?? 0
                let recentDeltas = (deltaHistory + [delta]).suffix(5)
                let shortAvgDelta = recentDeltas.suffix(3).reduce(0, +) / Double(max(recentDeltas.suffix(3).count, 1))
                let deltaAccl = DynIsf.deltaAccl(delta: delta, shortAvgDelta: shortAvgDelta)
                let maxDelta = recentDeltas.max() ?? delta
                let cumulativeRise30min = max(0, (deltaHistory + [delta]).suffix(6).reduce(0, +))
                let recentLowBg = (bgHistory + [bg]).suffix(12).min() ?? bg

                let iob = row.iobIob ?? 0
                let target = normalizedMgdl(row.sugCurrentTarget) ?? 100
                let eventualBg = normalizedMgdl(row.sugEventualbg) ?? (bg + shortAvgDelta * 12)
                let minGuardBg = normalizedMgdl(row.reasonMinguardbg) ?? recentLowBg
                let baseInsulinReq = max(0, row.sugInsulinreq ?? 0.3)
                let timeJump = prevEpoch.map { (epoch - $0) / 60.0 } ?? 0

                let inputs = V5Inputs(
                    delta: delta, shortAvgDelta: shortAvgDelta, deltaAccl: deltaAccl, bg: bg,
                    eventualBg: eventualBg, targetBg: target, maxDelta: maxDelta,
                    minGuardBg: minGuardBg, minGuardThreshold: 70,
                    deltaHistory: Array(recentDeltas), iob: iob, maxIob: maxIob,
                    baseInsulinReq: baseInsulinReq, roundSmbTo: 0.05, enableSmbPreChecks: true,
                    recentLowBg: recentLowBg, cumulativeRise30min: cumulativeRise30min,
                    hour: hourOfDay(epoch), exerciseActive: false, inPostExerciseWindow: false,
                    // 2026-09 opt-in dosing levers. Off by default so the baseline replay is
                    // unchanged; BOOST_REPLAY_LEVERS=1 turns them all on so the paths they add are
                    // exercised over the same real trajectories. The engine's own gates still
                    // decide whether any of them fires on a given cycle.
                    aggressiveEarlyConfirmEnabled: levers,
                    velocityBudgetActive: levers,
                    primerCapU: levers ? 0.6 : 0,
                    primerUseTempBasal: false,
                    nowMs: Double(epoch) * 1000,
                    timeJumpMinutes: timeJump
                )

                let decision = BoostV5Engine.decide(inputs, persisted: persisted)
                persisted = decision.newPersistedState

                // Robustness invariants.
                for v in [decision.finalDose, decision.insulinToDeliver, decision.score] {
                    if !v.isFinite { nonFinite += 1 }
                }
                if decision.finalDose < 0 { negative += 1 }
                if decision.finalDose > maxIob + 1E-6 { overMaxIob += 1 }

                stateCounts[decision.mealHypothesis, default: 0] += 1
                if decision.finalDose > 0 { dosed += 1
                    doseSum += decision.finalDose
                    doseMax = max(doseMax, decision.finalDose) }

                bgHistory.append(bg)
                if bgHistory.count > 16 { bgHistory.removeFirst() }
                deltaHistory.append(delta)
                if deltaHistory.count > 8 { deltaHistory.removeFirst() }
                prevEpoch = epoch
            }
        } // end per-user loop

        // Report.
        print("── V5 engine robustness replay (per-user timelines) ───────────────────────────────")
        print(
            "   users=\(byUser.count)  cycles=\(totalCycles)  dosed=\(dosed)  meanDose=\(dosed > 0 ? doseSum / Double(dosed) : 0)  maxDose=\(doseMax)"
        )
        print("   state distribution:")
        for s in stateCounts.keys.sorted(by: { "\($0)" < "\($1)" }) {
            print("     \(s): \(stateCounts[s]!)")
        }
        print("   violations — nonFinite=\(nonFinite) negative=\(negative) overMaxIob=\(overMaxIob)")

        // Invariants must hold on every cycle.
        XCTAssertEqual(nonFinite, 0, "engine produced non-finite output")
        XCTAssertEqual(negative, 0, "engine produced a negative dose")
        XCTAssertEqual(overMaxIob, 0, "engine produced a dose exceeding maxIOB")
    }

    // MARK: - helpers

    /// Console/columns mix mmol and mg/dL. Values < 25 are treated as mmol and scaled ×18.
    private func normalizedMgdl(_ v: Double?) -> Double? {
        guard let v, v > 0 else { return nil }
        return v < 25 ? v * 18.0 : v
    }

    private func hourOfDay(_ epochSeconds: Double) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.hour, from: Date(timeIntervalSince1970: epochSeconds))
    }
}
