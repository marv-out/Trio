import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Enacted Determination

    /// Observes the latest enacted determination from GRDB and keeps `determinationsFromPersistence`
    /// current. Replaces the former Core Data `enactedDeterminationController`. The store tracks the
    /// stable `enacted == true` region; the `timestamp >= halfHourAgo` staleness rule (from
    /// `NSPredicate.enactedDetermination`) is applied here so the tracked region stays deterministic.
    @MainActor func setupEnactedDeterminationController() {
        enactedDeterminationObservationCancellable = OrefDeterminationStore.observeEnacted()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Enacted determination observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] record in
                    Task { @MainActor in
                        guard let self else { return }
                        let cutoff = Date.halfHourAgo
                        if let record, (record.timestamp ?? .distantPast) >= cutoff {
                            self.determinationsFromPersistence = [record]
                        } else {
                            self.determinationsFromPersistence = []
                        }
                        await self.updateForecastData()
                    }
                }
            )
    }

    // MARK: - Determinations for COB/IOB Charts

    /// Observes recent determinations from GRDB and keeps `enactedAndNonEnactedDeterminations` current
    /// (COB/IOB charts). Replaces the former Core Data `determinationController`. The store tracks the
    /// newest 500 rows (a bounded, deterministic region); the `deliverAt >= oneDayAgo` rule (from
    /// `NSPredicate.determinationsForCobIobCharts`) is applied here.
    @MainActor func setupDeterminationController() {
        determinationObservationCancellable = OrefDeterminationStore.observeForCobIobCharts()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Determination observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    Task { @MainActor in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        let filtered = records.filter { ($0.deliverAt ?? .distantPast) >= cutoff }
                        self.enactedAndNonEnactedDeterminations = filtered
                        self.yAxisChartDataCobChart(determinations: filtered)
                        self.yAxisChartDataIobChart(determinations: filtered)
                        // The forecast tree is fetched for the newest determination in this list, so
                        // refresh it here too (the source array is set before the fetch runs).
                        await self.updateForecastData()
                    }
                }
            )
    }
}
