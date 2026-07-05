import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Insulin / Pump History

    /// Observes the pump-history chart feed from GRDB and keeps `insulinFromPersistence` (+ the derived
    /// `tempBasals` / `suspendAndResumeEvents`) current. Replaces the former Core Data `insulinController`.
    /// The store tracks the newest 1000 rows (a bounded, deterministic region); the `timestamp >=
    /// oneDayAgo` rule (from `NSPredicate.pumpHistoryLast24h`) is applied here.
    @MainActor func setupInsulinController() {
        insulinObservationCancellable = PumpEventStore.observeForChart()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Insulin observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] details in
                    Task { @MainActor in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        self.updateInsulinFromDetails(details.filter { ($0.timestamp ?? .distantPast) >= cutoff })
                        self.displayPumpStatusHighlightMessage()
                        self.displayPumpStatusBadge()
                    }
                }
            )
    }

    @MainActor private func updateInsulinFromDetails(_ details: [PumpEventDetails]) {
        insulinFromPersistence = details

        manualTempBasal = apsManager.isManualTempBasal
        tempBasals = details.filter { $0.tempBasal != nil }
        suspendAndResumeEvents = details.filter {
            $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue
        }
    }

    // MARK: - Last Bolus

    //
    // Drives the bolus progress bar. External boluses are filtered out (by the store) so the progress
    // bar does not display the amount of an external bolus added after a pump bolus.

    /// Observes the latest non-external bolus from GRDB and keeps `lastPumpBolus` current. Replaces the
    /// former Core Data `lastBolusController`. The store scans the newest 100 events (a deterministic
    /// bound covering the 20-minute window); the `timestamp >= 20min` rule (from
    /// `NSPredicate.lastPumpBolus`) is applied here.
    @MainActor func setupLastBolusController() {
        lastBolusObservationCancellable = PumpEventStore.observeLastBolus()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Last bolus observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] details in
                    Task { @MainActor in
                        guard let self else { return }
                        let cutoff = Date.twentyMinutesAgo
                        if let details, (details.timestamp ?? .distantPast) >= cutoff {
                            self.lastPumpBolus = details
                        } else {
                            self.lastPumpBolus = nil
                        }
                    }
                }
            )
    }
}
