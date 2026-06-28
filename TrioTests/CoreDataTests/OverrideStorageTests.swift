import Foundation
import GRDB
import Testing

@testable import Trio

@Suite("Override Storage Tests", .serialized) struct OverrideStorageTests {
    var grdb: GRDBStack!

    init() async throws {
        // In-memory GRDB store for tests (mirrors DynamicISFEnableTests).
        grdb = try GRDBStack.makeInMemoryForTests()
    }

    @Test("Store and retrieve override") func testStoreAndRetrieveOverride() async throws {
        let record = OverrideRecord(
            id: UUID().uuidString,
            name: "Test Override",
            date: Date(),
            enabled: false,
            isPreset: false,
            percentage: 130,
            duration: 120,
            target: 110
        )

        try await OverrideStore.store(record, pool: grdb.pool)

        let stored = try await grdb.pool.read { db in
            try OverrideRecord.filter(OverrideRecord.Columns.id == record.id!).fetchAll(db)
        }

        #expect(stored.count == 1, "Should have exactly one entry")
        #expect(stored.first?.name == "Test Override", "Name should match")
        #expect(stored.first?.percentage == 130, "Percentage should match")
        #expect(stored.first?.target == 110, "Target should match")
        #expect(stored.first?.isPreset == false, "isPreset should match")
    }

    @Test("Store and retrieve override preset assigns orderPosition") func testStoreAndRetrievePreset() async throws {
        let preset = OverrideRecord(
            id: UUID().uuidString,
            name: "Test Preset",
            date: Date(),
            enabled: false,
            isPreset: true,
            indefinite: true,
            percentage: 120,
            target: 110
        )

        try await OverrideStore.store(preset, pool: grdb.pool)
        let presets = try await OverrideStore.fetchPresets(pool: grdb.pool)

        #expect(presets.count == 1, "Should have stored preset")
        let stored = presets.first { $0.name == "Test Preset" }
        #expect(stored != nil, "Should find the test preset")
        #expect(stored?.isPreset == true, "Should be marked as preset")
        #expect(stored?.indefinite == true, "Should be indefinite")
        #expect(stored?.percentage == 120, "Percentage should match")
        #expect(stored?.orderPosition == 1, "First preset should get orderPosition 1")
    }

    @Test("Delete override preset") func testDeleteOverridePreset() async throws {
        let preset = OverrideRecord(id: UUID().uuidString, name: "Delete Test", date: Date(), isPreset: true)
        let stored = try await OverrideStore.store(preset, pool: grdb.pool)

        try await OverrideStore.delete(pk: stored.pk!, pool: grdb.pool)

        let remaining = try await OverrideStore.fetchPresets(pool: grdb.pool)
        #expect(remaining.isEmpty, "Should have no entries after deletion")
    }

    @Test("Get overrides not yet uploaded to Nightscout") func testGetOverridesNotYetUploaded() async throws {
        let record = OverrideRecord(
            id: UUID().uuidString,
            name: "NS Test",
            date: Date(),
            enabled: true, // only active, not-yet-uploaded overrides are returned
            isPreset: true,
            isUploadedToNS: false,
            indefinite: false,
            percentage: 120,
            duration: 90,
            target: 110
        )

        try await OverrideStore.store(record, pool: grdb.pool)

        let notUploaded = try await OverrideStore.fetchNotYetUploaded(pool: grdb.pool)
        let exercises = notUploaded.map(BaseOverrideStorage.nightscoutExercise(from:))

        #expect(!exercises.isEmpty, "Should have overrides not uploaded to NS")
        #expect(exercises[0].notes == "NS Test", "Override name should match")
        #expect(exercises[0].duration == 90, "Duration should match")
        #expect(exercises[0].eventType == .nsExercise, "Event type should be exercise")
    }
}
