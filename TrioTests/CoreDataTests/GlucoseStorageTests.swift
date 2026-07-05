import CoreData
import Foundation
import GRDB
import Swinject
import Testing

@testable import Trio

@Suite("GlucoseStorage Tests", .serialized) struct GlucoseStorageTests: Injectable {
    @Injected() var storage: GlucoseStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var grdb: GRDBStack!

    init() async throws {
        // Glucose lives in GRDB now: an in-memory pool backs the glucose assertions (exercised through
        // the `in:` seam). A Core Data test context is still needed for the other storages the assembler
        // graph builds.
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()
        grdb = try GRDBStack.makeInMemoryForTests()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    /// The resolved `BaseGlucoseStorage`, used to exercise the store/backfill dedup + clamp through the
    /// storage layer against the in-memory pool via the `in:` seam. Force-cast: the test assembly always
    /// registers `BaseGlucoseStorage`.
    // swiftlint:disable:next force_cast
    private var base: BaseGlucoseStorage { storage as! BaseGlucoseStorage }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        #expect(storage != nil, "GlucoseStorage should be injected")
        #expect(storage is BaseGlucoseStorage, "Storage should be of type BaseGlucoseStorage")
    }

    @Test("Store and retrieve glucose entries") func testStoreAndRetrieveGlucose() async throws {
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 126)
        ]

        try await base.storeGlucose(testGlucose, in: grdb.pool)

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.count == 1, "Should have exactly one entry")
        #expect(stored[0].glucose == 126, "Glucose value should match")
        #expect(stored[0].direction == "Flat", "Direction should match")
        #expect(stored[0].isManual == false, "CGM reading should not be manual")
    }

    @Test("Duplicate readings within the buffer are deduped") func testStoreDedup() async throws {
        let date = Date()
        let reading = [BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: date, glucose: 130)]

        try await base.storeGlucose(reading, in: grdb.pool)
        // Storing the same timestamp again must be filtered out (proximity dedup against DB dates).
        try await base.storeGlucose(reading, in: grdb.pool)

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.count == 1, "Duplicate reading should be deduped")
    }

    @Test("Delete writes a tombstone and removes the reading") func testDeleteWritesTombstone() async throws {
        let record = try await GlucoseStore.store(
            GlucoseRecord(id: UUID(), date: Date(), glucose: 140, isManual: true),
            pool: grdb.pool
        )
        let pk = try #require(record.pk)

        try await GlucoseStore.delete(pk: pk, pool: grdb.pool)

        let remaining = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(remaining.isEmpty, "Should have no entries after deletion")

        let tombstones = try await DeletedGlucoseStore.existingDates(
            from: Date.oneDayAgo,
            to: Date().addingTimeInterval(60),
            pool: grdb.pool
        )
        #expect(!tombstones.isEmpty, "Should have written a deleted-glucose tombstone")
    }

    @Test("A backfilled reading matching a tombstone is not re-ingested") func testBackfillSkipsTombstoned() async throws {
        let backfillDate = Date().addingTimeInterval(-30 * 60)
        // Seed a tombstone for that exact reading.
        try await DeletedGlucoseStore.store(
            DeletedGlucoseRecord(date: backfillDate, glucose: 100, isManualGlucoseEntry: false),
            pool: grdb.pool
        )

        try await base.backfillGlucose(
            [BloodGlucose(direction: BloodGlucose.Direction.flat, date: 456, dateString: backfillDate, glucose: 100)],
            in: grdb.pool
        )

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.isEmpty, "A backfilled reading matching a tombstone must not be re-ingested")
    }

    @Test("Get glucose not yet uploaded to Nightscout") func testGetGlucoseNotYetUploaded() async throws {
        try await base.storeGlucose(
            [BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 160)],
            in: grdb.pool
        )

        let notUploaded = try await GlucoseStore.fetchNotYetUploaded(channel: .nightscout, pool: grdb.pool)
        #expect(!notUploaded.isEmpty, "Should have entries not uploaded to NS")
        #expect(notUploaded[0].glucose == 160, "Glucose value should match")
        #expect(notUploaded[0].isUploadedToNS == false, "Freshly stored reading is not yet uploaded")
    }

    @Test("Mark uploaded flips the channel flag") func testMarkUploaded() async throws {
        let record = try await GlucoseStore.store(
            GlucoseRecord(id: UUID(), date: Date(), glucose: 155),
            pool: grdb.pool
        )
        let id = try #require(record.id)

        try await GlucoseStore.markUploaded(channel: .nightscout, ids: [id.uuidString], pool: grdb.pool)

        let notUploaded = try await GlucoseStore.fetchNotYetUploaded(channel: .nightscout, pool: grdb.pool)
        #expect(notUploaded.isEmpty, "Reading should be marked uploaded to NS")
    }

    @Test("Sub-39 glucose is clamped to 39 on storeGlucose") func testStoreGlucoseClampsBelowMinimum() async throws {
        // A CGM reading below the 39 mg/dL floor (e.g. LibreTransmitter delivering 23)
        try await base.storeGlucose(
            [BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 23)],
            in: grdb.pool
        )

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.count == 1, "Should have stored one reading")
        #expect(stored[0].glucose == 39, "Sub-39 glucose should be clamped to 39, not stored raw")
    }

    @Test("Sub-39 glucose is clamped to 39 on backfillGlucose") func testBackfillGlucoseClampsBelowMinimum() async throws {
        let backfillDate = Date().addingTimeInterval(-30 * 60)
        try await base.backfillGlucose(
            [BloodGlucose(direction: BloodGlucose.Direction.flat, date: 456, dateString: backfillDate, glucose: 28)],
            in: grdb.pool
        )

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.count == 1, "Should have stored one backfilled reading")
        #expect(stored[0].glucose == 39, "Sub-39 backfilled glucose should be clamped to 39")
    }

    @Test("Smoothed glucose round-trips as a lossless Decimal") func testSmoothedGlucoseRoundTrip() async throws {
        let record = try await GlucoseStore.store(
            GlucoseRecord(id: UUID(), date: Date(), glucose: 120),
            pool: grdb.pool
        )
        let pk = try #require(record.pk)

        try await GlucoseStore.updateSmoothed([(pk: pk, value: Decimal(118))], pool: grdb.pool)

        let stored = try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, pool: grdb.pool)
        #expect(stored.first?.smoothedGlucose == Decimal(118), "Smoothed glucose should round-trip exactly")
    }
}
