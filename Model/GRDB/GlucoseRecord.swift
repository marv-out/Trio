import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `GlucoseStored` entity (every CGM / manual blood-glucose
/// reading).
///
/// The **highest read/write-volume entity** and the last one to migrate (see `MIGRATION.md`, Step 12):
/// a reading arrives every ~5 minutes and is read by the live charts, every algorithm run, three
/// upload channels, and a fan of "latest glucose" consumers. Both `GlucoseStored` and
/// `DeletedGlucoseStored` are standalone (no relationships), so there are no foreign keys — the design
/// problem is the observation fan-out, solved by a single shared `observeLatestChanged()`.
///
/// `id` is the business UUID stored as TEXT; `pk` is the synthetic rowid and replaces `NSManagedObjectID`
/// for cross-thread identity. The single Decimal `smoothedGlucose` is stored as TEXT (lossless, like
/// `TDDRecord`/`BolusRecord`), so persistence is a manual `Row`/`PersistenceContainer` mapping.
struct GlucoseRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "glucoseStored"

    var pk: Int64?
    var id: UUID?
    var date: Date?
    var glucose: Int16
    var direction: String?
    var isManual: Bool
    var smoothedGlucose: Decimal?
    var isUploadedToNS: Bool
    var isUploadedToHealth: Bool
    var isUploadedToTidepool: Bool

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        date: Date? = nil,
        glucose: Int16 = 0,
        direction: String? = nil,
        isManual: Bool = false,
        smoothedGlucose: Decimal? = nil,
        isUploadedToNS: Bool = false,
        isUploadedToHealth: Bool = false,
        isUploadedToTidepool: Bool = false
    ) {
        self.pk = pk
        self.id = id
        self.date = date
        self.glucose = glucose
        self.direction = direction
        self.isManual = isManual
        self.smoothedGlucose = smoothedGlucose
        self.isUploadedToNS = isUploadedToNS
        self.isUploadedToHealth = isUploadedToHealth
        self.isUploadedToTidepool = isUploadedToTidepool
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        date = row["date"]
        glucose = row["glucose"]
        direction = row["direction"]
        isManual = row["isManual"]
        smoothedGlucose = Self.decimal(row["smoothedGlucose"])
        isUploadedToNS = row["isUploadedToNS"]
        isUploadedToHealth = row["isUploadedToHealth"]
        isUploadedToTidepool = row["isUploadedToTidepool"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["date"] = date
        container["glucose"] = glucose
        container["direction"] = direction
        container["isManual"] = isManual
        container["smoothedGlucose"] = Self.string(smoothedGlucose)
        container["isUploadedToNS"] = isUploadedToNS
        container["isUploadedToHealth"] = isUploadedToHealth
        container["isUploadedToTidepool"] = isUploadedToTidepool
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    /// The trend arrow, mirroring the former `GlucoseStored.directionEnum` (read by the chart /
    /// history / current-glucose views).
    var directionEnum: BloodGlucose.Direction? {
        BloodGlucose.Direction(rawValue: direction ?? "")
    }

    // Decimal <-> TEXT, non-localized (always '.'), lossless.
    private static func string(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    private static func decimal(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }

    enum Columns {
        static let id = Column("id")
        static let date = Column("date")
        static let glucose = Column("glucose")
        static let isManual = Column("isManual")
        static let smoothedGlucose = Column("smoothedGlucose")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let isUploadedToHealth = Column("isUploadedToHealth")
        static let isUploadedToTidepool = Column("isUploadedToTidepool")
    }
}

/// GRDB record replacing the Core Data `DeletedGlucoseStored` entity — a tombstone recording a deleted
/// reading so a later CGM backfill does not re-ingest it.
///
/// Standalone, no Decimals → a plain `Codable` GRDB record works (like `ContactImageRecord`). There is
/// **no upload path**: the Nightscout/Health *remote* delete is done synchronously in the delete flow by
/// the manager reading the live `GlucoseStored` `id`/`date` before deletion. The tombstone exists only
/// to stop a deleted reading from being re-ingested.
struct DeletedGlucoseRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "deletedGlucoseStored"

    var pk: Int64?
    var date: Date
    var glucose: Int16
    var isManualGlucoseEntry: Bool

    var id: Int64? { pk }

    init(pk: Int64? = nil, date: Date, glucose: Int16, isManualGlucoseEntry: Bool) {
        self.pk = pk
        self.date = date
        self.glucose = glucose
        self.isManualGlucoseEntry = isManualGlucoseEntry
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let date = Column("date")
    }
}

// MARK: - GlucoseStore

/// Typed data-access API for glucose readings. Replaces the Core Data code in `BaseGlucoseStorage`, the
/// `glucoseController` FRCs (Home, Treatments), the oref read path in `OpenAPS`, the smoothing pass in
/// `FetchGlucoseManager`, the three upload FRCs (Nightscout / Health / Tidepool), the Stat fetches, the
/// six "latest glucose" consumers (Live Activity, Watch, Garmin, Calendar, notifications, contact image),
/// and `BolusCalculationManager` / `StateIntentRequest`. Records are value types, so the old
/// `NSManagedObjectID` round-tripping is gone — call sites carry `pk` (Int64) or the business `id` (UUID).
///
/// The dominant design concern is the **observation fan-out**: a reading arrives every ~5 minutes, so
/// the six latest-glucose consumers subscribe to **one shared** `observeLatestChanged()` (`.share()`)
/// rather than each running its own `ValueObservation` on every write.
enum GlucoseStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// Which upload channel a not-yet-uploaded fetch / mark / observation targets. All three channels
    /// match on the business `id` (Tidepool's `syncIdentifier` *is* the `id`).
    enum UploadChannel {
        case nightscout
        case health
        case tidepool

        var column: Column {
            switch self {
            case .nightscout: return GlucoseRecord.Columns.isUploadedToNS
            case .health: return GlucoseRecord.Columns.isUploadedToHealth
            case .tidepool: return GlucoseRecord.Columns.isUploadedToTidepool
            }
        }

        var setter: ColumnAssignment {
            switch self {
            case .nightscout: return GlucoseRecord.Columns.isUploadedToNS.set(to: true)
            case .health: return GlucoseRecord.Columns.isUploadedToHealth.set(to: true)
            case .tidepool: return GlucoseRecord.Columns.isUploadedToTidepool.set(to: true)
            }
        }
    }

    // MARK: Fetches

    /// The workhorse read: readings with `date >= from`, ordered by date, optionally limited / restricted
    /// to CGM (non-manual) readings. Replaces the many Core Data `fetchEntitiesAsync(GlucoseStored, …)`
    /// call sites (recent-N reads for the Watch, Calendar, notifications, contact image, bolus calc,
    /// intents, Live Activity, etc.). Descending (newest first) by default, matching the FRC/predicate
    /// convention those sites used.
    static func fetch(
        from date: Date,
        ascending: Bool = false,
        limit: Int? = nil,
        manualExcluded: Bool = false,
        pool: DatabasePool? = nil
    ) async throws -> [GlucoseRecord] {
        try await (pool ?? Self.pool).read { db in
            var request = GlucoseRecord.filter(GlucoseRecord.Columns.date >= date)
            if manualExcluded { request = request.filter(GlucoseRecord.Columns.isManual == false) }
            request = request.order(ascending ? GlucoseRecord.Columns.date : GlucoseRecord.Columns.date.desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// Chart feed (Home / Treatments / History): readings `date >= oneDayAgo`. Ascending by default (the
    /// Home chart's binary search / delta logic assumes chronological order); Treatments/History re-sort
    /// descending per consumer.
    static func fetchForChart(ascending: Bool = true, pool: DatabasePool? = nil) async throws -> [GlucoseRecord] {
        try await fetch(from: Date.oneDayAgo, ascending: ascending, pool: pool)
    }

    /// Readings for the Stat screens (`glucoseForStats*` windows), newest first. Aggregation is
    /// order-independent, so this matches the former descending fetch.
    static func fetchForStats(from date: Date, pool: DatabasePool? = nil) async throws -> [GlucoseRecord] {
        try await fetch(from: date, ascending: false, pool: pool)
    }

    /// The oref algorithm window (`OpenAPS.fetchAndProcessGlucose`): `date >= from`, newest first,
    /// optionally limited. Returns records so the caller maps them to `AlgorithmGlucose` (applying the
    /// smoothed-vs-raw selection, issue #1054).
    static func fetchForAlgorithm(from date: Date, limit: Int?, pool: DatabasePool? = nil) async throws -> [GlucoseRecord] {
        try await fetch(from: date, ascending: false, limit: limit, pool: pool)
    }

    /// The newest `limit` **non-manual** readings, returned **chronological** (ascending) — the input to
    /// the exponential-smoothing pass. Replaces `FetchGlucoseManager.fetchGlucose` (the objectID list is
    /// gone). The DB fetch is descending+limited so it always keeps the most recent readings; the result
    /// is reversed to chronological order for the smoothing math.
    static func fetchForSmoothing(limit: Int = 350, pool: DatabasePool? = nil) async throws -> [GlucoseRecord] {
        let cutoff = Date.oneDayAgoInMinutes
        return try await (pool ?? Self.pool).read { db in
            let rows = try GlucoseRecord
                .filter(GlucoseRecord.Columns.date >= cutoff)
                .filter(GlucoseRecord.Columns.isManual == false)
                .order(GlucoseRecord.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
            return rows.reversed()
        }
    }

    /// The single newest reading within `minutes` (`fetchLatestGlucose` / the `alarm` path), or `nil`.
    static func fetchLatest(within minutes: Int = 20, pool: DatabasePool? = nil) async throws -> GlucoseRecord? {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return try await (pool ?? Self.pool).read { db in
            try GlucoseRecord
                .filter(GlucoseRecord.Columns.date >= cutoff)
                .order(GlucoseRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Synchronous newest reading within `minutes` (blocks the caller) — mirrors the former
    /// `context.performAndWait` in the `alarm` computed property.
    static func fetchLatestSync(within minutes: Int = 20) throws -> GlucoseRecord? {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return try pool.read { db in
            try GlucoseRecord
                .filter(GlucoseRecord.Columns.date >= cutoff)
                .order(GlucoseRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Synchronous date of the newest reading within the last day (`syncDate` / `lastGlucoseDate`), or
    /// `nil`. Blocks the caller — mirrors the former `context.performAndWait` fetches.
    static func fetchLatestDateSync() throws -> Date? {
        try pool.read { db in
            try GlucoseRecord
                .filter(GlucoseRecord.Columns.date >= Date.oneDayAgo)
                .order(GlucoseRecord.Columns.date.desc)
                .fetchOne(db)?.date
        }
    }

    /// Readings not yet uploaded to `channel` (`date >= oneDayAgo AND isUploadedTo… == false`), newest
    /// first. `manualOnly` adds the `isManual == true` filter (the Health/Tidepool manual variants).
    static func fetchNotYetUploaded(
        channel: UploadChannel,
        manualOnly: Bool = false,
        pool: DatabasePool? = nil
    ) async throws -> [GlucoseRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            var request = GlucoseRecord
                .filter(GlucoseRecord.Columns.date >= cutoff)
                .filter(channel.column == false)
            if manualOnly { request = request.filter(GlucoseRecord.Columns.isManual == true) }
            return try request.order(GlucoseRecord.Columns.date.desc).fetchAll(db)
        }
    }

    /// A single reading by `pk` — the History deletion path (read `id`/`date` for the remote-service
    /// deletes before `delete(pk:)`).
    static func fetch(pk: Int64, pool: DatabasePool? = nil) async throws -> GlucoseRecord? {
        try await (pool ?? Self.pool).read { db in try GlucoseRecord.fetchOne(db, key: pk) }
    }

    /// The `date`s of readings within `[from, to]` — the ingest dedup key. The comparison the storage
    /// layer performs is a **time-buffer proximity** match against these DB-stored (millisecond) dates,
    /// *not* exact sub-millisecond `Date` equality (the Step 11 precision lesson: raw incoming `Date`s
    /// carry sub-millisecond components the round-tripped DB value does not).
    static func existingDates(from: Date, to: Date, pool: DatabasePool? = nil) async throws -> [Date] {
        let request = GlucoseRecord
            .filter(GlucoseRecord.Columns.date >= from && GlucoseRecord.Columns.date <= to)
            .select(GlucoseRecord.Columns.date, as: Date?.self)
        let dates = try await (pool ?? Self.pool).read { db in try request.fetchAll(db) }
        return dates.compactMap { $0 }
    }

    // MARK: Writes

    /// Inserts a single reading. Used by the manual-entry path and any single-value store.
    @discardableResult static func store(_ record: GlucoseRecord, pool: DatabasePool? = nil) async throws -> GlucoseRecord {
        var record = record
        try await (pool ?? Self.pool).write { db in try record.insert(db) }
        return record
    }

    /// Inserts `records` in one write transaction — replaces `storeGlucoseRegular` **and** the
    /// `NSBatchInsertRequest` path (the regular/batch split existed only to trigger Core Data
    /// notifications; GRDB observation replaces that).
    static func batchInsert(_ records: [GlucoseRecord], pool: DatabasePool? = nil) async throws {
        guard !records.isEmpty else { return }
        try await (pool ?? Self.pool).write { db in
            for record in records {
                var record = record
                try record.insert(db)
            }
        }
    }

    /// Writes the smoothing pass results: `(pk, smoothedGlucose)` pairs, one write transaction. Replaces
    /// the in-place `object.smoothedGlucose = …` mutation in `FetchGlucoseManager`.
    static func updateSmoothed(_ pairs: [(pk: Int64, value: Decimal)], pool: DatabasePool? = nil) async throws {
        guard !pairs.isEmpty else { return }
        _ = try await (pool ?? Self.pool).write { db in
            for pair in pairs {
                try GlucoseRecord
                    .filter(key: pair.pk)
                    .updateAll(db, Column("smoothedGlucose").set(to: NSDecimalNumber(decimal: pair.value).stringValue))
            }
        }
    }

    /// Marks readings (by business `id`) uploaded to `channel`. All three channels match on `id`.
    static func markUploaded(channel: UploadChannel, ids: [String], pool: DatabasePool? = nil) async throws {
        let ids = ids.compactMap { $0 }
        guard !ids.isEmpty else { return }
        _ = try await (pool ?? Self.pool).write { db in
            try GlucoseRecord
                .filter(ids.contains(GlucoseRecord.Columns.id))
                .updateAll(db, channel.setter)
        }
    }

    /// Deletes a reading by `pk` **and** writes a `DeletedGlucoseRecord` tombstone in one transaction
    /// (mirrors the former `deleteGlucose`). The tombstone stops a later backfill from re-ingesting it.
    static func delete(pk: Int64, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in
            guard let record = try GlucoseRecord.fetchOne(db, key: pk) else { return }
            if let date = record.date {
                var tombstone = DeletedGlucoseRecord(
                    date: date,
                    glucose: record.glucose,
                    isManualGlucoseEntry: record.isManual
                )
                try tombstone.insert(db)
            }
            try GlucoseRecord.deleteOne(db, key: pk)
        }
    }

    /// Deletes readings older than `days` by `date` (periodic cleanup).
    static func deleteOlderThan(days: Int, pool: DatabasePool? = nil) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await (pool ?? Self.pool).write { db in
            try GlucoseRecord
                .filter(GlucoseRecord.Columns.date < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: Observation

    /// **The single shared "latest glucose changed" observation** the six latest-glucose consumers
    /// subscribe to (Live Activity, Watch, Garmin, Calendar, notifications, contact image). Tracking the
    /// newest row (`.fetchOne`) means it emits once per ~5-minute write; `.share()` multicasts that one
    /// query to every subscriber rather than each running its own `ValueObservation`. Subscribers do
    /// their own store fetch on notification (they need more than the single latest row) and should also
    /// perform an initial fetch on setup, since a `.share()` late subscriber does not replay the initial
    /// snapshot.
    static let observeLatestChanged: AnyPublisher<GlucoseRecord?, Error> = {
        let observation = ValueObservation.tracking { db in
            try GlucoseRecord
                .order(GlucoseRecord.Columns.date.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).share().eraseToAnyPublisher()
    }()

    /// Reactive chart feed (Home / Treatments / History) — replaces the `glucoseController` FRCs. Tracks
    /// the newest 1000 rows (a bounded, deterministic region covering >24h at 5-min cadence); the
    /// subscriber applies the `date >= oneDayAgo` filter and sorts per consumer (Home ascending,
    /// Treatments/History descending — see the Step 11 ordering lesson).
    static func observeForChart() -> AnyPublisher<[GlucoseRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try GlucoseRecord
                .order(GlucoseRecord.Columns.date.desc)
                .limit(1000)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits whenever the not-yet-uploaded set for `channel` changes — replaces the upload FRCs. Emits
    /// the count; the subscriber triggers an upload.
    static func observeNotYetUploadedCount(channel: UploadChannel) -> AnyPublisher<Int, Error> {
        let column = channel.column
        let observation = ValueObservation.tracking { db in
            try GlucoseRecord.filter(column == false).fetchCount(db)
        }
        // Only emit when the count actually changes — a glucose write that doesn't alter the
        // not-yet-uploaded set (e.g. a smoothing update) must not re-trigger an upload.
        return observation.publisher(in: pool).removeDuplicates().eraseToAnyPublisher()
    }
}

// MARK: - DeletedGlucoseStore

/// Typed data-access API for the deleted-glucose tombstones. Written by the glucose delete path (via
/// `GlucoseStore.delete`) and read by the backfill dedup (`existingDates`). No upload path.
enum DeletedGlucoseStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    static func store(_ record: DeletedGlucoseRecord, pool: DatabasePool? = nil) async throws {
        var record = record
        try await (pool ?? Self.pool).write { db in try record.insert(db) }
    }

    /// The `date`s of tombstones within `[from, to]` — the backfill dedup (proximity match in Swift
    /// against these DB-stored dates, mirroring `GlucoseStore.existingDates`).
    static func existingDates(from: Date, to: Date, pool: DatabasePool? = nil) async throws -> [Date] {
        let request = DeletedGlucoseRecord
            .filter(DeletedGlucoseRecord.Columns.date >= from && DeletedGlucoseRecord.Columns.date <= to)
            .select(DeletedGlucoseRecord.Columns.date, as: Date.self)
        return try await (pool ?? Self.pool).read { db in try request.fetchAll(db) }
    }

    static func deleteOlderThan(days: Int, pool: DatabasePool? = nil) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await (pool ?? Self.pool).write { db in
            try DeletedGlucoseRecord
                .filter(DeletedGlucoseRecord.Columns.date < cutoff)
                .deleteAll(db)
        }
    }
}
