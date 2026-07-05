import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `PumpEventStored` entity (every bolus / temp basal / suspend /
/// resume / rewind / prime / alarm / site-change the pump reports).
///
/// The **dosing path** (see `MIGRATION.md`, Step 11) — highest risk of the whole migration: this table
/// feeds the oref `pumphistory` every loop cycle and drives IOB/TDD math plus three upload channels.
/// The parent carries no Decimals, so persistence is a straight manual `Row`/`PersistenceContainer`
/// mapping (like the other records). `id` is the business **String** UUID (unique — mirrors the Core
/// Data uniqueness constraint on `id`); `pk` is the synthetic rowid and replaces `NSManagedObjectID`
/// for cross-thread identity. The `(timestamp, type)` composite uniqueness constraint (the batched
/// de-dup backstop) is enforced by a composite unique index in the schema.
struct PumpEventRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "pumpEventStored"

    var pk: Int64?
    var id: String?
    var timestamp: Date?
    var type: String?
    var note: String?
    var isUploadedToNS: Bool
    var isUploadedToHealth: Bool
    var isUploadedToTidepool: Bool

    init(
        pk: Int64? = nil,
        id: String? = nil,
        timestamp: Date? = nil,
        type: String? = nil,
        note: String? = nil,
        isUploadedToNS: Bool = false,
        isUploadedToHealth: Bool = false,
        isUploadedToTidepool: Bool = false
    ) {
        self.pk = pk
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.note = note
        self.isUploadedToNS = isUploadedToNS
        self.isUploadedToHealth = isUploadedToHealth
        self.isUploadedToTidepool = isUploadedToTidepool
    }

    init(row: Row) {
        pk = row["pk"]
        id = row["id"]
        timestamp = row["timestamp"]
        type = row["type"]
        note = row["note"]
        isUploadedToNS = row["isUploadedToNS"]
        isUploadedToHealth = row["isUploadedToHealth"]
        isUploadedToTidepool = row["isUploadedToTidepool"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["id"] = id
        container["timestamp"] = timestamp
        container["type"] = type
        container["note"] = note
        container["isUploadedToNS"] = isUploadedToNS
        container["isUploadedToHealth"] = isUploadedToHealth
        container["isUploadedToTidepool"] = isUploadedToTidepool
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let timestamp = Column("timestamp")
        static let type = Column("type")
        static let id = Column("id")
        static let isUploadedToNS = Column("isUploadedToNS")
        static let isUploadedToHealth = Column("isUploadedToHealth")
        static let isUploadedToTidepool = Column("isUploadedToTidepool")
    }
}

/// GRDB record replacing the Core Data `BolusStored` entity (an optional 1:1 child of a pump event).
///
/// The Core Data `pumpEvent` to-one relationship becomes the `pumpEventPk` foreign key referencing
/// `PumpEventRecord.pk`. `ON DELETE CASCADE` — a bolus has no meaning without its event. `amount` is
/// a Decimal stored as TEXT (lossless), so exact dose values are preserved (same pattern as
/// `TDDRecord`).
struct BolusRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "bolusStored"

    var pk: Int64?
    var amount: Decimal?
    var isSMB: Bool
    var isExternal: Bool
    var pumpEventPk: Int64?

    var id: Int64? { pk }

    init(
        pk: Int64? = nil,
        amount: Decimal? = nil,
        isSMB: Bool = false,
        isExternal: Bool = false,
        pumpEventPk: Int64? = nil
    ) {
        self.pk = pk
        self.amount = amount
        self.isSMB = isSMB
        self.isExternal = isExternal
        self.pumpEventPk = pumpEventPk
    }

    init(row: Row) {
        pk = row["pk"]
        amount = PumpEventDecimal.decimal(row["amount"])
        isSMB = row["isSMB"]
        isExternal = row["isExternal"]
        pumpEventPk = row["pumpEventPk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["amount"] = PumpEventDecimal.string(amount)
        container["isSMB"] = isSMB
        container["isExternal"] = isExternal
        container["pumpEventPk"] = pumpEventPk
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let isExternal = Column("isExternal")
        static let pumpEventPk = Column("pumpEventPk")
    }
}

/// GRDB record replacing the Core Data `TempBasalStored` entity (an optional 1:1 child of a pump event).
///
/// The Core Data `pumpEvent` to-one relationship becomes the `pumpEventPk` foreign key referencing
/// `PumpEventRecord.pk`. `ON DELETE CASCADE`. `rate` is a Decimal stored as TEXT (lossless); `duration`
/// is minutes (Int16, mirrors Core Data).
struct TempBasalRecord: FetchableRecord, MutablePersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "tempBasalStored"

    var pk: Int64?
    var duration: Int16
    var rate: Decimal?
    var tempType: String?
    var pumpEventPk: Int64?

    var id: Int64? { pk }

    init(
        pk: Int64? = nil,
        duration: Int16 = 0,
        rate: Decimal? = nil,
        tempType: String? = nil,
        pumpEventPk: Int64? = nil
    ) {
        self.pk = pk
        self.duration = duration
        self.rate = rate
        self.tempType = tempType
        self.pumpEventPk = pumpEventPk
    }

    init(row: Row) {
        pk = row["pk"]
        duration = row["duration"]
        rate = PumpEventDecimal.decimal(row["rate"])
        tempType = row["tempType"]
        pumpEventPk = row["pumpEventPk"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["duration"] = duration
        container["rate"] = PumpEventDecimal.string(rate)
        container["tempType"] = tempType
        container["pumpEventPk"] = pumpEventPk
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let pumpEventPk = Column("pumpEventPk")
    }
}

// Decimal <-> TEXT, non-localized (always '.'), lossless — shared by the pump child records.
private enum PumpEventDecimal {
    static func string(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    static func decimal(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }
}

// MARK: - PumpEventDetails

/// A pump event joined with its optional bolus / temp-basal child — the value-type equivalent of the
/// Core Data `PumpEventStored` object graph. The stores return this so call sites keep the familiar
/// `event.bolus?.amount` / `event.tempBasal?.rate` shape without an `NSManagedObject` graph. It also
/// carries the oref-JSON DTO helpers ported off `PumpEventStored` (they need the event + its child).
struct PumpEventDetails: Hashable, Identifiable {
    var event: PumpEventRecord
    var bolus: BolusRecord?
    var tempBasal: TempBasalRecord?

    /// Row identity for lists/dedup — the event's `pk` (present for every persisted row).
    var id: Int64 { event.pk ?? -1 }

    // Convenience passthroughs mirroring the former `PumpEventStored` accessors used by call sites.
    var timestamp: Date? { event.timestamp }
    var type: String? { event.type }
    var note: String? { event.note }

    // MARK: - oref-JSON DTO helpers (ported verbatim from `PumpEventStored`, `PumpEvent+helper.swift`)

    //
    // The `EventType`/`TempType` enums, the `dateFormatter`, and the `*DTO`/`PumpEventDTO` structs stay
    // on `PumpEventStored` (still used elsewhere); only the mapping moves here, reading off the records.

    func toBolusDTOEnum() -> PumpEventDTO? {
        guard let timestamp = event.timestamp, let bolus = bolus, let amount = bolus.amount else {
            return nil
        }

        let bolusDTO = BolusDTO(
            id: event.id ?? UUID().uuidString,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp),
            amount: NSDecimalNumber(decimal: amount).doubleValue,
            isExternal: bolus.isExternal,
            isSMB: bolus.isSMB,
            duration: 0
        )
        return .bolus(bolusDTO)
    }

    func toTempBasalDTOEnum() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let tempBasal = tempBasal, let rate = tempBasal.rate
        else {
            return nil
        }

        let tempBasalDTO = TempBasalDTO(
            id: "_\(id)",
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp),
            temp: tempBasal.tempType ?? "unknown",
            rate: NSDecimalNumber(decimal: rate).doubleValue
        )
        return .tempBasal(tempBasalDTO)
    }

    func toTempBasalDurationDTOEnum() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let tempBasal = tempBasal else {
            return nil
        }

        let tempBasalDurationDTO = TempBasalDurationDTO(
            id: id,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp),
            duration: Int(tempBasal.duration)
        )
        return .tempBasalDuration(tempBasalDurationDTO)
    }

    func toPumpSuspendDTO() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let type = event.type,
              type == PumpEventStored.EventType.pumpSuspend.rawValue
        else {
            return nil
        }

        let suspendDTO = SuspendDTO(
            id: id,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp)
        )
        return .suspend(suspendDTO)
    }

    func toPumpResumeDTO() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let type = event.type,
              type == PumpEventStored.EventType.pumpResume.rawValue
        else {
            return nil
        }

        let resumeDTO = ResumeDTO(
            id: id,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp)
        )
        return .resume(resumeDTO)
    }

    func toRewindDTO() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let type = event.type,
              type == PumpEventStored.EventType.rewind.rawValue
        else {
            return nil
        }

        let rewindDTO = RewindDTO(
            id: id,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp)
        )
        return .rewind(rewindDTO)
    }

    func toPrimeDTO() -> PumpEventDTO? {
        guard let id = event.id, let timestamp = event.timestamp, let type = event.type,
              type == PumpEventStored.EventType.prime.rawValue
        else {
            return nil
        }

        let primeDTO = PrimeDTO(
            id: id,
            timestamp: PumpEventStored.dateFormatter.string(from: timestamp)
        )
        return .prime(primeDTO)
    }
}

