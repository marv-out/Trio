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

        var carbEntryToEdit: CarbEntryRecord?
        var showCarbEntryEditor = false

        // Carbs (+ FPU equivalents) now live in GRDB; the meals list is observed via ValueObservation
        // instead of a SwiftUI @FetchRequest. The "date >= oneDayAgo" rule (from `carbsHistory`) is
        // applied in the sink so the tracked region stays deterministic.
        var carbEntryStored: [CarbEntryRecord] = []
        @ObservationIgnored private var carbEntryObservationCancellable: AnyCancellable?

        // Pump events (incl. boluses + temp basals) now live in GRDB; the insulin list is observed via
        // ValueObservation instead of a SwiftUI @FetchRequest. The "timestamp >= oneDayAgo" rule (from
        // `pumpHistoryLast24h`) is applied in the sink so the tracked region stays deterministic.
        var pumpEventStored: [PumpEventDetails] = []
        @ObservationIgnored private var pumpEventObservationCancellable: AnyCancellable?

        // Override + temp target runs now live in GRDB; observed via ValueObservation instead of a
        // SwiftUI @FetchRequest. The "startDate >= oneDayAgo" rule is applied in the sink.
        var overrideRunStored: [OverrideRunRecord] = []
        @ObservationIgnored private var overrideRunObservationCancellable: AnyCancellable?
        var tempTargetRunStored: [TempTargetRunRecord] = []
        @ObservationIgnored private var tempTargetRunObservationCancellable: AnyCancellable?

        // Glucose readings now live in GRDB; observed via ValueObservation instead of a SwiftUI
        // @FetchRequest. The "date >= oneDayAgo" rule is applied in the sink, descending (newest first)
        // to match the former FetchRequest sort order.
        var glucoseStored: [GlucoseRecord] = []
        @ObservationIgnored private var glucoseObservationCancellable: AnyCancellable?

        override func subscribe() {
            units = settingsManager.settings.units
            broadcaster.register(DeterminationObserver.self, observer: self)
            broadcaster.register(SettingsObserver.self, observer: self)
            setupCarbEntryObservation()
            setupPumpEventObservation()
            setupOverrideRunObservation()
            setupTempTargetRunObservation()
            setupGlucoseObservation()
        }

        private func setupPumpEventObservation() {
            pumpEventObservationCancellable = PumpEventStore.observeForChart()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            debug(.default, "\(DebuggingIdentifiers.failed) History pump event observation failed: \(error)")
                        }
                    },
                    receiveValue: { [weak self] details in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        pumpEventStored = details.filter { ($0.timestamp ?? .distantPast) >= cutoff }
                    }
                )
        }

        private func setupCarbEntryObservation() {
            carbEntryObservationCancellable = CarbEntryStore.observeHistory()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            debug(.default, "\(DebuggingIdentifiers.failed) History carb observation failed: \(error)")
                        }
                    },
                    receiveValue: { [weak self] records in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        carbEntryStored = records.filter { ($0.date ?? .distantPast) >= cutoff }
                    }
                )
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

        private func setupGlucoseObservation() {
            glucoseObservationCancellable = GlucoseStore.observeForChart()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            debug(.default, "\(DebuggingIdentifiers.failed) History glucose observation failed: \(error)")
                        }
                    },
                    receiveValue: { [weak self] records in
                        guard let self else { return }
                        let cutoff = Date.oneDayAgo
                        // observeForChart() returns newest 1000 rows descending; filter to oneDayAgo
                        // and keep descending order (newest first) to match former FetchRequest.
                        glucoseStored = records.filter { ($0.date ?? .distantPast) >= cutoff }
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
