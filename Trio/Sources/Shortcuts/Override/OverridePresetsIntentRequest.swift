import CoreData
import Foundation
import UIKit

@available(iOS 16.0, *) final class OverridePresetsIntentRequest: BaseIntentsRequest {
    enum overridePresetsError: Error {
        case noTempOverrideFound
        case noDurationDefined
        case noActiveOverride
    }

    private var intentSuccess: Bool = false

    /**
     Fetches and processes override presets from Core Data.

     - Returns: An array of `OverridePreset` objects.
     - Throws: An error if fetching fails or Core Data operations fail.
     */
    func fetchAndProcessOverrides() async throws -> [OverridePreset] {
        do {
            // Override presets are GRDB value types — no NSManagedObjectID round-trip needed.
            let presets = try await overrideStorage.fetchForOverridePresets()
            return presets.map { preset in
                guard let id = preset.id, let name = preset.name else {
                    return OverridePreset(id: UUID().uuidString, name: "")
                }
                return OverridePreset(id: id, name: name)
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Error fetching/processing overrides: \(error)"
            )
            throw error
        }
    }

    /**
     Fetches override presets by their IDs.

     - Parameter uuid: An array of `OverridePreset.ID` values to fetch.
     - Returns: An array of `OverridePreset` objects matching the provided IDs.
     - Throws: `overridePresetsError.noTempOverrideFound` if no presets are found.
     */
    func fetchIDs(_ uuid: [OverridePreset.ID]) async throws -> [OverridePreset] {
        let presets = try await overrideStorage.fetchForOverridePresets()
        let matching = presets.filter { uuid.contains($0.id ?? "") }

        if matching.isEmpty {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) No OverrideStored found for ids: \(uuid)"
            )
            throw overridePresetsError.noTempOverrideFound
        }

        return matching.map { OverridePreset(id: $0.id ?? UUID().uuidString, name: $0.name ?? "") }
    }

    /**
     Enacts an override preset by enabling it in Core Data and notifying the system.

     - Parameter preset: The `OverridePreset` to enact.
     - Returns: A boolean indicating whether the override was successfully enacted.
     */
    @MainActor func enactOverride(_ preset: OverridePreset) async -> Bool {
        debug(.default, "Enacting override: \(preset.name)")
        intentSuccess = false

        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = startBackgroundTask(withName: "Override Enact")

        await disableAllActiveOverrides(shouldStartBackgroundTask: false)

        do {
            guard let overrideToEnact = try await overrideStorage.fetchPreset(id: preset.id),
                  let pk = overrideToEnact.pk
            else {
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Enact")
                throw overridePresetsError.noTempOverrideFound
            }

            try await overrideStorage.enactOverride(pk: pk)

            debug(.default, "Waiting for notification...")
            Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
            await awaitNotification(.didUpdateOverrideConfiguration)
            debug(.default, "Notification received, continuing...")
            intentSuccess = true

            endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Enact")
            debug(.default, "Finished. Override enacted via Shortcut.")
            return intentSuccess
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to enact override: \(error)"
            )
            endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Enact")
            return false
        }
    }

    /**
     Cancels all active overrides asynchronously.
     */
    func cancelOverride() async {
        await disableAllActiveOverrides(shouldStartBackgroundTask: true)
    }

    /**
     Disables all active overrides and optionally starts a background task.

     - Parameter shouldStartBackgroundTask: A boolean indicating whether to start a background task.
     */
    @MainActor func disableAllActiveOverrides(shouldStartBackgroundTask: Bool) async {
        debug(.default, "Disabling all active overrides")
        var backgroundTaskID: UIBackgroundTaskIdentifier?

        if shouldStartBackgroundTask {
            debug(.default, "Starting background task for override cancel")
            backgroundTaskID = .invalid
            backgroundTaskID = startBackgroundTask(withName: "Override Cancel")
        }

        do {
            // Are there any active overrides to cancel?
            let active = try await overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 0)

            guard !active.isEmpty else {
                debug(.default, "No active overrides to cancel… returning early")
                if var backgroundTaskID = backgroundTaskID {
                    debug(.default, "Ending background task for override cancel")
                    endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Cancel")
                }
                return
            }

            // Log a run for the first cancelled override and disable all active overrides.
            try await overrideStorage.disableAllActiveOverrides(except: nil, createRunEntry: true)

            debug(.default, "Waiting for notification...")
            Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
            await awaitNotification(.didUpdateOverrideConfiguration)
            debug(.default, "Notification received, continuing...")

            if var backgroundTaskID = backgroundTaskID {
                debug(.default, "Ending background task for override cancel")
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Cancel")
            }
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to disable active Overrides with error: \(error)"
            )
            if var backgroundTaskID = backgroundTaskID {
                debug(.default, "Ending background task for override cancel")
                endBackgroundTaskSafely(&backgroundTaskID, taskName: "Override Cancel")
            }
        }
    }
}
