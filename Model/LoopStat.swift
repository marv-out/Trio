import Foundation
import GRDB

/// GRDB record replacing the Core Data `LoopStatRecord` entity.
///
/// A plain value type: `Sendable`, freely passed across threads, no faulting, no
/// `NSManagedObjectID` round-trips. Field names and optionality match the former Core
/// Data attributes so call sites and the stats math stay unchanged.
struct LoopStat: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "loopStatRecord"

    /// Synthetic rowid primary key (the Core Data entity had no id).
    var id: Int64?
    var start: Date?
    var end: Date?
    var loopStatus: String?
    var duration: Double = 0
    var interval: Double = 0

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum Columns {
        static let start = Column("start")
        static let end = Column("end")
        static let interval = Column("interval")
        static let loopStatus = Column("loopStatus")
    }
}

// MARK: - Store

/// Typed data-access API for loop statistics. Replaces the Core Data fetch/save code that
/// was scattered across `APSManager` and `StatStateModel`. All methods are async and run on
/// the database pool — no `perform` blocks, no contexts.
enum LoopStatStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// Persists one completed loop cycle.
    static func save(_ stat: LoopStat) async throws {
        var stat = stat
        try await pool.write { db in
            try stat.insert(db)
        }
    }

    /// `end` date of the most recently finished loop, used to compute the loop interval.
    static func lastEnd() async throws -> Date? {
        try await pool.read { db in
            try LoopStat
                .order(LoopStat.Columns.end.desc)
                .fetchOne(db)?
                .end
        }
    }

    /// Loops with a real interval since `date`, newest first — feeds the 24h loop-cycle stats.
    static func forCycleStats(since date: Date) async throws -> [LoopStat] {
        try await pool.read { db in
            try LoopStat
                .filter(LoopStat.Columns.interval > 0 && LoopStat.Columns.start > date)
                .order(LoopStat.Columns.start.desc)
                .fetchAll(db)
        }
    }

    /// All loops since `date`, newest first — feeds the Stat screen's loop charts.
    static func all(since date: Date) async throws -> [LoopStat] {
        try await pool.read { db in
            try LoopStat
                .filter(LoopStat.Columns.start > date)
                .order(LoopStat.Columns.start.desc)
                .fetchAll(db)
        }
    }
}
