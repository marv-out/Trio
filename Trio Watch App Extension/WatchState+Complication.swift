import Foundation
import WatchConnectivity
import WidgetKit

extension ComplicationSnapshot {
    /// The keys a watch state or complication payload from the phone carries; nil without a date or glucose
    init?(payload: [String: Any]) {
        guard let timestamp = payload[WatchMessageKeys.date] as? TimeInterval,
              let glucose = payload[WatchMessageKeys.currentGlucose] as? String
        else { return nil }
        self.init(
            date: Date(timeIntervalSince1970: timestamp),
            glucose: glucose,
            trend: payload[WatchMessageKeys.trend] as? String,
            delta: payload[WatchMessageKeys.delta] as? String,
            iob: payload[WatchMessageKeys.iob] as? String,
            cob: payload[WatchMessageKeys.cob] as? String,
            glucoseColorHex: payload[WatchMessageKeys.currentGlucoseColorString] as? String,
            glucoseDate: (payload[WatchMessageKeys.glucoseDate] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        )
    }
}

// MARK: - Complication

extension WatchState {
    /// Stores what the complication shows and redraws it when the values are newer than the stored ones
    func updateComplication(from payload: [String: Any]) {
        guard let snapshot = ComplicationSnapshot(payload: payload), ComplicationStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: ComplicationStore.widgetKind)
        WatchLogger.shared.debug(.data, "Complication updated with glucose \(snapshot.glucose) from \(snapshot.readingDate)")
    }

    /// Asks the phone for the complication values. Runs inside a background refresh, so it gives up
    /// after `timeout`; with the phone out of reach the request is queued for later instead.
    func requestComplicationUpdate(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
        guard let session else {
            completion(false)
            return
        }
        // A background launch creates the session right before this call
        waitForActivation(of: session, until: Date().addingTimeInterval(3)) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.sendComplicationRequest(on: session, timeout: timeout, completion: completion)
        }
    }

    private func waitForActivation(of session: WCSession, until deadline: Date, then body: @escaping () -> Void) {
        guard session.activationState != .activated, Date() < deadline else {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForActivation(of: session, until: deadline, then: body)
        }
    }

    private func sendComplicationRequest(on session: WCSession, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let request: [String: Any] = [WatchMessageKeys.requestComplicationUpdate: true]

        guard session.activationState == .activated else {
            WatchLogger.shared.debug(.connectivity, "Session not activated, complication request dropped")
            completion(false)
            return
        }

        guard session.isReachable else {
            WatchLogger.shared.debug(.connectivity, "Phone unreachable, complication request queued")
            session.transferUserInfo(request)
            completion(false)
            return
        }

        WatchLogger.shared.debug(.connectivity, "Requesting complication values from the phone")

        var finished = false
        let timeoutWorkItem = DispatchWorkItem {
            WatchLogger.shared.warning(.connectivity, "No complication values from the phone within \(Int(timeout)) s")
        }
        func finish(_ success: Bool) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                timeoutWorkItem.cancel()
                completion(success)
            }
        }

        session.sendMessage(request, replyHandler: { [weak self] reply in
            self?.handleIncomingWatchStatePayload(reply)
            finish(true)
        }, errorHandler: { error in
            WatchLogger.shared.warning(.connectivity, "Complication request failed", error: error)
            finish(false)
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !finished else { return }
            timeoutWorkItem.perform()
            finish(false)
        }
    }
}
