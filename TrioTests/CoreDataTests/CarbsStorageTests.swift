import CoreData
import Foundation
import GRDB
import Swinject
import Testing

@testable import Trio

@Suite("CarbsStorage Tests", .serialized) struct CarbsStorageTests: Injectable {
    @Injected() var storage: CarbsStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var grdb: GRDBStack!

    init() async throws {
        // Carbs live in GRDB now: an in-memory pool backs the carb assertions. A Core Data test
        // context is still needed for the other storages the assembler graph builds.
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

    /// The resolved `BaseCarbsStorage` (for `settings` injection), used to exercise the FPU split
    /// through the storage layer against the in-memory pool via the `in:` seam. Force-cast: the test
    /// assembly always registers `BaseCarbsStorage`.
    // swiftlint:disable:next force_cast
    private var base: BaseCarbsStorage { storage as! BaseCarbsStorage }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        #expect(storage != nil, "CarbsStorage should be injected")
        #expect(storage is BaseCarbsStorage, "Storage should be of type BaseCarbsStorage")
        #expect(storage.updatePublisher != nil, "Update publisher should be available")
    }

    @Test("Store and retrieve carbs entries") func testStoreAndRetrieveCarbs() async throws {
        let testEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: Date(),
            carbs: 20,
            fat: 0,
            protein: 0,
            note: "Test meal",
            enteredBy: "Test",
            isFPU: false,
            fpuID: nil
        )

        try await base.storeCarbs([testEntry], areFetchedFromRemote: false, in: grdb.pool)

        let recentEntries = try await CarbEntryStore.fetchForMealCalc(pool: grdb.pool)

