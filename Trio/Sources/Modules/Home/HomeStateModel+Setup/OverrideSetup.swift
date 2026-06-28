import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Overrides

    /// Observes active overrides from GRDB and keeps `overrides` current. Replaces the former
    /// Core Data `NSFetchedResultsController`. The "date >= oneDayAgo OR indefinite" rule is
    /// applied here so the tracked region stays deterministic (no `Date()` inside it).
    @MainActor func setupOverrideController() {
        overrideObservationCancellable = OverrideStore.observeActive()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Override observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let cutoff = Date.oneDayAgo
                    overrides = records.filter { ($0.date ?? .distantPast) >= cutoff || $0.indefinite }
                }
            )
    }

    // MARK: - Override Runs

    /// Observes recent override runs from GRDB and keeps `overrideRunStored` current. Replaces the
    /// former Core Data `NSFetchedResultsController`. The "startDate >= oneDayAgo" rule is applied
    /// here so the tracked region stays deterministic.
    @MainActor func setupOverrideRunController() {
        overrideRunObservationCancellable = OverrideRunStore.observeRecent()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Override run observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let cutoff = Date.oneDayAgo
                    overrideRunStored = records.filter { ($0.startDate ?? .distantPast) >= cutoff }
                }
            )
    }

    // MARK: - Override Actions

    /// Cancels the running Override (by GRDB rowid), logs an `OverrideRunStored` entry and posts a
    /// custom notification so the AdjustmentsView updates. The observation keeps `overrides`
    /// current automatically.
    @MainActor func cancelOverride(withPk pk: Int64) async {
        do {
            try await overrideStorage.cancelOverride(pk: pk)
            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to cancel Override with error: \(error)")
        }
    }
}
