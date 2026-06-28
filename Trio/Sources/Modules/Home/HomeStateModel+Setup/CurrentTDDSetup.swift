import Combine
import Foundation

extension Home.StateModel {
    /// Observes the most recent TDD entry from GRDB and publishes it to the header.
    /// Replaces the former Core Data `NSFetchedResultsController`. The "within last 24h"
    /// rule is applied here (the observation itself stays deterministic).
    @MainActor func setupTDDController() {
        tddObservationCancellable = TDDStore.observeMostRecent()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) TDD observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] record in
                    guard let self else { return }
                    if let record, let date = record.date, date >= Date.oneDayAgo {
                        fetchedTDDs = [TDD(totalDailyDose: record.total, timestamp: date)]
                    } else {
                        fetchedTDDs = []
                    }
                }
            )
    }
}
