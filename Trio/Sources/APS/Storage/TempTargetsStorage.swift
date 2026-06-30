import Foundation
import SwiftDate
import Swinject

protocol TempTargetsObserver {
    func tempTargetsDidUpdate(_ targets: [TempTarget])
}

/// GRDB-backed temp-target storage (see `MIGRATION.md`, Step 8).
///
/// Same shape as Step 7's `OverrideStorage`: the protocol now deals in `TempTargetRecord` /
/// `TempTargetRunRecord` value types instead of `NSManagedObjectID`s, and the "disable active +
/// log a run" composite (previously duplicated in the intents, RemoteControl, Watch and the state
/// models) is centralized here. The JSON `FileStorage` mirror (`recent()`, `current()`,
/// `presets()`, `saveTempTargetsToStorage`) is *not* Core Data and is unchanged — mutating call
/// sites still write to it in addition to GRDB.
protocol TempTargetsStorage {
    func storeTempTarget(tempTarget: TempTarget) async throws
    func saveTempTargetsToStorage(_ targets: [TempTarget])
    func fetchForTempTargetPresets() async throws -> [TempTargetRecord]
    func fetchScheduledTempTargets() async throws -> [TempTargetRecord]
    func fetchScheduledTempTarget(for targetDate: Date) async throws -> TempTargetRecord?
    func fetchPreset(id: UUID) async throws -> TempTargetRecord?
    func copyRunningTempTarget(_ tempTarget: TempTargetRecord) async throws -> TempTargetRecord
    func deleteTempTargetPreset(pk: Int64) async throws
    func reorderPresets(_ presets: [TempTargetRecord]) async throws
    func loadLatestTempTargetConfigurations(fetchLimit: Int) async throws -> [TempTargetRecord]
    func fetchLatestActiveTempTarget() async throws -> TempTargetRecord?
    /// Enables a single temp target (becomes the running one): `enabled = true`, `date = now`,
    /// `isUploadedToNS = false`. Returns the updated record.
    @discardableResult func enactTempTarget(pk: Int64) async throws -> TempTargetRecord?
    /// Disables every active temp target (optionally except `pk`), optionally logging a run for the
    /// first active one. Returns `true` if anything was disabled (so callers can mirror the JSON
    /// `FileStorage` cancel write only when state actually changed).
    @discardableResult func disableAllActiveTempTargets(except pk: Int64?, createRunEntry: Bool) async throws -> Bool
    /// Disables a single temp target by `pk` and logs a run for it — but only for "real" targets
    /// (`duration != 0 && target != 0`), matching the former Home cancel logic which skipped
    /// Nightscout cancel entries.
    func cancelTempTarget(pk: Int64) async throws
    /// Inserts a `TempTargetRunStored` row for `tempTarget`, linked via `tempTargetPk`.
    func saveTempTargetRun(for tempTarget: TempTargetRecord) async throws
    func syncDate() -> Date
    func recent() -> [TempTarget]
    func getTempTargetsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getTempTargetRunsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func presets() -> [TempTarget]
    func current() -> TempTarget?
    func existsTempTarget(with date: Date) async throws -> Bool
}

