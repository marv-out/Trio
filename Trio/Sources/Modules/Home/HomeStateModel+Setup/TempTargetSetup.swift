import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Temp Targets

    /// Observes temp targets for the main chart from GRDB and keeps `tempTargetStored` current.
    /// Replaces the former Core Data `NSFetchedResultsController`. The "active or future-scheduled"
    /// rule (`tempTargetsForMainChart`) is applied here so the tracked region stays deterministic
    /// (no `Date()` inside it).
    @MainActor func setupTempTargetController() {
        tempTargetObservationCancellable = TempTargetStore.observeForMainChart()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Temp target observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let now = Date()
                    tempTargetStored = records.filter { $0.isOnMainChart(now: now) }
                }
            )
    }

    // MARK: - Temp Target Runs

    /// Observes recent temp target runs from GRDB and keeps `tempTargetRunStored` current. Replaces
    /// the former Core Data `NSFetchedResultsController`. The "startDate >= oneDayAgo" rule is applied
    /// here so the tracked region stays deterministic.
    @MainActor func setupTempTargetRunController() {
        tempTargetRunObservationCancellable = TempTargetRunStore.observeRecent()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Temp target run observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    guard let self else { return }
                    let cutoff = Date.oneDayAgo
                    tempTargetRunStored = records.filter { ($0.startDate ?? .distantPast) >= cutoff }
                }
            )
    }

    // MARK: - Temp Target Actions

    /// Cancels the running Temp Target (by GRDB rowid), logs a `TempTargetRunStored` entry (only for
    /// real targets), mirrors the cancel into the JSON `FileStorage`, and posts a custom notification
    /// so the AdjustmentsView updates. The observation keeps `tempTargetStored` current automatically.
    @MainActor func cancelTempTarget(withPk pk: Int64) async {
        do {
            try await tempTargetStorage.cancelTempTarget(pk: pk)

            // We also need to update the JSON storage for temp targets.
            tempTargetStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date())])

            Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to cancel Temp Target with error: \(error)")
        }
    }
}
