import Combine
import Foundation
import GRDB
import SwiftDate
import Swinject

protocol CarbsObserver {
    func carbsDidUpdate(_ carbs: [CarbsEntry])
}

/// GRDB-backed carb storage (see `MIGRATION.md`, Step 9a).
///
/// Carbs are standalone — no relationships, presets, or runs — so this is simpler than
/// Override/TempTarget structurally: the protocol deals in `CarbEntryRecord` value types / `pk`s
/// instead of `NSManagedObjectID`s. `updatePublisher` is kept as the "something changed" signal
/// (`AppleWatchManager` and others subscribe to it) alongside the new `CarbEntryStore`
/// observations.
protocol CarbsStorage {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    func storeCarbs(_ carbs: [CarbsEntry], areFetchedFromRemote: Bool) async throws
    func deleteCarbsEntryStored(_ pk: Int64) async
    func syncDate() -> Date
    func getCarbsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getFPUsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getCarbsNotYetUploadedToHealth() async throws -> [CarbsEntry]
    func getCarbsNotYetUploadedToTidepool() async throws -> [CarbsEntry]
}

final class BaseCarbsStorage: CarbsStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BaseCarbsStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settings: SettingsManager!

    private let updateSubject = PassthroughSubject<Void, Never>()

    private let settingsProvider = PickerSettingsProvider.shared

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func storeCarbs(_ entries: [CarbsEntry], areFetchedFromRemote: Bool) async throws {
        try await storeCarbs(entries, areFetchedFromRemote: areFetchedFromRemote, in: nil)
    }

    /// Pool-injecting variant for tests (mirrors `BaseTDDStorage.hasSufficientTDD(in:)`): `pool == nil`
    /// uses the shared GRDB store; tests pass an in-memory pool to exercise the FPU split end-to-end.
    func storeCarbs(_ entries: [CarbsEntry], areFetchedFromRemote: Bool, in pool: DatabasePool?) async throws {
        var entriesToStore = entries

        if areFetchedFromRemote {
            entriesToStore = try await filterRemoteEntries(entries: entriesToStore)
        }

        // Check for FPU-only entries (fat/protein without carbs)
        let fpuOnlyEntries = entriesToStore.filter { entry in
            entry.carbs == 0 && (entry.fat ?? 0 > 0 || entry.protein ?? 0 > 0)
        }

        // Create additional Carb (non-FPU) entries with fat/protein amounts and carbs == 0
        for entry in fpuOnlyEntries {
            let additionalEntry = CarbsEntry(
                id: entry.id,
                createdAt: entry.createdAt,
                actualDate: entry.actualDate,
                carbs: Decimal(0),
                fat: entry.fat,
                protein: entry.protein,
                note: entry.note,
                enteredBy: entry.enteredBy,
                isFPU: false, // it should be a Carb entry
                fpuID: entry.fpuID
            )
            entriesToStore.append(additionalEntry)
        }

        await saveCarbsToStore(entries: entriesToStore, areFetchedFromRemote: areFetchedFromRemote, pool: pool)
        await saveCarbEquivalents(entries: entriesToStore, areFetchedFromRemote: areFetchedFromRemote, pool: pool)
    }

    private func filterRemoteEntries(entries: [CarbsEntry]) async throws -> [CarbsEntry] {
        // Fetch the dates of all carb entries within the last day from GRDB.
        let existing24hCarbEntries = (try? await CarbEntryStore.fetchRecent()) ?? []

        // Extract dates into a set for efficient lookup.
        let existingTimestamps = Set(existing24hCarbEntries.compactMap(\.date))

        // Remove all entries that have a matching date in existingTimestamps
        var filteredEntries = entries
        filteredEntries.removeAll { entry in
            let entryDate = entry.actualDate ?? entry.createdAt
            return existingTimestamps.contains(entryDate)
        }

        return filteredEntries
    }

    /**
     Converts fat and protein into delayed carb-equivalent entries (FPU handling).

     Behavior:

     - Calculates carb equivalents from fat and protein
       ((fat × 9 + protein × 4) / 10 × adjustment factor).
     - Rounds down to whole grams.
     - Drops values below 10 g.
     - Caps total equivalents at 99 g.
     - Splits into up to 3 entries.
     - Caps each entry at 33 g.
     - Distributes grams as evenly as possible.

     Timing:

     - First entry is scheduled after the configured delay
       (default: 60 minutes) from the carb entry timestamp.
     - Additional entries are spaced 30 minutes apart.

     Example (default):

     - Carb entry at T
     - 1st equivalent at T + 60 min
     - 2nd equivalent at T + 90 min
     - 3rd equivalent at T + 120 min

     Generated entries:

     - Are marked with `isFPU = true`
     - Contain only carbs (fat and protein set to 0)
     - Share the same `fpuID` as the original carb entry

     - Parameters:
       - entries: An array of `CarbsEntry` objects representing the carb equivalent entries to be processed.
       - fat: The amount of fat in the last entry.
       - protein: The amount of protein in the last entry.
       - createdAt: The creation date of the last entry.

     - Returns: A tuple containing the array of future carb entries and the total carb equivalents.
     */
    private func processFPU(
        entries: [CarbsEntry],
        fat: Decimal,
        protein: Decimal,
        createdAt: Date,
        actualDate: Date?
    ) -> ([CarbsEntry], Decimal) {
        let trioSettings = settings.settings
        let providerSettings = settingsProvider.settings

        let adjustment = trioSettings.individualAdjustmentFactor
            .clamp(to: providerSettings.individualAdjustmentFactor)

        let delayMinutes = trioSettings.delay
            .clamp(to: providerSettings.delay)

        let spreadInterval = trioSettings.minuteInterval
            .clamp(to: providerSettings.minuteInterval)

        // Constraints
        let maxTotalGrams = 99
        let maxEntries = 3
        let maxPerEntry = 33
        let minPerEntry = 10
        let spacing = TimeInterval(spreadInterval * 60)

        // kcal -> carb equivalents (kcal/10 * adjustment), rounded down to whole grams
        let kcal = protein * 4 + fat * 9
        let rawEquivalents = Int((kcal / 10) * adjustment)
        let totalGrams = min(maxTotalGrams, max(0, rawEquivalents))

        guard totalGrams >= minPerEntry else {
            return ([], Decimal(totalGrams))
        }

        let amounts = splitIntoCarbEquivalents(
            total: totalGrams,
            maxEntries: maxEntries,
            maxPerEntry: maxPerEntry,
            minPerEntry: minPerEntry
        )

        let baseDate = actualDate ?? createdAt
        let start = baseDate.addingTimeInterval(TimeInterval(delayMinutes * 60))
        let fpuID = entries.first?.fpuID ?? UUID().uuidString

        let futureEntries: [CarbsEntry] = amounts.enumerated().map { idx, grams in
            CarbsEntry(
                id: UUID().uuidString,
                createdAt: createdAt,
                actualDate: start.addingTimeInterval(TimeInterval(idx) * spacing),
                carbs: Decimal(grams),
                fat: 0,
                protein: 0,
                note: nil,
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: fpuID
            )
        }

        let totalScheduled = futureEntries.reduce(into: Decimal(0)) { $0 += $1.carbs }
        return (futureEntries, totalScheduled)
    }

    /**
     Splits a total carb-equivalent value into multiple integer entries.

     - Returns no entries if `total` is below `minPerEntry`.
     - Limits output to `maxEntries`.
     - Caps each entry at `maxPerEntry`.
     - Distributes grams evenly (difference ≤ 1 g).
     - Merges or removes entries below `minPerEntry`.

     - Returns:
       Integer gram values representing the split carb equivalents.
     */
    private func splitIntoCarbEquivalents(
        total: Int,
        maxEntries: Int,
        maxPerEntry: Int,
        minPerEntry: Int
    ) -> [Int] {
        guard total >= minPerEntry else { return [] }

        // Choose an entry count that *guarantees* each entry can be <= maxPerEntry
        let needed = (total + maxPerEntry - 1) / maxPerEntry
        let count = min(maxEntries, max(1, needed))

        // Even split (difference between buckets is at most 1)
        func evenSplit(_ total: Int, count: Int) -> [Int] {
            let base = total / count
            let rem = total % count
            return (0 ..< count).map { base + ($0 < rem ? 1 : 0) }
        }

        var buckets = evenSplit(total, count: count)

        // Enforce minPerEntry by merging any too-small tail bucket into the previous one
        // This should be rare, but it keeps the invariant
        if buckets.count > 1 {
            for i in stride(from: buckets.count - 1, through: 1, by: -1) {
                let v = buckets[i]
                guard v > 0, v < minPerEntry else { continue }
                buckets[i - 1] += v
                buckets[i] = 0
            }
            buckets = buckets.filter { $0 > 0 }
        }

        // Guarantee not to exceed maxPerEntry if merging a reduced count
        // Clamp as final guard here
        buckets = buckets.map { min(maxPerEntry, $0) }.filter { $0 >= minPerEntry }

        return buckets
    }

    private func saveCarbEquivalents(entries: [CarbsEntry], areFetchedFromRemote: Bool, pool: DatabasePool? = nil) async {
        guard let lastEntry = entries.last else { return }

        if let fat = lastEntry.fat, let protein = lastEntry.protein, fat > 0 || protein > 0 {
            let (futureCarbEquivalents, carbEquivalentCount) = processFPU(
                entries: entries,
                fat: fat,
                protein: protein,
                createdAt: lastEntry.createdAt,
                actualDate: lastEntry.actualDate
            )

            if carbEquivalentCount > 0 {
                await saveFPUsAsBatchInsert(
                    entries: futureCarbEquivalents,
                    areFetchedFromRemote: areFetchedFromRemote,
                    pool: pool
                )
            }
        }
    }

    private func saveCarbsToStore(entries: [CarbsEntry], areFetchedFromRemote: Bool, pool: DatabasePool? = nil) async {
        guard let entry = entries.last else { return }

        // A fresh UUID is generated for the carb row (mirrors the former Core Data write, which
        // ignored `entry.id` here); the FPU group keeps its shared `fpuID`.
        var fpuID: UUID?
        if entry.fat != nil, entry.protein != nil, let fpuId = entry.fpuID {
            fpuID = UUID(uuidString: fpuId)
        }

        let record = CarbEntryRecord(
            id: UUID(),
            date: entry.actualDate ?? entry.createdAt,
            carbs: Double(truncating: NSDecimalNumber(decimal: entry.carbs)),
            fat: Double(truncating: NSDecimalNumber(decimal: entry.fat ?? 0)),
            protein: Double(truncating: NSDecimalNumber(decimal: entry.protein ?? 0)),
            note: entry.note,
            isFPU: false,
            fpuID: fpuID,
            isUploadedToNS: areFetchedFromRemote,
            isUploadedToHealth: false,
            isUploadedToTidepool: false
        )

        do {
            try await CarbEntryStore.store(record, pool: pool)
        } catch {
            debug(.coreData, "Carbs Storage: \(DebuggingIdentifiers.failed) error saving carbs: \(error)")
        }
    }

    private func saveFPUsAsBatchInsert(entries: [CarbsEntry], areFetchedFromRemote: Bool, pool: DatabasePool? = nil) async {
        // all fpus should only get ONE id per batch insert to be able to delete them referencing the fpuID
        let commonFPUID = UUID(uuidString: entries.first?.fpuID ?? UUID().uuidString)

        let records: [CarbEntryRecord] = entries.compactMap { entry in
            guard let entryId = entry.id else { return nil }
            return CarbEntryRecord(
                id: UUID(uuidString: entryId),
                date: entry.actualDate,
                carbs: Double(truncating: NSDecimalNumber(decimal: entry.carbs)),
                fat: 0,
                protein: 0,
                note: nil,
                isFPU: true,
                fpuID: commonFPUID,
                isUploadedToNS: areFetchedFromRemote,
                // do NOT set Health and Tidepool flags to ensure they will NOT be uploaded
                isUploadedToHealth: false,
                isUploadedToTidepool: false
            )
        }

        do {
            try await CarbEntryStore.batchInsert(records, pool: pool)
            debug(.coreData, "Carbs Storage: \(DebuggingIdentifiers.succeeded) saved fpus to GRDB")

            // Notify subscriber in Home State Model to update the FPU Array
            updateSubject.send(())
        } catch {
            debug(.coreData, "Carbs Storage: \(DebuggingIdentifiers.failed) error while saving fpus to GRDB: \(error)")
        }
    }

    func syncDate() -> Date {
        Date().addingTimeInterval(-1.days.timeInterval)
    }

    func deleteCarbsEntryStored(_ pk: Int64) async {
        do {
            guard let carbEntry = try await CarbEntryStore.fetch(pk: pk) else {
                debug(.coreData, "Carb entry for delete not found. \(DebuggingIdentifiers.failed)")
                return
            }

            // entry has fpuID
            // case 1: carb equivalent entry
            // case 2: "parent" entry, but containing fat and/or protein, and possibly carbs
            // => use fpuID to delete all corresponding entries via batch delete
            if let fpuID = carbEntry.fpuID {
                let deleted = try await CarbEntryStore.deleteByFpuID(fpuID)
                debug(.coreData, "\(DebuggingIdentifiers.succeeded) Deleted \(deleted) items with FpuID \(fpuID)")

                // Notify subscribers of the batch delete
                updateSubject.send(())
            }
            // entry has no fpuID
            // => it's a carb-only entry. use its pk for deletion
            else {
                try await CarbEntryStore.delete(pk: pk)
                debug(.coreData, "CarbsStorage: \(#function) \(DebuggingIdentifiers.succeeded) deleted carb entry from GRDB")
            }
        } catch {
            debug(.coreData, "\(DebuggingIdentifiers.failed) Error deleting carb entry: \(error)")
        }
    }

    func getCarbsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let carbEntries = try await CarbEntryStore.fetchCarbsNotYetUploadedToNightscout()
        return carbEntries.map { result in
            NightscoutTreatment(
                duration: nil,
                rawDuration: nil,
                rawRate: nil,
                absolute: nil,
                rate: nil,
                eventType: .nsCarbCorrection,
                createdAt: result.date,
                enteredBy: CarbsEntry.local,
                bolus: nil,
                insulin: nil,
                notes: result.note,
                carbs: Decimal(result.carbs),
                fat: Decimal(result.fat),
                protein: Decimal(result.protein),
                foodType: result.note,
                targetTop: nil,
                targetBottom: nil,
                id: result.id?.uuidString
            )
        }
    }

    func getFPUsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let fpuEntries = try await CarbEntryStore.fetchFPUsNotYetUploadedToNightscout()
        return fpuEntries.map { result in
            NightscoutTreatment(
                duration: nil,
                rawDuration: nil,
                rawRate: nil,
                absolute: nil,
                rate: nil,
                eventType: .nsCarbCorrection,
                createdAt: result.date,
                enteredBy: CarbsEntry.local,
                bolus: nil,
                insulin: nil,
                notes: result.note,
                carbs: Decimal(result.carbs),
                fat: Decimal(result.fat),
                protein: Decimal(result.protein),
                foodType: result.note,
                targetTop: nil,
                targetBottom: nil,
                id: result.fpuID?.uuidString
            )
        }
    }

    func getCarbsNotYetUploadedToHealth() async throws -> [CarbsEntry] {
        let carbEntries = try await CarbEntryStore.fetchNotYetUploadedToHealth()
        return carbEntries.map { result in
            CarbsEntry(
                id: result.id?.uuidString,
                createdAt: result.date ?? Date(),
                actualDate: result.date,
                carbs: Decimal(result.carbs),
                fat: Decimal(result.fat),
                protein: Decimal(result.protein),
                note: result.note,
                enteredBy: CarbsEntry.local,
                isFPU: result.isFPU,
                fpuID: result.fpuID?.uuidString
            )
        }
    }

    func getCarbsNotYetUploadedToTidepool() async throws -> [CarbsEntry] {
        let carbEntries = try await CarbEntryStore.fetchNotYetUploadedToTidepool()
        return carbEntries.map { result in
            CarbsEntry(
                id: result.id?.uuidString,
                createdAt: result.date ?? Date(),
                actualDate: result.date,
                carbs: Decimal(result.carbs),
                fat: nil,
                protein: nil,
                note: result.note,
                enteredBy: CarbsEntry.local,
                isFPU: nil,
                fpuID: nil
            )
        }
    }
}
