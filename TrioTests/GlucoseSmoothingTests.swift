import CoreData
import Foundation
import GRDB
import LoopKitUI
import Swinject
import Testing

@testable import Trio

@Suite("Glucose Smoothing Tests", .serialized) struct GlucoseSmoothingTests: Injectable {
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var grdb: GRDBStack!
    var openAPS: OpenAPS!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()
        // Glucose lives in GRDB now: an in-memory pool backs the smoothing / selection assertions.
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

        let fileStorage = resolver.resolve(FileStorage.self)!
        openAPS = OpenAPS(storage: fileStorage, tddStorage: MockTDDStorage())
    }

    // MARK: - Exponential Smoothing Math (pure `computeExponentialSmoothing`)

    @Test(
        "Exponential smoothing produces smoothed values for CGM values when enough data exists"
    ) func testExponentialSmoothingStoresSmoothedValues() async throws {
        let records = makeRecords([100, 105, 110, 115, 120, 125], interval: 5 * 60)

        let pairs = smooth(records)

        // 6 values, no gap => validWindowCount 5 => 5 blended values for the most recent 5 readings.
        #expect(pairs.count >= 5, "Expected at least 5 smoothed values.")
        for pair in pairs {
            #expect(pair.value >= 39, "Smoothed glucose should be clamped to at least 39, got \(pair.value).")
            #expect(pair.value == pair.value.rounded(toPlaces: 0), "Smoothed glucose should be an integer, got \(pair.value).")
        }
    }

    @Test("fetchForSmoothing excludes manual glucose entries") func testFetchForSmoothingIgnoresManual() async throws {
        try await store([100, 105, 110, 115, 120].map(Int16.init), interval: 5 * 60, isManual: false)
        try await store([130], dates: [Date().addingTimeInterval(6 * 5 * 60)], isManual: true)

        let smoothingInput = try await GlucoseStore.fetchForSmoothing(pool: grdb.pool)

        #expect(smoothingInput.count == 5, "Manual entries must be excluded from the smoothing window.")
        #expect(smoothingInput.allSatisfy { !$0.isManual }, "No manual reading may enter the smoothing window.")
    }

    @Test(
        "Exponential smoothing clamps smoothed glucose to >= 39 and rounds to integer"
    ) func testExponentialSmoothingClampAndRounding() async throws {
        let records = makeRecords([40, 39, 41, 42, 43, 44], interval: 5 * 60)

        let pairs = smooth(records)

        #expect(!pairs.isEmpty, "Expected at least one smoothed glucose value.")
        for pair in pairs {
            #expect(pair.value >= 39, "Smoothed glucose must be clamped to >= 39, got \(pair.value).")
            #expect(pair.value == pair.value.rounded(toPlaces: 0), "Smoothed glucose must be an integer, got \(pair.value).")
        }
    }

    @Test(
        "Exponential smoothing stops at gaps >= 12 minutes and only updates the most recent window"
    ) func testExponentialSmoothingGapStopsWindow() async throws {
        let now = Date()
        var dates: [Date] = []
        var values: [Int16] = []

        // Older contiguous block (should remain untouched).
        for i in 0 ..< 10 {
            dates.append(now.addingTimeInterval(Double(i) * 5 * 60))
            values.append(Int16(100 + i * 5))
        }
        // GAP (15 minutes), then a recent block too small to smooth (fallback applies only here).
        let gapStart = now.addingTimeInterval(Double(10) * 5 * 60 + 15 * 60)
        for i in 0 ..< 3 {
            dates.append(gapStart.addingTimeInterval(Double(i) * 5 * 60))
            values.append(Int16(200 + i * 5))
        }

        let records = makeRecords(values, dates: dates)
        let recentPks = Set(records.suffix(3).compactMap(\.pk))
        let olderPks = Set(records.prefix(10).compactMap(\.pk))

        let pairs = smooth(records)
        let updatedPks = Set(pairs.map(\.pk))

        // Only the recent (post-gap) block is written; the older block is untouched.
        #expect(updatedPks.isSubset(of: recentPks), "Only the most recent window may be updated.")
        #expect(updatedPks.isDisjoint(with: olderPks), "Older values must not be overwritten by the fallback.")
        for pair in pairs {
            #expect(pair.value >= 39, "Fallback smoothed glucose must be clamped to >= 39, got \(pair.value).")
            #expect(pair.value == pair.value.rounded(toPlaces: 0), "Fallback smoothed glucose must be an integer.")
        }
    }

    @Test(
        "Exponential smoothing treats 38 mg/dL as xDrip error and clamps stored smoothed glucose"
    ) func testExponentialSmoothingXDrip38StopsWindow() async throws {
        let records = makeRecords([100, 105, 110, 38, 120, 125], interval: 5 * 60)

        let pairs = smooth(records)

        #expect(!pairs.isEmpty, "Expected at least one smoothed glucose value.")
        for pair in pairs {
            #expect(pair.value >= 39, "Smoothed glucose must be clamped to >= 39 even around xDrip 38, got \(pair.value).")
            #expect(pair.value == pair.value.rounded(toPlaces: 0), "Smoothed glucose must be an integer, got \(pair.value).")
        }
    }

    // MARK: - fetchForSmoothing Window Tests

    @Test(
        "fetchForSmoothing retains the most recent 350 readings (not the oldest) and returns them chronologically"
    ) func testFetchForSmoothingKeepsMostRecentWhenOverLimit() async throws {
        // 360 readings within the last 24h (3 min spacing => ~18h span), each with a unique value.
        let count = 360
        let values: [Int16] = (0 ..< count).map { Int16(100 + $0) }
        try await store(values, interval: 3 * 60, isManual: false)

        let window = try await GlucoseStore.fetchForSmoothing(limit: 350, pool: grdb.pool)

        #expect(window.count == 350, "fetchForSmoothing should respect the 350 limit, got \(window.count).")
        // Chronological (ascending) — the smoother walks the array oldest-first.
        let dates = window.compactMap(\.date)
        #expect(dates == dates.sorted(), "fetchForSmoothing must return readings in chronological order.")
        // The most recent reading (current BG) must survive the limit and be last.
        #expect(
            window.last?.glucose == Int16(100 + count - 1),
            "Most recent reading (current BG) must be retained after the 350-limit truncation."
        )
        // The oldest reading must be dropped — truncation cuts from the old end.
        #expect(
            !window.contains { $0.glucose == Int16(100) },
            "Oldest reading must be excluded by the limit (truncation should cut old, not recent)."
        )
    }

    @Test(
        "Exponential smoothing covers the current BG when the window holds more than 350 readings"
    ) func testExponentialSmoothingCoversCurrentBGAboveLimit() async throws {
        // 360 contiguous CGM readings within the last 24h (3 min spacing, no gaps).
        let count = 360
        try await store((0 ..< count).map { _ in Int16(120) }, interval: 3 * 60, isManual: false)

        let window = try await GlucoseStore.fetchForSmoothing(limit: 350, pool: grdb.pool)
        let pairs = smooth(window)

        // The most recent reading (window.last) must receive a smoothed value — regression test for the
        // bug where ascending+limit kept the OLDEST 350 readings and the current BG fell outside the window.
        let newestPk = try #require(window.last?.pk)
        #expect(pairs.contains { $0.pk == newestPk }, "Most recent reading (current BG) must receive a smoothed value.")
    }

    // MARK: - OpenAPS Glucose Selection Tests (#1054)

    @Test("Algorithm uses smoothed glucose when enabled") func testAlgorithmUsesSmoothedGlucose() async throws {
        try await store([150], dates: [Date()], isManual: false, smoothed: [Decimal(140)])

        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(algorithmInput.first?.glucose == 140, "Algorithm should have used the smoothed glucose value (140).")
    }

    @Test("Algorithm uses raw glucose when smoothing is disabled") func testAlgorithmUsesRawGlucose() async throws {
        try await store([150], dates: [Date()], isManual: false, smoothed: [Decimal(140)])

        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: false)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(algorithmInput.first?.glucose == 150, "Algorithm should have used the raw glucose value (150).")
    }

    @Test("Algorithm falls back to raw glucose if smoothed value is missing") func testAlgorithmFallbackToRawGlucose() async throws {
        try await store([150], dates: [Date()], isManual: false, smoothed: [nil])

        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(algorithmInput.first?.glucose == 150, "Algorithm should have fallen back to the raw glucose value (150).")
    }

    @Test("Algorithm ignores smoothed value for manual glucose entries") func testAlgorithmIgnoresSmoothedManualGlucose() async throws {
        try await store([150], dates: [Date()], isManual: true, smoothed: [Decimal(140)])

        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 150,
            "Algorithm should have ignored smoothing for a manual entry and used the raw value (150)."
        )
    }

    // MARK: - Helpers

    /// Runs the exponential smoothing math with the production parameters over the given (chronological) records.
    private func smooth(_ data: [GlucoseRecord]) -> [(pk: Int64, value: Decimal)] {
        BaseFetchGlucoseManager.computeExponentialSmoothing(
            glucoseReadings: data,
            minimumWindowSize: 4,
            maximumAllowedGapMinutes: 12,
            xDripErrorGlucose: 38,
            minimumSmoothedGlucose: 39,
            firstOrderWeight: 0.4,
            firstOrderAlpha: 0.5,
            secondOrderAlpha: 0.4,
            secondOrderBeta: 1.0
        )
    }

    /// Builds in-memory `GlucoseRecord`s (with synthetic `pk`s) for the pure smoothing math — no pool.
    private func makeRecords(_ values: [Int16], dates: [Date], isManual: Bool = false) -> [GlucoseRecord] {
        values.enumerated().map { i, value in
            GlucoseRecord(pk: Int64(i + 1), id: UUID(), date: dates[i], glucose: value, isManual: isManual)
        }
    }

    private func makeRecords(_ values: [Int16], interval: TimeInterval, isManual: Bool = false) -> [GlucoseRecord] {
        let now = Date()
        let dates = values.indices.map { now.addingTimeInterval(Double($0) * interval) }
        return makeRecords(values, dates: dates, isManual: isManual)
    }

    /// Inserts readings into the in-memory GRDB pool.
    private func store(_ values: [Int16], dates: [Date], isManual: Bool, smoothed: [Decimal?]? = nil) async throws {
        for (i, value) in values.enumerated() {
            _ = try await GlucoseStore.store(
                GlucoseRecord(
                    id: UUID(),
                    date: dates[i],
                    glucose: value,
                    isManual: isManual,
                    smoothedGlucose: smoothed?[i] ?? nil
                ),
                pool: grdb.pool
            )
        }
    }

    private func store(_ values: [Int16], interval: TimeInterval, isManual: Bool) async throws {
        let now = Date()
        let dates = values.indices.map { now.addingTimeInterval(Double($0) * interval) }
        try await store(values, dates: dates, isManual: isManual)
    }

    private func runFetchAndProcessGlucose(smoothGlucose: Bool) async throws -> [AlgorithmGlucose] {
        let jsonString = try await openAPS.fetchAndProcessGlucose(
            shouldSmoothGlucose: smoothGlucose,
            fetchLimit: 10,
            pool: grdb.pool
        )

        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateDouble = try container.decode(Double.self)
            return Date(timeIntervalSince1970: dateDouble / 1000)
        }

        return try decoder.decode([AlgorithmGlucose].self, from: data)
    }
}
