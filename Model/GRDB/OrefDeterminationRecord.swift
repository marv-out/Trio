import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `OrefDetermination` entity (the result of every
/// `determineBasal` run — the dosing decision plus its forecast curves).
///
/// The first **hot-path** family to migrate (see `MIGRATION.md`, Step 10) and the deepest
/// relationship graph: `OrefDetermination —(1:n)→ Forecast —(1:n)→ ForecastValue`. The 20
/// Decimals are stored as TEXT and converted here, so exact values are preserved (no Double
/// rounding) — same pattern as `TDDRecord`/`OverrideRecord`. `id` is the business UUID (string
/// form); `pk` is the synthetic rowid and replaces `NSManagedObjectID` for cross-thread identity.
struct OrefDeterminationRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "orefDeterminationStored"

    var pk: Int64?
    var id: UUID?
    var deliverAt: Date?
    var timestamp: Date?
    var timestampEnacted: Date?
    var enacted: Bool
    var received: Bool
    var isUploadedToNS: Bool
    var cob: Int16
    var carbsRequired: Int16
    var reason: String?
    var temp: String?
    // Decimals, stored as TEXT (lossless).
    var bolus: Decimal?
    var carbRatio: Decimal?
    var currentTarget: Decimal?
    var duration: Decimal?
    var eventualBG: Decimal?
    var expectedDelta: Decimal?
    var glucose: Decimal?
    var insulinForManualBolus: Decimal?
    var insulinReq: Decimal?
    var insulinSensitivity: Decimal?
    var iob: Decimal?
    var manualBolusErrorString: Decimal?
    var minDelta: Decimal?
    var rate: Decimal?
    var reservoir: Decimal?
    var scheduledBasal: Decimal?
    var sensitivityRatio: Decimal?
    var smbToDeliver: Decimal?
    var tempBasal: Decimal?
    var threshold: Decimal?

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        deliverAt: Date? = nil,
        timestamp: Date? = nil,
        timestampEnacted: Date? = nil,
        enacted: Bool = false,
        received: Bool = false,
        isUploadedToNS: Bool = false,
        cob: Int16 = 0,
        carbsRequired: Int16 = 0,
        reason: String? = nil,
        temp: String? = nil,
        bolus: Decimal? = nil,
        carbRatio: Decimal? = nil,
        currentTarget: Decimal? = nil,
        duration: Decimal? = nil,
        eventualBG: Decimal? = nil,
        expectedDelta: Decimal? = nil,
        glucose: Decimal? = nil,
        insulinForManualBolus: Decimal? = nil,
        insulinReq: Decimal? = nil,
        insulinSensitivity: Decimal? = nil,
        iob: Decimal? = nil,
        manualBolusErrorString: Decimal? = nil,
        minDelta: Decimal? = nil,
        rate: Decimal? = nil,
        reservoir: Decimal? = nil,
        scheduledBasal: Decimal? = nil,
        sensitivityRatio: Decimal? = nil,
        smbToDeliver: Decimal? = nil,
        tempBasal: Decimal? = nil,
        threshold: Decimal? = nil
    ) {
        self.pk = pk
        self.id = id
        self.deliverAt = deliverAt
        self.timestamp = timestamp
        self.timestampEnacted = timestampEnacted
        self.enacted = enacted
        self.received = received
        self.isUploadedToNS = isUploadedToNS
        self.cob = cob
        self.carbsRequired = carbsRequired
        self.reason = reason
        self.temp = temp
        self.bolus = bolus
        self.carbRatio = carbRatio
        self.currentTarget = currentTarget
        self.duration = duration
        self.eventualBG = eventualBG
        self.expectedDelta = expectedDelta
        self.glucose = glucose
        self.insulinForManualBolus = insulinForManualBolus
        self.insulinReq = insulinReq
        self.insulinSensitivity = insulinSensitivity
        self.iob = iob
        self.manualBolusErrorString = manualBolusErrorString
        self.minDelta = minDelta
        self.rate = rate
        self.reservoir = reservoir
        self.scheduledBasal = scheduledBasal
        self.sensitivityRatio = sensitivityRatio
        self.smbToDeliver = smbToDeliver
        self.tempBasal = tempBasal
        self.threshold = threshold
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        deliverAt = row["deliverAt"]
        timestamp = row["timestamp"]
        timestampEnacted = row["timestampEnacted"]
        enacted = row["enacted"]
        received = row["received"]
        isUploadedToNS = row["isUploadedToNS"]
        cob = row["cob"]
        carbsRequired = row["carbsRequired"]
        reason = row["reason"]
        temp = row["temp"]
        bolus = Self.decimal(row["bolus"])
        carbRatio = Self.decimal(row["carbRatio"])
        currentTarget = Self.decimal(row["currentTarget"])
        duration = Self.decimal(row["duration"])
        eventualBG = Self.decimal(row["eventualBG"])
        expectedDelta = Self.decimal(row["expectedDelta"])
        glucose = Self.decimal(row["glucose"])
        insulinForManualBolus = Self.decimal(row["insulinForManualBolus"])
        insulinReq = Self.decimal(row["insulinReq"])
        insulinSensitivity = Self.decimal(row["insulinSensitivity"])
        iob = Self.decimal(row["iob"])
        manualBolusErrorString = Self.decimal(row["manualBolusErrorString"])
        minDelta = Self.decimal(row["minDelta"])
        rate = Self.decimal(row["rate"])
        reservoir = Self.decimal(row["reservoir"])
        scheduledBasal = Self.decimal(row["scheduledBasal"])
        sensitivityRatio = Self.decimal(row["sensitivityRatio"])
        smbToDeliver = Self.decimal(row["smbToDeliver"])
        tempBasal = Self.decimal(row["tempBasal"])
        threshold = Self.decimal(row["threshold"])
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["deliverAt"] = deliverAt
        container["timestamp"] = timestamp
        container["timestampEnacted"] = timestampEnacted
        container["enacted"] = enacted
        container["received"] = received
        container["isUploadedToNS"] = isUploadedToNS
        container["cob"] = cob
        container["carbsRequired"] = carbsRequired
        container["reason"] = reason
        container["temp"] = temp
        container["bolus"] = Self.string(bolus)
        container["carbRatio"] = Self.string(carbRatio)
        container["currentTarget"] = Self.string(currentTarget)
        container["duration"] = Self.string(duration)
        container["eventualBG"] = Self.string(eventualBG)
        container["expectedDelta"] = Self.string(expectedDelta)
        container["glucose"] = Self.string(glucose)
        container["insulinForManualBolus"] = Self.string(insulinForManualBolus)
        container["insulinReq"] = Self.string(insulinReq)
        container["insulinSensitivity"] = Self.string(insulinSensitivity)
        container["iob"] = Self.string(iob)
        container["manualBolusErrorString"] = Self.string(manualBolusErrorString)
        container["minDelta"] = Self.string(minDelta)
        container["rate"] = Self.string(rate)
        container["reservoir"] = Self.string(reservoir)
        container["scheduledBasal"] = Self.string(scheduledBasal)
        container["sensitivityRatio"] = Self.string(sensitivityRatio)
        container["smbToDeliver"] = Self.string(smbToDeliver)
        container["tempBasal"] = Self.string(tempBasal)
        container["threshold"] = Self.string(threshold)
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
        static let deliverAt = Column("deliverAt")
        static let timestamp = Column("timestamp")
        static let enacted = Column("enacted")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let id = Column("id")
    }

    // MARK: - Reason parsing (ported verbatim from the former `OrefDetermination` Core Data helpers)

    var reasonParts: [String] {
        reason?.components(separatedBy: "; ").first?.components(separatedBy: ", ") ?? []
    }

    var reasonConclusion: String {
        reason?.components(separatedBy: "; ").last ?? ""
    }

    var minPredBGFromReason: Decimal? {
        if let minPredBGPart = reasonParts.first(where: { $0.contains("minPredBG") }) {
            let components = minPredBGPart.components(separatedBy: "minPredBG ")
            if let valueComponent = components.dropFirst().first {
                let valueString = valueComponent
                    .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)
                return Decimal(string: valueString)
            }
        }
        return nil
    }
}

