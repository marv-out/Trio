import CoreData
import Foundation

/// Represents statistical data about loop execution success/failure for a specific time period
struct LoopStatsByPeriod: Identifiable {
    /// The date representing this time period
    let period: Date
    /// Number of successful loop executions in this period
    let successful: Int
    /// Number of failed loop executions in this period
    let failed: Int
    /// Median duration of loop executions in this period
    let medianDuration: Double
    /// Number of glucose measurements in this period
    let glucoseCount: Int
    /// Total number of loop executions in this period
    var total: Int { successful + failed }
    /// Percentage of successful loops (0-100)
    var successPercentage: Double { total > 0 ? Double(successful) / Double(total) * 100 : 0 }
    /// Percentage of failed loops (0-100)
    var failurePercentage: Double { total > 0 ? Double(failed) / Double(total) * 100 : 0 }
    /// Unique identifier for this period, using the period date
    var id: Date { period }
}

struct LoopStatsProcessedData: Identifiable {
    var id = UUID()
    let category: LoopStatsDataType
    let count: Int
    let percentage: Double
    let medianDuration: Double
    let medianInterval: Double
    let totalDays: Int
}

enum LoopStatsDataType: String {
    case successfulLoop
    case glucoseCount

    var displayName: String {
        switch self {
        case .successfulLoop: return String(localized: "Successful Loops")
        case .glucoseCount: return String(localized: "Glucose Count")
        }
    }
}

extension Stat.StateModel {
    /// Initiates the process of fetching and processing loop statistics
    /// This function coordinates three main tasks:
    /// 1. Fetching loop stat record IDs for the selected duration
    /// 2. Calculating grouped statistics for the Loop stats chart
    /// 3. Updating loop stat records on the main thread (!) for the Loop duration chart
    func setupLoopStatRecords() {
        Task {
            do {
                let (allLoops, failedLoops) = try await self.fetchLoopStatRecords(for: selectedIntervalForLoopStats)

                // Update loop records for duration chart
                await self.updateLoopStatRecords(allLoops)

                // Calculate statistics and update on main thread
                let stats = try await self.getLoopStats(
                    allLoops: allLoops,
                    failedLoops: failedLoops,
                    interval: selectedIntervalForLoopStats
                )

                await MainActor.run {
                    self.loopStats = stats
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) failed to fetch loop stats: \(error)")
            }
        }
    }

    /// Fetches loop statistics records for the specified duration.
    /// - Parameter interval: The time period to fetch records for
    /// - Returns: A tuple of (all loops, failed loops) as value-type records. No
    ///   `NSManagedObjectID` round-trips — GRDB records are `Sendable` and cross threads freely.
    func fetchLoopStatRecords(for interval: StatsTimeIntervalWithToday) async throws
        -> ([LoopStat], [LoopStat])
    {
        // Calculate the date range based on selected duration
        let now = Date()
        let startDate: Date
        switch interval {
        case .day:
            startDate = now.addingTimeInterval(-24.hours.timeInterval)
        case .today:
            startDate = Calendar.current.startOfDay(for: now)
        case .week:
            startDate = now.addingTimeInterval(-7.days.timeInterval)
        case .month:
            startDate = now.addingTimeInterval(-30.days.timeInterval)
        case .total:
            startDate = now.addingTimeInterval(-90.days.timeInterval)
        }

        let allLoops = try await LoopStatStore.all(since: startDate)
        // Mirrors the former `loopStatus != "Success"` predicate, which excludes NULL.
        let failedLoops = allLoops.filter { $0.loopStatus != nil && $0.loopStatus != "Success" }
        return (allLoops, failedLoops)
    }

    /// Publishes the fetched loop records to the duration chart on the main thread.
    @MainActor func updateLoopStatRecords(_ allLoops: [LoopStat]) {
        loopStatRecords = allLoops
    }

