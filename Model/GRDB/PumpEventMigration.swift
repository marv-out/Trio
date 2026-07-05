import CoreData
import Foundation
import GRDB

/// One-time copy of `PumpEventStored` + `BolusStored` + `TempBasalStored` rows from Core Data into GRDB.
///
/// The **dosing path** migration (see `MIGRATION.md`, Step 11). The parent event carries two optional
/// 1:1 children; each is reached through the Core Data `bolus`/`tempBasal` relationship inside the read
/// perform block, so the `pumpEventPk` foreign key is resolved by inserting the parent first and reading
/// back its new `pk` (no separate `NSManagedObjectID` map needed — the relationship gives the child
/// directly). Same contract as the other migrations: once per install, idempotent, Core Data rows left
/// in place as a rollback source.
enum PumpEventMigration {
    private static let didMigrateKey = "grdb.didMigratePumpEvent"

    /// A pump event read out of Core Data with its (optional) child, ready to insert.
    private struct EventRow {
        var event: PumpEventRecord
        let bolus: BolusRecord?
        let tempBasal: TempBasalRecord?
    }

    static func migrateIfNeeded(into stack: GRDBStack) async throws {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let existingCount = try await stack.pool.read { db in
            try PumpEventRecord.fetchCount(db)
        }
        guard existingCount == 0 else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "PumpEventMigration.read"

        let rows = try await context.perform { () -> [EventRow] in
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
            return try context.fetch(request).map(mapEvent)
        }

        guard !rows.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            debug(.coreData, "No legacy PumpEventStored rows to migrate.")
            return
        }

        try await stack.pool.write { db in
            for row in rows {
                var event = row.event
                try event.insert(db)
                if var bolus = row.bolus {
                    bolus.pumpEventPk = event.pk
                    try bolus.insert(db)
                }
                if var tempBasal = row.tempBasal {
                    tempBasal.pumpEventPk = event.pk
                    try tempBasal.insert(db)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        debug(.coreData, "Migrated \(rows.count) PumpEventStored rows (+ children) into GRDB.")
    }

    private static func mapEvent(_ row: PumpEventStored) -> EventRow {
        let event = PumpEventRecord(
            id: row.id,
            timestamp: row.timestamp,
            type: row.type,
            note: row.note,
            isUploadedToNS: row.isUploadedToNS,
            isUploadedToHealth: row.isUploadedToHealth,
            isUploadedToTidepool: row.isUploadedToTidepool
        )
        let bolus = row.bolus.map { bolus in
            BolusRecord(
                amount: bolus.amount?.decimalValue,
                isSMB: bolus.isSMB,
                isExternal: bolus.isExternal
            )
        }
        let tempBasal = row.tempBasal.map { tempBasal in
            TempBasalRecord(
                duration: tempBasal.duration,
                rate: tempBasal.rate?.decimalValue,
                tempType: tempBasal.tempType
            )
        }
        return EventRow(event: event, bolus: bolus, tempBasal: tempBasal)
    }
}
