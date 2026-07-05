import CoreData
import Foundation
import Swinject

/// Shared safety checks applied to any bolus command originating outside the main bolus UI
/// (remote notifications, Shortcuts, etc.). Keeps validation logic consistent across call sites.
protocol BolusSafetyValidator {
    /// - Parameter lookbackStart: start of the window used for the recent-bolus 20% check.
    ///   Defaults to `now - BolusSafetyEvaluator.recentBolusWindowMinutes`. Callers that know when the
    ///   command was originally issued (e.g. APNS payload timestamp) should pass that instead so the
    ///   check covers any bolus since the command was sent.
    func validate(bolusAmount: Decimal, lookbackStart: Date?) async throws -> BolusSafetyResult
    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal
}

extension BolusSafetyValidator {
    func validate(bolusAmount: Decimal) async throws -> BolusSafetyResult {
        try await validate(bolusAmount: bolusAmount, lookbackStart: nil)
    }
}

enum BolusSafetyResult: Equatable {
    case allowed
    case rejected(BolusSafetyRejection)
}

enum BolusSafetyRejection: Equatable {
    case exceedsMaxBolus(maxBolus: Decimal)
    case iobUnavailable
    case exceedsMaxIOB(currentIOB: Decimal, maxIOB: Decimal)
    case recentBolusWithinWindow(totalRecent: Decimal)
}

struct BolusSafetyInputs: Equatable {
    let maxBolus: Decimal
    let maxIOB: Decimal
    let currentIOB: Decimal?
    /// Sum of bolus amounts delivered within the recent-bolus window (see `BolusSafetyEvaluator.recentBolusWindowMinutes`).
    let totalRecentBolus: Decimal
}

enum BolusSafetyEvaluator {
    static let recentBolusThreshold: Decimal = 0.2
    static let recentBolusWindowMinutes: Int = 6

    static func evaluate(bolusAmount: Decimal, inputs: BolusSafetyInputs) -> BolusSafetyResult {
        if bolusAmount > inputs.maxBolus {
            return .rejected(.exceedsMaxBolus(maxBolus: inputs.maxBolus))
        }
        guard let currentIOB = inputs.currentIOB else {
            return .rejected(.iobUnavailable)
        }
        if (currentIOB + bolusAmount) > inputs.maxIOB {
            return .rejected(.exceedsMaxIOB(currentIOB: currentIOB, maxIOB: inputs.maxIOB))
        }
        if inputs.totalRecentBolus >= bolusAmount * recentBolusThreshold {
            return .rejected(.recentBolusWithinWindow(totalRecent: inputs.totalRecentBolus))
        }
        return .allowed
    }
}

final class BaseBolusSafetyValidator: BolusSafetyValidator, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var iobService: IOBService!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func validate(bolusAmount: Decimal, lookbackStart: Date?) async throws -> BolusSafetyResult {
        let windowStart = lookbackStart
            ?? Date().addingTimeInterval(-Double(BolusSafetyEvaluator.recentBolusWindowMinutes * 60))
        let inputs = BolusSafetyInputs(
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxIOB: settingsManager.preferences.maxIOB,
            currentIOB: iobService.currentIOB,
            totalRecentBolus: try await fetchTotalRecentBolusAmount(since: windowStart)
        )
        return BolusSafetyEvaluator.evaluate(bolusAmount: bolusAmount, inputs: inputs)
    }

    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal {
        try await PumpEventStore.fetchTotalRecentBolusAmount(since: date)
    }
}