    /// Calculates loop and glucose statistics from the provided records.
    /// - Parameters:
    ///   - allLoops: All loop records in the period
    ///   - failedLoops: The subset of failed loops
    ///   - interval: The time period for statistics calculation
    /// - Returns: Per-category processed statistics (successful loops, glucose count)
    func getLoopStats(
        allLoops: [LoopStat],
        failedLoops: [LoopStat],
        interval: StatsTimeIntervalWithToday
    ) async throws
        -> [LoopStatsProcessedData]
    {
        // Calculate the date range for glucose readings
        let now = Date()
        let startDate: Date
        switch interval {
        case .day:
            startDate = now.addingTimeInterval(-24.hours.timeInterval)
        case .today:
            startDate = Calendar.current.startOfDay(for: now)
        case .week:
            startDate = now.addingTimeInterval(-7.days.timeInterval)
        case .month:
            startDate = now.addingTimeInterval(-30.days.timeInterval)
        case .total:
            startDate = now.addingTimeInterval(-90.days.timeInterval)
        }

        // Get glucose statistics (still Core Data until GlucoseStored is migrated)
        let totalGlucose = try await calculateGlucoseStats(from: startDate, to: now)

        // Pure value-type math — no context, no perform block.
        let totalLoopsCount = allLoops.count
        let failedLoopsCount = failedLoops.count
        let successfulLoops = totalLoopsCount - failedLoopsCount
        let maxLoopsPerDay = 288.0 // Maximum possible loops per day (every 5 minutes)

        let numberOfDays = max(1, Calendar.current.dateComponents([.day], from: startDate, to: now).day ?? 1)
        let averageLoopsPerDay = Double(successfulLoops) / Double(numberOfDays)
        let averageGlucosePerDay = Double(totalGlucose) / Double(numberOfDays)

        // Calculate median duration (time from start to end of each loop)
        let sortedDurations: [TimeInterval] = allLoops.compactMap { loop in
            guard let start = loop.start, let end = loop.end else { return nil }
            return end.timeIntervalSince(start)
        }.sorted()
        let medianDuration = sortedDurations.isEmpty ? 0.0 : sortedDurations[sortedDurations.count / 2]

        // Calculate median interval (time between end of n-th loop and start of n+1th loop)
        let sortedIntervals: [TimeInterval] = zip(allLoops.dropLast(), allLoops.dropFirst()).compactMap { previous, next in
            guard let previousEnd = previous.end, let nextStart = next.start else { return nil }
            return previousEnd.timeIntervalSince(nextStart)
        }.sorted()
        let medianInterval = sortedIntervals.isEmpty ? 0.0 : sortedIntervals[sortedIntervals.count / 2]

        let loopPercentage = (averageLoopsPerDay / maxLoopsPerDay) * 100
        let glucosePercentage = (averageGlucosePerDay / maxLoopsPerDay) * 100

        return [
            LoopStatsProcessedData(
                category: LoopStatsDataType.successfulLoop,
                count: Int(round(averageLoopsPerDay)),
                percentage: loopPercentage,
                medianDuration: medianDuration,
                medianInterval: medianInterval,
                totalDays: numberOfDays
            ),
            LoopStatsProcessedData(
                category: LoopStatsDataType.glucoseCount,
                count: Int(round(averageGlucosePerDay)),
                percentage: glucosePercentage,
                medianDuration: medianDuration,
                medianInterval: medianInterval,
                totalDays: numberOfDays
            )
        ]
    }

    /// Fetches and calculates glucose statistics for the given time period
    /// - Parameters:
    ///   - startDate: The start date of the period to analyze
    ///   - now: The current date (end of period)
    /// - Returns: Number of glucose readings in the period
    private func calculateGlucoseStats(
        from startDate: Date,
        to _: Date
    ) async throws -> Int {
        let loopTaskContext = CoreDataStack.shared.newTaskContext()
        loopTaskContext.name = "StatStateModel.calculateGlucoseStats"

        // Create predicate for glucose readings
        let glucosePredicate = NSPredicate(format: "date >= %@", startDate as NSDate)

        // Fetch glucose readings asynchronously
        let glucoseResult = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: loopTaskContext,
            predicate: glucosePredicate,
            key: "date",
            ascending: false
        )

        return await loopTaskContext.perform {
            guard let readings = glucoseResult as? [GlucoseStored] else {
                return 0
            }
            return readings.count
        }
    }
}
