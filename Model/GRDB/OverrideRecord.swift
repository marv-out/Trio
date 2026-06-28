import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `OverrideStored` entity (profile overrides + presets).
///
/// The first relationship-bearing family to migrate (see `MIGRATION.md`, Step 7). The 6 Decimals
/// (`duration`, `end`, `smbMinutes`, `start`, `target`, `uamMinutes`) are stored as TEXT and
/// converted here, so exact values are preserved (no Double rounding) — same pattern as `TDDRecord`.
/// `id` is the business UUID (string form); `pk` is the synthetic rowid and replaces
/// `NSManagedObjectID` for cross-thread identity.
struct OverrideRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "overrideStored"

    var pk: Int64?
    var id: String?
    var name: String?
    var date: Date?
    var enabled: Bool
    var isPreset: Bool
    var isUploadedToNS: Bool
    var orderPosition: Int
    var indefinite: Bool
    var percentage: Double
    var advancedSettings: Bool
    var isfAndCr: Bool
    var isf: Bool
    var cr: Bool
    var smbIsOff: Bool
    var smbIsScheduledOff: Bool
    var duration: Decimal?
    var target: Decimal?
    var smbMinutes: Decimal?
    var uamMinutes: Decimal?
    var start: Decimal?
    var end: Decimal?

    init(
        pk: Int64? = nil,
        id: String? = nil,
        name: String? = nil,
        date: Date? = nil,
        enabled: Bool = false,
        isPreset: Bool = false,
        isUploadedToNS: Bool = false,
        orderPosition: Int = 0,
        indefinite: Bool = false,
        percentage: Double = 100,
        advancedSettings: Bool = false,
        isfAndCr: Bool = true,
        isf: Bool = true,
        cr: Bool = true,
        smbIsOff: Bool = false,
        smbIsScheduledOff: Bool = false,
        duration: Decimal? = nil,
        target: Decimal? = nil,
        smbMinutes: Decimal? = nil,
        uamMinutes: Decimal? = nil,
        start: Decimal? = nil,
        end: Decimal? = nil
    ) {
        self.pk = pk
        self.id = id
        self.name = name
        self.date = date
        self.enabled = enabled
        self.isPreset = isPreset
        self.isUploadedToNS = isUploadedToNS
        self.orderPosition = orderPosition
        self.indefinite = indefinite
        self.percentage = percentage
        self.advancedSettings = advancedSettings
        self.isfAndCr = isfAndCr
        self.isf = isf
        self.cr = cr
        self.smbIsOff = smbIsOff
        self.smbIsScheduledOff = smbIsScheduledOff
        self.duration = duration
        self.target = target
        self.smbMinutes = smbMinutes
        self.uamMinutes = uamMinutes
        self.start = start
        self.end = end
    }

    init(row: Row) {
        pk = row["pk"]
        id = row["id"]
        name = row["name"]
        date = row["date"]
        enabled = row["enabled"]
        isPreset = row["isPreset"]
        isUploadedToNS = row["isUploadedToNS"]
        orderPosition = row["orderPosition"]
        indefinite = row["indefinite"]
        percentage = row["percentage"]
        advancedSettings = row["advancedSettings"]
        isfAndCr = row["isfAndCr"]
        isf = row["isf"]
        cr = row["cr"]
        smbIsOff = row["smbIsOff"]
        smbIsScheduledOff = row["smbIsScheduledOff"]
        duration = Self.decimal(row["duration"])
        target = Self.decimal(row["target"])
        smbMinutes = Self.decimal(row["smbMinutes"])
        uamMinutes = Self.decimal(row["uamMinutes"])
        start = Self.decimal(row["start"])
        end = Self.decimal(row["end"])
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id
        container["name"] = name
        container["date"] = date
        container["enabled"] = enabled
        container["isPreset"] = isPreset
        container["isUploadedToNS"] = isUploadedToNS
        container["orderPosition"] = orderPosition
        container["indefinite"] = indefinite
        container["percentage"] = percentage
        container["advancedSettings"] = advancedSettings
        container["isfAndCr"] = isfAndCr
        container["isf"] = isf
        container["cr"] = cr
        container["smbIsOff"] = smbIsOff
        container["smbIsScheduledOff"] = smbIsScheduledOff
        container["duration"] = Self.string(duration)
        container["target"] = Self.string(target)
        container["smbMinutes"] = Self.string(smbMinutes)
        container["uamMinutes"] = Self.string(uamMinutes)
        container["start"] = Self.string(start)
        container["end"] = Self.string(end)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    // Decimal <-> TEXT, non-localized (always '.'), lossless.
    private static func string(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    private static func decimal(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }

    enum Columns {
        static let date = Column("date")
        static let enabled = Column("enabled")
        static let isPreset = Column("isPreset")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let indefinite = Column("indefinite")
        static let orderPosition = Column("orderPosition")
        static let id = Column("id")
    }

    /// The override's contribution to the target glucose. Mirrors the former
    /// `@MainActor BaseOverrideStorage.calculateTarget` — now a pure value-type function.
    var calculatedTarget: Decimal {
        guard let target, target != 0 else { return 0 }
        return target
    }
}

/// GRDB record replacing the Core Data `OverrideRunStored` entity (a logged run of an override).
///
/// The Core Data `override` to-one relationship becomes the `overridePk` foreign key referencing
/// `OverrideRecord.pk`. `id` (a UUID) is the business identity. `target` is the only Decimal,
/// stored as TEXT for losslessness.
struct OverrideRunRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "overrideRunStored"

    var pk: Int64?
    var id: UUID?
    var name: String?
    var startDate: Date?
    var endDate: Date?
    var isUploadedToNS: Bool
    var target: Decimal?
    var overridePk: Int64?

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        name: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isUploadedToNS: Bool = false,
        target: Decimal? = nil,
        overridePk: Int64? = nil
    ) {
        self.pk = pk
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.isUploadedToNS = isUploadedToNS
        self.target = target
        self.overridePk = overridePk
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        name = row["name"]
        startDate = row["startDate"]
        endDate = row["endDate"]
        isUploadedToNS = row["isUploadedToNS"]
        target = Self.decimal(row["target"])
        overridePk = row["overridePk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["name"] = name
        container["startDate"] = startDate
        container["endDate"] = endDate
        container["isUploadedToNS"] = isUploadedToNS
        container["target"] = Self.string(target)
        container["overridePk"] = overridePk
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    private static func string(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    private static func decimal(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }

    enum Columns {
        static let startDate = Column("startDate")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let overridePk = Column("overridePk")
    }
}

// MARK: - OverrideStore

/// Typed data-access API for overrides. Replaces the Core Data fetch/save/delete code in
/// `BaseOverrideStorage`, the two `NSFetchedResultsController`s in `HomeStateModel`, and the
/// `@FetchRequest` in `HomeRootView`. Records are value types, so the old `NSManagedObjectID`
/// round-tripping (intents, RemoteControl, Watch) is gone — call sites carry `pk`/`id` instead.
enum OverrideStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    // MARK: Fetches

    /// All presets, ordered by `orderPosition` (mirrors `NSPredicate.allOverridePresets`).
    /// `pool` defaults to the shared store; tests pass an in-memory pool.
    static func fetchPresets(pool: DatabasePool? = nil) async throws -> [OverrideRecord] {
        try await (pool ?? Self.pool).read { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.isPreset == true)
                .order(OverrideRecord.Columns.orderPosition)
                .fetchAll(db)
        }
    }

    /// Active overrides (mirrors `NSPredicate.lastActiveOverride`), ordered by `orderPosition`.
    /// `limit == nil` fetches all (the old `fetchLimit: 0`).
    static func fetchActiveConfigurations(limit: Int? = nil) async throws -> [OverrideRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            var request = OverrideRecord
                .filter(OverrideRecord.Columns.enabled == true)
                .filter(OverrideRecord.Columns.date >= cutoff || OverrideRecord.Columns.indefinite == true)
                .order(OverrideRecord.Columns.orderPosition)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// The single most recent active override (`lastActiveOverride`, newest `date` first).
    static func fetchLatestActive() async throws -> OverrideRecord? {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.enabled == true)
                .filter(OverrideRecord.Columns.date >= cutoff || OverrideRecord.Columns.indefinite == true)
                .order(OverrideRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// The most recently created override within the last day (newest `date` first).
    static func fetchLastCreated() async throws -> OverrideRecord? {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.date >= cutoff)
                .order(OverrideRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    static func fetch(pk: Int64) async throws -> OverrideRecord? {
        try await pool.read { db in try OverrideRecord.fetchOne(db, key: pk) }
    }

    static func fetch(id: String) async throws -> OverrideRecord? {
        try await pool.read { db in
            try OverrideRecord.filter(OverrideRecord.Columns.id == id).fetchOne(db)
        }
    }

    /// Overrides not yet uploaded to Nightscout (`lastActiveAdjustmentNotYetUploadedToNightscout`).
    /// `pool` defaults to the shared store; tests pass an in-memory pool.
    static func fetchNotYetUploaded(pool: DatabasePool? = nil) async throws -> [OverrideRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.date >= cutoff)
                .filter(OverrideRecord.Columns.enabled == true)
                .filter(OverrideRecord.Columns.isUploadedToNS == false)
                .order(OverrideRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Overrides whose `date` falls within `[lower, upper]` (Nightscout re-render check).
    static func fetch(from lower: Date, to upper: Date) async throws -> [OverrideRecord] {
        try await pool.read { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.date >= lower && OverrideRecord.Columns.date <= upper)
                .order(OverrideRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    // MARK: Writes

    /// Inserts a fully-formed override. If it is a preset, `orderPosition` is set atomically to
    /// `presetCount + 1`. Returns the inserted record (with its assigned `pk`).
    @discardableResult static func store(_ record: OverrideRecord, pool: DatabasePool? = nil) async throws -> OverrideRecord {
        var record = record
        try await (pool ?? Self.pool).write { db in
            if record.isPreset {
                let count = try OverrideRecord
                    .filter(OverrideRecord.Columns.isPreset == true)
                    .fetchCount(db)
                record.orderPosition = count + 1
            }
            try record.insert(db)
        }
        return record
    }

    /// Copies a running preset into a fresh non-preset override (so editing it doesn't mutate the
    /// preset). `date` is bumped by 1s so it sorts as the latest; `isUploadedToNS` is set true to
    /// avoid a duplicate Nightscout entry. Returns the inserted copy. Mirrors the former
    /// `@MainActor copyRunningOverride`.
    static func copyRunning(_ source: OverrideRecord) async throws -> OverrideRecord {
        var copy = source
        copy.pk = nil
        copy.isPreset = false
        copy.date = source.date?.addingTimeInterval(1.seconds.timeInterval)
        copy.isUploadedToNS = true
        try await pool.write { db in try copy.insert(db) }
        return copy
    }

    /// Updates an existing override (enable/disable, re-date, mark uploaded, …).
    static func update(_ record: OverrideRecord) async throws {
        try await pool.write { db in try record.update(db) }
    }

    /// Marks a set of overrides (by `pk`) as disabled in a single transaction.
    static func disable(pks: [Int64]) async throws {
        guard !pks.isEmpty else { return }
        _ = try await pool.write { db in
            try OverrideRecord
                .filter(keys: pks)
                .updateAll(db, OverrideRecord.Columns.enabled.set(to: false))
        }
    }

    static func delete(pk: Int64, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in try OverrideRecord.deleteOne(db, key: pk) }
    }

    /// Marks overrides (by business `id`) as uploaded to Nightscout, in one transaction.
    static func markUploaded(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await pool.write { db in
            try OverrideRecord
                .filter(ids.contains(OverrideRecord.Columns.id))
                .updateAll(db, OverrideRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Persists `orderPosition` for a reordered preset list (array order = new positions, 1-based).
    static func reorder(_ presets: [OverrideRecord]) async throws {
        try await pool.write { db in
            for (index, preset) in presets.enumerated() {
                guard let pk = preset.pk else { continue }
                try OverrideRecord
                    .filter(key: pk)
                    .updateAll(db, OverrideRecord.Columns.orderPosition.set(to: index + 1))
            }
        }
    }

    /// Deletes overrides older than `days`, preserving presets (mirrors the
    /// `batchDeleteOlderThan(OverrideStored, isPresetKey:)` cleanup).
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.date < cutoff)
                .filter(OverrideRecord.Columns.isPreset == false)
                .deleteAll(db)
        }
    }

    // MARK: Observation

    /// Reactive feed of active overrides (`enabled == true`, newest first) — replaces the Home
    /// `overrideController` FRC and the `HomeRootView` `@FetchRequest`. The
    /// "date >= oneDayAgo OR indefinite" rule is applied by the subscriber so the tracked region
    /// stays deterministic (no `Date()` inside it).
    static func observeActive() -> AnyPublisher<[OverrideRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.enabled == true)
                .order(OverrideRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed of all presets, ordered by `orderPosition` — replaces preset-list refreshes.
    static func observePresets() -> AnyPublisher<[OverrideRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.isPreset == true)
                .order(OverrideRecord.Columns.orderPosition)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits the latest override row (any state) on every change — drives the LiveActivity reload,
    /// replacing the `coreDataPublisher.filteredByEntityName("OverrideStored")` sink.
    static func observeLatest() -> AnyPublisher<OverrideRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRecord
                .order(OverrideRecord.Columns.date.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed that emits whenever the not-yet-uploaded override set changes — replaces the
    /// Nightscout `overrideUploadController` FRC. Emits the count; subscriber triggers an upload.
    static func observeNotYetUploadedCount() -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRecord
                .filter(OverrideRecord.Columns.isUploadedToNS == false)
                .fetchCount(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}

// MARK: - OverrideRunStore

/// Typed data-access API for override runs. Replaces the Core Data code in `BaseOverrideStorage`
/// (run creation + Nightscout fetches), the Home `overrideRunController` FRC, and the
/// `HistoryRootView` `@FetchRequest`.
enum OverrideRunStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// Inserts a run, linking it to its source override via `overridePk`.
    @discardableResult static func saveRun(_ record: OverrideRunRecord) async throws -> OverrideRunRecord {
        var record = record
        try await pool.write { db in try record.insert(db) }
        return record
    }

    /// Runs started within the last day, newest first (mirrors `overridesRunStoredFromOneDayAgo`).
    static func fetchRecent() async throws -> [OverrideRunRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try OverrideRunRecord
                .filter(OverrideRunRecord.Columns.startDate >= cutoff)
                .order(OverrideRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
    }

    /// Runs not yet uploaded to Nightscout, newest first.
    static func fetchNotYetUploaded() async throws -> [OverrideRunRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try OverrideRunRecord
                .filter(OverrideRunRecord.Columns.startDate >= cutoff)
                .filter(OverrideRunRecord.Columns.isUploadedToNS == false)
                .order(OverrideRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
    }

    static func update(_ record: OverrideRunRecord) async throws {
        try await pool.write { db in try record.update(db) }
    }

    /// Marks runs (by business `id`) as uploaded to Nightscout, in one transaction.
    static func markUploaded(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await pool.write { db in
            try OverrideRunRecord
                .filter(strings.contains(Column("id")))
                .updateAll(db, OverrideRunRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Resolves the source override's `date` for a run, via the `overridePk` foreign key.
    /// Used by the Nightscout run upload as a `createdAt` fallback.
    static func sourceOverrideDate(for run: OverrideRunRecord) async throws -> Date? {
        guard let overridePk = run.overridePk else { return nil }
        return try await pool.read { db in
            try OverrideRecord.fetchOne(db, key: overridePk)?.date
        }
    }

    /// Reactive feed that emits whenever the not-yet-uploaded run set changes — replaces the
    /// Nightscout `overrideRunUploadController` FRC. Emits the count; subscriber triggers an upload.
    static func observeNotYetUploadedCount() -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRunRecord
                .filter(OverrideRunRecord.Columns.isUploadedToNS == false)
                .fetchCount(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Deletes runs older than `days` (periodic cleanup, mirrors the Core Data batch delete).
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try OverrideRunRecord
                .filter(OverrideRunRecord.Columns.startDate < cutoff)
                .deleteAll(db)
        }
    }

    /// Reactive feed of recent runs (newest first) — replaces the Home `overrideRunController` FRC
    /// and the `HistoryRootView` `@FetchRequest`. The "startDate >= oneDayAgo" rule is applied by
    /// the subscriber to keep the tracked region deterministic.
    static func observeRecent() -> AnyPublisher<[OverrideRunRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try OverrideRunRecord
                .order(OverrideRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
