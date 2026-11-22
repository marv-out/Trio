@testable import BoostV5Core
import Foundation
import XCTest

/// Parity of Trio's sleep detector with the real AAPS SleepStateDetector at Boost 6.3.3 (ecaad5ec6b)
/// on rebuilt history from the no-HR-feed study (boost-experiments 2026-11-sleep-no-hr-feed).
///
/// tim2000s/trio-boost-v1-parity scripts/sleep_no_hr_dump.py writes one file per user and period: the
/// reconstructed HR samples and cycles, the scenarios (the study's fitted settings and two other night
/// starts), the 24 h feed flag and the Kotlin states. This drives SleepStateDetector.step the way the
/// study's SleepReplay.kt drives the Kotlin, night start through effectiveNightStartMin, and requires
/// the same state on every cycle. Point SLEEP_NOHR_PARITY_DIR at the directory; without it the test
/// skips. The files are patient history and stay outside the repository.
final class SleepNoHrReplayParityTests: XCTestCase {
    func testDetectorMatchesKotlinOnEveryCycle() throws {
        guard let env = ProcessInfo.processInfo.environment["SLEEP_NOHR_PARITY_DIR"] else {
            throw XCTSkip("no sleep no-HR parity fixtures")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: env).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var cyclesCompared = 0
        for name in files {
            let o = try JSONSerialization
                .jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env + "/" + name))) as! [String: Any]
            let hr = (o["hr"] as! [[NSNumber]]).map { a in
                (
                    ts: a[0].int64Value,
                    bpm: a[1].doubleValue,
                    dur: a[2].int64Value,
                    arr: a.count > 3 ? a[3].int64Value : a[0].int64Value
                )
            }
            let cycles = o["cycles"] as! [[String: Any]]
            let now = cycles.map { ($0["nowMs"] as! NSNumber).int64Value }
            let int = { (c: [String: Any], k: String) -> Int? in (c[k] as? NSNumber)?.intValue }

            // The 24 h feed test, as SleepReplay.kt: the newest sample that had arrived by now.
            let byArr = hr.sorted { $0.arr < $1.arr }
            var feed: [Bool] = []
            var k = 0
            var newest = Int64.min
            for t in now {
                while k < byArr.count, byArr[k].arr <= t { newest = max(newest, byArr[k].ts)
                    k += 1 }
                feed.append(newest > t - 24 * 3_600_000)
            }
            XCTAssertEqual(feed.map { $0 ? "1" : "0" }.joined(), o["feed"] as! String, "\(name): feed")

            for (si, p) in (o["scenarios"] as! [[String: Any]]).enumerated() {
                let tzMin = int(p, "tzMin") ?? 0
                let cfgStart = int(p, "cfgStart")!, cfgEnd = int(p, "cfgEnd")!
                let useLearned = (p["useLearned"] as? NSNumber)?.boolValue ?? true
                var state = SleepDetectorState()
                var lo = 0, hi = 0
                var got = ""
                for (i, c) in cycles.enumerated() {
                    let t = now[i]
                    while hi < hr.count, hr[hi].ts <= t { hi += 1 }
                    while lo < hi, hr[lo].ts <= t - 30 * 60000 { lo += 1 }
                    let readings = hr[lo ..< hi].filter { $0.arr <= t }.map {
                        SleepHrReading(
                            timestampMs: Double($0.ts),
                            beatsPerMinute: $0.bpm,
                            durationMs: Double($0.dur),
                            isValid: true
                        )
                    }
                    let localMs = t + Int64(tzMin) * 60000
                    let minOfDay = Int(((localMs / 60000) % 1440 + 1440) % 1440)
                    let ns = SleepHistoryTracker.effectiveNightStartMin(
                        learned: useLearned ? int(c, "lOn") : nil, configured: cfgStart, bandMin: 90, hrFeedPresent: feed[i]
                    )
                    let ne = SleepHistoryTracker.clampToConfiguredBand(
                        learned: useLearned ? int(c, "lWk") : nil,
                        configured: cfgEnd,
                        bandMin: 90,
                        allowEarlier: false
                    )
                    state = SleepStateDetector.step(
                        SleepDetectorInputs(
                            hrReadings: readings, restingHeartRate: Double(int(c, "lRest") ?? int(p, "restFallback") ?? 60),
                            steps15min: int(c, "steps15") ?? 0, nowMinuteOfDay: minOfDay, nightStartMinute: ns,
                            nightEndMinute: ne,
                            preSleepLeadMin: int(p, "lead") ?? 60, sleepHysteresisMin: int(p, "sleepHyst") ?? 10,
                            wakeHrHysteresisMin: int(p, "wakeHyst") ?? 5, mlMealLikely: (c["meal"] as? NSNumber)?.doubleValue,
                            nowMs: Double(t), autoBySleep: true, stepsToday: int(c, "stepsToday") ?? -1,
                            sleepInStepsThreshold: int(p, "sleepInSteps") ?? 250, sleepInWindowMin: int(p, "sleepInMin") ?? 120,
                            hrFeedPresent: feed[i]
                        ),
                        state
                    )
                    got.append(state.state == .awake ? "A" : state.state == .preSleep ? "P" : "S")
                }
                let want = (o["states"] as! [String])[si]
                let diff = zip(got, want).enumerated().filter { $0.element.0 != $0.element.1 }
                XCTAssertEqual(got.count, want.count, "\(name) scenario \(si)")
                XCTAssertTrue(
                    diff.isEmpty,
                    "\(name) scenario \(si): \(diff.count) cycles differ (Trio awake where AAPS sleeps on \(diff.filter { $0.element.0 != "S" && $0.element.1 == "S" }.count), Trio sleeping where AAPS is not on \(diff.filter { $0.element.0 == "S" }.count)), first at \(diff.first?.offset ?? -1)"
                )
                cyclesCompared += got.count
            }
        }
        print("SleepNoHrReplayParity: \(files.count) files, \(cyclesCompared) cycles compared")
    }
}