/// GRDB record replacing the Core Data `Forecast` entity (one prediction curve — `iob`/`zt`/`cob`/`uam`).
///
/// The Core Data `orefDetermination` to-one relationship becomes the `orefDeterminationPk` foreign
/// key referencing `OrefDeterminationRecord.pk`. The FK is **nullable**: the bolus-preview path
/// (`OpenAPS.processAndSave`/`createForecast`) creates *orphan* forecasts with no determination.
/// `ON DELETE CASCADE` — deleting a determination wipes its forecasts (and transitively their values).
struct ForecastRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "forecastStored"

    var pk: Int64?
    var id: UUID?
    var type: String?
    var date: Date?
    var orefDeterminationPk: Int64?

    init(
        pk: Int64? = nil,
        id: UUID? = nil,
        type: String? = nil,
        date: Date? = nil,
        orefDeterminationPk: Int64? = nil
    ) {
        self.pk = pk
        self.id = id
        self.type = type
        self.date = date
        self.orefDeterminationPk = orefDeterminationPk
    }

    init(row: Row) {
        pk = row["pk"]
        id = (row["id"] as String?).flatMap { UUID(uuidString: $0) }
        type = row["type"]
        date = row["date"]
        orefDeterminationPk = row["orefDeterminationPk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id?.uuidString
        container["type"] = type
        container["date"] = date
        container["orefDeterminationPk"] = orefDeterminationPk
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let date = Column("date")
        static let type = Column("type")
        static let orefDeterminationPk = Column("orefDeterminationPk")
    }
}

