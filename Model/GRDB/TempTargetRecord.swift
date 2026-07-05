import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `TempTargetStored` entity (temp targets + presets).
///
/// Mirrors Step 7 (`OverrideRecord`): the 3 Decimals (`duration`, `target`, `halfBasalTarget`) are
/// stored as TEXT and converted here, so exact values are preserved (no Double rounding). Unlike
/// `OverrideRecord`, `id` is a `UUID` (stored as TEXT, like `OverrideRunRecord.id`). `pk` is the
/// synthetic rowid and replaces `NSManagedObjectID` for cross-thread identity.
struct TempTargetRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "tempTargetStored"

    var pk: Int64?
    var id: UUID?
    var name: String?
    var date: Date?
    var enabled: Bool
    var isPreset: Bool
    var isUploadedToNS: Bool
    var orderPosition: Int
    var enteredBy: String?
    var duration: Decimal?
    var target: Decimal?
    var halfBasalTarget: Decimal?

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        name: String? = nil,
        date: Date? = nil,
        enabled: Bool = false,
        isPreset: Bool = false,
        isUploadedToNS: Bool = false,
        orderPosition: Int = 0,
        enteredBy: String? = nil,
        duration: Decimal? = nil,
        target: Decimal? = nil,
        halfBasalTarget: Decimal? = nil
    ) {
        self.pk = pk
        self.id = id
        self.name = name
        self.date = date
        self.enabled = enabled
        self.isPreset = isPreset
        self.isUploadedToNS = isUploadedToNS
        self.orderPosition = orderPosition
        self.enteredBy = enteredBy
        self.duration = duration
        self.target = target
        self.halfBasalTarget = halfBasalTarget
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        name = row["name"]
        date = row["date"]
        enabled = row["enabled"]
        isPreset = row["isPreset"]
        isUploadedToNS = row["isUploadedToNS"]
        orderPosition = row["orderPosition"]
        enteredBy = row["enteredBy"]
        duration = Self.decimal(row["duration"])
        target = Self.decimal(row["target"])
        halfBasalTarget = Self.decimal(row["halfBasalTarget"])
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["name"] = name
        container["date"] = date
        container["enabled"] = enabled
        container["isPreset"] = isPreset
        container["isUploadedToNS"] = isUploadedToNS
        container["orderPosition"] = orderPosition
        container["enteredBy"] = enteredBy
        container["duration"] = Self.string(duration)
        container["target"] = Self.string(target)
        container["halfBasalTarget"] = Self.string(halfBasalTarget)
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
        static let orderPosition = Column("orderPosition")
        static let id = Column("id")
    }

    /// Whether this row belongs on the Home main chart: active (enabled, created within the last
    /// day) or future-scheduled (disabled, date in the future). Mirrors
    /// `NSPredicate.tempTargetsForMainChart`. `now` is injected so observation subscribers can
    /// apply the rule (the tracked region itself stays deterministic — no `Date()` inside it).
    func isOnMainChart(now: Date = Date()) -> Bool {
        guard let date else { return false }
        let active = enabled && date >= now.addingTimeInterval(-1.days.timeInterval)
        let scheduled = !enabled && date >= now
        return active || scheduled
    }
}

/// GRDB record replacing the Core Data `TempTargetRunStored` entity (a logged run of a temp target).
///
/// The Core Data `tempTarget` to-one relationship becomes the `tempTargetPk` foreign key referencing
/// `TempTargetRecord.pk`. `id` (a UUID) is the business identity. `target` is the only Decimal,
/// stored as TEXT for losslessness.
struct TempTargetRunRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "tempTargetRunStored"

    var pk: Int64?
    var id: UUID?
    var name: String?
    var startDate: Date?
    var endDate: Date?
    var isUploadedToNS: Bool
    var target: Decimal?
    var tempTargetPk: Int64?

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        name: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isUploadedToNS: Bool = false,
        target: Decimal? = nil,
        tempTargetPk: Int64? = nil
    ) {
        self.pk = pk
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.isUploadedToNS = isUploadedToNS
        self.target = target
        self.tempTargetPk = tempTargetPk
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        name = row["name"]
        startDate = row["startDate"]
        endDate = row["endDate"]
        isUploadedToNS = row["isUploadedToNS"]
        target = Self.decimal(row["target"])
        tempTargetPk = row["tempTargetPk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["name"] = name
        container["startDate"] = startDate
        container["endDate"] = endDate
        container["isUploadedToNS"] = isUploadedToNS
        container["target"] = Self.string(target)
        container["tempTargetPk"] = tempTargetPk
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
        static let tempTargetPk = Column("tempTargetPk")
    }
}

