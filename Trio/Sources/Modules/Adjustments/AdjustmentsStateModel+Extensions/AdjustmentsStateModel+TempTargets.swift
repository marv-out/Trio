import Combine
import Foundation

extension Adjustments.StateModel {
    // MARK: - State Initialization and Updates

    /// Updates the latest Temp Target configuration and state.
    /// Fetches the latest active Temp Target (value type — no `NSManagedObjectID` round-trip) and
    /// updates the State variables the View relies on. Also called when a Temp Target is cancelled
    /// from the Home View to refresh the button state.
    func updateLatestTempTargetConfiguration() {
        Task { [weak self] in
            do {
                guard let self = self else { return }

                let latest = try await self.tempTargetStorage.loadLatestTempTargetConfigurations(fetchLimit: 1)

                // execute sequentially instead of concurrently
                await self.updateLatestTempTargetConfigurationOfState(from: latest)
                await self.setCurrentTempTarget(from: latest)

                // perform determine basal sync to immediately apply temp target changes
                try await self.apsManager.determineBasalSync()
            } catch {
                debug(
                    .default,
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to load latest temp target configuration with error: \(error)"
                )
            }
        }
    }

    /// Updates state variables with the latest Temp Target configuration.
    @MainActor func updateLatestTempTargetConfigurationOfState(from records: [TempTargetRecord]) async {
        isTempTargetEnabled = records.first?.enabled ?? false
        if !isOverrideEnabled {
            await resetTempTargetState()
        }
    }

    /// Sets the current Temp Target for UI and logic purposes.
    @MainActor func setCurrentTempTarget(from records: [TempTargetRecord]) async {
        guard let first = records.first else {
            activeTempTargetName = "Custom Temp Target"
            currentActiveTempTarget = nil
            return
        }
        currentActiveTempTarget = first
        activeTempTargetName = first.name ?? String(localized: "Custom Temp Target")
        tempTargetTarget = first.target ?? 0
    }

    // MARK: - Temp Target Fetching and Setup