// MARK: - PumpEventStore

/// Typed data-access API for the pump-event family (event + its optional bolus / temp-basal child).
/// Replaces the Core Data code in `BasePumpHistoryStorage`, the `insulinController`/`lastBolusController`
/// FRCs (Home, Treatments), the oref read path in `OpenAPS`, `APSManager.fetchCurrentTempBasal`, the
/// three upload FRCs (Nightscout / Health / Tidepool), the Stat fetches, `BolusSafetyValidator`, and the
/// Watch/Garmin sinks. Records are value types, so the old `NSManagedObjectID` round-tripping is gone —
/// call sites carry `pk` (Int64) or the business `id` (String).
///
/// This is the **dosing path** (highest risk): reads feed the oref `pumphistory` every loop cycle and
/// IOB/TDD math; writes record every delivered bolus / temp basal. Reads return `PumpEventDetails`
/// (the event joined with its child), resolved via the `pumpEventPk` foreign key.
enum PumpEventStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    typealias EventType = PumpEventStored.EventType

    /// Which upload channel a not-yet-uploaded fetch / mark / observation targets.
    enum UploadChannel {
        case nightscout
        case health
        case tidepool

        var column: Column {
            switch self {
            case .nightscout: return PumpEventRecord.Columns.isUploadedToNS
            case .health: return PumpEventRecord.Columns.isUploadedToHealth
            case .tidepool: return PumpEventRecord.Columns.isUploadedToTidepool
            }
        }

        var setter: ColumnAssignment {
            switch self {
            case .nightscout: return PumpEventRecord.Columns.isUploadedToNS.set(to: true)
            case .health: return PumpEventRecord.Columns.isUploadedToHealth.set(to: true)
            case .tidepool: return PumpEventRecord.Columns.isUploadedToTidepool.set(to: true)
            }
        }
    }

    // MARK: Detail resolution (event + child)

    /// Batch-loads the bolus / temp-basal children for `events` and zips them into `PumpEventDetails`,
    /// preserving the input order. One query per child table (no N+1). The child FK is `pumpEventPk`.
    private static func loadDetails(_ events: [PumpEventRecord], _ db: Database) throws -> [PumpEventDetails] {
        let pks = events.compactMap(\.pk)
        guard !pks.isEmpty else { return events.map { PumpEventDetails(event: $0) } }

        let boluses = try BolusRecord.filter(pks.contains(BolusRecord.Columns.pumpEventPk)).fetchAll(db)
        let tempBasals = try TempBasalRecord.filter(pks.contains(TempBasalRecord.Columns.pumpEventPk)).fetchAll(db)

        var bolusByPk: [Int64: BolusRecord] = [:]
        for bolus in boluses { if let p = bolus.pumpEventPk { bolusByPk[p] = bolus } }
        var tempBasalByPk: [Int64: TempBasalRecord] = [:]
        for tempBasal in tempBasals { if let p = tempBasal.pumpEventPk { tempBasalByPk[p] = tempBasal } }

        return events.map { event in
            PumpEventDetails(
                event: event,
                bolus: event.pk.flatMap { bolusByPk[$0] },
                tempBasal: event.pk.flatMap { tempBasalByPk[$0] }
            )
        }
    }

    // MARK: Fetches

    /// Pump history within the last `hours`, newest first, capped at `limit`. Replaces `getPumpHistory`
    /// (`pumpHistoryLast24h`, limit 288) and the Home/History 24h fetches.
    static func fetchHistory(
        within hours: Int = 24,
        limit: Int? = 288,
        pool: DatabasePool? = nil
    ) async throws -> [PumpEventDetails] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return try await (pool ?? Self.pool).read { db in
            var request = PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .order(PumpEventRecord.Columns.timestamp.desc)
            if let limit { request = request.limit(limit) }
            return try loadDetails(request.fetchAll(db), db)
        }
    }

    /// The oref read window (`pumpHistoryLast1440Minutes` = 24h), newest first. Replaces
    /// `OpenAPS.fetchPumpHistoryObjectIDs` (the objectID list is gone — details cross threads directly).
    static func fetchForOref(within minutes: Int = 1440, pool: DatabasePool? = nil) async throws -> [PumpEventDetails] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return try await (pool ?? Self.pool).read { db in
            let events = try PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .order(PumpEventRecord.Columns.timestamp.desc)
                .fetchAll(db)
            return try loadDetails(events, db)
        }
    }

    /// Lightweight suspend/resume rows in the last `hours` (`pumpHistoryLast48h`), **ascending** by
    /// timestamp — the input to the cold-start orphaned-resume filter (issue #898). Returns only
    /// `(pk, type, timestamp)` so the filter can key on `pk` (replaces the `objectID` keying) without
    /// materializing whole events.
    static func fetchOrphanedResumeRows(
        within hours: Int = 48,
        pool: DatabasePool? = nil
    ) async throws -> [(pk: Int64, type: String?, timestamp: Date?)] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let suspend = EventType.pumpSuspend.rawValue
        let resume = EventType.pumpResume.rawValue
        return try await (pool ?? Self.pool).read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT pk, type, timestamp FROM \(PumpEventRecord.databaseTableName)
                WHERE timestamp >= ? AND (type = ? OR type = ?)
                ORDER BY timestamp ASC
                """,
                arguments: [cutoff, suspend, resume]
            )
            return rows.map { (pk: $0["pk"], type: $0["type"], timestamp: $0["timestamp"]) }
        }
    }

    /// The most recent temp-basal event within 20 minutes (`recentPumpHistory`), or `nil`. Replaces
    /// `APSManager.fetchCurrentTempBasal`'s fetch (the delta / `max(0, duration - delta)` math stays in
    /// `APSManager`, reading `tempBasal.duration`/`rate` off the record).
    static func fetchRecentTempBasal(pool: DatabasePool? = nil) async throws -> PumpEventDetails? {
        let cutoff = Date.twentyMinutesAgo
        return try await (pool ?? Self.pool).read { db in
            guard let event = try PumpEventRecord
                .filter(PumpEventRecord.Columns.type == EventType.tempBasal.rawValue)
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .order(PumpEventRecord.Columns.timestamp.desc)
                .fetchOne(db)
            else { return nil }
            return try loadDetails([event], db).first
        }
    }

    /// The most recent **non-external** bolus within 20 minutes (`lastPumpBolus`), or `nil`. The
    /// "not external" filter is on the child, so this loads details and filters in Swift.
    static func fetchLastBolus(pool: DatabasePool? = nil) async throws -> PumpEventDetails? {
        let cutoff = Date.twentyMinutesAgo
        return try await (pool ?? Self.pool).read { db in
            let events = try PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .order(PumpEventRecord.Columns.timestamp.desc)
                .fetchAll(db)
            return try loadDetails(events, db).first { $0.bolus != nil && $0.bolus?.isExternal == false }
        }
    }

    /// Temp-basal events within the last `hours` (`tempBasal != nil AND pumpHistoryLast24h`). Backs the
    /// Health/Tidepool predecessor-duration math (ascending, no limit) and the Garmin `tbrValue`
    /// (descending, limit 1).
    static func fetchTempBasals(
        within hours: Int = 24,
        ascending: Bool = true,
        limit: Int? = nil,
        pool: DatabasePool? = nil
    ) async throws -> [PumpEventDetails] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return try await (pool ?? Self.pool).read { db in
            var request = PumpEventRecord
                .filter(PumpEventRecord.Columns.type == EventType.tempBasal.rawValue)
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .order(ascending ? PumpEventRecord.Columns.timestamp : PumpEventRecord.Columns.timestamp.desc)
            if let limit { request = request.limit(limit) }
            return try loadDetails(request.fetchAll(db), db)
        }
    }

    /// Pump events for the Stat screens (`pumpHistoryForStats`), ascending by timestamp. Optionally
    /// restricted to `types` (bolus, tempBasal, suspend/resume). `from` sets the window start (BolusStats
    /// uses 3 months; TDD a shorter window).
    static func fetchForStats(
        from date: Date,
        types: [String]? = nil,
        pool: DatabasePool? = nil
    ) async throws -> [PumpEventDetails] {
        try await (pool ?? Self.pool).read { db in
            var request = PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp >= date)
                .order(PumpEventRecord.Columns.timestamp)
            if let types { request = request.filter(types.contains(PumpEventRecord.Columns.type)) }
            return try loadDetails(request.fetchAll(db), db)
        }
    }

    /// Events not yet uploaded to `channel` (`timestamp >= oneDayAgo AND isUploadedTo… == false`),
    /// newest first. Replaces the `getPumpHistoryNotYetUploadedTo…` fetches.
    static func fetchNotYetUploaded(channel: UploadChannel, pool: DatabasePool? = nil) async throws -> [PumpEventDetails] {
        let cutoff = Date.oneDayAgo
        return try await (pool ?? Self.pool).read { db in
            let events = try PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp >= cutoff)
                .filter(channel.column == false)
                .order(PumpEventRecord.Columns.timestamp.desc)
                .fetchAll(db)
            return try loadDetails(events, db)
        }
    }

    /// The sum of bolus amounts for `type == bolus AND timestamp > date` — `BolusSafetyValidator`.
    /// Decimals are summed in Swift (stored as TEXT), matching the TDD aggregates.
    static func fetchTotalRecentBolusAmount(since date: Date, pool: DatabasePool? = nil) async throws -> Decimal {
        let details = try await (pool ?? Self.pool).read { db -> [PumpEventDetails] in
            let events = try PumpEventRecord
                .filter(PumpEventRecord.Columns.type == EventType.bolus.rawValue)
                .filter(PumpEventRecord.Columns.timestamp > date)
                .order(PumpEventRecord.Columns.timestamp)
                .fetchAll(db)
            return try loadDetails(events, db)
        }
        return details.reduce(Decimal(0)) { $0 + ($1.bolus?.amount ?? 0) }
    }

    /// The stored event (with its child) matching `(timestamp, type)` exactly, or `nil` — the de-dup
    /// lookup for `storePumpEvents`. The equality is evaluated **in SQLite** on the bound `Date`, so it
    /// uses the same encoding GRDB used to persist the row (millisecond text). This is deliberately not
    /// a Swift-side `Date` comparison: the DB stores timestamps at millisecond precision, so a raw
    /// incoming `Date` with sub-millisecond components would not equal the round-tripped value in Swift,
    /// but *does* match here — mirroring the `(timestamp, type)` composite unique index and preventing a
    /// spurious duplicate insert (which would abort the whole dosing write). Because each insert commits
    /// before the next event is processed, this also catches duplicates *within* the same batch.
    static func fetchExisting(
        timestamp: Date,
        type: String,
        pool: DatabasePool? = nil
    ) async throws -> PumpEventDetails? {
        try await (pool ?? Self.pool).read { db in
            guard let event = try PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp == timestamp)
                .filter(PumpEventRecord.Columns.type == type)
                .fetchOne(db)
            else { return nil }
            return try loadDetails([event], db).first
        }
    }

    /// The `timestamp`s of events within `[from, to]` — the JSON-import dedupe key. `to` is injected
    /// (tests pass a fixed `now`), so the range is explicit rather than relative to the real clock.
    static func existingTimestamps(from: Date, to: Date, pool: DatabasePool? = nil) async throws -> Set<Date> {
        let request = PumpEventRecord
            .filter(PumpEventRecord.Columns.timestamp >= from && PumpEventRecord.Columns.timestamp <= to)
            .select(PumpEventRecord.Columns.timestamp, as: Date?.self)
        let dates = try await (pool ?? Self.pool).read { db in try request.fetchAll(db) }
        return Set(dates.compactMap { $0 })
    }

    /// A single event (with its child) by `pk` — the History deletion path (read `id`/`timestamp`/
    /// `bolus.amount` for the remote-service deletes before `delete(pk:)`).
    static func fetch(pk: Int64, pool: DatabasePool? = nil) async throws -> PumpEventDetails? {
        try await (pool ?? Self.pool).read { db in
            guard let event = try PumpEventRecord.fetchOne(db, key: pk) else { return nil }
            return try loadDetails([event], db).first
        }
    }

    // MARK: Writes

    /// Composite insert in one transaction: inserts the event, reads its assigned `pk`, then links and
    /// inserts the optional bolus / temp-basal child. Returns the inserted event (with its `pk`). The
    /// `(timestamp, type)` composite unique index is the race-safe backstop for the storage-layer dedup.
    @discardableResult static func insert(
        event: PumpEventRecord,
        bolus: BolusRecord? = nil,
        tempBasal: TempBasalRecord? = nil,
        pool: DatabasePool? = nil
    ) async throws -> PumpEventRecord {
        var event = event
        try await (pool ?? Self.pool).write { db in
            try event.insert(db)
            if var bolus {
                bolus.pumpEventPk = event.pk
                try bolus.insert(db)
            }
            if var tempBasal {
                tempBasal.pumpEventPk = event.pk
                try tempBasal.insert(db)
            }
        }
        return event
    }

    /// The partial-bolus update: overwrites the bolus child's `amount`/`isSMB` with the smaller value of
    /// a cancelled/partial bolus, and re-clears the parent's three upload flags (so the corrected dose is
    /// re-uploaded). One transaction. Mirrors the Core Data in-place mutation in `storePumpEvents`.
    static func updateBolusAmount(pk: Int64, amount: Decimal, isSMB: Bool, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in
            try BolusRecord
                .filter(BolusRecord.Columns.pumpEventPk == pk)
                .updateAll(
                    db,
                    Column("amount").set(to: NSDecimalNumber(decimal: amount).stringValue),
                    Column("isSMB").set(to: isSMB)
                )
            try PumpEventRecord
                .filter(key: pk)
                .updateAll(
                    db,
                    PumpEventRecord.Columns.isUploadedToNS.set(to: false),
                    PumpEventRecord.Columns.isUploadedToHealth.set(to: false),
                    PumpEventRecord.Columns.isUploadedToTidepool.set(to: false)
                )
        }
    }

    /// Marks events (by business `id`, String) uploaded to `channel`. All three channels match on the
    /// event `id`.
    static func markUploaded(channel: UploadChannel, ids: [String], pool: DatabasePool? = nil) async throws {
        let ids = ids.compactMap { $0 }
        guard !ids.isEmpty else { return }
        _ = try await (pool ?? Self.pool).write { db in
            try PumpEventRecord
                .filter(ids.contains(PumpEventRecord.Columns.id))
                .updateAll(db, channel.setter)
        }
    }

    /// Deletes an event (and its child via `ON DELETE CASCADE`) by `pk` — the History deletion path.
    static func delete(pk: Int64, pool: DatabasePool? = nil) async throws {
        _ = try await (pool ?? Self.pool).write { db in try PumpEventRecord.deleteOne(db, key: pk) }
    }

    /// Deletes events older than `days` by `timestamp` (periodic cleanup). Cascades to bolus/temp-basal
    /// children via the `ON DELETE CASCADE` foreign keys — the parent/child batch-delete helper is gone.
    static func deleteOlderThan(days: Int, pool: DatabasePool? = nil) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try await (pool ?? Self.pool).write { db in
            try PumpEventRecord
                .filter(PumpEventRecord.Columns.timestamp < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: Observation

    /// Reactive feed for the Home insulin chart / History list — replaces the `insulinController` FRC
    /// (`pumpHistoryLast24h`). Tracks the newest 1000 rows (a bounded, deterministic region covering >24h
    /// of pump activity); the subscriber applies the `timestamp >= oneDayAgo` rule.
    static func observeForChart() -> AnyPublisher<[PumpEventDetails], Error> {
        let observation = ValueObservation.tracking { db -> [PumpEventDetails] in
            let events = try PumpEventRecord
                .order(PumpEventRecord.Columns.timestamp.desc)
                .limit(1000)
                .fetchAll(db)
            return try loadDetails(events, db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits the latest non-external bolus on every change — replaces the `lastBolusController` FRC and
    /// the AppleWatch `PumpEventStored` sink. Scans the newest 100 events (a deterministic bound that
    /// always covers the 20-minute window); the subscriber applies the `timestamp >= 20min` rule.
    static func observeLastBolus() -> AnyPublisher<PumpEventDetails?, Error> {
        let observation = ValueObservation.tracking { db -> PumpEventDetails? in
            let events = try PumpEventRecord
                .order(PumpEventRecord.Columns.timestamp.desc)
                .limit(100)
                .fetchAll(db)
            return try loadDetails(events, db).first { $0.bolus != nil && $0.bolus?.isExternal == false }
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }

    /// Emits whenever the not-yet-uploaded set for `channel` changes — replaces the upload FRCs. Emits
    /// the count; the subscriber triggers an upload.
    static func observeNotYetUploadedCount(channel: UploadChannel) -> AnyPublisher<Int, Error> {
        let column = channel.column
        let observation = ValueObservation.tracking { db in
            try PumpEventRecord.filter(column == false).fetchCount(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
