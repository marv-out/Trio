import Combine
import CoreData
import Foundation
import SwiftUI

extension Adjustments.StateModel {
    // MARK: - Enact Overrides

    /// Enacts an Override Preset (by GRDB rowid) by enabling it and disabling others.
    @MainActor func enactOverridePreset(withPk pk: Int64) async {
        do {
            /// Wait for currently active override to be disabled before enabling the new one
            await disableAllActiveOverrides(createOverrideRunEntry: currentActiveOverride != nil)
            await resetStateVariables()

            try await overrideStorage.enactOverride(pk: pk)
            isOverrideEnabled = true

            updateLatestOverrideConfiguration()
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to enact Override Preset")
        }
    }

    // MARK: - Disable Overrides

    /// Disables all active Overrides (optionally except `pk`), optionally logging a run entry.
    @MainActor func disableAllActiveOverrides(
        except pk: Int64? = nil,
        createOverrideRunEntry: Bool
    ) async {
        do {
            try await overrideStorage.disableAllActiveOverrides(except: pk, createRunEntry: createOverrideRunEntry)
            updateLatestOverrideConfiguration()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to disable active overrides: \(error)"
            )
        }
    }

    // MARK: - Save Overrides

    /// Saves a custom Override and activates it.
    func saveCustomOverride() async {
        do {
            let override = Override(
                name: overrideName,
                enabled: true,
                date: Date(),
                duration: overrideDuration,
                indefinite: indefinite,
                percentage: overridePercentage,
                smbIsOff: smbIsOff,
                isPreset: isPreset,
                id: id,
                overrideTarget: shouldOverrideTarget,
                target: target,
                advancedSettings: advancedSettings,
                isfAndCr: isfAndCr,
                isf: isf,
                cr: cr,
                smbIsScheduledOff: smbIsScheduledOff,
                start: start,
                end: end,
                smbMinutes: smbMinutes,
                uamMinutes: uamMinutes
            )

            // First disable all Overrides
            await disableAllActiveOverrides(createOverrideRunEntry: true)

            // Then save and activate a new custom Override
            try await overrideStorage.storeOverride(override: override)

            // Reset State variables
            await resetStateVariables()

            // Update View
            updateLatestOverrideConfiguration()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to save custom override: \(error)"
            )
        }
    }

    /// Saves an Override Preset without activating it.
    /// `enabled` has to be false
    /// `isPreset` has to be true
    func saveOverridePreset() async {
        do {
            let preset = Override(
                name: overrideName,
                enabled: false,
                date: Date(),
                duration: overrideDuration,
                indefinite: indefinite,
                percentage: overridePercentage,
                smbIsOff: smbIsOff,
                isPreset: true,
                id: id,
                overrideTarget: shouldOverrideTarget,
                target: target,
                advancedSettings: advancedSettings,
                isfAndCr: isfAndCr,
                isf: isf,
                cr: cr,
                smbIsScheduledOff: smbIsScheduledOff,
                start: start,
                end: end,
                smbMinutes: smbMinutes,
                uamMinutes: uamMinutes
            )

            async let storeOverride: () = overrideStorage.storeOverride(override: preset)
            async let resetState: () = resetStateVariables()
            _ = try await (storeOverride, resetState)

            setupOverridePresetsArray()
            try await nightscoutManager.uploadProfiles()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to save override preset: \(error)"
            )
        }
    }

    // MARK: - Override Preset Management

    /// Subscribes the Override Presets list to GRDB (idempotent). The `ValueObservation` keeps
    /// `overridePresets` current automatically after edits/inserts/deletes/reorders, so the former
    /// one-shot fetch (which left the UI stale after an edit) is no longer needed. Call sites that
    /// used to re-fetch now rely on the live feed.
    func setupOverridePresetsArray() {
        guard overridePresetsObservationCancellable == nil else { return }
        overridePresetsObservationCancellable = OverrideStore.observePresets()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Override presets observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] presets in
                    self?.overridePresets = presets
                }
            )
    }

    /// Deletes an Override Preset (by GRDB rowid) and updates the view.
    func invokeOverridePresetDeletion(_ pk: Int64) async {
        do {
            try await overrideStorage.deleteOverridePreset(pk: pk)
            setupOverridePresetsArray()
            try await nightscoutManager.uploadProfiles()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to delete override preset: \(error)"
            )
        }
    }

    // MARK: - Update Latest Override Configuration

    /// Updates the latest Override configuration and state.
    /// Fetches the latest active Override (value type — no `NSManagedObjectID` round-trip) and
    /// updates the State variables the View relies on. Also called when an Override is cancelled
    /// from the Home View to refresh the button state.
    func updateLatestOverrideConfiguration() {
        Task { [weak self] in
            do {
                guard let self = self else { return }

                let latest = try await self.overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 1)

                // execute sequentially instead of concurrently
                await self.updateLatestOverrideConfigurationOfState(from: latest)
                await self.setCurrentOverride(from: latest)

                // perform determine basal sync to immediately apply override changes
                try await apsManager.determineBasalSync()
            } catch {
                debug(
                    .default,
                    "\(DebuggingIdentifiers.failed) Failed to update override configuration: \(error)"
                )
            }
        }
    }

    /// Updates state variables with the latest Override configuration.
    @MainActor func updateLatestOverrideConfigurationOfState(from records: [OverrideRecord]) async {
        isOverrideEnabled = records.first?.enabled ?? false
        if !isOverrideEnabled {
            await resetStateVariables()
        }
    }

    /// Sets the current active Override for UI purposes.
    @MainActor func setCurrentOverride(from records: [OverrideRecord]) async {
        guard let first = records.first else {
            activeOverrideName = "Custom Override"
            currentActiveOverride = nil
            return
        }
        currentActiveOverride = first
        activeOverrideName = first.name ?? String(localized: "Custom Override")
    }

    /// Duplicates the active Override Preset and cancels the previous one.
    @MainActor func duplicateOverridePresetAndCancelPreviousOverride() async {
        guard let overridePresetToDuplicate = currentActiveOverride, overridePresetToDuplicate.isPreset else { return }

        do {
            // Copy the running preset into a fresh non-preset override (so editing doesn't mutate
            // the preset), then disable everything else — the copy becomes the running override.
            let duplicate = try await overrideStorage.copyRunningOverride(overridePresetToDuplicate)
            try await overrideStorage.disableAllActiveOverrides(except: duplicate.pk, createRunEntry: false)

            currentActiveOverride = duplicate
            activeOverrideName = duplicate.name ?? String(localized: "Custom Override")
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to cancel previous Override: \(error)"
            )
        }
    }

    // MARK: - Helper Functions

    /// Resets state variables to default values.
    @MainActor func resetStateVariables() async {
        id = ""
        overrideDuration = 0
        indefinite = true
        overridePercentage = 100
        advancedSettings = false
        smbIsOff = false
        overrideName = ""
        shouldOverrideTarget = false
        isf = true
        cr = true
        isfAndCr = true
        smbIsScheduledOff = false
        start = 0
        end = 0
        smbMinutes = defaultSmbMinutes
        uamMinutes = defaultUamMinutes
        target = currentGlucoseTarget
    }

    /// Rounds a target value to the nearest step.
    static func roundTargetToStep(_ target: Decimal, _ step: Decimal) -> Decimal {
        // Convert target and step to NSDecimalNumber
        guard let targetValue = NSDecimalNumber(decimal: target).doubleValue as Double?,
              let stepValue = NSDecimalNumber(decimal: step).doubleValue as Double?
        else {
            return target
        }

        // Perform the remainder check using truncatingRemainder
        let remainder = Decimal(targetValue.truncatingRemainder(dividingBy: stepValue))

        if remainder != 0 {
            // Calculate how much to adjust (up or down) based on the remainder
            let adjustment = step - remainder
            return target + adjustment
        }

        // Return the original target if no adjustment is needed
        return target
    }

    /// Rounds an Override percentage to the nearest step.
    static func roundOverridePercentageToStep(_ percentage: Double, _ step: Int) -> Double {
        let stepDouble = Double(step)
        // Check if overridePercentage is not divisible by the selected step
        if percentage.truncatingRemainder(dividingBy: stepDouble) != 0 {
            let roundedValue: Double

            if percentage > 100 {
                // Round down to the nearest valid step away from 100
                let stepCount = (percentage - 100) / stepDouble
                roundedValue = 100 + floor(stepCount) * stepDouble
            } else {
                // Round up to the nearest valid step away from 100
                let stepCount = (100 - percentage) / stepDouble
                roundedValue = 100 - floor(stepCount) * stepDouble
            }

            // Ensure the value stays between 10 and 200
            return max(10, min(roundedValue, 200))
        }

        return percentage
    }
}

enum IsfAndOrCrOptions: String, CaseIterable {
    case isfAndCr
    case isf
    case cr
    case nothing

    var displayName: String {
        switch self {
        case .isfAndCr:
            return String(localized: "ISF/CR", comment: "Option for both ISF and CR")
        case .isf:
            return String(localized: "ISF", comment: "Option for Insulin Sensitivity Factor")
        case .cr:
            return String(localized: "CR", comment: "Option for Carb Ratio")
        case .nothing:
            return String(localized: "None", comment: "Option for no selection")
        }
    }
}

enum DisableSmbOptions: String, CaseIterable {
    case dontDisable
    case disable
    case disableOnSchedule

    var displayName: String {
        switch self {
        case .dontDisable:
            return String(localized: "Don't Disable", comment: "Option to keep SMB enabled")
        case .disable:
            return String(localized: "Disable", comment: "Option to disable SMB")
        case .disableOnSchedule:
            return String(localized: "Disable on Schedule", comment: "Option to disable SMB based on schedule")
        }
    }
}