/// GRDB record replacing the Core Data `ForecastValue` entity (a single point on a forecast curve).
///
/// The Core Data `forecast` to-one relationship becomes the `forecastPk` foreign key referencing
/// `ForecastRecord.pk`. `ON DELETE CASCADE` — values die with their forecast.
struct ForecastValueRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "forecastValueStored"

    var pk: Int64?
    var index: Int32
    var value: Int32
    var forecastPk: Int64?

    var id: Int64? { pk }

    init(
        pk: Int64? = nil,
        index: Int32 = 0,
        value: Int32 = 0,
        forecastPk: Int64? = nil
    ) {
        self.pk = pk
        self.index = index
        self.value = value
        self.forecastPk = forecastPk
    }

    init(row: Row) {
        pk = row["pk"]
        index = row["index"]
        value = row["value"]
        forecastPk = row["forecastPk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["index"] = index
        container["value"] = value
        container["forecastPk"] = forecastPk
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let index = Column("index")
        static let forecastPk = Column("forecastPk")
    }
}

// MARK: - OrefDeterminationStore

/// Typed data-access API for oref determinations. Replaces the Core Data code in
/// `BaseDeterminationStorage` (fetch/save/enacted/upload), the `enactedDeterminationController` and
/// `determinationController` FRCs in `HomeStateModel`, the `determinationController` in
/// `TreatmentsStateModel`, the Nightscout `determinationUploadController`, and the six
/// `coreDataPublisher.filteredByEntityName("OrefDetermination")` sinks. Records are value types, so
/// the old `NSManagedObjectID` round-tripping is gone — call sites carry `pk`/`id` instead.
///
/// This is the first **hot-path** store: `store(_:forecasts:)` runs at the end of every
/// `determineBasal` and writes the determination *and* its whole forecast tree in a single
/// transaction, so the dosing decision is never split across writes.
enum OrefDeterminationStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// A forecast curve to persist alongside a determination (one of iob/zt/cob/uam).
    struct ForecastInput {
        let type: String
        let date: Date
        let values: [Int]
    }

    // MARK: Fetches

    /// The most recent determination within a `minutes`-wide window, newest `deliverAt` first.
    /// Replaces `fetchLastDeterminationObjectID(predicate:)` for both determination predicates:
    /// - `enactedOnly == false` mirrors `predicateFor30MinAgoForDetermination` (`deliverAt >= cutoff`).
    /// - `enactedOnly == true` mirrors `enactedDetermination` (`enacted == true AND timestamp >= cutoff`).
    static func fetchLast(
        within minutes: Int = 30,
        enactedOnly: Bool = false,
        pool: DatabasePool? = nil
    ) async throws -> OrefDeterminationRecord? {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return try await (pool ?? Self.pool).read { db in
            var request = OrefDeterminationRecord.all()
            if enactedOnly {
                request = request
                    .filter(OrefDeterminationRecord.Columns.enacted == true)
                    .filter(OrefDeterminationRecord.Columns.timestamp >= cutoff)
            } else {
                request = request.filter(OrefDeterminationRecord.Columns.deliverAt >= cutoff)
            }
            return try request.order(OrefDeterminationRecord.Columns.deliverAt.desc).fetchOne(db)
        }
    }

    /// All determinations within a `minutes`-wide window, newest `deliverAt` first (no limit).
    /// Replaces `GarminManager.fetchDeterminations30Min` (which fetched the whole 30-min window).
    static func fetchRecent(within minutes: Int = 30) async throws -> [OrefDeterminationRecord] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return try await pool.read { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.deliverAt >= cutoff)
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchAll(db)
        }
    }

    /// All determinations from the last day, newest first (mirrors `determinationsForCobIobCharts`).
    static func fetchForCobIobCharts() async throws -> [OrefDeterminationRecord] {
        let cutoff = Date.oneDayAgo
        return try await pool.read { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.deliverAt >= cutoff)
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchAll(db)
        }
    }

    static func fetch(pk: Int64, pool: DatabasePool? = nil) async throws -> OrefDeterminationRecord? {
        try await (pool ?? Self.pool).read { db in try OrefDeterminationRecord.fetchOne(db, key: pk) }
    }

    /// Synchronous fetch of the newest determination (blocks the caller). Used by the synchronous
    /// IOB lookup (`IOBService.currentIOB`), which mirrors the former `context.performAndWait`.
    static func fetchLatestSync() throws -> OrefDeterminationRecord? {
        try pool.read { db in
            try OrefDeterminationRecord
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchOne(db)
        }
    }

    /// The set of `deliverAt` dates already stored in `[from, to]` — used by `JSONImporter` to
    /// dedupe determinations on import (replaces the Core Data `fetchDates` helper).
    static func existingDates(from: Date, to: Date, pool: DatabasePool? = nil) async throws -> Set<Date> {
        let request = OrefDeterminationRecord
            .filter(OrefDeterminationRecord.Columns.deliverAt >= from && OrefDeterminationRecord.Columns.deliverAt <= to)
            .select(OrefDeterminationRecord.Columns.deliverAt, as: Date?.self)
        let dates = try await (pool ?? Self.pool).read { db in try request.fetchAll(db) }
        return Set(dates.compactMap { $0 })
    }

    /// The newest enacted determination not yet uploaded to Nightscout
    /// (mirrors `enactedDeterminationsNotYetUploadedToNightscout`).
    static func fetchEnactedNotYetUploaded(pool: DatabasePool? = nil) async throws -> OrefDeterminationRecord? {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.deliverAt >= cutoff)
                .filter(OrefDeterminationRecord.Columns.isUploadedToNS == false)
                .filter(OrefDeterminationRecord.Columns.enacted == true)
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchOne(db)
        }
    }

    /// The newest suggested (non-enacted) determination not yet uploaded to Nightscout
    /// (mirrors `suggestedDeterminationsNotYetUploadedToNightscout`; `enacted != true` collapses to
    /// `enacted == false` since the GRDB column is a non-optional Bool defaulting to false).
    static func fetchSuggestedNotYetUploaded(pool: DatabasePool? = nil) async throws -> OrefDeterminationRecord? {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.deliverAt >= cutoff)
                .filter(OrefDeterminationRecord.Columns.isUploadedToNS == false)
                .filter(OrefDeterminationRecord.Columns.enacted == false)
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchOne(db)
        }
    }

    // MARK: Writes

    /// Hot-path write: inserts a determination **and its entire forecast tree** in one transaction.
    /// Reads the determination's assigned `pk` back, links each `ForecastRecord` to it, then links
    /// each `ForecastValueRecord` to its forecast — mirroring the Core Data object graph, but as a
    /// single fast write so the dosing decision is never persisted half-way. Returns the inserted
    /// determination (with its `pk`).
    @discardableResult static func store(
        _ record: OrefDeterminationRecord,
        forecasts: [ForecastInput] = [],
        pool: DatabasePool? = nil
    ) async throws -> OrefDeterminationRecord {
        var record = record
        try await (pool ?? Self.pool).write { db in
            try record.insert(db)
            let determinationPk = record.pk
            for input in forecasts {
                var forecast = ForecastRecord(
                    id: UUID(),
                    type: input.type,
                    date: input.date,
                    orefDeterminationPk: determinationPk
                )
                try forecast.insert(db)
                for (index, value) in input.values.enumerated() {
                    var forecastValue = ForecastValueRecord(
                        index: Int32(index),
                        value: Int32(value),
                        forecastPk: forecast.pk
                    )
                    try forecastValue.insert(db)
                }
            }
        }
        return record
    }

    /// The `reportEnacted` mutation: stamps `timestamp = now`, sets `enacted`, and clears
    /// `isUploadedToNS` so the (now enacted) determination is re-uploaded. Replaces the
    /// `existingObject(with:)` round-trip in `APSManager.reportEnacted`.
    static func updateEnacted(pk: Int64, enacted: Bool) async throws {
        let now = Date()
        _ = try await pool.write { db in
            try OrefDeterminationRecord
                .filter(key: pk)
                .updateAll(
                    db,
                    OrefDeterminationRecord.Columns.timestamp.set(to: now),
                    OrefDeterminationRecord.Columns.enacted.set(to: enacted),
                    OrefDeterminationRecord.Columns.isUploadedToNS.set(to: false)
                )
        }
    }

    /// Marks determinations (by business `id`) as uploaded to Nightscout, in one transaction.
    static func markUploaded(ids: [UUID], pool: DatabasePool? = nil) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        _ = try await (pool ?? Self.pool).write { db in
            try OrefDeterminationRecord
                .filter(strings.contains(OrefDeterminationRecord.Columns.id))
                .updateAll(db, OrefDeterminationRecord.Columns.isUploadedToNS.set(to: true))
        }
    }

    /// Deletes determinations older than `days` (periodic cleanup). Cascades to their forecasts and
    /// (transitively) their forecast values via the `ON DELETE CASCADE` foreign keys.
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.deliverAt < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: Observation

    /// Emits the latest enacted determination on every change — replaces the Home
    /// `enactedDeterminationController` FRC and the LiveActivity/Watch/Calendar/… publisher sinks.
    /// The "timestamp >= halfHourAgo" staleness rule is applied by the subscriber so the tracked
    /// region stays deterministic (no `Date()` inside it).
    static func observeEnacted() -> AnyPublisher<OrefDeterminationRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.enacted == true)
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits the latest determination (any state) on every change — replaces the six
    /// `coreDataPublisher.filteredByEntityName("OrefDetermination")` sinks (IOB, LiveActivity, Watch,
    /// Garmin, Calendar, ContactImage) that fire on *any* new determination, not just enacted ones.
    static func observeLatest() -> AnyPublisher<OrefDeterminationRecord?, Error> {
        let observation = ValueObservation.tracking { db in
            try OrefDeterminationRecord
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .fetchOne(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Reactive feed of recent determinations (newest first) — replaces the Home
    /// `determinationController` FRC (COB/IOB charts). Tracks the newest 500 rows (a deterministic,
    /// bounded region covering >24h at loop cadence); the subscriber applies "deliverAt >= oneDayAgo".
    static func observeForCobIobCharts() -> AnyPublisher<[OrefDeterminationRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try OrefDeterminationRecord
                .order(OrefDeterminationRecord.Columns.deliverAt.desc)
                .limit(500)
                .fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits whenever the not-yet-uploaded determination set changes — replaces the Nightscout
    /// `determinationUploadController` FRC. Emits the count; the subscriber triggers an upload.
    static func observeNotYetUploadedCount() -> AnyPublisher<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try OrefDeterminationRecord
                .filter(OrefDeterminationRecord.Columns.isUploadedToNS == false)
                .fetchCount(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}

// MARK: - ForecastStore

/// Typed data-access API for forecasts and their values. Replaces the entire
/// `fetchForecastHierarchy` → `fetchForecastObjects` → `existingObject` objectID dance (plus the
/// `relationshipKeyPathsForPrefetching` N+1 workaround) with two-level `pk` joins, and the
/// `parseForecastValues` per-type fetch. Orphan forecasts (bolus preview, no determination) go
/// through `storeOrphan`.
enum ForecastStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// The bolus-preview path: inserts forecasts + values with a `nil` determination FK
    /// (mirrors `OpenAPS.processAndSave`/`createForecast`, which create orphan forecasts).
    static func storeOrphan(forecasts: [OrefDeterminationStore.ForecastInput], pool: DatabasePool? = nil) async throws {
        guard !forecasts.isEmpty else { return }
        try await (pool ?? Self.pool).write { db in
            for input in forecasts {
                var forecast = ForecastRecord(id: UUID(), type: input.type, date: input.date, orefDeterminationPk: nil)
                try forecast.insert(db)
                for (index, value) in input.values.enumerated() {
                    var forecastValue = ForecastValueRecord(
                        index: Int32(index),
                        value: Int32(value),
                        forecastPk: forecast.pk
                    )
                    try forecastValue.insert(db)
                }
            }
        }
    }

    /// The whole forecast tree for a determination: each forecast with its values (sorted by
    /// `index`, capped at the first 36 = the first 3h). Replaces `fetchForecastHierarchy`.
    static func fetchHierarchy(
        for determinationPk: Int64,
        pool: DatabasePool? = nil
    ) async throws -> [(forecast: ForecastRecord, values: [ForecastValueRecord])] {
        try await (pool ?? Self.pool).read { db in
            let forecasts = try ForecastRecord
                .filter(ForecastRecord.Columns.orefDeterminationPk == determinationPk)
                .order(ForecastRecord.Columns.type)
                .fetchAll(db)
            return try forecasts.map { forecast in
                let values = try ForecastValueRecord
                    .filter(ForecastValueRecord.Columns.forecastPk == forecast.pk)
                    .order(ForecastValueRecord.Columns.index)
                    .limit(36)
                    .fetchAll(db)
                return (forecast, values)
            }
        }
    }

    /// The values for a single forecast type of a determination, sorted by `index`.
    /// Replaces `parseForecastValues(ofType:from:)`. Returns `[]` if the type is absent.
    static func fetchValues(type: String, for determinationPk: Int64, pool: DatabasePool? = nil) async throws -> [Int] {
        try await (pool ?? Self.pool).read { db in
            guard let forecast = try ForecastRecord
                .filter(ForecastRecord.Columns.orefDeterminationPk == determinationPk)
                .filter(ForecastRecord.Columns.type == type)
                .fetchOne(db)
            else { return [] }
            let values = try ForecastValueRecord
                .filter(ForecastValueRecord.Columns.forecastPk == forecast.pk)
                .order(ForecastValueRecord.Columns.index)
                .fetchAll(db)
            return values.map { Int($0.value) }
        }
    }

    /// Deletes forecasts older than `days` by `date` (mirrors the `Forecast` cleanup). Cascades to
    /// their values via `ON DELETE CASCADE`, so the old parent/child batch-delete helper is gone.
    /// Orphan (bolus-preview) forecasts carry a `date` and are pruned too.
    static func deleteOlderThan(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await pool.write { db in
            try ForecastRecord.filter(ForecastRecord.Columns.date < cutoff).deleteAll(db)
        }
    }
}
