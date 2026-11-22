import Foundation
import Testing

@testable import Trio

@Suite("Watch activity payload") struct WatchActivityPayloadTests {
    @Test("Valid heart rate and step samples are parsed") func parsesValidSamples() {
        let now = Date().timeIntervalSince1970.rounded()
        let payload: [String: Any] = [
            WatchMessageKeys.heartRateSamples: [
                [WatchMessageKeys.date: now - 60, WatchMessageKeys.value: 72.0]
            ],
            WatchMessageKeys.stepSamples: [
                [WatchMessageKeys.start: now - 600, WatchMessageKeys.end: now - 300, WatchMessageKeys.value: 420]
            ]
        ]

        let parsed = WatchActivityPayload.parse(payload: payload)

        #expect(parsed.heartRates == [WatchHeartRateSample(date: Date(timeIntervalSince1970: now - 60), bpm: 72)])
        #expect(parsed.steps == [
            WatchStepSample(
                start: Date(timeIntervalSince1970: now - 600),
                end: Date(timeIntervalSince1970: now - 300),
                steps: 420
            )
        ])
    }

    @Test("Implausible, future and malformed samples are dropped") func dropsInvalidSamples() {
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            WatchMessageKeys.heartRateSamples: [
                [WatchMessageKeys.date: now - 60, WatchMessageKeys.value: 5.0], // too low
                [WatchMessageKeys.date: now - 60, WatchMessageKeys.value: 300.0], // too high
                [WatchMessageKeys.date: now + 3600, WatchMessageKeys.value: 80.0], // future
                [WatchMessageKeys.value: 80.0] // no date
            ],
            WatchMessageKeys.stepSamples: [
                [WatchMessageKeys.start: now - 300, WatchMessageKeys.end: now - 600, WatchMessageKeys.value: 10], // end before start
                [WatchMessageKeys.start: now - 600, WatchMessageKeys.end: now - 300, WatchMessageKeys.value: -1], // negative
                [WatchMessageKeys.start: now + 3600, WatchMessageKeys.end: now + 3900, WatchMessageKeys.value: 10] // future
            ]
        ]

        let parsed = WatchActivityPayload.parse(payload: payload)

        #expect(parsed.heartRates.isEmpty)
        #expect(parsed.steps.isEmpty)
    }

    // MARK: - Step windows

    /// 1 min buckets ending at `end`, `count` of them, `steps` each
    private func buckets(endingAt end: TimeInterval, count: Int, steps: Int = 10) -> [WatchStepSample] {
        (0 ..< count).reversed().map { index in
            let start = end - Double(index + 1) * 60
            return WatchStepSample(
                start: Date(timeIntervalSince1970: start),
                end: Date(timeIntervalSince1970: start + 60),
                steps: steps
            )
        }
    }

    @Test("Window counts the complete minutes inside it") func countsWindow() {
        let newestEnd: TimeInterval = 1_800_000_000 // aligned to the minute
        let now = Date(timeIntervalSince1970: newestEnd + 30)
        let data = buckets(endingAt: newestEnd, count: 90)

        // Window starts 30 s into a minute: that minute is left out, 14 full minutes remain
        #expect(BaseWatchActivityStorage.stepCount(in: data, lastMinutes: 15, now: now, maxAge: 300) == 140)
        #expect(BaseWatchActivityStorage.stepCount(in: data, lastMinutes: 60, now: now, maxAge: 300) == 590)
    }

    @Test("Outdated data gives nil, not 0") func outdatedIsNil() {
        let newestEnd: TimeInterval = 1_800_000_000
        let now = Date(timeIntervalSince1970: newestEnd + 301)
        let data = buckets(endingAt: newestEnd, count: 60)

        #expect(BaseWatchActivityStorage.stepCount(in: data, lastMinutes: 15, now: now, maxAge: 300) == nil)
    }

    @Test("A missing minute gives nil") func gapIsNil() {
        let newestEnd: TimeInterval = 1_800_000_000
        let now = Date(timeIntervalSince1970: newestEnd + 30)
        var data = buckets(endingAt: newestEnd, count: 60)
        data.remove(at: 50) // a minute inside the last 15

        #expect(BaseWatchActivityStorage.stepCount(in: data, lastMinutes: 15, now: now, maxAge: 300) == nil)
        // A gap outside the window does not matter
        var older = buckets(endingAt: newestEnd, count: 60)
        older.remove(at: 5)
        #expect(BaseWatchActivityStorage.stepCount(in: older, lastMinutes: 15, now: now, maxAge: 300) == 140)
    }

    @Test("No data gives nil") func emptyIsNil() {
        #expect(BaseWatchActivityStorage.stepCount(in: [], lastMinutes: 15, now: Date(), maxAge: 300) == nil)
    }

    @Test("Watch status is parsed") func parsesStatus() {
        let payload: [String: Any] = [
            WatchMessageKeys.watchStatus: [
                WatchMessageKeys.liveSession: true,
                WatchMessageKeys.motionAuthorization: "denied",
                WatchMessageKeys.stepError: "CMErrorDomain 105: not authorized"
            ]
        ]
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(WatchActivityPayload.status(from: payload, receivedAt: date) == WatchActivityStatus(
            receivedAt: date,
            liveSessionRunning: true,
            motionAuthorization: "denied",
            stepError: "CMErrorDomain 105: not authorized"
        ))
        #expect(WatchActivityPayload.status(from: [:]) == nil)
    }

    @Test("Resting heart rate is parsed within plausible limits") func parsesRestingHeartRate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func payload(_ bpm: Double, _ offset: TimeInterval = -3600) -> [String: Any] {
            [WatchMessageKeys.restingHeartRate: [
                WatchMessageKeys.date: now.timeIntervalSince1970 + offset,
                WatchMessageKeys.value: bpm
            ]]
        }

        #expect(WatchActivityPayload.restingHeartRate(from: payload(58), now: now)
            == WatchHeartRateSample(date: now.addingTimeInterval(-3600), bpm: 58))
        #expect(WatchActivityPayload.restingHeartRate(from: payload(20), now: now) == nil) // too low
        #expect(WatchActivityPayload.restingHeartRate(from: payload(180), now: now) == nil) // too high
        #expect(WatchActivityPayload.restingHeartRate(from: payload(58, 3600), now: now) == nil) // future
        #expect(WatchActivityPayload.restingHeartRate(from: [:], now: now) == nil)
    }

    @Test("A window ending at the newest minute counts the minutes before it") func windowEndingAtNewest() {
        // As BaseWatchActivityStorage.stepCount(minutesEndingAtNewest:) calls it: now = newest bucket end
        let newestEnd: TimeInterval = 1_800_000_000
        let data = buckets(endingAt: newestEnd, count: 60)
        let atNewest = Date(timeIntervalSince1970: newestEnd)

        #expect(BaseWatchActivityStorage.stepCount(
            in: data, lastMinutes: 5, now: atNewest, maxAge: .greatestFiniteMagnitude
        ) == 50)
        #expect(BaseWatchActivityStorage.stepCount(
            in: data, lastMinutes: 60, now: atNewest, maxAge: .greatestFiniteMagnitude
        ) == 600)
    }
}