    /// Subscribes the Temp Target Presets list to GRDB (idempotent). The `ValueObservation` keeps
    /// `tempTargetPresets` current automatically after edits/inserts/deletes/reorders, so the former
    /// one-shot fetch (which left the UI stale after an edit) is no longer needed.
    func setupTempTargetPresetsArray() {
        guard tempTargetPresetsObservationCancellable == nil else { return }
        tempTargetPresetsObservationCancellable = TempTargetStore.observePresets()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Temp target presets observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] presets in
                    self?.tempTargetPresets = presets
                }
            )
    }

    /// Subscribes the scheduled (future-dated) Temp Targets list to GRDB (idempotent). The
    /// `date > now` rule is applied in the sink so the tracked region stays deterministic.
    func setupScheduledTempTargetsArray() {
        guard scheduledTempTargetsObservationCancellable == nil else { return }
        scheduledTempTargetsObservationCancellable = TempTargetStore.observeScheduled()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        debug(.default, "\(DebuggingIdentifiers.failed) Scheduled temp targets observation failed: \(error)")
                    }
                },
                receiveValue: { [weak self] records in
                    let now = Date()
                    self?.scheduledTempTargets = records.filter { ($0.date ?? .distantPast) > now }
                }
            )
    }

    // MARK: - Temp Target Creation and Management

    /// Saves a Temp Target to storage.
    func saveTempTargetToStorage(tempTargets: [TempTarget]) {
        tempTargetStorage.saveTempTargetsToStorage(tempTargets)
    }

    /// Saves a Temp Target based on whether it is scheduled or custom.
    func invokeSaveOfCustomTempTargets() async throws {
        if date > Date() {
            try await saveScheduledTempTarget()
        } else {
            try await saveCustomTempTarget()
        }
    }

    /// Saves a scheduled Temp Target and activates it at the specified date.
    func saveScheduledTempTarget() async throws {
        let date = self.date
        guard date > Date() else { return }

        let adjustmentType = halfBasalTarget == settingHalfBasalTarget ? "Standard" : "Custom"
        debug(
            .default,
            "TempTarget: target=\(tempTargetTarget), HBT=\(settingHalfBasalTarget), effectiveHBT=\(halfBasalTarget), percentage=\(Int(percentage))%, adjustmentType=\(adjustmentType)"
        )
        let tempTarget = TempTarget(
            name: tempTargetName,
            createdAt: date,
            targetTop: tempTargetTarget,
            targetBottom: tempTargetTarget,
            duration: tempTargetDuration,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: false,
            enabled: false,
            halfBasalTarget: halfBasalTarget
        )
        try await tempTargetStorage.storeTempTarget(tempTarget: tempTarget)
        setupScheduledTempTargetsArray()
        await waitUntilDate(date)
        await disableAllActiveTempTargets(createTempTargetRunEntry: true)
        await enableScheduledTempTarget(for: date)
        tempTargetStorage.saveTempTargetsToStorage([tempTarget])
    }

    /// Enables a scheduled Temp Target for a specific date.
    func enableScheduledTempTarget(for date: Date) async {
        do {
            guard let scheduled = try await tempTargetStorage.fetchScheduledTempTarget(for: date), let pk = scheduled.pk
            else {
                debug(.default, "No Temp Target found for the specified date.")
                return
            }

            guard let enacted = try await tempTargetStorage.enactTempTarget(pk: pk) else { return }
            await setCurrentTempTarget(from: [enacted])
            await MainActor.run { isTempTargetEnabled = true }

            setupScheduledTempTargetsArray()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to enable scheduled temp target: \(error)"
            )
        }
    }

    /// Waits until a target date before proceeding.
    private func waitUntilDate(_ targetDate: Date) async {
        while Date() < targetDate {
            let timeInterval = targetDate.timeIntervalSince(Date())
            let sleepDuration = min(timeInterval, 60.0)
            try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
        }
    }

    /// Saves a custom Temp Target and disables existing ones.
    func saveCustomTempTarget() async throws {
        await disableAllActiveTempTargets(createTempTargetRunEntry: true)
        let adjustmentType = halfBasalTarget == settingHalfBasalTarget ? "Standard" : "Custom"
        debug(
            .default,
            "TempTarget: target=\(tempTargetTarget), HBT=\(settingHalfBasalTarget), effectiveHBT=\(halfBasalTarget), percentage=\(Int(percentage))%, adjustmentType=\(adjustmentType)"
        )
        let tempTarget = TempTarget(
            name: tempTargetName,
            /// We don't need to use the state var date here as we are using a different function for scheduled Temp Targets 'saveScheduledTempTarget()'
            createdAt: Date(),
            targetTop: tempTargetTarget,
            targetBottom: tempTargetTarget,
            duration: tempTargetDuration,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: false,
            enabled: true,
            halfBasalTarget: halfBasalTarget
        )
        try await tempTargetStorage.storeTempTarget(tempTarget: tempTarget)
        tempTargetStorage.saveTempTargetsToStorage([tempTarget])
        await resetTempTargetState()
        isTempTargetEnabled = true
        updateLatestTempTargetConfiguration()
    }

    /// Creates a new Temp Target preset.
    func saveTempTargetPreset() async throws {
        let adjustmentType = halfBasalTarget == settingHalfBasalTarget ? "Standard" : "Custom"
        debug(
            .default,
            "TempTarget: target=\(tempTargetTarget), HBT=\(settingHalfBasalTarget), effectiveHBT=\(halfBasalTarget), percentage=\(Int(percentage))%, adjustmentType=\(adjustmentType)"
        )
        let tempTarget = TempTarget(
            name: tempTargetName,
            createdAt: Date(),
            targetTop: tempTargetTarget,
            targetBottom: tempTargetTarget,
            duration: tempTargetDuration,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: true,
            enabled: false,
            halfBasalTarget: halfBasalTarget
        )
        try await tempTargetStorage.storeTempTarget(tempTarget: tempTarget)
        await resetTempTargetState()
        setupTempTargetPresetsArray()
    }

    /// Enacts a Temp Target preset (by GRDB rowid) by enabling it and disabling others.
    @MainActor func enactTempTargetPreset(withPk pk: Int64) async {
        do {
            /// Wait for currently active temp target to be disabled before storing the new temp target
            await disableAllActiveTempTargets(createTempTargetRunEntry: true)
            await resetTempTargetState()

            guard let enacted = try await tempTargetStorage.enactTempTarget(pk: pk) else { return }
            isTempTargetEnabled = true

            updateLatestTempTargetConfiguration()

            let tempTarget = TempTarget(
                name: enacted.name,
                createdAt: Date(),
                targetTop: enacted.target,
                targetBottom: enacted.target,
                duration: enacted.duration ?? 0,
                enteredBy: TempTarget.local,
                reason: TempTarget.custom,
                isPreset: true,
                enabled: true,
                halfBasalTarget: halfBasalTarget
            )
            tempTargetStorage.saveTempTargetsToStorage([tempTarget])
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to enact TempTarget Preset")
        }
    }

    /// Disables all active Temp Targets (optionally except `pk`), optionally logging a run entry.
    /// The "disable + log a run" composite lives in `TempTargetsStorage`; this wrapper mirrors the
    /// cancel into the JSON `FileStorage` (only when something was actually disabled).
    @MainActor func disableAllActiveTempTargets(
        except pk: Int64? = nil,
        createTempTargetRunEntry: Bool
    ) async {
        do {
            let didDisable = try await tempTargetStorage.disableAllActiveTempTargets(
                except: pk,
                createRunEntry: createTempTargetRunEntry
            )
            if didDisable {
                tempTargetStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date().addingTimeInterval(-1))])
            }
            updateLatestTempTargetConfiguration()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to disable active temp targets: \(error)"
            )
        }
    }

    /// Duplicates the active Temp Target Preset and cancels the previous one.
    @MainActor func duplicateTempTargetPresetAndCancelPreviousTempTarget() async {
        // We get the current active Preset by using currentActiveTempTarget which can either be a Preset or a custom TempTarget
        guard let tempTargetPresetToDuplicate = currentActiveTempTarget,
              tempTargetPresetToDuplicate.isPreset == true else { return }

        do {
            // Copy the running preset into a fresh non-preset temp target (so editing doesn't mutate
            // the preset), then disable everything else — the copy becomes the running temp target.
            let duplicate = try await tempTargetStorage.copyRunningTempTarget(tempTargetPresetToDuplicate)
            try await tempTargetStorage.disableAllActiveTempTargets(except: duplicate.pk, createRunEntry: false)

            currentActiveTempTarget = duplicate
            activeTempTargetName = duplicate.name ?? String(localized: "Custom Temp Target")
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to cancel previous temp target with error: \(error)"
            )
        }
    }

    /// Deletes a Temp Target preset (by GRDB rowid).
    func invokeTempTargetPresetDeletion(_ pk: Int64) async {
        do {
            try await tempTargetStorage.deleteTempTargetPreset(pk: pk)
            setupTempTargetPresetsArray()
            setupScheduledTempTargetsArray()
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to delete temp target preset: \(error)"
            )
        }
    }

    /// Resets Temp Target state variables.
    @MainActor func resetTempTargetState() async {
        tempTargetName = ""
        tempTargetTarget = 100
        tempTargetDuration = 0
        percentage = 100
        halfBasalTarget = settingHalfBasalTarget
        date = Date()
    }

    // MARK: - Calculations

    /// Determines if sensitivity adjustment is enabled based on target.
    func isAdjustSensEnabled(usingTarget initialTarget: Decimal? = nil) -> Bool {
        let target = initialTarget ?? tempTargetTarget
        if target < TempTargetCalculations.normalTarget, lowTTlowersSens && autosensMax > 1 { return true }
        if target > TempTargetCalculations.normalTarget, highTTraisesSens || isExerciseModeActive { return true }
        return false
    }

    /// Computes the low value for the slider based on the target.
    func computeSliderLow(usingTarget initialTarget: Decimal? = nil) -> Double {
        let calcTarget = initialTarget ?? tempTargetTarget
        guard calcTarget != 0 else { return TempTargetCalculations.minSensitivityRatioTT } // oref defined maximum sensitivity
        let minSens = calcTarget < TempTargetCalculations.normalTarget ? 105 : TempTargetCalculations.minSensitivityRatioTT
        return Double(max(0, minSens))
    }

    /// Computes the high value for the slider based on the target.
    func computeSliderHigh(usingTarget initialTarget: Decimal? = nil) -> Double {
        let calcTarget = initialTarget ?? tempTargetTarget
        guard calcTarget != 0
        else { return Double(autosensMax * 100) } // oref defined limit for increased insulin delivery
        let maxSens = calcTarget > TempTargetCalculations.normalTarget ? 95 : Double(autosensMax * 100)
        return maxSens
    }
}

enum TempTargetSensitivityAdjustmentType: String, CaseIterable {
    case standard = "Standard"
    case slider = "Custom"
}
