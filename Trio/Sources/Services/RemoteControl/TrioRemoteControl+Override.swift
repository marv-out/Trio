import Foundation
import UIKit

extension TrioRemoteControl {
    @MainActor internal func handleCancelOverrideCommand(_ payload: CommandPayload) async {
        await disableAllActiveOverrides()
        await logSuccess(
            "Remote command processed successfully. \(payload.humanReadableDescription())",
            payload: payload,
            customNotificationMessage: "Override canceled"
        )
    }

    @MainActor internal func handleStartOverrideCommand(_ payload: CommandPayload) async {
        do {
            guard let overrideName = payload.overrideName, !overrideName.isEmpty else {
                await logError("Command rejected: override name is missing.", payload: payload)
                return
            }
            let presets = try await overrideStorage.fetchForOverridePresets()
            if let preset = presets.first(where: { $0.name == overrideName }) {
                await enactOverridePreset(preset: preset, payload: payload)
            } else {
                await logError("Command rejected: override preset '\(overrideName)' not found.", payload: payload)
            }
        } catch {
            debug(.remoteControl, "\(DebuggingIdentifiers.failed) Failed to handle start override command: \(error)")
            await logError("Command failed: \(error.localizedDescription)", payload: payload)
        }
    }

    @MainActor private func enactOverridePreset(preset: OverrideRecord, payload: CommandPayload) async {
        guard let pk = preset.pk else {
            await logError("Command rejected: override preset has no identity.", payload: payload)
            return
        }
        do {
            // Cancel & log any previously active override, then enable the requested preset.
            try await overrideStorage.disableAllActiveOverrides(except: nil, createRunEntry: true)
            try await overrideStorage.enactOverride(pk: pk)

            Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
            await awaitNotification(.didUpdateOverrideConfiguration)
            await logSuccess(
                "Remote command processed successfully. \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: "Override started"
            )
        } catch {
            debug(.remoteControl, "Failed to enact override preset: \(error)")
            await logError("Failed to enact override preset: \(error.localizedDescription)", payload: payload)
        }
    }

    @MainActor private func disableAllActiveOverrides() async {
        do {
            let active = try await overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 0)
            guard !active.isEmpty else { return }

            try await overrideStorage.disableAllActiveOverrides(except: nil, createRunEntry: true)

            Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
            await awaitNotification(.didUpdateOverrideConfiguration)
        } catch {
            debug(.remoteControl, "\(DebuggingIdentifiers.failed) Failed to disable active overrides: \(error)")
        }
    }
}
