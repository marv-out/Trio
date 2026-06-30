import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `CarbEntryStored` entity (carb entries + their FPU
/// carb-equivalents).
///
/// Standalone, no relationships (verified against the model): `fpuID` is a *grouping key* shared by
/// the carb-equivalent rows of one fat/protein entry, not a foreign key. Unlike the previous
/// relationship-bearing steps, `carbs`/`fat`/`protein` are `Double` in Core Data, so they are stored
/// as `.double` columns directly — no Decimal↔TEXT dance.
///
/// Two independent serializations live on this type and must not be confused:
/// - GRDB persistence uses the manual `init(row:)` / `encode(to container:)` (GRDB's
///   `PersistenceContainer` overload), keyed by column name.
/// - Swift `Encodable` (`encode(to encoder:)`) produces the oref/meal JSON shape
///   (`actualDate`/`created_at`/`enteredBy`), ported verbatim from `CarbEntryStored+helper.swift`.
/// They have different method signatures, so a single struct carries both.
struct CarbEntryRecord: FetchableRecord, MutablePersistableRecord, Encodable, Hashable, Identifiable {
    static let databaseTableName = "carbEntryStored"

    var pk: Int64?
    var id: UUID?
    var date: Date?
    var carbs: Double
    var fat: Double
    var protein: Double
    var note: String?
    var isFPU: Bool
    var fpuID: UUID?
    var isUploadedToNS: Bool
    var isUploadedToHealth: Bool
    var isUploadedToTidepool: Bool

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        date: Date? = nil,
        carbs: Double = 0,
        fat: Double = 0,
        protein: Double = 0,
        note: String? = nil,
        isFPU: Bool = false,
        fpuID: UUID? = nil,
        isUploadedToNS: Bool = false,
        isUploadedToHealth: Bool = false,
        isUploadedToTidepool: Bool = false
    ) {
        self.pk = pk
        self.id = id
        self.date = date
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.note = note
        self.isFPU = isFPU
        self.fpuID = fpuID
        self.isUploadedToNS = isUploadedToNS
        self.isUploadedToHealth = isUploadedToHealth
        self.isUploadedToTidepool = isUploadedToTidepool
    }

    // MARK: GRDB persistence (column-keyed)

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        date = row["date"]
        carbs = row["carbs"] ?? 0
        fat = row["fat"] ?? 0
        protein = row["protein"] ?? 0
        note = row["note"]
        isFPU = row["isFPU"]
        fpuID = (row["fpuID"] as String?).flatMap { UUID(uuidString: $0) }
        isUploadedToNS = row["isUploadedToNS"]
        isUploadedToHealth = row["isUploadedToHealth"]
        isUploadedToTidepool = row["isUploadedToTidepool"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["date"] = date
        container["carbs"] = carbs
        container["fat"] = fat
        container["protein"] = protein
        container["note"] = note
        container["isFPU"] = isFPU
        container["fpuID"] = fpuID?.uuidString
        container["isUploadedToNS"] = isUploadedToNS
        container["isUploadedToHealth"] = isUploadedToHealth
        container["isUploadedToTidepool"] = isUploadedToTidepool
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let date = Column("date")
        static let carbs = Column("carbs")
        static let isFPU = Column("isFPU")
        static let fpuID = Column("fpuID")
        static let id = Column("id")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let isUploadedToHealth = Column("isUploadedToHealth")
        static let isUploadedToTidepool = Column("isUploadedToTidepool")
    }

    // MARK: Swift Encodable (oref/meal JSON) — ported from `CarbEntryStored+helper.swift`

    enum CodingKeys: String, CodingKey {
        case actualDate
        case created_at
        case carbs
        case fat
        case id
        case isFPU
        case note
        case protein
        case enteredBy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formattedDate = dateFormatter.string(from: date ?? Date())
        try container.encode(formattedDate, forKey: .actualDate)
        try container.encode(formattedDate, forKey: .created_at)

        // TODO: handle this conditionally; pass in the enteredBy string (manual entry or via NS or Apple Health)
        try container.encode("Trio", forKey: .enteredBy)

        try container.encode(carbs, forKey: .carbs)
        try container.encode(fat, forKey: .fat)
        try container.encode(isFPU, forKey: .isFPU)
        try container.encode(note, forKey: .note)
        try container.encode(protein, forKey: .protein)
        try container.encode(id, forKey: .id)
    }
}

// MARK: - CarbEntryStore

