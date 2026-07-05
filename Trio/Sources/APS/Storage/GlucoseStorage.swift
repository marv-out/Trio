import AVFAudio
import Combine
import Foundation
import GRDB
import LoopKit
import SwiftDate
import SwiftUI
import Swinject

protocol GlucoseStorage {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    func storeGlucose(_ glucose: [BloodGlucose]) async throws
    func backfillGlucose(_ glucose: [BloodGlucose]) async throws
    func addManualGlucose(glucose: Int)
    func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool
    func syncDate() -> Date
    func filterTooFrequentGlucose(_ glucose: [BloodGlucose], at: Date) -> [BloodGlucose]
    func lastGlucoseDate() -> Date?
    func isGlucoseFresh() -> Bool
    func getGlucoseNotYetUploadedToNightscout() async throws -> [BloodGlucose]
    func getCGMStateNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose]
    func getManualGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose]
    func getGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample]
    func getManualGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample]
//    func getGlucoseStatus() async throws -> GlucoseStatus? // FIXME: prepared for later use
    var alarm: GlucoseAlarm? { get }
    func deleteGlucose(_ pk: Int64) async
}

final class BaseGlucoseStorage: GlucoseStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BaseGlucoseStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!

    private let updateSubject = PassthroughSubject<Void, Never>()

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    private enum Config {
        static let filterTime: TimeInterval = 3.5 * 60
        static let minimumGlucose: Int = 39
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if settingsManager.settings.units == .mmolL {
            formatter.maximumFractionDigits = 1
        }
        formatter.decimalSeparator = "."
        return formatter
    }

    /// Backfills glucose values and stores them in GRDB.
    ///
    /// CGM managers will sometimes backfill glucose readings. To handle these backfilled values
    /// correctly, we need some logic to handle a few cases:
    ///  - _Not_ adding back previously deleted glucose
    ///  - Avoiding duplicate values for the same reading
    ///  - Avoiding overlapping glucose readings when switching sources
    ///  Of these corner cases, overlapping glucose readings when switching sources is both
    ///  the most challenging and most rare since it would happen if wearing two devices and
    ///  switching or moving from direct glucose handling to xdrip. It's not worth the complexity
    ///  to deal with source switching perfectly, so instead we will backfill glucose if and only if
    ///  it isn't within 3.5 minutes of an existing glucose reading, which is simple but not perfect.
    ///  But since this is a corner case that really shouldn't happen often, it's good enough.
    func backfillGlucose(_ glucose: [BloodGlucose]) async throws {
        try await backfillGlucose(glucose, in: nil)
    }

    /// Pool-injecting variant for tests (mirrors `BaseCarbsStorage.storeCarbs(…, in:)`): `pool == nil`
    /// uses the shared GRDB store; tests pass an in-memory pool.
    func backfillGlucose(_ glucose: [BloodGlucose], in pool: DatabasePool?) async throws {
        let clamped = clampToMinimum(glucose)

        // Remove already-deleted glucose values (tombstones), 1s buffer.
        let withoutDeletedGlucose = try await filterAgainstDeletedTombstones(clamped, timeBuffer: 1, pool: pool)

        // Check for a 3.5 minute difference between existing values.
        let filteredGlucose = try await filterAgainstExistingGlucose(
            withoutDeletedGlucose,
            timeBuffer: 3.5 * 60,
            pool: pool
        )

        guard !filteredGlucose.isEmpty else { return }

        try await GlucoseStore.batchInsert(filteredGlucose.map(makeGlucoseRecord), pool: pool)
        updateSubject.send()
    }

    func storeGlucose(_ glucose: [BloodGlucose]) async throws {
        try await storeGlucose(glucose, in: nil)
    }

    func storeGlucose(_ glucose: [BloodGlucose], in pool: DatabasePool?) async throws {
        let clamped = clampToMinimum(glucose)

        // Get new glucose values that don't exist yet (1s buffer).
        let newGlucose = try await filterAgainstExistingGlucose(clamped, timeBuffer: 1, pool: pool)
        guard !newGlucose.isEmpty else { return }

        try await GlucoseStore.batchInsert(newGlucose.map(makeGlucoseRecord), pool: pool)
        updateSubject.send()

        // Store CGM state if needed (JSON FileStorage, unchanged).
        storeCGMState(clamped)
    }

    /// Clamps CGM-sourced glucose readings to a minimum of `Config.minimumGlucose`
    /// (39 mg/dL — the official Libre/Dexcom algorithmic floor). Some CGM plugins
    /// (notably LibreTransmitter) deliberately bypass the vendor floor and forward
    /// values down to 1 mg/dL; the JS oref `glucose-get-last` filter then drops them
    /// (`> 38`) and the loop has no fresh BG during the most dangerous range. We
    /// clamp here so determination always has a usable value and emit a debug log
    /// line so the raw reading survives for diagnostics.
    private func clampToMinimum(_ glucose: [BloodGlucose]) -> [BloodGlucose] {
        glucose.map { entry in
            var clamped = entry
            if let raw = entry.glucose, raw < Config.minimumGlucose {
                debug(
                    .deviceManager,
                    "Clamping sub-\(Config.minimumGlucose) glucose: raw=\(raw) at \(entry.dateString) -> \(Config.minimumGlucose)"
                )
                clamped.glucose = Config.minimumGlucose
            }
            if let raw = entry.sgv, raw < Config.minimumGlucose {
                clamped.sgv = Config.minimumGlucose
            }
            return clamped
        }
    }

    /// Filters out incoming readings that are within `timeBuffer` of an existing `glucoseStored` row.
    private func filterAgainstExistingGlucose(
        _ glucose: [BloodGlucose],
        timeBuffer: TimeInterval,
        pool: DatabasePool?
    ) async throws -> [BloodGlucose] {
        guard let range = bufferedRange(for: glucose, timeBuffer: timeBuffer) else { return glucose }
        let existingDates = try await GlucoseStore.existingDates(from: range.from, to: range.to, pool: pool)
        return filterGlucoseValues(glucose, existingDates: existingDates, timeBuffer: timeBuffer)
    }

    /// Filters out incoming readings that are within `timeBuffer` of a `deletedGlucoseStored` tombstone.
    private func filterAgainstDeletedTombstones(
        _ glucose: [BloodGlucose],
        timeBuffer: TimeInterval,
        pool: DatabasePool?
    ) async throws -> [BloodGlucose] {
        guard let range = bufferedRange(for: glucose, timeBuffer: timeBuffer) else { return glucose }
        let existingDates = try await DeletedGlucoseStore.existingDates(from: range.from, to: range.to, pool: pool)
        return filterGlucoseValues(glucose, existingDates: existingDates, timeBuffer: timeBuffer)
    }

    /// The `[first - buffer, last + buffer]` window covering the incoming readings, or `nil` if empty.
    private func bufferedRange(for glucose: [BloodGlucose], timeBuffer: TimeInterval) -> (from: Date, to: Date)? {
        let datesToCheck = glucose.map(\.dateString).sorted()
        guard let first = datesToCheck.first, let last = datesToCheck.last else { return nil }
        return (first.addingTimeInterval(-timeBuffer), last.addingTimeInterval(timeBuffer))
    }

    /// Removes readings within `timeBuffer` of any `existingDates`.
    ///
    /// ⚠️ **Precision (Step 11 lesson).** `existingDates` are the DB-stored (millisecond) dates, and the
    /// comparison is a *proximity* match against them — not exact `Date` equality. A raw incoming `Date`
    /// carries sub-millisecond components the round-tripped DB value does not, so an exact-equality key
    /// (in memory) would miss duplicates; the buffer comparison against DB-stored dates is robust.
    ///
    /// This is an inefficient filtering algorithm, but the time spans are short and duplicates are rare,
    /// so in the common case there won't be any existing dates.
    private func filterGlucoseValues(
        _ glucose: [BloodGlucose],
        existingDates: [Date],
        timeBuffer: TimeInterval
    ) -> [BloodGlucose] {
        guard !existingDates.isEmpty else { return glucose }
        return glucose.filter { glucose in
            for existingDate in existingDates {
                let difference = abs(existingDate.timeIntervalSince(glucose.dateString))
                if difference <= timeBuffer {
                    return false
                }
            }
            return true
        }
    }

    /// Maps an incoming `BloodGlucose` to a fresh CGM `GlucoseRecord` (mirrors the former
    /// `configureGlucoseEntry`): new `id`, upload flags cleared, `isManual == false`.
    private func makeGlucoseRecord(from glucose: BloodGlucose) -> GlucoseRecord {
        GlucoseRecord(
            id: UUID(),
            date: glucose.dateString,
            glucose: Int16(glucose.glucose ?? 0),
            direction: glucose.direction?.rawValue,
            isManual: false
        )
    }

    private func storeCGMState(_ glucose: [BloodGlucose]) {
        debug(.deviceManager, "start storage cgmState")
        storage.transaction { storage in
            let file = OpenAPS.Monitor.cgmState
            var treatments = storage.retrieve(file, as: [NightscoutTreatment].self) ?? []
            var updated = false

            for x in glucose {
                guard let sessionStartDate = x.sessionStartDate else { continue }

                // Skip if we already have a recent treatment
                if let lastTreatment = treatments.last,
                   let createdAt = lastTreatment.createdAt,
                   abs(createdAt.timeIntervalSince(sessionStartDate)) < TimeInterval(60)
                {
                    continue
                }

                let notes = createCGMStateNotes(transmitterID: x.transmitterID, activationDate: x.activationDate)
                let treatment = createCGMStateTreatment(sessionStartDate: sessionStartDate, notes: notes)

                debug(.deviceManager, "CGM sensor change \(treatment)")
                treatments.append(treatment)
                updated = true
            }

            if updated {
                storage.save(
                    treatments.filter { $0.createdAt?.addingTimeInterval(30.days.timeInterval) ?? .distantPast > Date() },
                    as: file
                )
            }
        }
    }

    private func createCGMStateNotes(transmitterID: String?, activationDate: Date?) -> String {
        var notes = ""
        if let t = transmitterID {
            notes = t
        }
        if let a = activationDate {
            notes = "\(notes) activated on \(a)"
        }
        return notes
    }

    private func createCGMStateTreatment(sessionStartDate: Date, notes: String) -> NightscoutTreatment {
        NightscoutTreatment(
            duration: nil,
            rawDuration: nil,
            rawRate: nil,
            absolute: nil,
            rate: nil,
            eventType: .nsSensorChange,
            createdAt: sessionStartDate,
            enteredBy: NightscoutTreatment.local,
            bolus: nil,
            insulin: nil,
            notes: notes,
            carbs: nil,
            fat: nil,
            protein: nil,
            targetTop: nil,
            targetBottom: nil
        )
    }

    func addManualGlucose(glucose: Int) {
        let record = GlucoseRecord(
            id: UUID(),
            date: Date(),
            glucose: Int16(glucose),
            isManual: true
        )

        Task {
            do {
                try await GlucoseStore.store(record)
                // Glucose subscribers already listen to the update publisher, so call here to update
                // glucose-related data.
                updateSubject.send()
            } catch {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to save manual glucose to GRDB with error: \(error)"
                )
            }
        }
    }

    func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool {
        guard let glucoseDate = glucoseDate else { return false }
        return glucoseDate > Date().addingTimeInterval(-6 * 60)
    }

    func syncDate() -> Date {
        do {
            return try GlucoseStore.fetchLatestDateSync() ?? .distantPast
        } catch {
            debugPrint("Fetch error: \(DebuggingIdentifiers.failed) \(error)")
            return .distantPast
        }
    }

    func lastGlucoseDate() -> Date? {
        do {
            return try GlucoseStore.fetchLatestDateSync()
        } catch let error as NSError {
            debug(.storage, "Fetch error: \(DebuggingIdentifiers.failed) \(error), \(error.userInfo)")
            return nil
        }
    }

    func isGlucoseFresh() -> Bool {
        Date().timeIntervalSince(lastGlucoseDate() ?? .distantPast) <= Config.filterTime
    }

    func filterTooFrequentGlucose(_ glucose: [BloodGlucose], at date: Date) -> [BloodGlucose] {
        var lastDate = date
        var filtered: [BloodGlucose] = []
        let sorted = glucose.sorted { $0.date < $1.date }

        for entry in sorted {
            guard entry.dateString.addingTimeInterval(-Config.filterTime) > lastDate else {
                continue
            }
            filtered.append(entry)
            lastDate = entry.dateString
        }

        return filtered
    }

    // Fetch glucose that is not uploaded to Nightscout yet
    /// - Returns: Array of BloodGlucose to ensure the correct format for the NS Upload
    func getGlucoseNotYetUploadedToNightscout() async throws -> [BloodGlucose] {
        let records = try await GlucoseStore.fetchNotYetUploaded(channel: .nightscout)
        return records.map { record in
            if record.isManual {
                BloodGlucose(
                    id: record.id?.uuidString ?? UUID().uuidString,
                    mbg: Int(record.glucose),
                    date: Decimal(record.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: record.date ?? Date(),
                    type: "mbg"
                )
            } else {
                BloodGlucose(
                    id: record.id?.uuidString ?? UUID().uuidString,
                    sgv: Int(record.glucose),
                    direction: BloodGlucose.Direction(from: record.direction ?? ""),
                    date: Decimal(record.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: record.date ?? Date(),
                    unfiltered: Decimal(record.glucose),
                    filtered: Decimal(record.glucose),
                    noise: nil,
                    glucose: Int(record.glucose),
                    type: "sgv"
                )
            }
        }
    }

    func getCGMStateNotYetUploadedToNightscout() async -> [NightscoutTreatment] {
        async let alreadyUploaded: [NightscoutTreatment] = storage
            .retrieveAsync(OpenAPS.Nightscout.uploadedCGMState, as: [NightscoutTreatment].self) ?? []
        async let allValues: [NightscoutTreatment] = storage
            .retrieveAsync(OpenAPS.Monitor.cgmState, as: [NightscoutTreatment].self) ?? []

        let (alreadyUploadedValues, allValuesSet) = await (alreadyUploaded, allValues)
        return Array(Set(allValuesSet).subtracting(Set(alreadyUploadedValues)))
    }

    // Fetch glucose that is not uploaded to Apple Health yet
    /// - Returns: Array of BloodGlucose to ensure the correct format for the Health Upload
    func getGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose] {
        let records = try await GlucoseStore.fetchNotYetUploaded(channel: .health)
        return records.map(makeSgvBloodGlucose)
    }

    // Fetch manual glucose that is not uploaded to Apple Health yet
    func getManualGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose] {
        let records = try await GlucoseStore.fetchNotYetUploaded(channel: .health, manualOnly: true)
        return records.map(makeSgvBloodGlucose)
    }

    // Fetch glucose that is not uploaded to Tidepool yet
    /// - Returns: Array of StoredGlucoseSample to ensure the correct format for Tidepool upload
    func getGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample] {
        let records = try await GlucoseStore.fetchNotYetUploaded(channel: .tidepool)
        return records.map(makeSgvBloodGlucose).map { $0.convertStoredGlucoseSample(isManualGlucose: false) }
    }

    // Fetch manual glucose that is not uploaded to Tidepool yet
    /// - Returns: Array of StoredGlucoseSample to ensure the correct format for the Tidepool upload
    func getManualGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample] {
        let records = try await GlucoseStore.fetchNotYetUploaded(channel: .tidepool, manualOnly: true)
        return records.map(makeSgvBloodGlucose).map { $0.convertStoredGlucoseSample(isManualGlucose: true) }
    }

    /// Maps a `GlucoseRecord` to the `sgv`-shaped `BloodGlucose` used by the Health / Tidepool uploads.
    private func makeSgvBloodGlucose(from record: GlucoseRecord) -> BloodGlucose {
        BloodGlucose(
            id: record.id?.uuidString ?? UUID().uuidString,
            sgv: Int(record.glucose),
            direction: BloodGlucose.Direction(from: record.direction ?? ""),
            date: Decimal(record.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
            dateString: record.date ?? Date(),
            unfiltered: Decimal(record.glucose),
            filtered: Decimal(record.glucose),
            noise: nil,
            glucose: Int(record.glucose)
        )
    }

    func deleteGlucose(_ pk: Int64) async {
        do {
            try await GlucoseStore.delete(pk: pk)
            updateSubject.send()
            debugPrint("\(#file) \(#function) \(DebuggingIdentifiers.succeeded) deleted glucose from GRDB")
        } catch {
            debugPrint(
                "\(#file) \(#function) \(DebuggingIdentifiers.failed) error while deleting glucose from GRDB: \(error)"
            )
        }
    }

    var alarm: GlucoseAlarm? {
        /// glucose can not be older than 20 minutes due to the fetch window
        do {
            guard let glucose = try GlucoseStore.fetchLatestSync() else { return nil }

            let glucoseValue = glucose.glucose

            if Decimal(glucoseValue) <= settingsManager.settings.lowGlucose {
                return .low
            }

            if Decimal(glucoseValue) >= settingsManager.settings.highGlucose {
                return .high
            }

            return nil
        } catch {
            debugPrint("Error fetching latest glucose: \(error)")
            return nil
        }
    }
}

protocol GlucoseObserver {
    func glucoseDidUpdate(_ glucose: [BloodGlucose])
}

enum GlucoseAlarm {
    case high
    case low

    var displayName: String {
        switch self {
        case .high:
            return String(localized: "LOWALERT!", comment: "LOWALERT!")
        case .low:
            return String(localized: "HIGHALERT!", comment: "HIGHALERT!")
        }
    }
}
