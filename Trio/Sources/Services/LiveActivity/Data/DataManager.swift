import CoreData
import Foundation

// Fetch Data for Glucose and Determination from Core Data and map them to the Structs in order to pass them thread safe to the glucoseDidUpdate/ pushUpdate function

@available(iOS 16.2, *)
extension LiveActivityManager {
    func fetchAndMapGlucose() async throws -> [GlucoseData] {
        // Glucose moved to GRDB: the readings within the last 6 hours, newest first. (`dev` dropped the
        // former `fetchLimit: 72` here; the 6-hour window already bounds the result.)
        let records = try await GlucoseStore.fetch(from: Date.sixHoursAgo, ascending: false)
        return records.map {
            GlucoseData(glucose: Int($0.glucose), date: $0.date ?? Date(), direction: $0.directionEnum)
        }
    }

    // TODO: extract logic or at least rename function appropiately
    func fetchAndMapDetermination() async throws -> DeterminationData? {
        // Determination now lives in GRDB (value type — no Core Data perform block).
        guard let determination = try await OrefDeterminationStore.fetchLast(within: 30, enactedOnly: false) else {
            return nil
        }

        let latestTDD = try await TDDStore.mostRecent(since: Date.halfHourAgo)
        let tddValue = latestTDD?.total ?? 0

        // Compute cone bounds and per-type lines from the forecast tree (cap at 24 values = 2h)
        var allForecastValues = [[Int]]()
        var forecastLines = [(type: String, values: [Int])]()

        if let pk = determination.pk {
            // Hierarchy is ordered by type; values by index (capped at 36 by the store).
            let hierarchy = try await ForecastStore.fetchHierarchy(for: pk)
            let hasCarbs = hierarchy.contains {
                ($0.forecast.type == "cob" || $0.forecast.type == "uam") && !$0.values.isEmpty
            }
            for entry in hierarchy {
                let values = entry.values.prefix(24).map { Int($0.value) }
                guard !values.isEmpty else { continue }
                // iob is hidden when cob or uam are active (matches phone app behavior)
                if entry.forecast.type == "iob", hasCarbs { continue }
                allForecastValues.append(Array(values))
                if let type = entry.forecast.type {
                    forecastLines.append((type: type, values: Array(values)))
                }
            }
        }

        let minCount = allForecastValues.map(\.count).min() ?? 0
        var minForecast = [Int]()
        var maxForecast = [Int]()

        for index in 0 ..< minCount {
            let col = allForecastValues.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            minForecast.append(col.min() ?? 0)
            maxForecast.append(col.max() ?? 0)
        }

        return DeterminationData(
            cob: Int(determination.cob),
            tdd: tddValue,
            target: determination.currentTarget ?? 0,
            date: determination.deliverAt,
            minForecast: minForecast,
            maxForecast: maxForecast,
            forecastLines: forecastLines
        )
    }

    func fetchAndMapTempTarget() async throws -> TempTargetData? {
        // Temp targets now live in GRDB; read the latest within the last day directly.
        guard let record = try await TempTargetStore.fetchLastCreated() else { return nil }
        return TempTargetData(
            isActive: record.enabled,
            tempTargetName: record.name ?? "Temp Target",
            date: record.date ?? Date(),
            duration: record.duration ?? 0,
            target: record.target ?? 0
        )
    }

    func fetchAndMapOverride() async throws -> OverrideData? {
        // Overrides now live in GRDB; read the latest within the last day directly.
        guard let record = try await OverrideStore.fetchLastCreated() else { return nil }
        return OverrideData(
            isActive: record.enabled,
            overrideName: record.name ?? "Override",
            date: record.date ?? Date(),
            duration: record.duration ?? 0,
            target: record.target ?? 0
        )
    }

    private func fetchAndMapLatest<Entity: NSManagedObject, Output>(
        ofType type: Entity.Type,
        predicate: NSPredicate,
        key: String,
        propertiesToFetch: [String],
        map: @escaping ([String: Any]) -> Output
    ) async throws -> Output? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapLatest"

        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: type,
            onContext: context,
            predicate: predicate,
            key: key,
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: propertiesToFetch
        )

        return try await context.perform {
            guard let rows = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return rows.first.map(map)
        }
    }
}
