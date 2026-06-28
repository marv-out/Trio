import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `OpenAPS_Battery` entity (pump battery status).
///
/// `voltage` was a Core Data Decimal but is always written as `nil` in practice and only
/// read by the Nightscout upload; stored here as `Double?` so the record stays a plain
/// `Codable` (the Nightscout read converts to `Decimal`).
struct BatteryRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "openAPSBattery"

    var pk: Int64?
    var id: UUID?
    var date: Date?
    var percent: Double?
    var voltage: Double?
    var status: String?
    var display: Bool?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let date = Column("date")
    }
}

// MARK: - Store

/// Typed data-access API for pump battery status. Replaces the Core Data fetch/save/delete
/// in `APSManager`, `DeviceDataManager`, `NightscoutManager`, and the Home `batteryController`.
enum BatteryStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    static func insert(_ record: BatteryRecord) async throws {
        var record = record
        try await pool.write { db in try record.insert(db) }
    }

    static func update(_ record: BatteryRecord) async throws {
        try await pool.write { db in try record.update(db) }
    }

    /// Most recent entry no older than `date` (e.g. last 30 min). Used by the upsert logic
    /// and the Nightscout read.
    static func mostRecent(since date: Date) async throws -> BatteryRecord? {
        try await pool.read { db in
            try BatteryRecord
                .filter(BatteryRecord.Columns.date >= date)
                .order(BatteryRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Deletes every battery row (pump disconnected).
    static func deleteAll() async throws {
        _ = try await pool.write { db in
            try BatteryRecord.deleteAll(db)
        }
    }

    /// Deletes rows older than `days` (periodic cleanup).
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try BatteryRecord
                .filter(BatteryRecord.Columns.date < cutoff)
                .deleteAll(db)
        }
    }

    /// Reactive feed of the most recent battery entry — replaces the Home
    /// `NSFetchedResultsController`. The "within last 30 min" rule is applied by the subscriber.
    static func observeMostRecent() -> AnyPublisher<BatteryRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try BatteryRecord
                .order(BatteryRecord.Columns.date.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
