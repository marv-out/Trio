import Foundation

/// Paces the budgeted complication pushes. watchOS allows about 50 `transferCurrentComplicationUserInfo`
/// calls a day; spending one on every reading would use them up by mid-morning, so each push waits
/// long enough for the rest to last until the budget resets at midnight.
enum ComplicationTransferPolicy {
    /// Never push more often than the CGM delivers
    static let minimumInterval: TimeInterval = 5 * 60

    /// True when a budgeted push should go out now
    static func shouldTransfer(
        now: Date,
        lastTransfer: Date?,
        remainingTransfers: Int,
        calendar: Calendar = .current
    ) -> Bool {
        guard remainingTransfers > 0 else { return false }
        guard let lastTransfer else { return true }
        return now
            .timeIntervalSince(lastTransfer) >= interval(now: now, remainingTransfers: remainingTransfers, calendar: calendar)
    }

    /// The wait between pushes that spreads what is left of the budget over what is left of the day
    static func interval(now: Date, remainingTransfers: Int, calendar: Calendar = .current) -> TimeInterval {
        let midnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        return max(minimumInterval, midnight.timeIntervalSince(now) / Double(max(remainingTransfers, 1)))
    }

    /// The part of a watch state the complication shows. Kept small because copies wait in the transfer queue.
    static func payload(for state: WatchState) -> [String: Any] {
        var payload: [String: Any] = [
            WatchMessageKeys.date: state.date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? ""
        ]
        if let glucoseDate = state.glucoseDate {
            payload[WatchMessageKeys.glucoseDate] = glucoseDate.timeIntervalSince1970
        }
        return payload
    }
}
