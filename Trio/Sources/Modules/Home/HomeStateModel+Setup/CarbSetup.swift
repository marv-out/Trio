import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Carbs

    /// Observes carb-only chart rows from GRDB and keeps `carbsFromPersistence` current. Replaces the
    /// former Core Data `NSFetchedResultsController`. The store tracks the stable
    /// `isFPU == false AND carbs > 0` region; the `date >= oneDayAgo` rule (from
    /// `NSPredicate.carbsForChart`) is applied here so the tracked region stays deterministic.
    @MainActor func setupCarbsController() {
        carbsObservationCancellable = CarbEntryStore.observeCarbsForChart()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Carbs observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let cutoff = Date.oneDayAgo
                    carbsFromPersistence = records.filter { ($0.date ?? .distantPast) >= cutoff }
                }
            )
    }

    // MARK: - FPUs

    /// Observes FPU carb-equivalent chart rows from GRDB and keeps `fpusFromPersistence` current.
    /// Replaces the former Core Data `NSFetchedResultsController`. The store tracks the stable
    /// `isFPU == true` region; the `date >= oneDayAgo` rule (from `NSPredicate.fpusForChart`) is
    /// applied here so the tracked region stays deterministic.
    @MainActor func setupFPUController() {
        fpusObservationCancellable = CarbEntryStore.observeFPUsForChart()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) FPU observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let cutoff = Date.oneDayAgo
                    fpusFromPersistence = records.filter { ($0.date ?? .distantPast) >= cutoff }
                }
            )
    }
}
