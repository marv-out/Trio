import Foundation
import GRDB

/// Central access point for Trio's GRDB-backed SQLite store.
///
/// This is the GRDB counterpart to `CoreDataStack`. During the staged Core Data → GRDB
/// migration both stacks coexist: an entity lives in *either* Core Data *or* GRDB, never
/// both. `LoopStatRecord` is the first entity to move (see `MIGRATION.md`).
///
/// Threading model — deliberately different from Core Data:
/// - A single `DatabasePool` serializes all writes and allows concurrent reads (WAL).
/// - Records are value types (`struct`), so they are `Sendable` and cross thread
///   boundaries freely. None of Core Data's `NSManagedObjectID`-passing / per-context
///   confinement is needed here.
final class GRDBStack {
    static let shared = GRDBStack()

    /// The database connection. `nil` until `bootstrap()` has run successfully.
    /// Reads/writes go through `pool` (see accessor) which fatalErrors if used before bootstrap —
    /// callers must not touch the store before app startup has initialized it.
    private(set) var dbPool: DatabasePool?

    private let inMemory: Bool

    private init(inMemory: Bool = false) {
        self.inMemory = inMemory
    }

    /// The live pool, or a fatalError if accessed before `bootstrap()`.
    /// Stores expose async APIs that call this, so misuse surfaces immediately in development.
    var pool: DatabasePool {
        guard let dbPool else {
            fatalError("GRDBStack accessed before bootstrap(). Call GRDBStack.shared.bootstrap() at app startup.")
        }
        return dbPool
    }

    // MARK: - Lifecycle

    /// Opens the database, runs schema migrations, and performs one-time data migrations
    /// from Core Data. Call once at app startup, *after* `CoreDataStack.initializeStack()`
    /// (the Core Data store must be readable for the data migration step).
    func bootstrap() async throws {
        guard dbPool == nil else { return }

        let pool = try Self.makePool(inMemory: inMemory)
        try Self.migrator.migrate(pool)
        dbPool = pool
        debug(.coreData, "GRDB stack initialized at \(Self.databaseURL().path)")

        // One-time Core Data → GRDB data migrations for already-moved entities.
        try await LoopStatMigration.migrateIfNeeded(into: self)
    }

    // MARK: - Connection

    private static func makePool(inMemory: Bool) throws -> DatabasePool {
        var config = Configuration()
        // Keep SQL out of logs in production; flip on for local debugging.
        config.prepareDatabase { db in
            #if DEBUG
                db.trace { debug(.coreData, "SQL: \($0.description)") }
            #endif
        }

        if inMemory {
            // DatabasePool requires a file path; tests use a temp file under the cache dir.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("trio-grdb-test-\(UUID().uuidString).sqlite")
            return try DatabasePool(path: tmp.path, configuration: config)
        }

        let url = databaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try DatabasePool(path: url.path, configuration: config)
    }

    /// Database file location. Prefers the shared App Group container so that extensions
    /// (widgets, Live Activities) can read the same store — mirroring how Core Data's
    /// persistent store is shared today. Falls back to Application Support if no group is set.
    static func databaseURL() -> URL {
        let fileName = "TrioGRDB.sqlite"
        if let suiteName = Bundle.main.appGroupSuiteName,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        {
            return container.appendingPathComponent("GRDB/\(fileName)")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("GRDB/\(fileName)")
    }

    // MARK: - Test support

    static func makeInMemoryForTests() throws -> GRDBStack {
        let stack = GRDBStack(inMemory: true)
        let pool = try makePool(inMemory: true)
        try migrator.migrate(pool)
        stack.dbPool = pool
        return stack
    }
}
