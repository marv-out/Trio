import Foundation
import Swinject

/// GRDB-backed override storage (see `MIGRATION.md`, Step 7).
///
/// The Core Data implementation returned `NSManagedObjectID`s that callers re-fetched across
/// thread/process boundaries. GRDB records are `Sendable` value types, so this protocol now deals
/// in `OverrideRecord` / `OverrideRunRecord` directly — identity is carried by the rowid `pk` or
/// the business `id`. The "disable active + log a run" composite (previously duplicated in the
/// intents, RemoteControl, Watch and the state models) is centralized here.
protocol OverrideStorage {
    func fetchForOverridePresets() async throws -> [OverrideRecord]
    func loadLatestOverrideConfigurations(fetchLimit: Int) async throws -> [OverrideRecord]
    func fetchLatestActiveOverride() async throws -> OverrideRecord?
    func fetchLastCreatedOverride() async throws -> OverrideRecord?
    func fetchPreset(id: String) async throws -> OverrideRecord?
    func calculateTarget(override: OverrideRecord) -> Decimal
    func storeOverride(override: Override) async throws
    func copyRunningOverride(_ override: OverrideRecord) async throws -> OverrideRecord
    func deleteOverridePreset(pk: Int64) async throws
    func reorderPresets(_ presets: [OverrideRecord]) async throws
    /// Enables a single override (becomes the running one): `enabled = true`, `date = now`,
    /// `isUploadedToNS = false`. Returns the updated record.
    @discardableResult func enactOverride(pk: Int64) async throws -> OverrideRecord?
    /// Disables every active override (optionally except `pk`), optionally logging a run for the
    /// first active one. Mirrors the former `disableAllActiveOverrides`.
    func disableAllActiveOverrides(except pk: Int64?, createRunEntry: Bool) async throws
    /// Disables a single override by `pk` and logs a run for it (Home/Watch "stop" actions).
    func cancelOverride(pk: Int64) async throws
    /// Inserts an `OverrideRunStored` row for `override`, linked via `overridePk`.
    func saveOverrideRun(for override: OverrideRecord) async throws
    func getOverridesNotYetUploadedToNightscout() async throws -> [NightscoutExercise]
    func getOverrideRunsNotYetUploadedToNightscout() async throws -> [NightscoutExercise]
    func checkIfShouldDeleteNightscoutOverrideEntry(
        forCreatedAt createdAtString: String,
        newDuration: Int?,
        using nightscout: NightscoutAPI
    ) async throws
    func getPresetOverridesForNightscout() async throws -> [NightscoutPresetOverride]
}

final class BaseOverrideStorage: OverrideStorage, Injectable {
    init(resolver: Resolver) {
        injectServices(resolver)
    }

