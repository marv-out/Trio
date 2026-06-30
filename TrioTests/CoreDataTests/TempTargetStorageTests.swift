import Foundation
import GRDB
import Testing

@testable import Trio

@Suite("TempTargetStorage Tests", .serialized) struct TempTargetsStorageTests {
    var grdb: GRDBStack!

    init() async throws {
        // In-memory GRDB store for tests (mirrors OverrideStorageTests).
        grdb = try GRDBStack.makeInMemoryForTests()
    }

    @Test("Store and retrieve temp target") func testStoreAndRetrieveTempTarget() async throws {
        let record = TempTargetRecord(
            id: UUID(),
            name: "Test Target",
            date: Date(),
            enabled: false,
            isPreset: false,
            duration: 60,
            target: 120,
            halfBasalTarget: 160
        )

        try await TempTargetStore.store(record, pool: grdb.pool)

        let stored = try await grdb.pool.read { db in
            try TempTargetRecord.filter(TempTargetRecord.Columns.id == record.id!.uuidString).fetchAll(db)
        }

        #expect(stored.count == 1, "Should have exactly one entry")
        #expect(stored.first?.name == "Test Target", "Name should match")
        #expect(stored.first?.target == 120, "Target should match")
        #expect(stored.first?.duration == 60, "Duration should match")
        #expect(stored.first?.isPreset == false, "isPreset should match")
    }

    @Test("Store temp target preset assigns orderPosition") func testStoreAndRetrievePreset() async throws {
        let preset = TempTargetRecord(
            id: UUID(),
            name: "Test Preset",
            date: Date(),
            isPreset: true,
            target: 110
        )

        try await TempTargetStore.store(preset, pool: grdb.pool)
        let presets = try await TempTargetStore.fetchPresets(pool: grdb.pool)

        #expect(presets.count == 1, "Should have stored preset")
        let stored = presets.first { $0.name == "Test Preset" }
        #expect(stored != nil, "Should find the test preset")
        #expect(stored?.isPreset == true, "Should be marked as preset")
        #expect(stored?.target == 110, "Target should match")
        #expect(stored?.orderPosition == 1, "First preset should get orderPosition 1")
    }

    @Test("Delete temp target preset") func testDeleteTempTargetPreset() async throws {
        let preset = TempTargetRecord(id: UUID(), name: "Delete Test", date: Date(), isPreset: true)
        let stored = try await TempTargetStore.store(preset, pool: grdb.pool)

        try await TempTargetStore.delete(pk: stored.pk!, pool: grdb.pool)

        let remaining = try await TempTargetStore.fetchPresets(pool: grdb.pool)
        #expect(remaining.isEmpty, "Should have no entries after deletion")
    }

    @Test("Get temp targets not yet uploaded to Nightscout") func testGetTempTargetsNotYetUploaded() async throws {
        let record = TempTargetRecord(
            id: UUID(),
            name: "NS Test",
            date: Date(),
            enabled: true, // only active, not-yet-uploaded temp targets are returned
            isPreset: true,
            isUploadedToNS: false,
            duration: 45,
            target: 120
        )

        try await TempTargetStore.store(record, pool: grdb.pool)

        let notUploaded = try await TempTargetStore.fetchNotYetUploaded(pool: grdb.pool)

        #expect(!notUploaded.isEmpty, "Should have temp targets not uploaded to NS")
        #expect(notUploaded[0].name == "NS Test", "Temp target name should match")
        #expect(notUploaded[0].duration == 45, "Duration should match")
        #expect(notUploaded[0].target == 120, "Target should match")
    }
}
