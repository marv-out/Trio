import Foundation
import Testing

@testable import Trio

@Suite("Watch complication transfer policy") struct ComplicationTransferPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: 11, day: 15, hour: hour, minute: minute).date!
    }

    @Test("Spreads the remaining budget over the rest of the day") func intervalSpreadsBudget() {
        // 12 hours and 24 transfers left: one every 30 minutes
        #expect(ComplicationTransferPolicy.interval(now: date(hour: 12), remainingTransfers: 24, calendar: calendar) == 30 * 60)
    }

    @Test("Never pushes more often than every five minutes") func intervalFloor() {
        #expect(
            ComplicationTransferPolicy.interval(now: date(hour: 23, minute: 50), remainingTransfers: 50, calendar: calendar) ==
                5 * 60
        )
    }

    @Test("The first push goes out at once, the next waits for the interval") func shouldTransfer() {
        let now = date(hour: 12)
        #expect(
            ComplicationTransferPolicy
                .shouldTransfer(now: now, lastTransfer: nil, remainingTransfers: 24, calendar: calendar)
        )
        #expect(!ComplicationTransferPolicy.shouldTransfer(
            now: now,
            lastTransfer: now.addingTimeInterval(-20 * 60),
            remainingTransfers: 24,
            calendar: calendar
        ))
        #expect(ComplicationTransferPolicy.shouldTransfer(
            now: now,
            lastTransfer: now.addingTimeInterval(-30 * 60),
            remainingTransfers: 24,
            calendar: calendar
        ))
    }

    @Test("Without budget nothing is pushed") func noBudget() {
        #expect(!ComplicationTransferPolicy.shouldTransfer(
            now: date(hour: 12),
            lastTransfer: nil,
            remainingTransfers: 0,
            calendar: calendar
        ))
    }

    @Test("The payload carries only what the face shows") func payloadContents() {
        var state = WatchState(date: date(hour: 12))
        state.currentGlucose = "112"
        state.currentGlucoseColorString = "#ff0000"
        state.trend = "Flat"
        state.delta = "+1"
        state.iob = "1.25"
        state.cob = "24"
        state.lastLoopTime = "2 min"
        state.glucoseDate = date(hour: 11, minute: 58)
        state.glucoseValues = [WatchGlucoseObject(date: date(hour: 11), glucose: 100, color: "#ffffff")]

        let payload = ComplicationTransferPolicy.payload(for: state)

        #expect(payload[WatchMessageKeys.date] as? TimeInterval == date(hour: 12).timeIntervalSince1970)
        #expect(payload[WatchMessageKeys.currentGlucose] as? String == "112")
        #expect(payload[WatchMessageKeys.currentGlucoseColorString] as? String == "#ff0000")
        #expect(payload[WatchMessageKeys.trend] as? String == "Flat")
        #expect(payload[WatchMessageKeys.delta] as? String == "+1")
        #expect(payload[WatchMessageKeys.iob] as? String == "1.25")
        #expect(payload[WatchMessageKeys.cob] as? String == "24")
        #expect(payload[WatchMessageKeys.glucoseDate] as? TimeInterval == date(hour: 11, minute: 58).timeIntervalSince1970)
        #expect(payload[WatchMessageKeys.glucoseValues] == nil)
        #expect(payload[WatchMessageKeys.forecastData] == nil)
    }

    @Test("A state without a reading still serializes with placeholders") func payloadWithoutReading() {
        let payload = ComplicationTransferPolicy.payload(for: WatchState(date: date(hour: 12)))

        #expect(payload[WatchMessageKeys.currentGlucose] as? String == "--")
        #expect(payload[WatchMessageKeys.glucoseDate] == nil)
    }
}
