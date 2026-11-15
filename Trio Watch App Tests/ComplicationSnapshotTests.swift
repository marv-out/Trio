import Foundation
import Testing
@testable import Trio_Watch_App

@Suite("Watch complication snapshot") struct ComplicationSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func payload(glucose: String? = "112", trend: String? = "FortyFiveUp", glucoseDate: Date? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            WatchMessageKeys.date: now.timeIntervalSince1970,
            WatchMessageKeys.delta: "+4",
            WatchMessageKeys.iob: "1.25",
            WatchMessageKeys.cob: "24",
            WatchMessageKeys.currentGlucoseColorString: "#ff0000"
        ]
        if let glucose { payload[WatchMessageKeys.currentGlucose] = glucose }
        if let trend { payload[WatchMessageKeys.trend] = trend }
        if let glucoseDate { payload[WatchMessageKeys.glucoseDate] = glucoseDate.timeIntervalSince1970 }
        return payload
    }

    @Test("Reads every shown value from a phone payload") func parsesPayload() throws {
        let reading = now.addingTimeInterval(-90)
        let snapshot = try #require(ComplicationSnapshot(payload: payload(glucoseDate: reading)))

        #expect(snapshot.date == now)
        #expect(snapshot.glucose == "112")
        #expect(snapshot.trend == "FortyFiveUp")
        #expect(snapshot.trendArrow == "\u{2197}")
        #expect(snapshot.delta == "+4")
        #expect(snapshot.iob == "1.25")
        #expect(snapshot.cob == "24")
        #expect(snapshot.glucoseColorHex == "#ff0000")
        #expect(snapshot.readingDate == reading)
    }

    @Test("A payload without glucose is not a snapshot") func rejectsPayloadWithoutGlucose() {
        #expect(ComplicationSnapshot(payload: payload(glucose: nil)) == nil)
    }

    @Test("Without a reading time the build time stands in") func readingDateFallsBack() throws {
        let snapshot = try #require(ComplicationSnapshot(payload: payload()))
        #expect(snapshot.readingDate == now)
    }

    @Test("Turns stale 15 minutes after the reading") func staleness() throws {
        let snapshot = try #require(ComplicationSnapshot(payload: payload()))
        #expect(!snapshot.isStale(at: now.addingTimeInterval(14 * 60)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(16 * 60)))
    }

    @Test("Maps every direction to an arrow") func arrows() throws {
        let expected: [String: String] = [
            "TripleUp": "\u{2191}\u{2191}",
            "DoubleUp": "\u{2191}\u{2191}",
            "SingleUp": "\u{2191}",
            "FortyFiveUp": "\u{2197}",
            "Flat": "\u{2192}",
            "FortyFiveDown": "\u{2198}",
            "SingleDown": "\u{2193}",
            "DoubleDown": "\u{2193}\u{2193}",
            "TripleDown": "\u{2193}\u{2193}",
            "NONE": "",
            "NOT COMPUTABLE": ""
        ]
        for (direction, arrow) in expected {
            let snapshot = try #require(ComplicationSnapshot(payload: payload(trend: direction)))
            #expect(snapshot.trendArrow == arrow, "\(direction)")
        }
        let withoutTrend = try #require(ComplicationSnapshot(payload: payload(trend: nil)))
        #expect(withoutTrend.trendArrow == "")
    }

    @Test("The store keeps only newer snapshots") func storeKeepsNewest() throws {
        let suite = "ComplicationSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ComplicationStore.load(from: defaults) == nil)

        let first = try #require(ComplicationSnapshot(payload: payload()))
        #expect(ComplicationStore.save(first, to: defaults))
        #expect(ComplicationStore.load(from: defaults) == first)

        var older = first
        older.date = now.addingTimeInterval(-60)
        older.glucose = "99"
        #expect(!ComplicationStore.save(older, to: defaults))
        #expect(ComplicationStore.load(from: defaults) == first)

        // The same values again change nothing, so the face is not redrawn for them
        #expect(!ComplicationStore.save(first, to: defaults))

        var newer = first
        newer.date = now.addingTimeInterval(60)
        newer.glucose = "120"
        #expect(ComplicationStore.save(newer, to: defaults))
        #expect(ComplicationStore.load(from: defaults)?.glucose == "120")
    }

    @Test("Without an app group nothing is stored") func storeWithoutAppGroup() throws {
        let snapshot = try #require(ComplicationSnapshot(payload: payload()))
        #expect(!ComplicationStore.save(snapshot, to: nil))
        #expect(ComplicationStore.load(from: nil) == nil)
    }
}
