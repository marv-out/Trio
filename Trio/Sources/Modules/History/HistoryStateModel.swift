import Combine
import CoreData
import HealthKit
import Observation
import SwiftUI

extension History {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var broadcaster: Broadcaster!
        @ObservationIgnored @Injected() var apsManager: APSManager!
        @ObservationIgnored @Injected() var unlockmanager: UnlockManager!
        @ObservationIgnored @Injected() private var storage: FileStorage!
        @ObservationIgnored @Injected() var pumpHistoryStorage: PumpHistoryStorage!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var healthKitManager: HealthKitManager!
        @ObservationIgnored @Injected() var carbsStorage: CarbsStorage!

        var mode: Mode = .treatments
        var treatments: [Treatment] = []
        var manualGlucose: Decimal = 0
        var waitForSuggestion: Bool = false

        var insulinEntryDeleted: Bool = false
        var carbEntryDeleted: Bool = false

        var units: GlucoseUnits = .mgdL

        var carbEntryToEdit: CarbEntryStored?
        var showCarbEntryEditor = false

        // Override + temp target runs now live in GRDB; observed via ValueObservation instead of a
        // SwiftUI @FetchRequest. The "startDate >= oneDayAgo" rule is applied in the sink.
        var overrideRunStored: [OverrideRunRecord] = []
        @ObservationIgnored private var overrideRunObservationCancellable: AnyCancellable?
        var tempTargetRunStored: [TempTargetRunRecord] = []
        @ObservationIgnored private var tempTargetRunObservationCancellable: AnyCancellable?

        override func subscribe() {
            units = settingsManager.settings.units
            broadcaster.register(DeterminationObserver.self, observer: self)
            broadcaster.register(SettingsObserver.self, observer: self)
            setupOverrideRunObservation()
            setupTempTargetRunObservation()
        }

        private func setupOverrideRunObservation() {
            overrideRunObservationCancellable = OverrideRunStore.observeRecent()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            debug(.default, "\(DebuggingIdentifiers.failed) History override run observation failed: \(error)")
                        }
                    },
                    receiveValue: { [weak self] records in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        overrideRunStored = records.filter { ($0.startDate ?? .distantPast) >= cutoff }
                    }
                )
        }

        private func setupTempTargetRunObservation() {
            tempTargetRunObservationCancellable = TempTargetRunStore.observeRecent()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            debug(.default, "\(DebuggingIdentifiers.failed) History temp target run observation failed: \(error)")
                        }
                    },
                    receiveValue: { [weak self] records in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        tempTargetRunStored = records.filter { ($0.startDate ?? .distantPast) >= cutoff }
                    }
                )
        }

        /// Checks if the glucose data is fresh based on the given date
        /// - Parameter glucoseDate: The date to check
        /// - Returns: Boolean indicating if the data is fresh
        func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool {
            glucoseStorage.isGlucoseDataFresh(glucoseDate)
        }

        func addManualGlucose() {
            // Always save value in mg/dL
            let glucose = units == .mmolL ? manualGlucose.asMgdL : manualGlucose
            let glucoseAsInt = Int(glucose)

            glucoseStorage.addManualGlucose(glucose: glucoseAsInt)
        }
    }
}

extension History.StateModel: DeterminationObserver, SettingsObserver {
    func determinationDidUpdate(_: Determination) {
        DispatchQueue.main.async {
            self.waitForSuggestion = false
        }
    }

    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