    private var dateFormatter: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        dateFormatter.locale = Locale.current
        return dateFormatter
    }

    // MARK: - Fetches

    func fetchForOverridePresets() async throws -> [OverrideRecord] {
        try await OverrideStore.fetchPresets()
    }

    /// `fetchLimit <= 0` means "no limit" (the old Core Data `fetchLimit: 0` convention).
    func loadLatestOverrideConfigurations(fetchLimit: Int) async throws -> [OverrideRecord] {
        try await OverrideStore.fetchActiveConfigurations(limit: fetchLimit > 0 ? fetchLimit : nil)
    }

    func fetchLatestActiveOverride() async throws -> OverrideRecord? {
        try await OverrideStore.fetchLatestActive()
    }

    func fetchLastCreatedOverride() async throws -> OverrideRecord? {
        try await OverrideStore.fetchLastCreated()
    }

    func fetchPreset(id: String) async throws -> OverrideRecord? {
        try await OverrideStore.fetch(id: id)
    }

    /// Pure value-type replacement for the former `@MainActor calculateTarget`.
    func calculateTarget(override: OverrideRecord) -> Decimal {
        override.calculatedTarget
    }

    // MARK: - Writes

    func storeOverride(override: Override) async throws {
        var record = OverrideRecord()
        record.id = UUID().uuidString
        record.name = override.name.isEmpty
            ? "Override \(dateFormatter.string(from: Date()))"
            : override.name
        record.date = override.date
        record.isPreset = override.isPreset
        record.isUploadedToNS = false
        record.duration = override.duration
        record.indefinite = override.indefinite
        record.percentage = override.percentage
        record.isfAndCr = override.isfAndCr
        record.isf = override.isf
        record.cr = override.cr
        record.enabled = override.enabled
        record.smbIsOff = override.smbIsOff
        record.target = override.overrideTarget ? override.target : 0

        if override.advancedSettings {
            record.advancedSettings = true
            record.smbMinutes = override.smbMinutes
            record.uamMinutes = override.uamMinutes
        }

        if override.smbIsScheduledOff {
            record.smbIsScheduledOff = true
            record.start = override.start
            record.end = override.end
        } else {
            record.smbIsScheduledOff = false
        }

        // `orderPosition` (presets only) is assigned atomically inside the store.
        try await OverrideStore.store(record)
    }

    func copyRunningOverride(_ override: OverrideRecord) async throws -> OverrideRecord {
        try await OverrideStore.copyRunning(override)
    }

    func deleteOverridePreset(pk: Int64) async throws {
        try await OverrideStore.delete(pk: pk)
    }

    func reorderPresets(_ presets: [OverrideRecord]) async throws {
        try await OverrideStore.reorder(presets)
    }

    @discardableResult func enactOverride(pk: Int64) async throws -> OverrideRecord? {
        guard var record = try await OverrideStore.fetch(pk: pk) else { return nil }
        record.enabled = true
        record.date = Date()
        record.isUploadedToNS = false
        try await OverrideStore.update(record)
        return record
    }

    func disableAllActiveOverrides(except pk: Int64? = nil, createRunEntry: Bool) async throws {
        let active = try await OverrideStore.fetchActiveConfigurations()
        guard !active.isEmpty else { return }

        if createRunEntry, let canceled = active.first {
            try await saveOverrideRun(for: canceled)
        }

        let pksToDisable = active.compactMap(\.pk).filter { $0 != pk }
        try await OverrideStore.disable(pks: pksToDisable)
    }

    func cancelOverride(pk: Int64) async throws {
        guard var record = try await OverrideStore.fetch(pk: pk) else { return }
        record.enabled = false
        try await OverrideStore.update(record)
        try await saveOverrideRun(for: record)
    }

    func saveOverrideRun(for override: OverrideRecord) async throws {
        let run = OverrideRunRecord(
            id: UUID(),
            name: override.name,
            startDate: override.date ?? .distantPast,
            endDate: Date(),
            isUploadedToNS: false,
            target: calculateTarget(override: override),
            overridePk: override.pk
        )
        try await OverrideRunStore.saveRun(run)
    }

    // MARK: - Nightscout

    func getOverridesNotYetUploadedToNightscout() async throws -> [NightscoutExercise] {
        let overrides = try await OverrideStore.fetchNotYetUploaded()
        return overrides.map(Self.nightscoutExercise(from:))
    }

    /// Pure mapping `OverrideRecord` → `NightscoutExercise` (exposed for tests).
    static func nightscoutExercise(from override: OverrideRecord) -> NightscoutExercise {
        let duration = override.indefinite ? Decimal(43200) : (override.duration ?? 0) // 43200 min = 30 days
        return NightscoutExercise(
            duration: Int(truncating: duration as NSNumber),
            eventType: OverrideStored.EventType.nsExercise,
            createdAt: override.date ?? Date(),
            enteredBy: NightscoutExercise.local,
            notes: override.name ?? String(localized: "Custom Override"),
            id: UUID(uuidString: override.id ?? UUID().uuidString)
        )
    }

    func getOverrideRunsNotYetUploadedToNightscout() async throws -> [NightscoutExercise] {
        let runs = try await OverrideRunStore.fetchNotYetUploaded()
        var result: [NightscoutExercise] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            var durationInMinutes = (run.endDate?.timeIntervalSince(run.startDate ?? Date()) ?? 1) / 60
            durationInMinutes = durationInMinutes < 1 ? 1 : durationInMinutes
            // `overrideRun.override?.date` traversal becomes a foreign-key lookup.
            let sourceDate = try await OverrideRunStore.sourceOverrideDate(for: run)
            result.append(NightscoutExercise(
                duration: Int(durationInMinutes),
                eventType: OverrideStored.EventType.nsExercise,
                createdAt: (run.startDate ?? sourceDate) ?? Date(),
                enteredBy: NightscoutExercise.local,
                notes: run.name ?? String(localized: "Custom Override"),
                id: run.id
            ))
        }
        return result
    }

    /// This check is needed to force re-rendering of overrides in the Nightscout main chart
    /// if the override duration has changed (cancelled, customized or replaced with other override),
    /// since just updating durations in existing entries doesn't trigger re-rendering.
    func checkIfShouldDeleteNightscoutOverrideEntry(
        forCreatedAt createdAtString: String,
        newDuration: Int?,
        using nightscout: NightscoutAPI
    ) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let jsonDate = formatter.date(from: createdAtString) else {
            debug(.nightscout, "Could not parse override created_at string: \(createdAtString)")
            return
        }

        /// Tolerance window (in seconds) for rounding/conversion differences between Core Data /
        /// GRDB dates and the NightscoutExercise JSON.
        let tolerance: TimeInterval = 0.1
        let lowerBound = jsonDate.addingTimeInterval(-tolerance)
        let upperBound = jsonDate.addingTimeInterval(tolerance)

        let matches = try await OverrideStore.fetch(from: lowerBound, to: upperBound)
        guard let record = matches.first, let recordDate = record.date else { return }

        let duration = record.indefinite ? Decimal(43200) : (record.duration ?? 0)
        let existing = NightscoutExercise(
            duration: Int(truncating: duration as NSNumber),
            eventType: OverrideStored.EventType.nsExercise,
            createdAt: recordDate,
            enteredBy: NightscoutExercise.local,
            notes: record.name ?? String(localized: "Custom Override"),
            id: UUID(uuidString: record.id ?? UUID().uuidString)
        )

        // Only delete existing nightscout entries if the durations differ.
        if let existingDuration = existing.duration, let newDuration = newDuration, existingDuration != newDuration {
            try await nightscout.deleteNightscoutOverride(withCreatedAt: createdAtString)
        }
    }

    func getPresetOverridesForNightscout() async throws -> [NightscoutPresetOverride] {
        let presets = try await OverrideStore.fetchPresets()
        return presets.map { preset in
            let duration = (preset.duration ?? 0) != 0 ? preset.duration : nil
            let percentage = preset.percentage != 0 ? preset.percentage : nil
            let target = (preset.target ?? 0) != 0 ? preset.target : nil
            return NightscoutPresetOverride(
                name: preset.name ?? "",
                duration: duration,
                percentage: percentage,
                target: target
            )
        }
    }
}
