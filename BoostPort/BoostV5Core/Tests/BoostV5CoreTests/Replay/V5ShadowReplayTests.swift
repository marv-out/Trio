@testable import BoostV5Core
import Foundation
import XCTest

/// Dosing golden master: replay the on-device **V5 shadow** decisions (Nightscout deviceStatus
/// `openaps.suggested.boostV5_*`, produced by the AndroidAPS Kotlin V5) through the Trio Swift port
/// (`BoostV5Core`) and assert the port reproduces them.
///
/// The shadow records the V5 intermediates we can't recompute without the on-device ML model
/// (`boostV5_budget`, `boostV5_actionMult`, `boostV5_state`). So we feed those recorded intermediates
/// into the port's **dose-cap + Phase-3 safety-gate** tail — exactly `BoostV5Engine.decide`'s dosing
/// stages — and check it reproduces:
///   • the full gate-reduction string (`HARD:…` / `iobHeadroom:…,decel:…,maxIOB` / `none`)
///   • the final SMB dose (`boostV5_finalDose`)
///   • the per-state action multiplier (`boostV5_actionMult`)
///
/// This is the dosing-path / safety-gate validation the DynISF backtest couldn't give. deltas,
/// maxDelta and the 30-min rise are reconstructed from each user's CGM sequence (gaps reset it).
///
/// Requires the fixture (gitignored). Generate with:
///   python3 BoostPort/sim/fetch_v5shadow.py --days 10
final class V5ShadowReplayTests: XCTestCase {
    struct Cycle: Decodable {
        let user: String
        let ts: String
        let bg: Double
        let eventualBG: Double?
        let minGuardBG: Double?
        let iob: Double?
        let targetBG: Double?
        let insulinReq: Double?
        let deltaAccl: Double?
        let mlHypoRisk: Double?
        let maxIob: Double?
        let lgsThreshold: Double?
        let roundSmbTo: Double?
        let smbAllowed: Bool?
        let v5_state: String?
        let v5_budget: Double?
        let v5_actionMult: Double?
        let v5_finalDose: Double?
        let v5_gateReduction: String?
    }

