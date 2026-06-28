import Foundation
import GRDB
import Testing

@testable import Trio

@Suite("Dynamic ISF Enable Logic Tests", .serialized) struct DynamicISFEnableTests {
    var grdb: GRDBStack!

    init() async throws {
        // In-memory GRDB store for tests
        grdb = try GRDBStack.makeInMemoryForTests()
    }

    func testEnableLogic(percentSamples: Double) async throws -> Bool {
        let numberOfSamples = Int(288 * 7 * percentSamples)
        let now = Date() // internal function uses Date()

        try await grdb.pool.write { db in
            for index in 0 ..< numberOfSamples {
                let timeDelta = Double(index * 5 * 60)
                var tdd = TDDRecord(
                    id: UUID().uuidString,
                    date: now - timeDelta,
                    total: 30,
                    bolus: 15,
                    tempBasal: 15,
                    scheduledBasal: 0
                )
                try tdd.insert(db)
            }
        }

        return try await BaseTDDStorage.hasSufficientTDD(in: grdb.pool)
    }

    @Test("Confirm samples from last 7 days enables Dynamic ISF") func testPercentSamplesEnablingLogic() async throws {
        let enabled = try await testEnableLogic(percentSamples: 0.8)
        #expect(enabled)
    }

    @Test("Confirm insufficient samples from last 7 days disables Dynamic ISF") func testPercentSamplesDisablesLogic() async throws {
        let enabled = try await testEnableLogic(percentSamples: 0.7)
        #expect(!enabled)
    }
}
