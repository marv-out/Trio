import CoreData
import Foundation

// Fetch Data for Glucose and Determination from Core Data and map them to the Structs in order to pass them thread safe to the glucoseDidUpdate/ pushUpdate function

@available(iOS 16.2, *)
extension LiveActivityManager {
    func fetchAndMapGlucose() async throws -> [GlucoseData] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapGlucose"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForSixHoursAgo,
            key: "date",
            ascending: false,
            fetchLimit: 72
        )

        return try await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return glucoseResults.map {
                GlucoseData(glucose: Int($0.glucose), date: $0.date ?? Date(), direction: $0.directionEnum)
            }
        }
    }

    // TODO: extract logic or at least rename function appropiately
    func fetchAndMapDetermination() async throws -> DeterminationData? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapDetermination"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["cob", "currentTarget", "deliverAt"]
        )

        // TDD now lives in GRDB — fetch before the Core Data perform block.
        let latestTDD = try await TDDStore.mostRecent(since: Date.halfHourAgo)
        let tddValue = latestTDD?.total ?? 0

        return try await context.perform {
            guard let determinationResults = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            guard let determination = determinationResults.first else {
                return nil
            }

            return DeterminationData(
                cob: (determination["cob"] as? Int) ?? 0,
                tdd: tddValue,
                target: (determination["currentTarget"] as? NSDecimalNumber)?.decimalValue ?? 0,
                date: determination["deliverAt"] as? Date ?? nil
            )
        }
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
