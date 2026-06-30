import Foundation
import UIKit

extension TrioRemoteControl {
    @MainActor func handleTempTargetCommand(_ payload: CommandPayload) async throws {
        guard let targetValue = payload.target, let durationValue = payload.duration else {
            await logError("Command rejected: temp target data is incomplete or invalid.", payload: payload)
            return
        }

        let durationInMinutes = Int(durationValue)
        let payloadDate = Date(timeIntervalSince1970: payload.timestamp)

        let tempTarget = TempTarget(
            name: TempTarget.custom, createdAt: payloadDate,
            targetTop: Decimal(targetValue), targetBottom: Decimal(targetValue),
            duration: Decimal(durationInMinutes), enteredBy: TempTarget.local,
            reason: TempTarget.custom, isPreset: false, enabled: true,
            halfBasalTarget: settings.preferences.halfBasalExerciseTarget
        )

        try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget)
        tempTargetsStorage.saveTempTargetsToStorage([tempTarget])

        await logSuccess(
            "Remote command processed successfully. \(payload.humanReadableDescription())",
            payload: payload,
            customNotificationMessage: "Temp target set"
        )
    }

    @MainActor func cancelTempTarget(_ payload: CommandPayload) async {
        debug(.remoteControl, "Cancelling temp target.")
        await disableAllActiveTempTargets()
        await logSuccess(
            "Remote command processed successfully. \(payload.humanReadableDescription())",
            payload: payload,
            customNotificationMessage: "Temp target canceled"
        )
    }

    @MainActor func disableAllActiveTempTargets() async {
        do {
            let active = try await tempTargetsStorage.loadLatestTempTargetConfigurations(fetchLimit: 0)
            guard !active.isEmpty else {
                await logError("Command rejected: no active temp target to cancel.")
                return
            }

            // Cancel & log a run for any previously active temp target.
            try await tempTargetsStorage.disableAllActiveTempTargets(except: nil, createRunEntry: true)
            tempTargetsStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date().addingTimeInterval(-1))])

            Foundation.NotificationCenter.default.post(name: .willUpdateTempTargetConfiguration, object: nil)
            await awaitNotification(.didUpdateTempTargetConfiguration)
        } catch {
            debug(.remoteControl, "\(DebuggingIdentifiers.failed) Failed to disable active temp targets: \(error)")
            await logError("Failed to disable temp targets: \(error.localizedDescription)")
        }
    }
}
