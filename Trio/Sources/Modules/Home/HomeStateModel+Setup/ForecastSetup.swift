import Foundation

extension Home.StateModel {
    /// Fetches the whole forecast tree (each forecast + its values, capped at 36) for the newest
    /// determination in `enactedAndNonEnactedDeterminations`. Replaces the former
    /// `fetchForecastHierarchy` → `fetchForecastObjects` → `existingObject` objectID dance and the
    /// `SELF IN %@` prefetch N+1 workaround with a single two-level `pk` join.
    @MainActor func preprocessForecastData() async -> [(forecast: ForecastRecord, values: [ForecastValueRecord])] {
        guard let determinationPk = enactedAndNonEnactedDeterminations.first?.pk else {
            debug(.default, "No determination found for forecast preprocessing")
            return []
        }

        do {
            return try await determinationStorage.fetchForecastHierarchy(for: determinationPk)
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to preprocess forecast data: \(error)"
            )
            return []
        }
    }

    // Update forecast data and UI on the main thread
    @MainActor func updateForecastData() async {
        let hierarchy = await preprocessForecastData()

        var allForecastValues = [[Int]]()
        var preprocessedData = [(id: UUID, forecast: ForecastRecord, forecastValue: ForecastValueRecord)]()

        for entry in hierarchy {
            // One grouping id per forecast (all its values share it) — used by `ForecastView`'s ForEach.
            let groupID = entry.forecast.id ?? UUID()

            // Extract values for graph
            let forecastValueInts = entry.values.map { Int($0.value) }
            allForecastValues.append(forecastValueInts)

            // Add data for further processing
            preprocessedData.append(contentsOf: entry.values.map {
                (id: groupID, forecast: entry.forecast, forecastValue: $0)
            })
        }

        // Update UI-relevant data
        self.preprocessedData = preprocessedData

        guard !allForecastValues.isEmpty else {
            minForecast = []
            maxForecast = []
            return
        }

        minCount = max(12, allForecastValues.map(\.count).min() ?? 0)
        let localMinCount = minCount

        guard localMinCount > 0 else { return }

        // Calculate min/max values for graph
        let (minResult, maxResult) = await Task.detached {
            let minForecast = (0 ..< localMinCount).map { index in
                allForecastValues.compactMap { $0.indices.contains(index) ? $0[index] : nil }
                    .min() ?? 0
            }

            let maxForecast = (0 ..< localMinCount).map { index in
                allForecastValues.compactMap { $0.indices.contains(index) ? $0[index] : nil }
                    .max() ?? 0
            }

            return (minForecast, maxForecast)
        }.value

        minForecast = minResult
        maxForecast = maxResult
    }
}
