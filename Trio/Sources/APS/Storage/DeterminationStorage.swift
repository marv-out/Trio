import Combine
import Foundation
import GRDB
import Swinject

protocol DeterminationStorage {
    /// The most recent determination within a `minutes`-wide window (mirrors the former
    /// `fetchLastDeterminationObjectID` for both determination predicates). `enactedOnly == true`
    /// filters `enacted == true AND timestamp >= cutoff`; otherwise `deliverAt >= cutoff`.
    func fetchLastDetermination(within minutes: Int, enactedOnly: Bool) async throws -> OrefDeterminationRecord?
    /// All determinations within a `minutes`-wide window, newest first (Garmin's 30-min window).
    func fetchRecentDeterminations(within minutes: Int) async throws -> [OrefDeterminationRecord]
    /// The whole forecast tree for a determination (each forecast + its values, values capped at 36).
    func fetchForecastHierarchy(for determinationPk: Int64) async throws
        -> [(forecast: ForecastRecord, values: [ForecastValueRecord])]
    /// Builds the Nightscout `Determination` DTO for a determination record (assembles the four
    /// forecast curves via the store). Replaces `getOrefDeterminationNotYetUploadedToNightscout`.
    func buildDeterminationDTO(from record: OrefDeterminationRecord) async -> Determination
}

final class BaseDeterminationStorage: DeterminationStorage, Injectable {
    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func fetchLastDetermination(within minutes: Int = 30, enactedOnly: Bool = false) async throws
        -> OrefDeterminationRecord?
    {
        try await OrefDeterminationStore.fetchLast(within: minutes, enactedOnly: enactedOnly)
    }

    func fetchRecentDeterminations(within minutes: Int = 30) async throws -> [OrefDeterminationRecord] {
        try await OrefDeterminationStore.fetchRecent(within: minutes)
    }

    func fetchForecastHierarchy(for determinationPk: Int64) async throws
        -> [(forecast: ForecastRecord, values: [ForecastValueRecord])]
    {
        try await ForecastStore.fetchHierarchy(for: determinationPk)
    }

    func buildDeterminationDTO(from record: OrefDeterminationRecord) async -> Determination {
        // Reassemble the four forecast curves (empty → nil, as the former `parseForecastValues` did).
        var predictions = Predictions(iob: nil, zt: nil, cob: nil, uam: nil)
        if let pk = record.pk {
            func values(_ type: String) async -> [Int]? {
                let v = (try? await ForecastStore.fetchValues(type: type, for: pk)) ?? []
                return v.isEmpty ? nil : v
            }
            predictions = await Predictions(
                iob: values("iob"),
                zt: values("zt"),
                cob: values("cob"),
                uam: values("uam")
            )
        }

        return Determination(
            id: record.id ?? UUID(),
            reason: record.reason ?? "",
            units: record.smbToDeliver,
            insulinReq: record.insulinReq ?? 0,
            // Mirrors the former `orefDetermination.eventualBG as? Int`, which always yielded nil
            // (an NSDecimalNumber never bridges to Int via `as?`). Kept verbatim to stay in scope.
            eventualBG: nil,
            sensitivityRatio: record.sensitivityRatio ?? 0,
            rate: record.rate ?? 0,
            duration: record.duration ?? 0,
            iob: record.iob ?? 0,
            cob: Decimal(record.cob),
            predictions: predictions,
            deliverAt: record.deliverAt,
            carbsReq: record.carbsRequired != 0 ? Decimal(record.carbsRequired) : nil,
            temp: TempType(rawValue: record.temp ?? "absolute"),
            bg: record.glucose ?? 0,
            reservoir: record.reservoir ?? 0,
            isf: record.insulinSensitivity ?? 0,
            timestamp: record.timestamp,
            current_target: record.currentTarget ?? 0,
            minDelta: record.minDelta ?? 0,
            expectedDelta: record.expectedDelta ?? 0,
            minGuardBG: nil,
            minPredBG: nil,
            threshold: record.threshold ?? 0,
            carbRatio: record.carbRatio ?? 0,
            received: record.enacted // this is actually part of NS...
        )
    }
}
