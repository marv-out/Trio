import Foundation

/// Boost-specific Circadian ISF sensitivity factor.
///
/// 1:1 port of `DetermineBasalBoost.getCircadianSensitivity(hourOfDay)` from AAPS
/// (`plugins/aps/.../openAPSBoost/DetermineBasalBoost.kt`). The curve is a
/// piecewise cubic polynomial keyed on time of day, returning a sensitivity
/// multiplier (~0.4–1.4). Coefficients and segment boundaries match the Kotlin
/// source exactly.
public enum CircadianISF {
    /// Circadian sensitivity factor for the given hour of day (0–23).
    ///
    /// Mirrors the Kotlin `when` expression. `now` is `max(hourOfDay, 0)` as a
    /// Double; within the first segment `n = max(now, 0.5)`.
    public static func sensitivity(hourOfDay: Int) -> Double {
        let now = Double(max(hourOfDay, 0))
        switch now {
        case 0.0 ..< 2.0:
            let n = max(now, 0.5)
            return (0.09130 * pow(n, 3)) - (0.33261 * pow(n, 2)) + 1.4
        case 2.0 ..< 3.0:
            return (0.0869 * pow(now, 3)) - (0.05217 * pow(now, 2)) - (0.23478 * now) + 0.8
        case 3.0 ..< 8.0:
            return (0.0007 * pow(now, 3)) - (0.000730 * pow(now, 2)) - (0.0007826 * now) + 0.6
        case 8.0 ..< 11.0:
            return (0.001244 * pow(now, 3)) - (0.007619 * pow(now, 2)) - (0.007826 * now) + 0.4
        case 11.0 ..< 15.0:
            return (0.00078 * pow(now, 3)) - (0.00272 * pow(now, 2)) - (0.07619 * now) + 0.8
        case 15.0 ... 22.0:
            return 1.0
        case 22.0 ... 24.0:
            return (0.000125 * pow(now, 3)) - (0.0015 * pow(now, 2)) - (0.0045 * now) + 1.2
        default:
            return 1.0
        }
    }

    /// Applies the circadian factor to a variable sensitivity, rounded to 1 dp.
    ///
    /// Mirrors Kotlin: `sens = round(variable_sens * circadian_sensitivity, 1)`,
    /// where `round` is `Math.round(value * scale) / scale` (HALF_UP for the
    /// non-negative inputs used here).
    public static func apply(variableSens: Double, hourOfDay: Int) -> Double {
        let value = variableSens * sensitivity(hourOfDay: hourOfDay)
        return round1(value)
    }

    /// Matches Kotlin `round(value, 1)`: `Math.round(value * 10) / 10`.
    private static func round1(_ value: Double) -> Double {
        if value.isNaN { return Double.nan }
        let scale = 10.0
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
