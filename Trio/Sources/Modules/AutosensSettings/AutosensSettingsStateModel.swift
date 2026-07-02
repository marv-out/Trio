import CoreData
import Observation
import SwiftUI

extension AutosensSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var settings: SettingsManager!
        @Injected() var storage: FileStorage!
        @Injected() var determinationStorage: DeterminationStorage!

        var units: GlucoseUnits = .mgdL

        private(set) var autosensISF: Decimal?
        private(set) var autosensRatio: Decimal = 1
        @Published var determinationsFromPersistence: [OrefDeterminationRecord] = []

        @Published var autosensMax: Decimal = 1.2
        @Published var autosensMin: Decimal = 0.7
        @Published var rewindResetsAutosens: Bool = true

        var preferences: Preferences {
            settingsManager.preferences
        }

        override func subscribe() {
            units = settingsManager.settings.units

            subscribePreferencesSetting(\.autosensMax, on: $autosensMax) { autosensMax = $0 }
            subscribePreferencesSetting(\.autosensMin, on: $autosensMin) { autosensMin = $0 }
            subscribePreferencesSetting(\.rewindResetsAutosens, on: $rewindResetsAutosens) { rewindResetsAutosens = $0 }

            if let newISF = provider.autosense.newisf {
                autosensISF = newISF
            }

            autosensRatio = provider.autosense.ratio
            setupDeterminationsArray()
        }

        private func setupDeterminationsArray() {
            Task {
                do {
                    let determination = try await determinationStorage.fetchLastDetermination(
                        within: 30,
                        enactedOnly: true
                    )
                    await MainActor.run {
                        determinationsFromPersistence = determination.map { [$0] } ?? []
                    }
                } catch {
                    debug(
                        .default,
                        "\(DebuggingIdentifiers.failed) Error fetching last determination: \(error)"
                    )
                }
            }
        }
    }
}

extension AutosensSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
