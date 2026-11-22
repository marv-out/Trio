@testable import BoostV5Core
import Foundation
import XCTest

/// Parity of BoostV1Engine with the real AAPS DetermineBasalBoost.determine_basal.
///
/// The cases and the Kotlin outputs come from tim2000s/trio-boost-v1-parity: gen_cases.py draws the
/// inputs and run_kotlin.sh runs the AAPS engine over them. Point BOOST_V1_PARITY_DIR at a directory
/// holding cases.jsonl and kotlin_out.jsonl, or place them in Fixtures/v1parity; without them the
/// test skips, as the other replay suites do. Every RT field the engine sets is compared, each
/// number to 1e-9 and each prediction series exactly. Reason strings are not compared.
final class BoostV1ParityTests: XCTestCase {
    private func fixtureDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["BOOST_V1_PARITY_DIR"] {
            return URL(fileURLWithPath: env)
        }
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let dir = here.appendingPathComponent("Fixtures/v1parity")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("cases.jsonl").path) ? dir : nil
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    private func dbl(_ o: [String: Any], _ k: String) -> Double { (o[k] as! NSNumber).doubleValue }
    private func dblN(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
    private func bool(_ o: [String: Any], _ k: String) -> Bool { (o[k] as! NSNumber).boolValue }
    private func int(_ o: [String: Any], _ k: String) -> Int { (o[k] as! NSNumber).intValue }

    /// The stand-in for the ML models, identical to mlStub in BoostV1ParityDump.kt.
    private func models(_ c: [String: Any]) -> V1MlModels {
        let hypoBase = dblN(c, "mlHypoBase")
        let mealBase = dblN(c, "mlMealBase")
        return V1MlModels(
            hypoRisk: hypoBase
                .map { base in { m in Swift.min(1, Swift.max(0, base + 0.05 * m.insulinReq + 0.001 * (m.bg - m.targetBg))) } },
            mealLikely: mealBase.map { base in { m in Swift.min(1, Swift.max(0, base + 0.02 * m.insulinReq)) } }
        )
    }

    private func inputs(_ c: [String: Any], calendar: Calendar) -> V1Inputs {
        let gs = c["glucoseStatus"] as! [String: Any]
        let ct = c["currentTemp"] as! [String: Any]
        let p = c["profile"] as! [String: Any]
        let meal = c["meal"] as! [String: Any]
        let ticks = (c["iobArray"] as! [[String: Any]]).map {
            V1IobTick(
                iob: dbl($0, "iob"), activity: dbl($0, "activity"), basaliob: dbl($0, "basaliob"),
                netbasalinsulin: dbl($0, "netbasalinsulin"), lastBolusTime: dbl($0, "lastBolusTime"),
                zeroTempActivity: dbl($0, "zeroTempActivity")
            )
        }
        let profile = V1Profile(
            maxIob: dbl(p, "maxIob"), maxDailyBasal: dbl(p, "maxDailyBasal"), maxBasal: dbl(p, "maxBasal"),
            minBg: dbl(p, "minBg"), maxBg: dbl(p, "maxBg"), carbRatio: dbl(p, "carbRatio"), sens: dbl(p, "sens"),
            maxDailySafetyMultiplier: dbl(p, "maxDailySafetyMultiplier"),
            currentBasalSafetyMultiplier: dbl(p, "currentBasalSafetyMultiplier"),
            sensitivityRaisesTarget: bool(p, "sensitivityRaisesTarget"),
            resistanceLowersTarget: bool(p, "resistanceLowersTarget"),
            advTargetAdjustments: bool(p, "advTargetAdjustments"), halfBasalExerciseTarget: int(p, "halfBasalExerciseTarget"),
            skipNeutralTemps: bool(p, "skipNeutralTemps"), remainingCarbsCap: int(p, "remainingCarbsCap"),
            enableUAM: bool(p, "enableUAM"), smbInterval: int(p, "smbInterval"), enableSMBWithCOB: bool(p, "enableSMBWithCOB"),
            enableSMBWithTemptarget: bool(p, "enableSMBWithTemptarget"),
            allowSMBWithHighTemptarget: bool(p, "allowSMBWithHighTemptarget"),
            enableSMBAlways: bool(p, "enableSMBAlways"), enableSMBAfterCarbs: bool(p, "enableSMBAfterCarbs"),
            maxSMBBasalMinutes: int(p, "maxSMBBasalMinutes"), maxUAMSMBBasalMinutes: int(p, "maxUAMSMBBasalMinutes"),
            bolusIncrement: dbl(p, "bolusIncrement"), carbsReqThreshold: int(p, "carbsReqThreshold"),
            currentBasal: dbl(p, "currentBasal"), temptargetSet: bool(p, "temptargetSet"), autosensMax: dbl(p, "autosensMax"),
            lgsThreshold: (p["lgsThreshold"] as? NSNumber)?.intValue,
            variableSens: dbl(p, "variableSens"), insulinDivisor: int(p, "insulinDivisor"), tdd: dbl(p, "tdd"),
            dynISFBgCap: dbl(p, "dynISFBgCap"), dynISFBgCapped: dbl(p, "dynISFBgCapped"),
            sensNormalTarget: dbl(p, "sensNormalTarget"),
            normalTarget: dbl(p, "normalTarget"), dynISFvelocity: dbl(p, "dynISFvelocity"), insulinPeak: int(p, "insulinPeak"),
            boostActive: bool(p, "boostActive"), profileSwitch: int(p, "profileSwitch"), boostBolus: dbl(p, "boostBolus"),
            boostMaxIOB: dbl(p, "boostMaxIOB"), boostInsulinReq: dbl(p, "boostInsulinReq"), boostScale: dbl(p, "boostScale"),
            boostPercentScale: dbl(p, "boostPercentScale"), enableBoostPercentScale: bool(p, "enableBoostPercentScale"),
            enableCircadianISF: bool(p, "enableCircadianISF"), recentLowBG: dbl(p, "recentLowBG"),
            dynIsfMode: bool(p, "dynIsfMode")
        )
        return V1Inputs(
            glucoseStatus: V1GlucoseStatus(
                glucose: dbl(gs, "glucose"), noise: dbl(gs, "noise"), delta: dbl(gs, "delta"),
                shortAvgDelta: dbl(gs, "shortAvgDelta"), longAvgDelta: dbl(gs, "longAvgDelta"), date: dbl(gs, "date")
            ),
            currentTemp: V1CurrentTemp(duration: int(ct, "duration"), rate: dbl(ct, "rate")),
            iobArray: ticks,
            profile: profile,
            autosensRatio: dbl(c, "autosensRatio"),
            meal: V1MealData(
                carbs: dbl(meal, "carbs"), mealCOB: dbl(meal, "mealCOB"), lastCarbTime: dbl(meal, "lastCarbTime"),
                slopeFromMaxDeviation: dbl(meal, "slopeFromMaxDeviation"),
                slopeFromMinDeviation: dbl(meal, "slopeFromMinDeviation")
            ),
            microBolusAllowed: bool(c, "microBolusAllowed"),
            currentTime: dbl(c, "currentTime"),
            flatBGsDetected: bool(c, "flatBGsDetected"),
            ml: models(c),
            recentSmbVolume60Min: dbl(c, "recentSmbVolume60Min"),
            cumulativeSmbCap60Min: dbl(c, "cumulativeSmbCap60Min"),
            recentLowBG45Min: dbl(c, "recentLowBG45Min"),
            timeSinceLastSmbMin: dbl(c, "timeSinceLastSmbMin"),
            postRescueTightRampCap: dblN(c, "postRescueTightRampCap"),
            calendar: calendar
        )
    }

    private func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            if x.isNaN, y.isNaN { return true }
            return abs(x - y) <= 1E-9
        default: return false
        }
    }

    func testEngineMatchesKotlinOnEveryCase() throws {
        guard let dir = fixtureDir() else { throw XCTSkip("no V1 parity fixtures") }
        let cases = try lines(dir.appendingPathComponent("cases.jsonl"))
        let kotlin = try lines(dir.appendingPathComponent("kotlin_out.jsonl"))
        XCTAssertEqual(cases.count, kotlin.count)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!

        var mismatches: [String: Int] = [:]
        var examples: [String] = []
        var tiers: [String: Int] = [:]
        var errorsBoth = 0
        for (c, k) in zip(cases, kotlin) {
            let id = int(c, "id")
            XCTAssertEqual(int(k, "id"), id)
            let swift: V1Result
            do {
                swift = try BoostV1Engine.determineBasal(inputs(c, calendar: calendar))
            } catch {
                if k["error"] != nil { errorsBoth += 1 } else {
                    mismatches["error", default: 0] += 1
                    if examples.count < 20 { examples.append("case \(id): Swift threw \(error), Kotlin did not") }
                }
                continue
            }
            if let err = k["error"] {
                mismatches["error", default: 0] += 1
                if examples.count < 20 { examples.append("case \(id): Kotlin threw \(err), Swift did not") }
                continue
            }
            tiers[swift.boostTier, default: 0] += 1
            let numeric: [(String, Double?)] = [
                ("units", swift.units), ("rate", swift.rate), ("duration", swift.duration.map(Double.init)),
                ("insulinReq", swift.insulinReq), ("eventualBG", swift.eventualBG), ("targetBG", swift.targetBG),
                ("sensitivityRatio", swift.sensitivityRatio), ("bg", swift.bg), ("cob", swift.cob), ("iob", swift.iob),
                ("variableSens", swift.variableSens), ("dynamicISF", swift.dynamicISF), ("minGuardBG", swift.minGuardBG),
                ("carbsReq", swift.carbsReq.map(Double.init)), ("carbsReqWithin", swift.carbsReqWithin.map(Double.init)),
                ("insulinReqPctEffective", swift.insulinReqPctEffective), ("mlHypoRisk", swift.mlHypoRisk),
                ("mlMealLikely", swift.mlMealLikely), ("mlRiskScale", swift.mlRiskScale),
                ("deltaAcceleration", swift.deltaAcceleration), ("deliverAt", swift.deliverAt)
            ]
            for (name, value) in numeric where !same(value, dblN(k, name)) {
                mismatches[name, default: 0] += 1
                if examples
                    .count <
                    20
                {
                    examples
                        .append(
                            "case \(id) \(name): swift \(String(describing: value)) kotlin \(String(describing: dblN(k, name)))"
                        )
                }
            }
            let series: [(String, [Int]?)] = [
                ("predIOB", swift.predIOB), ("predZT", swift.predZT), ("predCOB", swift.predCOB), ("predUAM", swift.predUAM)
            ]
            for (name, value) in series {
                let kv = (k[name] as? [NSNumber])?.map(\.intValue)
                if value != kv {
                    mismatches[name, default: 0] += 1
                    if examples
                        .count <
                        20
                    {
                        examples
                            .append("case \(id) \(name): swift \(String(describing: value)) kotlin \(String(describing: kv))") }
                }
            }
            if swift.boostTier != (k["boostTier"] as? String) {
                mismatches["boostTier", default: 0] += 1
                if examples
                    .count <
                    20
                {
                    examples
                        .append("case \(id) boostTier: swift \(swift.boostTier) kotlin \(String(describing: k["boostTier"]))") }
            }
            if swift.fastCarbProtection != bool(k, "fastCarbProtection") { mismatches["fastCarbProtection", default: 0] += 1 }
            if swift.mlG3ReleaseSource != (k["mlG3ReleaseSource"] as? String) { mismatches["mlG3ReleaseSource", default: 0] += 1 }
        }
        print("V1 parity: \(cases.count) cases, both threw on \(errorsBoth), tiers \(tiers.sorted { $0.key < $1.key })")
        print("V1 parity mismatches by field: \(mismatches.sorted { $0.key < $1.key })")
        examples.forEach { print("  " + $0) }
        XCTAssertTrue(mismatches.isEmpty, "V1 parity mismatches: \(mismatches)")
    }
}
