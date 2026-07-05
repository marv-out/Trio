import Foundation
import GRDB
import Testing

@testable import Trio

@Suite("Determination Storage Tests", .serialized) struct DeterminationStorageTests {
    var grdb: GRDBStack!

    init() async throws {
        // In-memory GRDB store for tests (mirrors OverrideStorageTests / DynamicISFEnableTests).
        grdb = try GRDBStack.makeInMemoryForTests()
    }

    // MARK: - fetchLast

    @Test("fetchLast returns the newest determination within the window") func testFetchLast() async throws {
        let date = Date()
        let id = UUID()

        try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: id, deliverAt: date, timestamp: date, enacted: true, isUploadedToNS: true),
            pool: grdb.pool
        )

        let within = try await OrefDeterminationStore.fetchLast(within: 30, enactedOnly: false, pool: grdb.pool)
        #expect(within != nil, "Should find a determination within 30 minutes")
        #expect(within?.id == id, "Should return the stored determination")
        #expect(within?.enacted == true, "Determination should be enacted")

        let enacted = try await OrefDeterminationStore.fetchLast(within: 30, enactedOnly: true, pool: grdb.pool)
        #expect(enacted?.id == id, "Enacted-only fetch should find the enacted determination")
    }

    @Test("fetchLast ignores determinations outside the window") func testFetchLastOutsideWindow() async throws {
        let old = Date().addingTimeInterval(-60 * 60) // 1h ago

        try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: UUID(), deliverAt: old, timestamp: old, enacted: true),
            pool: grdb.pool
        )

        let within = try await OrefDeterminationStore.fetchLast(within: 30, enactedOnly: false, pool: grdb.pool)
        #expect(within == nil, "Should not find determinations older than the window")
    }

    // MARK: - Forecast hierarchy

    @Test("Store and fetch complete forecast hierarchy") func testForecastHierarchy() async throws {
        let date = Date()
        let forecasts: [OrefDeterminationStore.ForecastInput] = [
            .init(type: "iob", date: date, values: [100, 110, 120, 130, 140]),
            .init(type: "cob", date: date, values: [50, 55, 60, 65, 70]),
            .init(type: "zt", date: date, values: [80, 88, 96, 104, 112]),
            .init(type: "uam", date: date, values: [120, 105, 90, 75, 60])
        ]

        let stored = try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: UUID(), deliverAt: date, timestamp: date, enacted: true),
            forecasts: forecasts,
            pool: grdb.pool
        )
        let pk = try #require(stored.pk)

        let hierarchy = try await ForecastStore.fetchHierarchy(for: pk, pool: grdb.pool)
        #expect(hierarchy.count == 4, "Should have all four forecast curves")

        for entry in hierarchy {
            #expect(entry.values.count == 5, "Each forecast should have five values")
            let sorted = entry.values.sorted { $0.index < $1.index }
            switch entry.forecast.type {
            case "iob":
                #expect(sorted.first?.value == 100 && sorted.last?.value == 140, "IOB pattern should match")
            case "cob":
                #expect(sorted.first?.value == 50 && sorted.last?.value == 70, "COB pattern should match")
            case "zt":
                #expect(sorted.first?.value == 80 && sorted.last?.value == 112, "ZT pattern should match")
            case "uam":
                #expect(sorted.first?.value == 120 && sorted.last?.value == 60, "UAM pattern should match")
            default:
                Issue.record("Unexpected forecast type: \(String(describing: entry.forecast.type))")
            }
        }
    }

    @Test("fetchValues returns the sorted values for one type") func testFetchValues() async throws {
        let date = Date()
        let stored = try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: UUID(), deliverAt: date, timestamp: date, enacted: true),
            forecasts: [.init(type: "iob", date: date, values: [100, 110, 120])],
            pool: grdb.pool
        )
        let pk = try #require(stored.pk)

        let iob = try await ForecastStore.fetchValues(type: "iob", for: pk, pool: grdb.pool)
        #expect(iob == [100, 110, 120], "IOB values should come back in index order")

        let cob = try await ForecastStore.fetchValues(type: "cob", for: pk, pool: grdb.pool)
        #expect(cob.isEmpty, "Missing forecast type should return an empty array")
    }

    @Test("Deleting a determination cascades to its forecasts and values") func testCascadeDelete() async throws {
        // Store a determination clearly older than the prune cutoff so `deleteOlderThan` removes it.
        let old = Date().addingTimeInterval(-10)
        try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: UUID(), deliverAt: old, timestamp: old, enacted: true),
            forecasts: [.init(type: "iob", date: old, values: [1, 2, 3])],
            pool: grdb.pool
        )

        // Precondition: children exist.
        let forecastsBefore = try await grdb.pool.read { db in try ForecastRecord.fetchCount(db) }
        let valuesBefore = try await grdb.pool.read { db in try ForecastValueRecord.fetchCount(db) }
        #expect(forecastsBefore == 1 && valuesBefore == 3, "Forecast tree should be stored")

        // cutoff = now → the 10s-old determination is deleted, cascading to its forecast + values.
        try await OrefDeterminationStore.deleteOlderThan(days: 0)

        let forecastCount = try await grdb.pool.read { db in try ForecastRecord.fetchCount(db) }
        let valueCount = try await grdb.pool.read { db in try ForecastValueRecord.fetchCount(db) }
        #expect(forecastCount == 0, "Forecasts should be cascade-deleted with their determination")
        #expect(valueCount == 0, "Forecast values should be cascade-deleted transitively")
    }

    // MARK: - Not-yet-uploaded splits

    @Test("Enacted / suggested not-yet-uploaded fetches split by enacted flag") func testNotYetUploadedSplit() async throws {
        let now = Date()

        // An enacted, not-yet-uploaded determination
        let enacted = try await OrefDeterminationStore.store(
            OrefDeterminationRecord(id: UUID(), deliverAt: now, timestamp: now, enacted: true, isUploadedToNS: false),
            pool: grdb.pool
        )
        // A suggested (non-enacted), not-yet-uploaded determination, slightly older
        let suggested = try await OrefDeterminationStore.store(
            OrefDeterminationRecord(
                id: UUID(),
                deliverAt: now.addingTimeInterval(-60),
                enacted: false,
                isUploadedToNS: false
            ),
            pool: grdb.pool
        )

        let fetchedEnacted = try await OrefDeterminationStore.fetchEnactedNotYetUploaded(pool: grdb.pool)
        #expect(fetchedEnacted?.id == enacted.id, "Enacted fetch should return the enacted determination")

        let fetchedSuggested = try await OrefDeterminationStore.fetchSuggestedNotYetUploaded(pool: grdb.pool)
        #expect(fetchedSuggested?.id == suggested.id, "Suggested fetch should return the non-enacted determination")

        // Marking uploaded removes them from the not-yet-uploaded sets.
        try await OrefDeterminationStore.markUploaded(ids: [enacted.id!, suggested.id!], pool: grdb.pool)
        let stillEnacted = try await OrefDeterminationStore.fetchEnactedNotYetUploaded(pool: grdb.pool)
        let stillSuggested = try await OrefDeterminationStore.fetchSuggestedNotYetUploaded(pool: grdb.pool)
        #expect(stillEnacted == nil, "Uploaded enacted determination should no longer be pending")
        #expect(stillSuggested == nil, "Uploaded suggested determination should no longer be pending")
    }

    @Test("Decimals round-trip losslessly through TEXT storage") func testDecimalRoundTrip() async throws {
        let date = Date()
        let stored = try await OrefDeterminationStore.store(
            OrefDeterminationRecord(
                id: UUID(),
                deliverAt: date,
                cob: 12,
                currentTarget: 100, insulinReq: Decimal(string: "1.234")!,
                iob: Decimal(string: "-0.5")!
            ),
            pool: grdb.pool
        )
        let pk = try #require(stored.pk)

        let fetched = try await OrefDeterminationStore.fetch(pk: pk, pool: grdb.pool)
        #expect(fetched?.insulinReq == Decimal(string: "1.234"), "insulinReq should round-trip losslessly")
        #expect(fetched?.iob == Decimal(string: "-0.5"), "iob should round-trip losslessly")
        #expect(fetched?.cob == 12, "cob should round-trip")
        #expect(fetched?.currentTarget == 100, "currentTarget should round-trip")
    }
}