final class BaseTempTargetsStorage: TempTargetsStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BaseTempTargetsStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    /// `100 mg/dL` fallback target in the user's display unit (mirrors the former Core Data mapping).
    private var defaultTargetInUserUnits: Decimal {
        settingsManager.settings.units == .mgdL ? 100.0 : 100.asMmolL
    }

    // MARK: - Fetches

    func fetchForTempTargetPresets() async throws -> [TempTargetRecord] {
        try await TempTargetStore.fetchPresets()
    }

    /// `fetchLimit <= 0` means "no limit" (the old Core Data `fetchLimit: 0` convention).
    func loadLatestTempTargetConfigurations(fetchLimit: Int) async throws -> [TempTargetRecord] {
        try await TempTargetStore.fetchActiveConfigurations(limit: fetchLimit > 0 ? fetchLimit : nil)
    }

    func fetchLatestActiveTempTarget() async throws -> TempTargetRecord? {
        try await TempTargetStore.fetchLatestActive()
    }

    func fetchScheduledTempTargets() async throws -> [TempTargetRecord] {
        try await TempTargetStore.fetchScheduled()
    }

    func fetchScheduledTempTarget(for targetDate: Date) async throws -> TempTargetRecord? {
        try await TempTargetStore.fetchScheduled(for: targetDate)
    }

    func fetchPreset(id: UUID) async throws -> TempTargetRecord? {
        try await TempTargetStore.fetch(id: id)
    }

    func existsTempTarget(with date: Date) async throws -> Bool {
        try await TempTargetStore.exists(date: date)
    }

    // MARK: - Writes

    func storeTempTarget(tempTarget: TempTarget) async throws {
        var record = TempTargetRecord()
        record.id = UUID()
        record.date = tempTarget.createdAt
        record.enabled = tempTarget.enabled ?? false
        record.duration = tempTarget.duration
        record.isUploadedToNS = false
        record.name = tempTarget.name
        record.target = tempTarget.targetTop ?? 0
        record.isPreset = tempTarget.isPreset ?? false
        record.enteredBy = tempTarget.enteredBy

        // Nullify half basal target to ensure the latest HBT is used via OpenAPS Manager when
        // sending TT data to oref; set it only if it differs from the preference default.
        record.halfBasalTarget = nil
        if let halfBasalTarget = tempTarget.halfBasalTarget,
           halfBasalTarget != settingsManager.preferences.halfBasalExerciseTarget
        {
            record.halfBasalTarget = halfBasalTarget
        }

        // `orderPosition` (presets only) is assigned atomically inside the store.
        try await TempTargetStore.store(record)
    }

    func copyRunningTempTarget(_ tempTarget: TempTargetRecord) async throws -> TempTargetRecord {
        try await TempTargetStore.copyRunning(tempTarget)
    }

    func deleteTempTargetPreset(pk: Int64) async throws {
        try await TempTargetStore.delete(pk: pk)
    }

    func reorderPresets(_ presets: [TempTargetRecord]) async throws {
        try await TempTargetStore.reorder(presets)
    }

    @discardableResult func enactTempTarget(pk: Int64) async throws -> TempTargetRecord? {
        guard var record = try await TempTargetStore.fetch(pk: pk) else { return nil }
        record.enabled = true
        record.date = Date()
        record.isUploadedToNS = false
        try await TempTargetStore.update(record)
        return record
    }

    @discardableResult func disableAllActiveTempTargets(except pk: Int64? = nil, createRunEntry: Bool) async throws -> Bool {
        let active = try await TempTargetStore.fetchActiveConfigurations()
        guard !active.isEmpty else { return false }

        if createRunEntry, let canceled = active.first {
            try await saveTempTargetRun(for: canceled)
        }

        let pksToDisable = active.compactMap(\.pk).filter { $0 != pk }
        try await TempTargetStore.disable(pks: pksToDisable)
        return true
    }

    func cancelTempTarget(pk: Int64) async throws {
        guard var record = try await TempTargetStore.fetch(pk: pk) else { return }
        record.enabled = false
        try await TempTargetStore.update(record)

        // Do not log a run for Nightscout "cancel" entries (duration/target == 0).
        if (record.duration ?? 0) != 0, (record.target ?? 0) != 0 {
            try await saveTempTargetRun(for: record)
        }
    }

    func saveTempTargetRun(for tempTarget: TempTargetRecord) async throws {
        let run = TempTargetRunRecord(
            id: UUID(),
            name: tempTarget.name,
            startDate: tempTarget.date ?? .distantPast,
            endDate: Date(),
            isUploadedToNS: false,
            target: tempTarget.target ?? 0,
            tempTargetPk: tempTarget.pk
        )
        try await TempTargetRunStore.saveRun(run)
    }

    // MARK: - FileStorage (JSON mirror — not Core Data, unchanged)

    func saveTempTargetsToStorage(_ targets: [TempTarget]) {
        processQueue.async {
            let file = OpenAPS.Settings.tempTargets
            var uniqEvents: [TempTarget] = []
            self.storage.transaction { storage in
                storage.append(targets, to: file, uniqBy: \.createdAt)

                let retrievedTargets = storage.retrieve(file, as: [TempTarget].self) ?? []
                uniqEvents = retrievedTargets
                    .filter { $0.isWithinLastDay }
                    .sorted(by: { $0.createdAt > $1.createdAt })

                storage.save(uniqEvents, as: file)
            }

            self.broadcaster.notify(TempTargetsObserver.self, on: self.processQueue) {
                $0.tempTargetsDidUpdate(uniqEvents)
            }
        }
    }

    func syncDate() -> Date {
        Date().addingTimeInterval(-1.days.timeInterval)
    }

    func recent() -> [TempTarget] {
        storage.retrieve(OpenAPS.Settings.tempTargets, as: [TempTarget].self)?.reversed() ?? []
    }

    func current() -> TempTarget? {
        guard let last = recent().last else {
            return nil
        }

        guard last.createdAt.addingTimeInterval(Int(last.duration).minutes.timeInterval) > Date(), last.createdAt <= Date(),
              last.duration != 0
        else {
            return nil
        }

        return last
    }

    func presets() -> [TempTarget] {
        storage.retrieve(OpenAPS.Trio.tempTargetsPresets, as: [TempTarget].self)?.reversed() ?? []
    }

    // MARK: - Nightscout

    func getTempTargetsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let tempTargets = try await TempTargetStore.fetchNotYetUploaded()
        let fallback = defaultTargetInUserUnits
        return tempTargets.map { tempTarget in
            NightscoutTreatment(
                duration: Int(truncating: (tempTarget.duration ?? 60) as NSNumber),
                rawDuration: nil,
                rawRate: nil,
                absolute: nil,
                rate: nil,
                eventType: .nsTempTarget,
                createdAt: tempTarget.date ?? Date(),
                enteredBy: tempTarget.enteredBy ?? TempTarget.local,
                bolus: nil,
                insulin: nil,
                notes: tempTarget.name ?? TempTarget.custom,
                carbs: nil,
                targetTop: tempTarget.target ?? fallback,
                targetBottom: tempTarget.target ?? fallback,
                id: tempTarget.id?.uuidString
            )
        }
    }

    func getTempTargetRunsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let runs = try await TempTargetRunStore.fetchNotYetUploaded()
        let fallback = defaultTargetInUserUnits
        var result: [NightscoutTreatment] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            var durationInMinutes = (run.endDate?.timeIntervalSince(run.startDate ?? Date()) ?? 1) / 60
            durationInMinutes = durationInMinutes < 1 ? 1 : durationInMinutes
            // `tempTargetRun.tempTarget?.{date,enteredBy,name}` traversals become a foreign-key lookup.
            let source = try await TempTargetRunStore.sourceTempTarget(for: run)
            result.append(NightscoutTreatment(
                duration: Int(durationInMinutes),
                rawDuration: nil,
                rawRate: nil,
                absolute: nil,
                rate: nil,
                eventType: .nsTempTarget,
                createdAt: (run.startDate ?? source?.date) ?? Date(),
                enteredBy: source?.enteredBy ?? TempTarget.local,
                bolus: nil,
                insulin: nil,
                notes: source?.name ?? TempTarget.custom,
                carbs: nil,
                targetTop: run.target ?? fallback,
                targetBottom: run.target ?? fallback,
                id: run.id?.uuidString
            ))
        }
        return result
    }
}

private extension TempTarget {
    var isActive: Bool {
        let expirationTime = createdAt.addingTimeInterval(Int(duration).minutes.timeInterval)
        return expirationTime > Date() && createdAt <= Date()
    }

    var isWithinLastDay: Bool {
        createdAt.addingTimeInterval(1.days.timeInterval) > Date()
    }
}