/// Typed data-access API for carb entries. Replaces the Core Data fetch/save/delete code in
/// `BaseCarbsStorage`, the two `NSFetchedResultsController`s in `HomeStateModel`, the History
/// `@FetchRequest`, and the three upload-channel FRCs (Nightscout / Health / Tidepool).
///
/// Carbs have no relationships, presets, or runs (unlike Override/TempTarget), so the surface is a
/// flat set of fetches + the FPU grouping (`fpuID`). The three upload channels each track a
/// separate `isUploadedTo*` flag.
enum CarbEntryStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    // MARK: Fetches — charts

    /// Carb-only rows for the Home main chart: `isFPU == false AND date >= oneDayAgo AND carbs > 0`
    /// (mirrors `NSPredicate.carbsForChart`), newest first.
    static func fetchCarbsForChart(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.isFPU == false)
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.carbs > 0)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// FPU carb-equivalent rows for the Home main chart: `isFPU == true AND date >= oneDayAgo`
    /// (mirrors `NSPredicate.fpusForChart`), newest first.
    static func fetchFPUsForChart(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.isFPU == true)
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    // MARK: Fetches — stats / meal calc

    /// Carb entries for the Stat screen: `date >= threeMonthsAgo AND isFPU == false`
    /// (mirrors `NSPredicate.carbsForStats`), newest first.
    static func fetchForStats(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.threeMonthsAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.isFPU == false)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// All carb entries within the last day (`NSPredicate.predicateForOneDayAgo`), newest first —
    /// the meal-calc input for OpenAPS (carbs + FPU equivalents, both passed to oref).
    static func fetchForMealCalc(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Recent carb entries within the last day, newest first (`AppleWatchManager` / RemoteControl
    /// recent-carb reads). `limit == nil` fetches all.
    static func fetchRecent(limit: Int? = nil, pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            var request = CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .order(CarbEntryRecord.Columns.date.desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    static func fetch(pk: Int64, pool: DatabasePool? = nil) async throws -> CarbEntryRecord? {
        try await (pool ?? Self.pool).read { db in try CarbEntryRecord.fetchOne(db, key: pk) }
    }

    /// All rows sharing `fpuID` (one entry's carb + carb-equivalents), newest first. Backs the
    /// History FPU-vs-carb edit resolution (`getCorrespondingCarbEntry` / `getZeroCarbNonFPUEntry`),
    /// which filter the group in Swift.
    static func fetchByFpuID(_ fpuID: UUID, pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.fpuID == fpuID.uuidString)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    // MARK: Fetches — not yet uploaded (per channel)

    /// Carb-only rows not yet uploaded to Nightscout
    /// (`isUploadedToNS == false AND isFPU == false AND carbs > 0 AND date >= oneDayAgo`).
    static func fetchCarbsNotYetUploadedToNightscout(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.isUploadedToNS == false)
                .filter(CarbEntryRecord.Columns.isFPU == false)
                .filter(CarbEntryRecord.Columns.carbs > 0)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// FPU rows not yet uploaded to Nightscout
    /// (`isUploadedToNS == false AND isFPU == true AND date >= oneDayAgo`).
    static func fetchFPUsNotYetUploadedToNightscout(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.isUploadedToNS == false)
                .filter(CarbEntryRecord.Columns.isFPU == true)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Rows not yet uploaded to Apple Health (`isUploadedToHealth == false AND date >= oneDayAgo`).
    static func fetchNotYetUploadedToHealth(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.isUploadedToHealth == false)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Rows not yet uploaded to Tidepool (`isUploadedToTidepool == false AND date >= oneDayAgo`).
    static func fetchNotYetUploadedToTidepool(pool: DatabasePool? = nil) async throws -> [CarbEntryRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date >= cutoff)
                .filter(CarbEntryRecord.Columns.isUploadedToTidepool == false)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    // MARK: Writes

    /// Inserts a single carb entry. Returns the inserted record (with its assigned `pk`).
    @discardableResult static func store(
        _ record: CarbEntryRecord,
        pool: DatabasePool? = nil
    ) async throws -> CarbEntryRecord {
        var record = record
        try await (pool ?? Self.pool).write { db in try record.insert(db) }
        return record
    }

    /// Inserts many carb entries in a single transaction (replaces the Core Data
    /// `NSBatchInsertRequest`). Used for the FPU carb-equivalent rows of one fat/protein entry (all
    /// sharing one `fpuID`) and for the JSON history import.
    static func batchInsert(_ records: [CarbEntryRecord], pool: DatabasePool? = nil) async throws {
        guard !records.isEmpty else { return }
        try await (pool ?? Self.pool).write { db in
            for record in records {
                var record = record
                try record.insert(db)
            }
        }
    }

    /// The `date`s of carb entries within `[from, to]` — the JSON-import dedupe key. `to` is injected
    /// (tests pass a fixed `now`), so the range is explicit rather than relative to the real clock.
    static func existingDates(from: Date, to: Date, pool: DatabasePool? = nil) async throws -> Set<Date> {
        let request = CarbEntryRecord
            .filter(CarbEntryRecord.Columns.date >= from && CarbEntryRecord.Columns.date <= to)
            .select(CarbEntryRecord.Columns.date, as: Date?.self)
        let dates = try await (pool ?? Self.pool).read { db in try request.fetchAll(db) }
        return Set(dates.compactMap { $0 })
    }

    /// Updates an existing carb entry (edit, mark uploaded, …).
    static func update(_ record: CarbEntryRecord, pool: DatabasePool? = nil) async throws {
        try await (pool ?? Self.pool).write { db in try record.update(db) }
    }

    static func delete(pk: Int64, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in try CarbEntryRecord.deleteOne(db, key: pk) }
    }

    /// Deletes all rows sharing `fpuID` (the FPU group delete cascade). Returns the deleted count.
    @discardableResult static func deleteByFpuID(_ fpuID: UUID, pool: DatabasePool? = nil) async throws -> Int {
        try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.fpuID == fpuID.uuidString)
                .deleteAll(db)
        }
    }

    /// Deletes carb entries older than `days` (mirrors `batchDeleteOlderThan(CarbEntryStored, days:)`).
    static func deleteOlderThan(days: Int, pool: DatabasePool? = nil) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.date < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: Mark uploaded

    /// Marks carbs (by business `id`) uploaded to Nightscout. The NS carb treatment carries
    /// `id = carbEntry.id`, so the upload-completion match is on `id`.
    static func markUploadedToNightscout(ids: [UUID], pool: DatabasePool? = nil) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(strings.contains(CarbEntryRecord.Columns.id))
                .updateAll(db, CarbEntryRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Marks FPU rows (by `fpuID`) uploaded to Nightscout. The NS FPU treatment carries
    /// `id = carbEntry.fpuID`, so the match must be on `fpuID`, not `id` (a whole FPU group is one
    /// NS treatment).
    static func markFPUsUploadedToNightscout(fpuIDs: [UUID], pool: DatabasePool? = nil) async throws {
        guard !fpuIDs.isEmpty else { return }
        let strings = fpuIDs.map(\.uuidString)
        _ = try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(strings.contains(CarbEntryRecord.Columns.fpuID))
                .updateAll(db, CarbEntryRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    static func markUploadedToHealth(ids: [UUID], pool: DatabasePool? = nil) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(strings.contains(CarbEntryRecord.Columns.id))
                .updateAll(db, CarbEntryRecord.Columns.isUploadedToHealth.set(to: true))
        }
    }

    static func markUploadedToTidepool(ids: [UUID], pool: DatabasePool? = nil) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await (pool ?? Self.pool).write { db in
            try CarbEntryRecord
                .filter(strings.contains(CarbEntryRecord.Columns.id))
                .updateAll(db, CarbEntryRecord.Columns.isUploadedToTidepool.set(to: true))
        }
    }

    // MARK: Observation

    /// Reactive feed of carb-only chart rows — replaces the Home `carbsController` FRC. Tracks the
    /// stable `isFPU == false AND carbs > 0` region (no `Date()` in the tracked region); the
    /// subscriber applies the `date >= oneDayAgo` rule.
    static func observeCarbsForChart() -> AnyPublisher<[CarbEntryRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.isFPU == false)
                .filter(CarbEntryRecord.Columns.carbs > 0)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed of FPU chart rows — replaces the Home `fpuController` FRC. Tracks the stable
    /// `isFPU == true` region; the subscriber applies the `date >= oneDayAgo` rule.
    static func observeFPUsForChart() -> AnyPublisher<[CarbEntryRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.isFPU == true)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed for the History meals list — replaces the `carbsHistory` `@FetchRequest`. Both
    /// carbs and FPU-equivalent rows appear (the predicate is `carbs > 0`, no `isFPU` filter). Tracks
    /// the stable `carbs > 0` region; the subscriber applies the `date >= oneDayAgo` rule.
    static func observeHistory() -> AnyPublisher<[CarbEntryRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try CarbEntryRecord
                .filter(CarbEntryRecord.Columns.carbs > 0)
                .order(CarbEntryRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits whenever the not-yet-uploaded-to-Nightscout set changes — replaces the NS carb upload
    /// FRC. Emits the count; the subscriber triggers an upload of both carbs and FPUs.
    static func observeNotYetUploadedToNightscoutCount() -> AnyPublisher<Int, Error> {
        observeCount(column: CarbEntryRecord.Columns.isUploadedToNS)
    }

    /// Emits whenever the not-yet-uploaded-to-Health set changes — replaces the Health upload FRC.
    static func observeNotYetUploadedToHealthCount() -> AnyPublisher<Int, Error> {
        observeCount(column: CarbEntryRecord.Columns.isUploadedToHealth)
    }

    /// Emits whenever the not-yet-uploaded-to-Tidepool set changes — replaces the Tidepool upload FRC.
    static func observeNotYetUploadedToTidepoolCount() -> AnyPublisher<Int, Error> {
        observeCount(column: CarbEntryRecord.Columns.isUploadedToTidepool)
    }

    private static func observeCount(column: Column) -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try CarbEntryRecord.filter(column == false).fetchCount(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
