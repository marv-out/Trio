import Foundation

struct ComputedBGTargetEntry: Codable {
    var low: Decimal
    var high: Decimal
    var start: String
    var offset: Int
    var maxBg: Decimal?
    var minBg: Decimal?
    var temptargetSet: Bool?
}

extension ComputedBGTargetEntry {
    private enum CodingKeys: String, CodingKey {
        case low
        case high
        case start
        case offset
        case maxBg = "max_bg"
        case minBg = "min_bg"
        case temptargetSet
    }
}

struct ComputedBGTargets: Codable {
    let units: GlucoseUnits
    let userPreferredUnits: GlucoseUnits
    var targets: [ComputedBGTargetEntry]
    /// Boost: the scheduled profile target (mg/dL) at decision time, captured BEFORE any
    /// active temp target overwrites it. AAPS night mode (`isNightModeActiveImpl`) compares
    /// against the base profile target — not the TT-adjusted one — for both the low-TT gate
    /// and the final bg-vs-target gate. Transient (excluded from CodingKeys, so it is not
    /// serialized as part of the targets blob); set in `Targets.lookup` and surfaced onto
    /// `Profile.boostBaseTargetMgdl` (which IS serialized) by `ProfileGenerator`.
    var baseProfileTargetMgdl: Decimal? = nil
}

extension ComputedBGTargets {
    private enum CodingKeys: String, CodingKey {
        case units
        case userPreferredUnits = "user_preferred_units"
        case targets
    }
}
