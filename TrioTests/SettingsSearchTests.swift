import Foundation
import Testing
@testable import Trio

@Suite("Settings Search Navigation") struct SettingsSearchTests {
    @Test("Lower threshold names and legacy aliases navigate to the renamed setting") func searchLowerRangeThreshold() {
        for query in ["TIR Lower Threshold", "Standard", "Extended", "Time in Range Type", "TITR", "TING"] {
            let results = SettingItems.filteredItems(searchText: query)
            #expect(results.contains {
                $0.settingItem.view == .userInterfaceSettings && $0.scrollLabel == "TIR Lower Threshold"
            }, "No lower threshold search target for \(query)")
        }
    }

    @Test("Searching 'Dynamic ISF' finds the Dynamic Settings screen") func searchDynamicISF() {
        let results = SettingItems.filteredItems(searchText: "Dynamic ISF")
        #expect(!results.isEmpty)
        let match = results.first { $0.matchedContent == "Dynamic ISF" }
        #expect(match != nil)
        #expect(match?.settingItem.view == .dynamicISF)
        #expect(match?.scrollLabel == "Dynamic ISF")
    }

    @Test("All scrollTargetLabels have valid non-empty targets") func scrollTargetLabelsNonEmpty() {
        for item in SettingItems.allItems {
            guard let labels = item.scrollTargetLabels else { continue }
            for (key, value) in labels {
                #expect(!value.isEmpty)
                #expect(item.searchContents?.contains(key) == true)
            }
        }
    }

    @Test("Every searchContents entry produces at least one result") func allSearchContentsAreSearchable() {
        for item in SettingItems.allItems {
            guard let contents = item.searchContents else { continue }
            for content in contents {
                let results = SettingItems.filteredItems(searchText: content)
                #expect(!results.isEmpty)
            }
        }
    }

    @Test("SearchResultTarget is Hashable and equatable by value") func searchResultTargetHashable() {
        let a = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Dynamic ISF")
        let b = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Dynamic ISF")
        let c = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Adjust Basal")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("SettingsSearchHighlight starts nil and accepts assignments")
    @MainActor func highlightStateTransitions() {
        let highlight = SettingsSearchHighlight()
        #expect(highlight.highlightedSetting == nil)

        highlight.highlightedSetting = "Dynamic ISF"
        #expect(highlight.highlightedSetting == "Dynamic ISF")

        highlight.highlightedSetting = nil
        #expect(highlight.highlightedSetting == nil)
    }

    @Test("SettingsSearchHighlight can be set and cleared in sequence")
    @MainActor func highlightSequentialUpdates() async {
        let highlight = SettingsSearchHighlight()

        highlight.highlightedSetting = "First Setting"
        #expect(highlight.highlightedSetting == "First Setting")

        highlight.highlightedSetting = "Second Setting"
        #expect(highlight.highlightedSetting == "Second Setting")

        highlight.highlightedSetting = nil
        #expect(highlight.highlightedSetting == nil)
    }
}

/// A Boost settings slider writes through the state model to the stored preferences, so moving a
/// slider changes the setting itself. Whether the screen redraws is a separate matter: the advanced
/// screen is its own view observing the state model.
@Suite("Boost settings write-through", .serialized) struct BoostSettingsWriteThroughTests {
    @Test("A slider write reaches the stored preferences") func sliderWriteReachesPreferences() {
        let resolver = TrioApp().resolver
        let settingsManager = resolver.resolve(SettingsManager.self)!
        let original = settingsManager.preferences.boostV5Sensitivity
        defer { settingsManager.preferences.boostV5Sensitivity = original }

        let state = Settings.StateModel()
        state.resolver = resolver
        let moved: Decimal = original == 1.15 ? 0.85 : 1.15
        state.boostV5Sensitivity = moved

        #expect(settingsManager.preferences.boostV5Sensitivity == moved)
    }
}

/// Votes from a run whose raise guard was overridden are kept apart from the scheduled ledger, so a
/// scheduled run cannot complete a two-run confirmation with one; and only one run holds the lock.
@Suite("Boost re-derivation ledgers", .serialized) struct BoostRedriveLedgerTests {
    @Test("An overridden run's vote is invisible to a scheduled run") func overriddenVotesAreSeparate() {
        BoostRedriveStore.reset()
        defer { BoostRedriveStore.reset() }
        BoostRedriveStore.setPending(.committedCapU, 0.8, overridden: true)
        BoostRedriveStore.setPendingFlag("aec.prev", true, overridden: true)
        #expect(BoostRedriveStore.pending(.committedCapU) == nil)
        #expect(BoostRedriveStore.pendingFlag("aec.prev") == nil)
        #expect(BoostRedriveStore.pending(.committedCapU, overridden: true) == 0.8)
    }

    @Test("A run without the override clears the overridden votes") func ordinaryRunClearsOverriddenVotes() {
        BoostRedriveStore.reset()
        defer { BoostRedriveStore.reset() }
        BoostRedriveStore.setPending(.committedCapU, 0.8)
        BoostRedriveStore.setPending(.committedCapU, 0.8, overridden: true)
        #expect(BoostRedriveStore.voteLedger(overrideLiftsGuard: true))
        #expect(BoostRedriveStore.pending(.committedCapU, overridden: true) == 0.8)
        #expect(!BoostRedriveStore.voteLedger(overrideLiftsGuard: false))
        #expect(BoostRedriveStore.pending(.committedCapU, overridden: true) == nil)
        #expect(BoostRedriveStore.pending(.committedCapU) == 0.8)
    }

    @Test("Only one run at a time") func oneRunAtATime() {
        #expect(BoostRedriveStore.tryBeginRun())
        #expect(!BoostRedriveStore.tryBeginRun())
        BoostRedriveStore.endRun()
        #expect(BoostRedriveStore.tryBeginRun())
        BoostRedriveStore.endRun()
    }
}
