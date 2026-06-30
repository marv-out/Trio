import Foundation
import UIKit

/// Handles intent requests related to temporary presets, such as fetching, enacting, and canceling temp targets.
final class TempPresetsIntentRequest: BaseIntentsRequest {
    /// Enum representing possible errors related to temporary presets.
    enum TempPresetsError: Error {
        case noTempTargetFound
        case noDurationDefined
    }

    /// Tracks whether the intent execution was successful.
    private var intentSuccess: Bool = false

    /// Fetches and processes all available temporary target presets.
    ///
    /// - Returns: An array of `TempPreset` objects.
    /// - Throws: An error if fetching or processing fails.
    func fetchAndProcessTempTargets() async throws -> [TempPreset] {
        // Temp target presets are GRDB value types — no NSManagedObjectID round-trip needed.
        let presets = try await tempTargetsStorage.fetchForTempTargetPresets()
        return try presets.compactMap { preset in
            guard let id = preset.id,
                  let name = preset.name,
                  let target = preset.target,
                  let duration = preset.duration
            else {
                debugPrint("\(#file) \(#function) Missing data for temp target preset.")
                throw TempPresetsError.noTempTargetFound
            }
            return TempPreset(id: id, name: name, targetTop: target, duration: duration)
        }
    }

    /// Fetches temporary target presets based on the given identifiers.
    ///
    /// - Parameter uuid: An array of preset IDs to fetch.
    /// - Returns: An array of `TempPreset` objects.
    func fetchIDs(_ uuid: [TempPreset.ID]) async -> [TempPreset] {
        do {
            let presets = try await tempTargetsStorage.fetchForTempTargetPresets()
            let matching = presets.filter { record in
                guard let id = record.id else { return false }
                return uuid.contains(id)
            }

            if matching.isEmpty {
                debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) No temp target found for ids: \(uuid)")
                return [TempPreset(id: UUID(), name: "", duration: 0)]
            }

            return matching.map { record in
                TempPreset(
                    id: record.id ?? UUID(),
                    name: record.name ?? "",
                    duration: record.duration ?? 0
                )
            }
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to fetch TempTarget: \(error)")
            return [TempPreset(id: UUID(), name: "", duration: 0)]
        }
    }

    /// Enacts a temporary target preset by enabling it in GRDB and notifying relevant components.
    ///
    /// - Parameter preset: The `TempPreset` to apply.
    /// - Returns: `true` if successfully enacted, otherwise `false`.
    @MainActor func enactTempTarget(_ preset: TempPreset) async -> Bool {
        debug(.default, "Enacting Temp Target: \(preset.name)")
        intentSuccess = false

        // Start background task
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = startBackgroundTask(withName: "TempTarget Enact")

        // Disable previous temp targets if necessary, without starting a background task
        await disableAllActiveTempTargets(shouldStartBackgroundTask: false)

        do {
            guard let tempTargetToEnact = try await tempTargetsStorage.fetchPreset(id: preset.id),
                  let pk = tempTargetToEnact.pk
            else {
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Enact")
                throw TempPresetsError.noTempTargetFound
            }

            // Enable the temp target (becomes the running one).
            guard let enacted = try await tempTargetsStorage.enactTempTarget(pk: pk),
                  let target = enacted.target, let duration = enacted.duration
            else {
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Enact")
                return false
            }

            // Prepare JSON for oref and save it so the edited Temp Target gets used.
            let tempTargetToStoreAsJSON = TempTarget(
                name: enacted.name,
                createdAt: enacted.date ?? Date(),
                targetTop: target,
                targetBottom: target,
                duration: duration,
                enteredBy: TempTarget.local,
                reason: TempTarget.custom,
                isPreset: enacted.isPreset,
                enabled: enacted.enabled,
                halfBasalTarget: enacted.halfBasalTarget
            )
            tempTargetsStorage.saveTempTargetsToStorage([tempTargetToStoreAsJSON])

            debug(.default, "Waiting for notification...")
            // Update State variables in TempTargetView
            Foundation.NotificationCenter.default.post(name: .willUpdateTempTargetConfiguration, object: nil)
            await awaitNotification(.didUpdateTempTargetConfiguration)
            debug(.default, "Notification received, continuing...")
            intentSuccess = true

            endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Enact")
            debug(.default, "Finished. Temp Target enacted via Shortcut.")
            return intentSuccess
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to enact Temp Target with error: \(error)"
            )
            endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Enact")
            intentSuccess = false
            return intentSuccess
        }
    }

    /// Cancels an active temporary target.
    func cancelTempTarget() async {
        await disableAllActiveTempTargets(shouldStartBackgroundTask: true)
        tempTargetsStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date().addingTimeInterval(-1))])
    }

    /// Disables all active temporary targets.
    ///
    /// - Parameter shouldStartBackgroundTask: A flag indicating whether a background task should be started.
    @MainActor func disableAllActiveTempTargets(shouldStartBackgroundTask: Bool) async {
        var backgroundTaskID: UIBackgroundTaskIdentifier?

        if shouldStartBackgroundTask {
            debug(.default, "Starting background task for temp target cancel")
            backgroundTaskID = .invalid
            backgroundTaskID = startBackgroundTask(withName: "TempTarget Cancel")
        }

        do {
            // Are there any active temp targets to cancel?
            let active = try await tempTargetsStorage.loadLatestTempTargetConfigurations(fetchLimit: 0)

            guard !active.isEmpty else {
                debug(.default, "No active temp targets to cancel... returning early")
                if var backgroundTaskID = backgroundTaskID {
                    debug(.default, "Ending background task for temp target cancel")
                    endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Cancel")
                }
                return
            }

            // Log a run for the first cancelled temp target and disable all active temp targets.
            try await tempTargetsStorage.disableAllActiveTempTargets(except: nil, createRunEntry: true)

            debug(.default, "Waiting for notification...")
            Foundation.NotificationCenter.default.post(name: .willUpdateTempTargetConfiguration, object: nil)
            await awaitNotification(.didUpdateTempTargetConfiguration)
            debug(.default, "Notification received, continuing...")

            if var backgroundTaskID = backgroundTaskID {
                debug(.default, "Ending background task for temp target cancel")
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Cancel")
            }
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to disable active Temp Targets with error: \(error)"
            )
            if var backgroundTaskID = backgroundTaskID {
                debug(.default, "Ending background task for temp target cancel")
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "TempTarget Cancel")
            }
        }
    }
}