    private func loadByUser() throws -> [(user: String, cycles: [Cycle])] {
        let url = ReplayFixture.v5ShadowURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("""
            V5 shadow fixture not found at \(url.path).
            Generate it with:  python3 BoostPort/sim/fetch_v5shadow.py --days 10
            """)
        }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        var rows: [Cycle] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let c = try? dec.decode(Cycle.self, from: Data(line)) { rows.append(c) }
        }
        guard !rows.isEmpty else { throw XCTSkip("V5 shadow fixture decoded to 0 rows") }
        return Dictionary(grouping: rows, by: { $0.user })
            .map { (user: $0.key, cycles: $0.value.sorted { $0.ts < $1.ts }) }
            .sorted { $0.user < $1.user }
    }

    /// Mirror the device's gate-reduction string from the Swift `GateReductions`.
    private func gateString(_ r: GateReductions) -> String {
        if let h = r.hardGateFired { return "HARD:\(h)" }
        var parts: [String] = []
        if r.iobHeadroomBrake < 1.0 { parts.append(String(format: "iobHeadroom:%.2f", r.iobHeadroomBrake)) }
        if r.decelerationBrake < 1.0 { parts.append(String(format: "decel:%.2f", r.decelerationBrake)) }
        if r.maxIobClampApplied { parts.append("maxIOB") }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    /// Parse the recorded composite gate string into its components.
    private func parseGate(_ s: String) -> (hard: String?, iobHeadroom: Double?, decel: Double?, maxIob: Bool) {
        if s.hasPrefix("HARD:") { return (String(s.dropFirst(5)), nil, nil, false) }
        var ih: Double?, dc: Double?, mx = false
        for part in s.split(separator: ",") {
            if part.hasPrefix("iobHeadroom:") { ih = Double(part.dropFirst(12)) }
            else if part.hasPrefix("decel:") { dc = Double(part.dropFirst(6)) }
            else if part == "maxIOB" { mx = true }
        }
        return (nil, ih, dc, mx)
    }

    /// Whether a cycle carries the signature of an opt-in lever the port has but this replay runs
    /// with off, so the port computes zero where the device dosed. See the call site for the
    /// evidence separating the two shapes.
    private func isOptInLeverCycle(
        state: MealHypothesis, bg: Double?, insulinReq: Double?, dose: Double
    ) -> Bool {
        guard (insulinReq ?? 1) <= 0.01, dose > 0, let bg else { return false }
        // Velocity-budget floor: the budget-near-zero high tail, delivering the tier hold.
        if state == .idle, bg > VelocityBudgetFloor.minBgMgdl, dose <= VelocityBudgetFloor.tierU + 1E-9 {
            return true
        }
        // Primer: once per OBSERVING session, inside its glucose band, at or under its largest cap.
        if state == .observing, bg >= Primer.bgLo, bg <= Primer.bgCeil, dose <= 2.5 { return true }
        return false
    }

    func testV5ShadowDosingReproduced() throws {
        let byUser = try loadByUser()

        // Stages whose inputs ARE logged → reproducible to telemetry precision:
        var actionMult = ReplayReport("actionMultiplier (per state)", tolerance: 1E-6)
        var iobBrake = ReplayReport("iobHeadroom brake", tolerance: 0.005)
        var decelBrake = ReplayReport("deceleration brake", tolerance: 0.02)
        // finalDose (uncapped states): classify how closely the port reproduces the on-device dose.
        var doseExact = 0, doseVelocity = 0, doseMlResidual = 0, doseGenuine = 0
        var doseOptInLever = 0
        var genuine = ReplayReport("finalDose genuine divergence", tolerance: 0.001)
        var hardTotal = 0, cappedSeen = 0

        for (user, cycles) in byUser {
            // The Aggression knob is a per-user setting the shadow telemetry does not carry, and it
            // scales the CONFIRMED multiplier only. Assuming 1.0 measured anyone who has moved the
            // slider as a divergence: a user running 1.3 records 2.34 where the base is 1.8, which
            // is the knob and not a port difference. Fit it per user from the recorded CONFIRMED
            // rows instead, the same way the DynISF replay fits the insulin divisor per profile.
            let confirmedRatios = cycles.compactMap { c -> Double? in
                guard c.v5_state == MealHypothesis.confirmed.rawValue, let m = c.v5_actionMult
                else { return nil }
                let base = MealActionMultiplier.value(for: .confirmed, aggressionUserKnob: 1.0)
                return base > 0 ? m / base : nil
            }.sorted()
            let aggression = confirmedRatios.isEmpty ? 1.0 : confirmedRatios[confirmedRatios.count / 2]
            if abs(aggression - 1.0) > 1E-6 {
                print("   \(user): fitted Aggression knob \(String(format: "%.2f", aggression)) "
                    + "from \(confirmedRatios.count) CONFIRMED rows")
            }

            for c in cycles {
                guard let stateStr = c.v5_state, let state = MealHypothesis(rawValue: stateStr),
                      let budget = c.v5_budget, let recActionMult = c.v5_actionMult
                else { continue }
                let rec = parseGate(c.v5_gateReduction ?? "none")

                // 1) action multiplier — pure function of state and the per-user Aggression knob.
                actionMult.record(
                    expected: recActionMult,
                    got: MealActionMultiplier.value(for: state, aggressionUserKnob: aggression),
                    ctx: "\(stateStr)"
                )

                // 2) iobHeadroom brake — inputs (IOB, maxIOB) are logged.
                if let iob = c.iob, let maxIob = c.maxIob, maxIob > 0 {
                    let got = SafetyGates.iobHeadroomBrake(iob, maxIob)
                    iobBrake.record(
                        expected: rec.iobHeadroom ?? 1.0,
                        got: got,
                        ctx: "iob=\(iob) maxIob=\(maxIob)"
                    )
                }

                // 3) deceleration brake — VALUE depends only on deltaAccl (logged exactly); the
                //    delta>8 disable-gate uses delta, which isn't logged, so validate the formula on
                //    the cycles where the device actually applied the brake (delta<=8 there).
                // Skip deltaAccl==0: that's the guarded sentinel (shortAvg≈0), not the brake's true
                // internal input, so it isn't reconstructable from telemetry.
                if let recDecel = rec.decel, let da = c.deltaAccl, da != 0 {
                    decelBrake.record(
                        expected: recDecel,
                        got: SafetyGates.decelerationBrake(da, 0.0),
                        ctx: "deltaAccl=\(da)"
                    )
                }

                // 4) finalDose — uncapped states only (the device's CONFIRMED/COMMITTED cap config
                //    isn't logged; those are counted separately). Two inputs are unavailable offline:
                //    the velocity factor (the 30-min rise isn't logged) and the post-action ML
                //    hypo-risk brake (needs the on-device model). Classify each cycle by how closely
                //    the port reproduces the recorded dose from budget × actionMult × the logged
                //    brakes:
                //      exact    — reproduced at velocity factor 1.0
                //      velocity — reproduced by SOME velocity factor in [0.40, 1.0] (rise not logged)
                //      ml       — not velocity-reconcilable but mlHypoRisk present (on-device brake)
                //      genuine  — none of the above: a real port-vs-reference difference
                if state == .confirmed || state == .committed {
                    cappedSeen += 1
                } else if let recDose = c.v5_finalDose, rec.hard == nil {
                    let rs = c.roundSmbTo ?? 0.05
                    let base = budget * recActionMult * (rec.iobHeadroom ?? 1.0) * (rec.decel ?? 1.0)
                    if doseMatches(base: base, velocity: 1.0, recDose: recDose, rs: rs) {
                        doseExact += 1
                    } else if velocityReconciles(base: base, recDose: recDose, rs: rs) {
                        doseVelocity += 1
                    } else if c.mlHypoRisk != nil {
                        doseMlResidual += 1
                    } else if isOptInLeverCycle(state: state, bg: c.bg, insulinReq: c.insulinReq, dose: recDose) {
                        // The device is running an opt-in lever this replay leaves off, so the port
                        // computes zero where the device dosed. Both are identifiable by shape.
                        //
                        // The velocity-budget floor delivers min(0.5, committedCap) on the
                        // budget-near-zero high tail: in this fixture all 10 such cycles are IDLE,
                        // every one above 180 mg/dL, every one dosing exactly 0.5 U.
                        //
                        // The primer is a ceiling scaled by rise, glucose room and insulin headroom,
                        // fired once per OBSERVING session: all 35 such cycles are OBSERVING, all
                        // within its 90 to 220 mg/dL band, graduated from 0.05 to 0.45 U.
                        //
                        // Neither is reproducible here, because the per-user cap and ceiling that
                        // size them are not in the telemetry. Counted separately so they are not
                        // read as port-vs-reference differences, which is what they were before the
                        // port gained these levers.
                        doseOptInLever += 1
                    } else {
                        doseGenuine += 1
                        genuine.record(
                            expected: recDose,
                            got: max(0, (base / rs + 1E-9).rounded(.down) * rs),
                            ctx: "\(stateStr) base=\(base)"
                        )
                    }
                }

                // 5) HARD-gate firing — DIAGNOSTIC. The V5 gate's true min-guard input is not the
                //    logged (oref) minGuardBG, so we only tally how often device vs port agree.
                if rec.hard != nil { hardTotal += 1 }
            }
        }

        let doseTot = doseExact + doseVelocity + doseMlResidual + doseGenuine + doseOptInLever
        func pct(_ n: Int) -> Double { doseTot > 0 ? 100.0 * Double(n) / Double(doseTot) : 0 }
        let reproduced = doseExact + doseVelocity // explained by inputs we DO have

        print("── V5 shadow dosing replay ───────────────────────────────")
        actionMult.printSummary()
        iobBrake.printSummary()
        decelBrake.printSummary()
        print("── finalDose (uncapped states) — port vs on-device dose, \(doseTot) cycles ──")
        print(String(format: "   exact (velFactor=1.0)             : %6d (%.1f%%)", doseExact, pct(doseExact)))
        print(String(format: "   velocity-reconciled [rise unlogged]: %6d (%.1f%%)", doseVelocity, pct(doseVelocity)))
        print(String(format: "   opt-in lever [replay runs it off]  : %6d (%.1f%%)", doseOptInLever, pct(doseOptInLever)))
        print(String(
            format: "   ML hypo-risk brake [model offline] : %6d (%.1f%%)  device dosed LESS",
            doseMlResidual,
            pct(doseMlResidual)
        ))
        print(String(format: "   genuine port-vs-reference diff     : %6d (%.2f%%)", doseGenuine, pct(doseGenuine)))
        print(String(format: "   => reproduced within available inputs: %.1f%%", pct(reproduced)))
        if doseGenuine > 0 { genuine.printSummary() }
        print("   DIAGNOSTIC — not golden-mastered (inputs/config absent from telemetry):")
        print("     HARD-gate cycles in data: \(hardTotal) (device min-guard input not logged)")
        print("     CONFIRMED/COMMITTED cycles: \(cappedSeen) (dose-cap config not logged)")

        // Assert on the cleanly-reconstructable stages …
        XCTAssertGreaterThan(actionMult.checked, 10000, "expected a large multi-user V5 sample")
        XCTAssertGreaterThanOrEqual(actionMult.matchFraction, 0.999, "actionMultiplier diverged")
        XCTAssertGreaterThanOrEqual(
            iobBrake.matchFraction,
            0.97,
            "iobHeadroom brake diverged on \(iobBrake.failures)/\(iobBrake.checked)"
        )
        // Residual ~3% is logged-deltaAccl rounding (1-2 dp) shifting the floor/ceiling clamp.
        XCTAssertGreaterThanOrEqual(
            decelBrake.matchFraction,
            0.95,
            "deceleration brake formula diverged on \(decelBrake.failures)/\(decelBrake.checked)"
        )
        // … and on the dose: once the two offline-unavailable inputs (velocity rise + ML risk model)
        // are accounted for the port must reproduce the on-device dose, and GENUINE differences
        // (no velocity/ML explanation) must be negligible.
        XCTAssertGreaterThan(doseTot, 5000, "expected a large uncapped-dose sample")
        XCTAssertGreaterThanOrEqual(
            Double(reproduced) / Double(doseTot),
            0.95,
            "dose reproduced (incl. velocity) below 95%"
        )
        XCTAssertLessThanOrEqual(
            Double(doseGenuine) / Double(doseTot),
            0.01,
            "genuine dose divergence \(doseGenuine)/\(doseTot) exceeds 1%"
        )
    }

    /// floor(base · velocity / rs) · rs == recDose ?
    private func doseMatches(base: Double, velocity: Double, recDose: Double, rs: Double) -> Bool {
        let d = max(0, (base * velocity / rs + 1E-9).rounded(.down) * rs)
        return abs(d - recDose) <= 0.001
    }

    /// Does ANY velocity factor in [0.40, 1.0] reproduce recDose? The 30-min rise that sets that
    /// factor isn't in the telemetry, so an in-band value that reconciles the dose is a missing
    /// input, not a port error. floor(base·v/rs)·rs == recDose  ⇔  base·v ∈ [recDose, recDose+rs).
    private func velocityReconciles(base: Double, recDose: Double, rs: Double) -> Bool {
        if base <= 0 { return recDose == 0 }
        let vLo = recDose / base
        let vHi = (recDose + rs) / base
        return vLo < 1.0 + 1E-9 && vHi > 0.40 - 1E-9
    }
}
