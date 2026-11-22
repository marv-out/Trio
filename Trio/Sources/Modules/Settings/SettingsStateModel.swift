import CoreData
import Foundation
import LoopKit
import LoopKitUI
import SwiftUI
import TidepoolServiceKit

extension Settings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var broadcaster: Broadcaster!
        @Injected() var logExport: LogExport!
        @Injected() private var nightscoutManager: NightscoutManager!
        @Injected() var pluginManager: PluginManager!
        @Injected() var fetchCgmManager: FetchGlucoseManager!
        @Injected() private var storage: FileStorage!
        @Injected() var overrideStorage: OverrideStorage!
        @Injected() private var keychain: Keychain!
        @Injected() private var boostActivityMonitor: BoostActivityMonitor!
        @Injected() private var apsManager: APSManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var dosingMode: DosingMode = .open
        @Published var debugOptions = false
        @Published var boostMode: BoostMode = .off
        @Published var boostV5Aggression: Decimal = 1.0
        @Published var boostV5HypoCaution: Decimal = 1.0
        @Published var boostMaxIOB: Decimal = 12
        @Published var boostV5Sensitivity: Decimal = 1.0
        @Published var boostV5ConfirmedCapU: Decimal = 2.5
        @Published var boostV5CommittedCapU: Decimal = 0.5
        @Published var boostCumulativeSmbCap60Min: Decimal = 10.0
        @Published var boostV5FastCarbConfirm: Bool = true
        @Published var boostV5ComposedFloorActive: Bool = false
        @Published var boostV5AggressiveEarlyConfirm: Bool = false
        @Published var boostV5VelocityBudgetActive: Bool = false
        @Published var boostV5PrimerCapU: Decimal = 0
        @Published var boostV5PrimerTbrFallback: Bool = true
        @Published var boostV5PrimerBolusMode: Bool = false
        @Published var boostV5ConfirmTranche: Bool = false
        @Published var boostV5TrancheFraction: Decimal = 0.5
        @Published var boostV5TrancheThreshold: Decimal = 0.48
        @Published var boostV5PostRescueTightRampTrial: Bool = false
        @Published var boostUseTdd: Bool = false
        @Published var boostAutosensWhenNoTdd: Bool = true
        @Published var boostEnableCircadianIsf: Bool = false
        @Published var boostDynIsfNormalTarget: Decimal = 99
        @Published var boostDynIsfBgCap: Decimal = 210
        @Published var boostDynIsfVelocity: Decimal = 100
        @Published var boostDynIsfAdjustmentFactor: Decimal = 100
        @Published var boostNightModeEnabled: Bool = false
        @Published var boostNightModeStartHour: Decimal = 22
        @Published var boostNightModeEndHour: Decimal = 7
        @Published var boostNightModeBgOffset: Decimal = 27
        @Published var boostNightModeDisableWithCob: Bool = false
        @Published var boostNightModeDisableWithLowTt: Bool = false
        @Published var boostNightModeAutoBySleep: Bool = false
        @Published var boostSleepInHours: Decimal = 2.0
        @Published var boostSleepInSteps: Decimal = 250
        @Published var boostV6PreMealEnabled: Bool = false
        @Published var boostV6PreMealTargetMgdl: Decimal = 72
        @Published var boostV6PreMealLeadMin: Decimal = 60
        @Published var boostActivitySteps5: Decimal = 420
        @Published var boostActivitySteps15: Decimal = 800
        @Published var boostActivitySteps30: Decimal = 1200
        @Published var boostActivitySteps60: Decimal = 1800
        @Published var boostActivityPct: Decimal = 80
        @Published var boostInactivitySteps: Decimal = 500
        @Published var boostInactivityPct: Decimal = 130
        @Published var boostHrIntegrationEnabled: Bool = false
        @Published var boostHrMaxBpm: Decimal = 180
        @Published var boostHrRestingBpm: Decimal = 60
        @Published var boostHrStressDetection: Bool = false
        @Published var boostPostExerciseEnabled: Bool = false
        @Published var boostPostExerciseHours: Decimal = 2
        @Published var boostPostExerciseTarget: Decimal = 144
        @Published var boostPostExerciseScale: Decimal = 0.5
        @Published var boostPostExerciseMinDuration: Decimal = 10
        @Published var serviceUIType: ServiceUI.Type?
        @Published var setupTidepool = false

        private(set) var buildNumber = ""
        private(set) var versionNumber = ""
        private(set) var branch = ""
        private(set) var copyrightNotice = ""
        private(set) var reportSubmitter: ReportSubmitting?

        override func subscribe() {
            units = settingsManager.settings.units
            reportSubmitter = ReportEndpoint.submitter(keychain: keychain)

            subscribeSetting(\.debugOptions, on: $debugOptions) { debugOptions = $0 }
            subscribeSetting(\.dosingMode, on: $dosingMode) { dosingMode = $0 }
            subscribePreferencesSetting(
                \.boostMode,
                on: $boostMode,
                initial: { boostMode = $0 },
                didSet: { [weak self] mode in
                    // Enabling Boost prompts for the HealthKit read access its activity/sleep/
                    // post-exercise sensing needs — the app otherwise only requests Health via the
                    // separate Apple Health toggle, so without this those features stay silently
                    // inert. Idempotent (no re-prompt once decided). Fires on the initial subscribe
                    // too, so already-enabled users get prompted next time they open the screen.
                    if mode != .off { self?.boostActivityMonitor?.requestAuthorization() }
                }
            )
            subscribePreferencesSetting(\.boostV5Aggression, on: $boostV5Aggression) { boostV5Aggression = $0 }
            subscribePreferencesSetting(\.boostV5HypoCaution, on: $boostV5HypoCaution) { boostV5HypoCaution = $0 }
            subscribePreferencesSetting(\.boostMaxIOB, on: $boostMaxIOB) { boostMaxIOB = $0 }
            subscribePreferencesSetting(\.boostV5Sensitivity, on: $boostV5Sensitivity) { boostV5Sensitivity = $0 }
            subscribePreferencesSetting(\.boostV5ConfirmedCapU, on: $boostV5ConfirmedCapU) { boostV5ConfirmedCapU = $0 }
            subscribePreferencesSetting(\.boostV5CommittedCapU, on: $boostV5CommittedCapU) { boostV5CommittedCapU = $0 }
            subscribePreferencesSetting(\.boostCumulativeSmbCap60Min, on: $boostCumulativeSmbCap60Min) {
                boostCumulativeSmbCap60Min = $0 }
            subscribePreferencesSetting(\.boostV5FastCarbConfirm, on: $boostV5FastCarbConfirm) { boostV5FastCarbConfirm = $0 }
            subscribePreferencesSetting(\.boostV5ComposedFloorActive, on: $boostV5ComposedFloorActive) {
                boostV5ComposedFloorActive = $0 }
            subscribePreferencesSetting(\.boostV5AggressiveEarlyConfirm, on: $boostV5AggressiveEarlyConfirm) {
                boostV5AggressiveEarlyConfirm = $0 }
            subscribePreferencesSetting(\.boostV5VelocityBudgetActive, on: $boostV5VelocityBudgetActive) {
                boostV5VelocityBudgetActive = $0 }
            subscribePreferencesSetting(\.boostV5PrimerCapU, on: $boostV5PrimerCapU) {
                boostV5PrimerCapU = $0 }
            subscribePreferencesSetting(\.boostV5PrimerTbrFallback, on: $boostV5PrimerTbrFallback) {
                boostV5PrimerTbrFallback = $0 }
            subscribePreferencesSetting(\.boostV5PrimerBolusMode, on: $boostV5PrimerBolusMode) {
                boostV5PrimerBolusMode = $0 }
            subscribePreferencesSetting(\.boostV5ConfirmTranche, on: $boostV5ConfirmTranche) {
                boostV5ConfirmTranche = $0 }
            subscribePreferencesSetting(\.boostV5TrancheFraction, on: $boostV5TrancheFraction) {
                boostV5TrancheFraction = $0 }
            subscribePreferencesSetting(\.boostV5TrancheThreshold, on: $boostV5TrancheThreshold) {
                boostV5TrancheThreshold = $0 }
            subscribePreferencesSetting(\.boostV5PostRescueTightRampTrial, on: $boostV5PostRescueTightRampTrial) {
                boostV5PostRescueTightRampTrial = $0 }
            subscribePreferencesSetting(\.boostUseTdd, on: $boostUseTdd) { boostUseTdd = $0 }
            subscribePreferencesSetting(\.boostAutosensWhenNoTdd, on: $boostAutosensWhenNoTdd) {
                boostAutosensWhenNoTdd = $0 }
            subscribePreferencesSetting(\.boostEnableCircadianIsf, on: $boostEnableCircadianIsf) { boostEnableCircadianIsf = $0 }
            subscribePreferencesSetting(\.boostDynIsfNormalTarget, on: $boostDynIsfNormalTarget) { boostDynIsfNormalTarget = $0 }
            subscribePreferencesSetting(\.boostDynIsfBgCap, on: $boostDynIsfBgCap) { boostDynIsfBgCap = $0 }
            subscribePreferencesSetting(\.boostDynIsfVelocity, on: $boostDynIsfVelocity) { boostDynIsfVelocity = $0 }
            subscribePreferencesSetting(\.boostDynIsfAdjustmentFactor, on: $boostDynIsfAdjustmentFactor) {
                boostDynIsfAdjustmentFactor = $0 }
            subscribePreferencesSetting(\.boostNightModeEnabled, on: $boostNightModeEnabled) { boostNightModeEnabled = $0 }
            subscribePreferencesSetting(\.boostNightModeStartHour, on: $boostNightModeStartHour) { boostNightModeStartHour = $0 }
            subscribePreferencesSetting(\.boostNightModeEndHour, on: $boostNightModeEndHour) { boostNightModeEndHour = $0 }
            subscribePreferencesSetting(\.boostNightModeBgOffset, on: $boostNightModeBgOffset) { boostNightModeBgOffset = $0 }
            subscribePreferencesSetting(\.boostNightModeDisableWithCob, on: $boostNightModeDisableWithCob) {
                boostNightModeDisableWithCob = $0 }
            subscribePreferencesSetting(\.boostNightModeDisableWithLowTt, on: $boostNightModeDisableWithLowTt) {
                boostNightModeDisableWithLowTt = $0 }
            subscribePreferencesSetting(\.boostNightModeAutoBySleep, on: $boostNightModeAutoBySleep) {
                boostNightModeAutoBySleep = $0 }
            subscribePreferencesSetting(\.boostSleepInHours, on: $boostSleepInHours) { boostSleepInHours = $0 }
            subscribePreferencesSetting(\.boostSleepInSteps, on: $boostSleepInSteps) { boostSleepInSteps = $0 }
            subscribePreferencesSetting(\.boostV6PreMealEnabled, on: $boostV6PreMealEnabled) { boostV6PreMealEnabled = $0 }
            subscribePreferencesSetting(\.boostV6PreMealTargetMgdl, on: $boostV6PreMealTargetMgdl) {
                boostV6PreMealTargetMgdl = $0 }
            subscribePreferencesSetting(\.boostV6PreMealLeadMin, on: $boostV6PreMealLeadMin) { boostV6PreMealLeadMin = $0 }
            subscribePreferencesSetting(\.boostActivitySteps5, on: $boostActivitySteps5) { boostActivitySteps5 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps15, on: $boostActivitySteps15) { boostActivitySteps15 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps30, on: $boostActivitySteps30) { boostActivitySteps30 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps60, on: $boostActivitySteps60) { boostActivitySteps60 = $0 }
            subscribePreferencesSetting(\.boostActivityPct, on: $boostActivityPct) { boostActivityPct = $0 }
            subscribePreferencesSetting(\.boostInactivitySteps, on: $boostInactivitySteps) { boostInactivitySteps = $0 }
            subscribePreferencesSetting(\.boostInactivityPct, on: $boostInactivityPct) { boostInactivityPct = $0 }
            subscribePreferencesSetting(\.boostHrIntegrationEnabled, on: $boostHrIntegrationEnabled) {
                boostHrIntegrationEnabled = $0 }
            subscribePreferencesSetting(\.boostHrMaxBpm, on: $boostHrMaxBpm) { boostHrMaxBpm = $0 }
            subscribePreferencesSetting(\.boostHrRestingBpm, on: $boostHrRestingBpm) { boostHrRestingBpm = $0 }
            subscribePreferencesSetting(\.boostHrStressDetection, on: $boostHrStressDetection) { boostHrStressDetection = $0 }
            subscribePreferencesSetting(\.boostPostExerciseEnabled, on: $boostPostExerciseEnabled) {
                boostPostExerciseEnabled = $0 }
            subscribePreferencesSetting(\.boostPostExerciseHours, on: $boostPostExerciseHours) { boostPostExerciseHours = $0 }
            subscribePreferencesSetting(\.boostPostExerciseTarget, on: $boostPostExerciseTarget) { boostPostExerciseTarget = $0 }
            subscribePreferencesSetting(\.boostPostExerciseScale, on: $boostPostExerciseScale) { boostPostExerciseScale = $0 }
            subscribePreferencesSetting(\.boostPostExerciseMinDuration, on: $boostPostExerciseMinDuration) {
                boostPostExerciseMinDuration = $0 }
            broadcaster.register(SettingsObserver.self, observer: self)

            buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

            versionNumber = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

            branch = BuildDetails.shared.branchAndSha

            copyrightNotice = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

            serviceUIType = TidepoolService.self as? ServiceUI.Type
        }

        var logKinds: [LogExport.Kind] {
            var kinds: [LogExport.Kind] = [.all]
            // Read during the first render, before the resolver is set
            if provider?.deviceManager?.pumpManager != nil {
                kinds.append(.pump)
            }
            if let fetchCgmManager, fetchCgmManager.cgmGlucoseSourceType == .plugin, fetchCgmManager.cgmManager != nil {
                kinds.append(.cgm)
            }
            return kinds
        }

        func reportContext() -> ProblemReport.Context {
            var cgm: String?
            if let source = fetchCgmManager?.cgmGlucoseSourceType, source != .none {
                cgm = source == .plugin ? fetchCgmManager?.cgmManager?.localizedTitle : source.displayName
            }
            return .current(pump: provider?.deviceManager?.pumpManager?.localizedTitle, cgm: cgm)
        }

        func hideSettingsModal() {
            hideModal()
        }

        // Commenting this out for now, as not needed and possibly dangerous for users to be able to nuke their pump pairing informations via the debug menu
        // Leaving it in here, as it may be a handy functionality for further testing or developers.
        // See https://github.com/nightscout/Trio/pull/277 for more information
