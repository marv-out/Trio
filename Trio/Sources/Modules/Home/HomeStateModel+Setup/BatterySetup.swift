import Combine
import Foundation

extension Home.StateModel {
    /// Observes the most recent battery entry from GRDB and publishes it to the pump header.
    /// Replaces the former Core Data `NSFetchedResultsController`. The "within last 30 min"
    /// rule is applied here (the observation itself stays deterministic).
    @MainActor func setupBatteryController() {
        batteryObservationCancellable = BatteryStore.observeMostRecent()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Battery observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] record in
                    guard let self else { return }
                    if let record, let date = record.date, date >= Date.halfHourAgo {
                        batteryFromPersistence = [record]
                    } else {
                        batteryFromPersistence = []
                    }
                }
            )
    }

    /// Previously re-ran the fetch from the `pumpDisplayState` sink / settings changes.
    /// The ValueObservation now keeps `batteryFromPersistence` current automatically, so this
    /// is a no-op kept for call-site compatibility.
    func setupBatteryArray() {}
}