// MARK: - TempTargetStore

/// Typed data-access API for temp targets. Replaces the Core Data fetch/save/delete code in
/// `BaseTempTargetsStorage`, the two `NSFetchedResultsController`s in `HomeStateModel`, and the
/// `@FetchRequest`s. Records are value types, so the old `NSManagedObjectID` round-tripping
/// (intents, RemoteControl, Watch) is gone — call sites carry `pk`/`id` instead.
///
/// Temp Targets differ from Overrides in three ways (see `MIGRATION.md`, Step 8): there is no
/// `indefinite` flag; `lastActiveTempTarget` is just `date >= oneDayAgo AND enabled`; and there is a
/// notion of *scheduled* (future-dated, not-yet-enabled) targets with no Override analog.
enum TempTargetStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    // MARK: Fetches

    /// All presets, ordered by `orderPosition` (mirrors `NSPredicate.allTempTargetPresets`).
    /// `pool` defaults to the shared store; tests pass an in-memory pool.
    static func fetchPresets(pool: DatabasePool? = nil) async throws -> [TempTargetRecord] {
        try await (pool ?? Self.pool).read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.isPreset == true)
                .order(TempTargetRecord.Columns.orderPosition)
                .fetchAll(db)
        }
    }

    /// Active temp targets (mirrors `NSPredicate.lastActiveTempTarget`: `date >= oneDayAgo AND
    /// enabled`), ordered by `orderPosition`. `limit == nil` fetches all (the old `fetchLimit: 0`).
    /// Note: no `indefinite` clause — Temp Targets have none.
    static func fetchActiveConfigurations(limit: Int? = nil) async throws -> [TempTargetRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            var request = TempTargetRecord
                .filter(TempTargetRecord.Columns.enabled == true)
                .filter(TempTargetRecord.Columns.date >= cutoff)
                .order(TempTargetRecord.Columns.orderPosition)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// The single most recent active temp target (`lastActiveTempTarget`, newest `date` first).
    static func fetchLatestActive() async throws -> TempTargetRecord? {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.enabled == true)
                .filter(TempTargetRecord.Columns.date >= cutoff)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// The most recently created temp target within the last day (newest `date` first), regardless
    /// of `enabled`. Drives the LiveActivity (mirrors the former `predicateForOneDayAgo` fetch).
    static func fetchLastCreated() async throws -> TempTargetRecord? {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date >= cutoff)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Rows for the Home main chart: active OR future-scheduled (mirrors
    /// `NSPredicate.tempTargetsForMainChart`).
    static func fetchForMainChart() async throws -> [TempTargetRecord] {
        let cutoff = Date.oneDayAgo
        let now = Date()
        return try await pool.read { db in
            try TempTargetRecord
                .filter(
                    (TempTargetRecord.Columns.date >= cutoff && TempTargetRecord.Columns.enabled == true)
                        || (TempTargetRecord.Columns.date >= now && TempTargetRecord.Columns.enabled == false)
                )
                .order(TempTargetRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Future-scheduled temp targets (`date > now`), newest first.
    static func fetchScheduled() async throws -> [TempTargetRecord] {
        let now = Date()
        return try await pool.read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date > now)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// The scheduled temp target whose `date` exactly matches `targetDate` (used when activating a
    /// previously-scheduled target). Newest first, limited to one.
    static func fetchScheduled(for targetDate: Date) async throws -> TempTargetRecord? {
        try await pool.read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date == targetDate)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchOne(db)
        }
    }

    /// Whether any temp target exists with exactly `date` (Nightscout import dedupe).
    static func exists(date: Date) async throws -> Bool {
        try await pool.read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date == date)
                .fetchCount(db) > 0
        }
    }

    static func fetch(pk: Int64) async throws -> TempTargetRecord? {
        try await pool.read { db in try TempTargetRecord.fetchOne(db, key: pk) }
    }

    static func fetch(id: UUID) async throws -> TempTargetRecord? {
        try await pool.read { db in
            try TempTargetRecord.filter(TempTargetRecord.Columns.id == id.uuidString).fetchOne(db)
        }
    }

    /// Temp targets not yet uploaded to Nightscout (`lastActiveAdjustmentNotYetUploadedToNightscout`).
    /// `pool` defaults to the shared store; tests pass an in-memory pool.
    static func fetchNotYetUploaded(pool: DatabasePool? = nil) async throws -> [TempTargetRecord] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date >= cutoff)
                .filter(TempTargetRecord.Columns.enabled == true)
                .filter(TempTargetRecord.Columns.isUploadedToNS == false)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchAll(db)
        }
    }

    // MARK: Writes

    /// Inserts a fully-formed temp target. If it is a preset, `orderPosition` is set atomically to
    /// `presetCount + 1`. Returns the inserted record (with its assigned `pk`).
    @discardableResult static func store(
        _ record: TempTargetRecord,
        pool: DatabasePool? = nil
    ) async throws -> TempTargetRecord {
        var record = record
        try await (pool ?? Self.pool).write { db in
            if record.isPreset {
                let count = try TempTargetRecord
                    .filter(TempTargetRecord.Columns.isPreset == true)
                    .fetchCount(db)
                record.orderPosition = count + 1
            }
            try record.insert(db)
        }
        return record
    }

    /// Copies a running preset into a fresh non-preset temp target (so editing it doesn't mutate the
    /// preset). `isUploadedToNS` is set true to avoid a duplicate Nightscout entry; `halfBasalTarget`
    /// is kept only if it differs from the HBT default (160). Returns the inserted copy. Mirrors the
    /// former `@MainActor copyRunningTempTarget`.
    static func copyRunning(_ source: TempTargetRecord) async throws -> TempTargetRecord {
        var copy = TempTargetRecord(
            id: source.id,
            name: source.name,
            date: source.date,
            enabled: source.enabled,
            isPreset: false,
            isUploadedToNS: true,
            orderPosition: 0,
            enteredBy: nil,
            duration: source.duration,
            target: source.target,
            halfBasalTarget: source.halfBasalTarget != 160 ? source.halfBasalTarget : nil
        )
        try await pool.write { db in try copy.insert(db) }
        return copy
    }

    /// Updates an existing temp target (enable/disable, re-date, mark uploaded, …).
    static func update(_ record: TempTargetRecord) async throws {
        try await pool.write { db in try record.update(db) }
    }

    /// Marks a set of temp targets (by `pk`) as disabled in a single transaction.
    static func disable(pks: [Int64]) async throws {
        guard !pks.isEmpty else { return }
        _ = try await pool.write { db in
            try TempTargetRecord
                .filter(keys: pks)
                .updateAll(db, TempTargetRecord.Columns.enabled.set(to: false))
        }
    }

    static func delete(pk: Int64, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in try TempTargetRecord.deleteOne(db, key: pk) }
    }

    /// Marks temp targets (by business `id`) as uploaded to Nightscout, in one transaction.
    static func markUploaded(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await pool.write { db in
            try TempTargetRecord
                .filter(strings.contains(TempTargetRecord.Columns.id))
                .updateAll(db, TempTargetRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Persists `orderPosition` for a reordered preset list (array order = new positions, 1-based).
    static func reorder(_ presets: [TempTargetRecord]) async throws {
        try await pool.write { db in
            for (index, preset) in presets.enumerated() {
                guard let pk = preset.pk else { continue }
                try TempTargetRecord
                    .filter(key: pk)
                    .updateAll(db, TempTargetRecord.Columns.orderPosition.set(to: index + 1))
            }
        }
    }

    /// Deletes temp targets older than `days`, preserving presets (mirrors the
    /// `batchDeleteOlderThan(TempTargetStored, isPresetKey:)` cleanup).
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.date < cutoff)
                .filter(TempTargetRecord.Columns.isPreset == false)
                .deleteAll(db)
        }
    }

    // MARK: Observation

    /// Reactive feed for the Home main chart — replaces the `tempTargetController` FRC. Tracks the
    /// whole table (low volume, keeps the region deterministic); the subscriber applies the
    /// active-or-future rule via `TempTargetRecord.isOnMainChart`.
    static func observeForMainChart() -> AnyPublisher<[TempTargetRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRecord
                .order(TempTargetRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed of all presets, ordered by `orderPosition` — replaces preset-list refreshes.
    static func observePresets() -> AnyPublisher<[TempTargetRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.isPreset == true)
                .order(TempTargetRecord.Columns.orderPosition)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed of scheduled (future-dated) temp targets — replaces
    /// `setupScheduledTempTargetsArray`. Tracks disabled rows; the subscriber applies the
    /// `date > now` rule so the tracked region stays deterministic.
    static func observeScheduled() -> AnyPublisher<[TempTargetRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.enabled == false)
                .order(TempTargetRecord.Columns.date.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits the latest temp-target row (any state) on every change — drives the LiveActivity reload,
    /// replacing the `coreDataPublisher.filteredByEntityName("TempTargetStored")` sink.
    static func observeLatest() -> AnyPublisher<TempTargetRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRecord
                .order(TempTargetRecord.Columns.date.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed that emits whenever the not-yet-uploaded temp-target set changes — replaces the
    /// Nightscout upload FRC. Emits the count; subscriber triggers an upload.
    static func observeNotYetUploadedCount() -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRecord
                .filter(TempTargetRecord.Columns.isUploadedToNS == false)
                .fetchCount(db)
        }
        // Only emit on an actual count change so an unrelated write does not re-trigger an upload.
        return observation.publisher(in: pool).removeDuplicates().eraseToAnyPublisher()
    }
}

// MARK: - TempTargetRunStore

/// Typed data-access API for temp-target runs. Replaces the Core Data code in
/// `BaseTempTargetsStorage` (run creation + Nightscout fetches), the Home `tempTargetRunController`
/// FRC, and the `HistoryRootView` `@FetchRequest`.
enum TempTargetRunStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// Inserts a run, linking it to its source temp target via `tempTargetPk`.
    @discardableResult static func saveRun(_ record: TempTargetRunRecord) async throws -> TempTargetRunRecord {
        var record = record
        try await pool.write { db in try record.insert(db) }
        return record
    }

    /// Runs started within the last day, newest first.
    static func fetchRecent() async throws -> [TempTargetRunRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try TempTargetRunRecord
                .filter(TempTargetRunRecord.Columns.startDate >= cutoff)
                .order(TempTargetRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
    }

    /// Runs not yet uploaded to Nightscout, newest first.
    static func fetchNotYetUploaded() async throws -> [TempTargetRunRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try TempTargetRunRecord
                .filter(TempTargetRunRecord.Columns.startDate >= cutoff)
                .filter(TempTargetRunRecord.Columns.isUploadedToNS == false)
                .order(TempTargetRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
    }

    static func update(_ record: TempTargetRunRecord) async throws {
        try await pool.write { db in try record.update(db) }
    }

    /// Marks runs (by business `id`) as uploaded to Nightscout, in one transaction.
    static func markUploaded(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await pool.write { db in
            try TempTargetRunRecord
                .filter(strings.contains(Column("id")))
                .updateAll(db, TempTargetRunRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Resolves the source temp target for a run, via the `tempTargetPk` foreign key. The Nightscout
    /// run upload needs the source's `enteredBy`/`name`/`date` (Override only needed `date`).
    static func sourceTempTarget(for run: TempTargetRunRecord) async throws -> TempTargetRecord? {
        guard let tempTargetPk = run.tempTargetPk else { return nil }
        return try await pool.read { db in
            try TempTargetRecord.fetchOne(db, key: tempTargetPk)
        }
    }

    /// Reactive feed that emits whenever the not-yet-uploaded run set changes — replaces the
    /// Nightscout run upload FRC. Emits the count; subscriber triggers an upload.
    static func observeNotYetUploadedCount() -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRunRecord
                .filter(TempTargetRunRecord.Columns.isUploadedToNS == false)
                .fetchCount(db)
        }
        // Only emit on an actual count change so an unrelated write does not re-trigger an upload.
        return observation.publisher(in: pool).removeDuplicates().eraseToAnyPublisher()
    }

    /// Deletes runs older than `days` (periodic cleanup, mirrors the Core Data batch delete).
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try TempTargetRunRecord
                .filter(TempTargetRunRecord.Columns.startDate < cutoff)
                .deleteAll(db)
        }
    }

    /// Reactive feed of recent runs (newest first) — replaces the Home `tempTargetRunController` FRC
    /// and the `HistoryRootView` `@FetchRequest`. The "startDate >= oneDayAgo" rule is applied by the
    /// subscriber to keep the tracked region deterministic.
    static func observeRecent() -> AnyPublisher<[TempTargetRunRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try TempTargetRunRecord
                .order(TempTargetRunRecord.Columns.startDate.desc)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