//
//        func resetLoopDocuments() {
//            guard let localDocuments = try? FileManager.default.url(
//                for: .documentDirectory,
//                in: .userDomainMask,
//                appropriateFor: nil,
//                create: true
//            ) else {
//                preconditionFailure("Could not get a documents directory URL.")
//            }
//            let storageURL = localDocuments.appendingPathComponent("PumpManagerState" + ".plist")
//            try? FileManager.default.removeItem(at: storageURL)
//        }
        func hasCgmAndPump() -> Bool {
            let hasCgm = fetchCgmManager.cgmGlucoseSourceType != .none
            let hasPump = provider.deviceManager.pumpManager != nil
            return hasCgm && hasPump
        }

        /// Runs auto-config now and reloads the values it can write, so the screen shows them and a
        /// slider moved next starts from them rather than overwriting the run.
        @MainActor func runBoostAutoConfigNow(overrideHypoProtections: Bool) async -> [String] {
            let lines = await apsManager.runBoostAutoConfigNow(overrideHypoProtections: overrideHypoProtections)
            let p = settingsManager.preferences
            boostV5Aggression = p.boostV5Aggression
            boostV5HypoCaution = p.boostV5HypoCaution
            boostV5ConfirmedCapU = p.boostV5ConfirmedCapU
            boostV5CommittedCapU = p.boostV5CommittedCapU
            boostCumulativeSmbCap60Min = p.boostCumulativeSmbCap60Min
            boostV5PrimerCapU = p.boostV5PrimerCapU
            boostV5PrimerTbrFallback = p.boostV5PrimerTbrFallback
            boostV5AggressiveEarlyConfirm = p.boostV5AggressiveEarlyConfirm
            boostV5FastCarbConfirm = p.boostV5FastCarbConfirm
            return lines
        }

        // The user moved a V5 dosing-cap slider — record it so first-activation auto-config never
        // overrides a deliberately-set cap (Swift parity with Android's getIfExists==null). Called
        // from the slider's onEditingChanged (genuine user interaction only, never programmatic).
        func markBoostV5ConfirmedCapUserSet() { settingsManager.preferences.boostV5ConfirmedCapUUserSet = true }
        func markBoostV5CommittedCapUserSet() { settingsManager.preferences.boostV5CommittedCapUUserSet = true }
        func markBoostCumulativeSmbCap60MinUserSet() { settingsManager.preferences.boostCumulativeSmbCap60MinUserSet = true }
    }
}

extension Settings.StateModel: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        dosingMode = settings.dosingMode
        debugOptions = settings.debugOptions
    }
}

extension Settings.StateModel: ServiceOnboardingDelegate {
    func serviceOnboarding(didCreateService service: Service) {
        info(.settings, "Service \(service.pluginIdentifier) added")
        provider.tidepoolManager.addTidepoolService(service: service)
    }

    func serviceOnboarding(didOnboardService service: Service) {
        precondition(service.isOnboarded)
        debug(.settings, "Service \(service.pluginIdentifier) onboarded")
    }
}

extension Settings.StateModel: CompletionDelegate {
    func completionNotifyingDidComplete(_: CompletionNotifying) {
        setupTidepool = false
        provider.tidepoolManager.forceTidepoolDataUpload()
    }
}