        #expect(recentEntries.count == 1, "Should have exactly one entry")
        #expect(recentEntries[0].carbs == 20, "Carbs value should match")
        #expect(recentEntries[0].fat == 0, "Fat value should match")
        #expect(recentEntries[0].protein == 0, "Protein value should match")
        #expect(recentEntries[0].note == "Test meal", "Note should match")
        #expect(recentEntries[0].isFPU == false, "Should be a carb entry")
    }

    @Test("Delete single carb entry by pk") func testDeleteCarbsEntry() async throws {
        let testEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: Date(),
            carbs: 30,
            fat: nil,
            protein: nil,
            note: "Delete test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: nil
        )

        try await base.storeCarbs([testEntry], areFetchedFromRemote: false, in: grdb.pool)

        let stored = try await CarbEntryStore.fetchForMealCalc(pool: grdb.pool)
        guard let pk = stored.first?.pk else {
            throw TestError("Failed to get stored entry's pk")
        }

        try await CarbEntryStore.delete(pk: pk, pool: grdb.pool)

        let remaining = try await CarbEntryStore.fetchForMealCalc(pool: grdb.pool)
        #expect(remaining.isEmpty, "Should have no entries after deletion")
    }

    @Test("Delete cascade removes all rows sharing fpuID") func testDeleteCascadeByFpuID() async throws {
        let fpuID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_010_000)

        // One carb-bearing parent row + two FPU equivalents, all sharing one fpuID.
        let parent = CarbEntryRecord(id: UUID(), date: baseDate, carbs: 30, fat: 20, protein: 10, isFPU: false, fpuID: fpuID)
        let fpu1 = CarbEntryRecord(id: UUID(), date: baseDate.addingTimeInterval(3600), carbs: 15, isFPU: true, fpuID: fpuID)
        let fpu2 = CarbEntryRecord(id: UUID(), date: baseDate.addingTimeInterval(5400), carbs: 15, isFPU: true, fpuID: fpuID)
        try await CarbEntryStore.batchInsert([parent, fpu1, fpu2], pool: grdb.pool)

        #expect(try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool).count == 3, "All three rows should be stored")

        let deleted = try await CarbEntryStore.deleteByFpuID(fpuID, pool: grdb.pool)
        #expect(deleted == 3, "Should delete all three rows sharing the fpuID")
        #expect(try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool).isEmpty, "No rows should remain for the fpuID")
    }

    @Test(
        "Store carb entry with fat/protein creates capped, spaced FPU entries (defaults: adjustment=0.5, delay=60m)"
    ) func testStoreFatProteinCarbEntryCreatesFPUEntries() async throws {
        let fpuID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Defaults: adjustment = 0.5, delay = 60
        // fat=50g -> 450 kcal; protein=100g -> 400 kcal; total 850; (kcal/10)=85; 85*0.5=42 -> two 21g entries.
        let mealEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: baseDate,
            actualDate: baseDate,
            carbs: 30,
            fat: 50,
            protein: 100,
            note: "FPU deterministic default split test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: fpuID.uuidString
        )

        try await base.storeCarbs([mealEntry], areFetchedFromRemote: false, in: grdb.pool)

        let storedEntries = try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool)
        #expect(!storedEntries.isEmpty, "Should have stored entries")

        let originalCarbEntry = storedEntries.first(where: { $0.isFPU == false })
        #expect(originalCarbEntry != nil, "Should have one non-FPU original entry")
        #expect(originalCarbEntry?.carbs == 30, "Original carbs should match")
        #expect(originalCarbEntry?.fat == 50, "Original fat should match")
        #expect(originalCarbEntry?.protein == 100, "Original protein should match")

        let fpuEntries = storedEntries.filter { $0.isFPU == true }
        #expect(fpuEntries.count == 2, "Expected exactly two FPU entries under default settings")

        for fpuEntry in fpuEntries {
            #expect(fpuEntry.fat == 0, "FPU fat must be 0")
            #expect(fpuEntry.protein == 0, "FPU protein must be 0")
            #expect(fpuEntry.carbs >= 10, "FPU carbs must be >= 10g")
            #expect(fpuEntry.carbs <= 33, "FPU carbs must be <= 33g")
            #expect(fpuEntry.carbs.truncatingRemainder(dividingBy: 1) == 0, "FPU carbs must be whole grams")
        }

        let scheduledTotal = fpuEntries.reduce(0.0) { $0 + $1.carbs }
        #expect(scheduledTotal <= 99, "Scheduled FPU carbs must be capped at 99g")

        let fpuDates = fpuEntries.compactMap(\.date).sorted()
        #expect(fpuDates.count == 2, "Both FPU entries should have a date")
        #expect(
            fpuDates[0] >= baseDate.addingTimeInterval(60 * 60),
            "First FPU entry should not be scheduled earlier than +60 minutes after the input timestamp"
        )

        #expect(storedEntries.allSatisfy { $0.fpuID == fpuID }, "All entries should share the same fpuID")
    }

    @Test(
        "Store very large fat/protein meal caps FPU equivalents at 99g and splits into 3×33g (defaults: adjustment=0.5, delay=60m)"
    ) func testStoreVeryLargeFatProteinMealCapsAndSplits() async throws {
        let fpuID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_001_000)

        // fat=200g -> 1800 kcal; protein=200g -> 800 kcal; total 2600; (kcal/10)=260; 260*0.5=130 -> capped 99 -> [33,33,33].
        let heftyMealEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: baseDate,
            actualDate: baseDate,
            carbs: 30,
            fat: 200,
            protein: 200,
            note: "Hefty BBQ meal - cap test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: fpuID.uuidString
        )

        try await base.storeCarbs([heftyMealEntry], areFetchedFromRemote: false, in: grdb.pool)

        let storedEntries = try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool)
        let fpuEntries = storedEntries.filter { $0.isFPU == true }
        #expect(fpuEntries.count == 3, "Capped large meal should create exactly 3 FPU entries")

        let fpuGrams = fpuEntries.map { Int($0.carbs) }.sorted()
        #expect(fpuGrams == [33, 33, 33], "Expected capped split to be [33, 33, 33]")

        let scheduledTotal = fpuEntries.reduce(0) { $0 + Int($1.carbs) }
        #expect(scheduledTotal == 99, "Total scheduled FPU grams should be exactly 99g after cap")

        let fpuDates = fpuEntries.compactMap(\.date).sorted()
        #expect(fpuDates.count == 3, "All FPU entries should have a date")
        #expect(
            fpuDates[0] >= baseDate.addingTimeInterval(60 * 60),
            "First FPU entry should not be scheduled earlier than +60 minutes after the input timestamp"
        )
        for index in 1 ..< fpuDates.count {
            let spacingSeconds = fpuDates[index].timeIntervalSince(fpuDates[index - 1])
            #expect(Int(spacingSeconds) == 30 * 60, "FPU entries should be spaced +30 minutes apart")
        }

        #expect(storedEntries.allSatisfy { $0.fpuID == fpuID }, "All entries should share the same fpuID")
    }

    @Test(
        "Store small fat/protein meal drops FPU equivalents when total would be <10g (defaults: adjustment=0.5, delay=60m)"
    ) func testStoreSmallFatProteinMealDropsFPUBelowMinimum() async throws {
        let fpuID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_002_000)

        // fat=2g -> 18 kcal; protein=2g -> 8 kcal; total 26; (kcal/10)=2.6; 2.6*0.5=1 (<10) -> dropped.
        let smallMealEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: baseDate,
            actualDate: baseDate,
            carbs: 30,
            fat: 2,
            protein: 2,
            note: "Tiny macros - min threshold test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: fpuID.uuidString
        )

        try await base.storeCarbs([smallMealEntry], areFetchedFromRemote: false, in: grdb.pool)

        let storedEntries = try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool)
        let originalCarbEntry = storedEntries.first(where: { $0.isFPU == false })
        #expect(originalCarbEntry != nil, "Should have one non-FPU original entry")
        #expect(originalCarbEntry?.carbs == 30, "Original carbs should match")

        let fpuEntries = storedEntries.filter { $0.isFPU == true }
        #expect(fpuEntries.isEmpty, "No FPU entries should be created when equivalents are <10g")
    }

    @Test("Get carbs not yet uploaded to Nightscout") func testGetCarbsNotYetUploadedToNightscout() async throws {
        let testEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: Date(),
            carbs: 40,
            fat: nil,
            protein: nil,
            note: "NS test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: nil
        )

        try await base.storeCarbs([testEntry], areFetchedFromRemote: false, in: grdb.pool)

        let notUploaded = try await CarbEntryStore.fetchCarbsNotYetUploadedToNightscout(pool: grdb.pool)
        #expect(notUploaded.count == 1, "Should have one carb entry not uploaded to NS")
        #expect(notUploaded[0].carbs == 40, "Carbs value should match")
        #expect(notUploaded[0].isFPU == false, "Should be a carb (non-FPU) entry")
    }

    @Test("Get FPUs not yet uploaded to Nightscout") func testGetFPUsNotYetUploadedToNightscout() async throws {
        let fpuID = UUID()
        let testEntry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: Date(),
            carbs: 30,
            fat: 20,
            protein: 10,
            note: "FPU test",
            enteredBy: "Test",
            isFPU: false,
            fpuID: fpuID.uuidString
        )

        try await base.storeCarbs([testEntry], areFetchedFromRemote: false, in: grdb.pool)

        let allStoredEntries = try await CarbEntryStore.fetchByFpuID(fpuID, pool: grdb.pool)
        #expect(allStoredEntries.count > 1, "Should have multiple entries due to FPU splitting")

        let carbNonFpuEntry = allStoredEntries.first(where: { $0.isFPU == false })
        #expect(carbNonFpuEntry?.carbs == 30, "Original carbs should match")
        #expect(carbNonFpuEntry?.protein == 10, "Original protein should match")
        #expect(carbNonFpuEntry?.fat == 20, "Original fat should match")

        let notUploadedFPUs = try await CarbEntryStore.fetchFPUsNotYetUploadedToNightscout(pool: grdb.pool)
        #expect(!notUploadedFPUs.isEmpty, "Should have FPUs not uploaded to NS")
        let fpu = notUploadedFPUs[0]
        #expect(fpu.carbs < 30, "FPU carb-equivalent should be less than the meal carbs")
        #expect(fpu.protein == 0, "FPU protein value should be 0")
        #expect(fpu.fat == 0, "FPU fat value should be 0")
        #expect(notUploadedFPUs.allSatisfy { $0.fpuID == fpuID }, "All FPUs should share the same fpuID")
    }

    @Test("Mark carbs uploaded to a channel by id") func testMarkUploaded() async throws {
        let id = UUID()
        let record = CarbEntryRecord(id: id, date: Date(), carbs: 25, isFPU: false)
        try await CarbEntryStore.store(record, pool: grdb.pool)

        #expect(
            try await CarbEntryStore.fetchNotYetUploadedToHealth(pool: grdb.pool).count == 1,
            "Entry should start not uploaded to Health"
        )

        try await CarbEntryStore.markUploadedToHealth(ids: [id], pool: grdb.pool)

        #expect(
            try await CarbEntryStore.fetchNotYetUploadedToHealth(pool: grdb.pool).isEmpty,
            "Entry should be marked uploaded to Health"
        )
    }
}
