import CoreData
import Foundation
import GRDB

/// One-time copy of `OrefDetermination` + `Forecast` + `ForecastValue` rows from Core Data into GRDB.
///
/// The deepest migration so far: a two-level relationship tree. Each `Forecast.orefDetermination`
/// to-one link is resolved to the new GRDB `orefDeterminationPk`, and each `ForecastValue.forecast`
/// link to the new `forecastPk`. Both are keyed by the legacy `NSManagedObjectID` → new `pk` map
/// (the business `id`s are not guaranteed unique). Orphan forecasts (no `orefDetermination` — the
/// bolus-preview path) copy with `orefDeterminationPk = nil`. Same contract as the other migrations:
/// once per install, idempotent, Core Data rows left in place as a rollback source.
enum OrefDeterminationMigration {
    private static let didMigrateKey = "grdb.didMigrateOrefDetermination"

    /// A forecast read out of Core Data, with the objectIDs needed to rebuild its links.
    private struct ForecastRow {
        let objectID: NSManagedObjectID
        let determinationObjectID: NSManagedObjectID?
        var record: ForecastRecord
        let values: [ForecastValueRecord]
    }

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try OrefDeterminationRecord.fetchCount(db) + ForecastRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "OrefDeterminationMigration.read"

        // Read determinations (with their objectID) and forecasts (with their parent's objectID and
        // their values). Everything is mapped inside the perform block to stay context-confined.
        let (determinations, forecasts) = try await context
            .perform { () -> ([(NSManagedObjectID, OrefDeterminationRecord)], [ForecastRow]) in
                let determinationRequest = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
                determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
                let determinationRows = try context.fetch(determinationRequest)
                let determinations = determinationRows.map { ($0.objectID, mapDetermination($0)) }

                let forecastRequest = Forecast.fetchRequest() as NSFetchRequest<Forecast>
                forecastRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                forecastRequest.relationshipKeyPathsForPrefetching = ["forecastValues"]
                let forecastRows = try context.fetch(forecastRequest).map { forecast in
                    ForecastRow(
                        objectID: forecast.objectID,
                        determinationObjectID: forecast.orefDetermination?.objectID,
                        record: mapForecast(forecast),
                        values: forecast.forecastValuesArray.map(mapForecastValue)
                    )
                }

                return (determinations, forecastRows)
            }

        guard !determinations.isEmpty || !forecasts.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy OrefDetermination/Forecast rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            // 1) Insert determinations, mapping legacy objectID -> new pk.
            var determinationPkByObjectID: [NSManagedObjectID: Int64] = [:]
            for (objectID, var record) in determinations {
                try record.insert(db)
                if let pk = record.pk { determinationPkByObjectID[objectID] = pk }
            }
            // 2) Insert forecasts (resolving the determination FK), then their values (linked to the
            //    freshly-assigned forecast pk).
            for forecast in forecasts {
                var record = forecast.record
                if let determinationObjectID = forecast.determinationObjectID {
                    record.orefDeterminationPk = determinationPkByObjectID[determinationObjectID]
                }
                try record.insert(db)
                for var value in forecast.values {
                    value.forecastPk = record.pk
                    try value.insert(db)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(
            .coreData,
            "Migrated \(determinations.count) OrefDetermination + \(forecasts.count) Forecast rows into GRDB."
        )
    }

    private static func mapDetermination(_ row: OrefDetermination) -> OrefDeterminationRecord {
        OrefDeterminationRecord(
            id: row.id,
            deliverAt: row.deliverAt,
            timestamp: row.timestamp,
            timestampEnacted: row.timestampEnacted,
            enacted: row.enacted,
            received: row.received,
            isUploadedToNS: row.isUploadedToNS,
            cob: row.cob,
            carbsRequired: row.carbsRequired,
            reason: row.reason,
            temp: row.temp,
            bolus: row.bolus?.decimalValue,
            carbRatio: row.carbRatio?.decimalValue,
            currentTarget: row.currentTarget?.decimalValue,
            duration: row.duration?.decimalValue,
            eventualBG: row.eventualBG?.decimalValue,
            expectedDelta: row.expectedDelta?.decimalValue,
            glucose: row.glucose?.decimalValue,
            insulinForManualBolus: row.insulinForManualBolus?.decimalValue,
            insulinReq: row.insulinReq?.decimalValue,
            insulinSensitivity: row.insulinSensitivity?.decimalValue,
            iob: row.iob?.decimalValue,
            manualBolusErrorString: row.manualBolusErrorString?.decimalValue,
            minDelta: row.minDelta?.decimalValue,
            rate: row.rate?.decimalValue,
            reservoir: row.reservoir?.decimalValue,
            scheduledBasal: row.scheduledBasal?.decimalValue,
            sensitivityRatio: row.sensitivityRatio?.decimalValue,
            smbToDeliver: row.smbToDeliver?.decimalValue,
            tempBasal: row.tempBasal?.decimalValue,
            threshold: row.threshold?.decimalValue
        )
    }

    private static func mapForecast(_ row: Forecast) -> ForecastRecord {
        ForecastRecord(
            id: row.id,
            type: row.type,
            date: row.date,
            orefDeterminationPk: nil
        )
    }

    private static func mapForecastValue(_ row: ForecastValue) -> ForecastValueRecord {
        ForecastValueRecord(
            index: row.index,
            value: row.value,
            forecastPk: nil
        )
    }
}
