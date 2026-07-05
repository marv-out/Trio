import AppIntents
import Foundation

@available(iOS 16.0, *) struct ListStateIntent: AppIntent {
    // Title of the action in the Shortcuts app
    static var title: LocalizedStringResource = "List last state available with Trio"

    // Description of the action in the Shortcuts app
    static var description = IntentDescription(
        "Allow to list the last glucose reading, trends, IOB and COB available in Trio"
    )

    static var parameterSummary: some ParameterSummary {
        Summary("List all states of Trio")
    }

    @MainActor func perform() async throws -> some ReturnsValue<StateResults> & ShowsSnippetView {
        let stateIntent = StateIntentRequest()

        let glucoseValues = try? await stateIntent.getLastGlucose()
        let iob_cob = await stateIntent.getIobAndCob()

        guard let glucoseValue = glucoseValues else { throw StateIntentError.NoBG }
        let BG = StateResults(
            glucose: glucoseValue.glucose,
            trend: glucoseValue.trend,
            delta: glucoseValue.delta,
            date: glucoseValue.dateGlucose,
            iob: iob_cob.iob,
            cob: iob_cob.cob,
            unit: stateIntent.settingsManager.settings.units
        )
        return .result(
            value: BG,
            view: ListStateView(state: BG)
        )
    }
}
