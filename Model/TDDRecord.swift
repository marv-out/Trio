import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `TDDStored` entity (Total Daily Dose aggregates).
///
/// Named `TDDRecord` to avoid colliding with the existing `TDD` DTO and the (being-removed)
/// Core Data `TDDStored` class. Decimals are stored as TEXT and converted here, so exact
/// values are preserved (no Double rounding). Only `date` and `total` are ever read back;
/// the other fields are kept for the historical record.
struct TDDRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "tddStored"

    var pk: Int64?
    var id: String?
    var date: Date?
    var total: Decimal?
    var bolus: Decimal?
    var tempBasal: Decimal?
    var scheduledBasal: Decimal?
    var weightedAverage: Decimal?

    init(
        id: String? = nil,
        date: Date? = nil,
        total: Decimal? = nil,
        bolus: Decimal? = nil,
        tempBasal: Decimal? = nil,
        scheduledBasal: Decimal? = nil,
        weightedAverage: Decimal? = nil
    ) {
        self.id = id
        self.date = date
        self.total = total
        self.bolus = bolus
        self.tempBasal = tempBasal
        self.scheduledBasal = scheduledBasal
        self.weightedAverage = weightedAverage
    }

    init(row: Row) {
        pk = row["pk"]
        id = row["id"]
        date = row["date"]
        total = Self.decimal(row["total"])
        bolus = Self.decimal(row["bolus"])
        tempBasal = Self.decimal(row["tempBasal"])
        scheduledBasal = Self.decimal(row["scheduledBasal"])
        weightedAverage = Self.decimal(row["weightedAverage"])
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id
        container["date"] = date
        container["total"] = Self.string(total)
        container["bolus"] = Self.string(bolus)
        container["tempBasal"] = Self.string(tempBasal)
        container["scheduledBasal"] = Self.string(scheduledBasal)
        container["weightedAverage"] = Self.string(weightedAverage)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    // Decimal <-> TEXT, non-localized (always '.'), lossless.
    private static func string(_ value: Decimal?) -> String? {
        guard let value else { return nil }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private static func decimal(_ string: String?) -> Decimal? {
        guard let string else { return nil }
        return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    enum Columns {
        static let date = Column("date")
        static let total = Column("total")
    }
}

// MARK: - Store

/// Typed data-access API for Total Daily Dose. Replaces the Core Data fetch/save/aggregate
/// code in `TDDStorage`, plus the read sites in `OpenAPS`, `NightscoutManager`, the LiveActivity
/// `DataManager`, and the Stat/Home state models.
///
/// Aggregates are computed in Swift after a windowed fetch. The windows are small (≤ ~2880 rows
/// for 10 days at 288/day), so this is sub-millisecond and avoids storing Decimals as lossy REAL
/// just to enable SQL `SUM`. See MIGRATION.md.
enum TDDStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    static func save(_ record: TDDRecord) async throws {
        var record = record
        try await pool.write { db in
            try record.insert(db)
        }
    }

    /// (sum of total, number of entries) since `date`. Mirrors the old `aggregateTDD`.
    static func aggregate(since date: Date) async throws -> (total: Decimal, count: Int) {
        try await pool.read { db in
            let totals = try TDDRecord
                .filter(TDDRecord.Columns.date >= date)
                .fetchAll(db)
                .compactMap(\.total)
            return (totals.reduce(0, +), totals.count)
        }
    }

    /// Number of entries with `total > 0` since `date`. Mirrors `hasSufficientTDD`'s count.
    /// `pool` defaults to the shared store; tests pass an in-memory pool.
    static func countWithPositiveTotal(since date: Date, pool: DatabasePool? = nil) async throws -> Int {
        try await (pool ?? Self.pool).read { db in
            try TDDRecord
                .filter(TDDRecord.Columns.date > date)
                .fetchAll(db)
                .filter { ($0.total ?? 0) > 0 }
                .count
        }
    }

    /// Entries since `date`, oldest first. `positiveTotalOnly` mirrors the `total > 0` predicate
    /// used by OpenAPS' oref variables. Used by OpenAPS and the Stat TDD chart.
    static func entries(since date: Date, positiveTotalOnly: Bool = false) async throws -> [TDDRecord] {
        try await pool.read { db in
            let rows = try TDDRecord
                .filter(TDDRecord.Columns.date > date)
                .order(TDDRecord.Columns.date)
                .fetchAll(db)
            return positiveTotalOnly ? rows.filter { ($0.total ?? 0) > 0 } : rows
        }
    }

    /// Most recent entry no older than `date` (e.g. last 30 min). Used by NightscoutManager
    /// and the LiveActivity DataManager.
    static func mostRecent(since date: Date) async throws -> TDDRecord? {
        try await pool.read { db in
            try TDDRecord
                .filter(TDDRecord.Columns.date >= date)
                .order(TDDRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Reactive feed of the single most recent TDD entry — replaces the Core Data
    /// `NSFetchedResultsController` in `HomeStateModel`. Emits on every insert.
    /// The "within last 24h" rule is applied by the subscriber so the observation itself
    /// stays deterministic (no `Date()` inside the tracked region).
    static func observeMostRecent() -> AnyPublisher<TDDRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try TDDRecord
                .order(TDDRecord.Columns.date.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
