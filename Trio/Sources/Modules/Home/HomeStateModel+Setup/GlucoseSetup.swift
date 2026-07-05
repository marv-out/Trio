import Combine
import Foundation

extension Home.StateModel {
    /// Observes the glucose chart feed from GRDB and keeps `glucoseFromPersistence` (+ the derived
    /// `latestTwoGlucoseValues` and the Y-axis) current. Replaces the former Core Data `glucoseController`.
    /// The store tracks the newest 1000 rows (a bounded, deterministic region); the `date >= oneDayAgo`
    /// rule (from `NSPredicate.glucose`) is applied here.
    ///
    /// ⚠️ Sort **ascending** to match the former `glucoseController` FRC (ascending: true): the chart's
    /// binary search (`MainChartHelper.timeToNearestGlucose`), `latestTwoGlucoseValues = suffix(2)`, and
    /// the delta / "minutes ago" logic all assume chronological order — a descending list corrupts them.
    @MainActor func setupGlucoseController() {
        glucoseObservationCancellable = GlucoseStore.observeForChart()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Glucose observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    Task { @MainActor in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        let filtered = records
                            .filter { ($0.date ?? .distantPast) >= cutoff }
                            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                        self.updateGlucoseFromController(filtered)
                    }
                }
            )
    }

    @MainActor func updateGlucoseFromController(_ objects: [GlucoseRecord]) {
        glucoseFromPersistence = objects
        latestTwoGlucoseValues = Array(objects.suffix(2))
        updateGlucoseChartYAxis(glucoseValues: objects)
    }

    /// Called from `MainChartView` on `.onChange(of: units)` to recompute the glucose-derived chart state.
    func setupGlucoseArray() {
        Task { @MainActor in
            updateGlucoseChartYAxis(glucoseValues: glucoseFromPersistence)
        }
    }
}
