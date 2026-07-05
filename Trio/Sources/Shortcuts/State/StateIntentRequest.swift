import AppIntents
import CoreData
import Foundation

enum StateIntentError: Error {
    case StateIntentUnknownError
    case NoBG
    case NoIOBCOB
}

struct StateResults: AppEntity {
    static var defaultQuery = StateBGQuery()

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Trio State Result"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(glucose)")
    }

    var id: UUID
    @Property(title: "Glucose") var glucose: String

    @Property(title: "Trend") var trend: String

    @Property(title: "Delta") var delta: String

    @Property(title: "Date") var date: Date

    @Property(title: "IOB") var iob: Double?

    @Property(title: "COB") var cob: Double?

    @Property(title: "unit") var unit: String?

    init(glucose: String, trend: String, delta: String, date: Date, iob: Double, cob: Double, unit: GlucoseUnits) {
        id = UUID()
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.date = date
        self.iob = iob
        self.cob = cob
        self.unit = unit.rawValue
    }
}

struct StateBGQuery: EntityQuery {
    func entities(for _: [StateResults.ID]) async throws -> [StateResults] {
        []
    }

    func suggestedEntities() async throws -> [StateResults] {
        []
    }
}

final class StateIntentRequest: BaseIntentsRequest {
    func getLastGlucose() async throws
        -> (dateGlucose: Date, glucose: String, trend: String, delta: String)
    {
        do {
            let results = try await GlucoseStore.fetch(from: Date.halfHourAgo, ascending: false, limit: 2)

            guard let lastValue = results.first else { throw StateIntentError.NoBG }

            /// calculate delta
            let lastGlucose = lastValue.glucose
            let secondLastGlucose = results.dropFirst().first?.glucose
            let delta = results.count > 1 ? (lastGlucose - (secondLastGlucose ?? 0)) : nil
            /// formatting
            let units = settingsManager.settings.units
            let glucoseAsString = glucoseFormatter.string(from: Double(
                units == .mmolL ? Decimal(lastGlucose)
                    .asMmolL : Decimal(lastGlucose)
            ) as NSNumber)!

            let directionAsString = lastValue.direction ?? String(localized: "none")

            let deltaAsString = delta
                .map {
                    self.deltaFormatter
                        .string(from: Double(
                            units == .mmolL ? Decimal($0)
                                .asMmolL : Decimal($0)
                        ) as NSNumber)!
                } ?? "--"
            debugPrint("StateIntentRequest: \(#function) \(DebuggingIdentifiers.succeeded) fetched latest 2 glucose values")
            return (lastValue.date ?? Date(), glucoseAsString, directionAsString, deltaAsString)
        } catch {
            debugPrint("StateIntentRequest: \(#function) \(DebuggingIdentifiers.failed) failed to fetch latest 2 glucose values")
            return (Date(), "", "", "")
        }
    }

    func getIobAndCob() async -> (iob: Double, cob: Double) {
        let determination = try? await OrefDeterminationStore.fetchLast(within: 30, enactedOnly: true)

        let iobAsDouble = Double(truncating: (iobService.currentIOB ?? 0.0) as NSNumber)
        let cobAsDouble = Double(determination?.cob ?? 0)

        return (iobAsDouble, cobAsDouble)
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if settingsManager.settings.units == .mmolL {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        }
        formatter.roundingMode = .halfUp
        return formatter
    }

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
    }
}
