import Foundation

/// Silent shadow of Boost V4.4.2's TDD-anchored EMA sensitivity ratio.
///
/// 1:1 port of `BoostIsfShadow.computeShadow(...)` from AAPS
/// (`plugins/aps/.../openAPSBoost/BoostIsfShadow.kt`).
///
/// V1's behaviour: `ratio = (tdd_24h / tdd_7d).coerceIn(autosensMin, autosensMax)`.
/// V4.4.2's behaviour: `ratio = EMA(τ=3h, raw_ratio)` with a 5-day cold-start blend
/// toward 1.0.
///
/// The Kotlin original keeps mutable EMA state in fields persisted to
/// SharedPreferences. This port is **pure**: the prior state is passed in and the
/// updated state is returned in the result. `nowMs` is also injected (no `Date.now`).
public struct IsfShadowState: Codable, Equatable, Sendable {
    /// Current EMA value (`emaState` in the Kotlin source). `nil` => not yet seeded.
    public var emaState: Double?
    /// Last EMA update timestamp in ms since epoch. `nil` => never updated.
    public var lastUpdateMs: Double?
    /// Earliest known TDD record timestamp in ms since epoch (drives warmup).
    /// `nil` => not yet seeded.
    public var firstSeenMs: Double?

    public init(emaState: Double? = nil, lastUpdateMs: Double? = nil, firstSeenMs: Double? = nil) {
        self.emaState = emaState
        self.lastUpdateMs = lastUpdateMs
        self.firstSeenMs = firstSeenMs
    }
}

public struct IsfShadowResult: Equatable, Sendable {
    /// Bounded EMA value — V4.4.2's final output (`bounded` in the Kotlin source).
    public let ratio: Double
    /// Raw `tdd_24h / tdd_7d` clamped to `[autosensMin, autosensMax]` — V1's value.
    public let raw: Double
    /// EMA value before the final autosens clamp.
    public let ema: Double
    /// Cold-start warmup fraction in `0.0...1.0`.
    public let warmupFraction: Double
    /// Updated persisted state to carry into the next call.
    public let newState: IsfShadowState

    public init(
        ratio: Double,
        raw: Double,
        ema: Double,
        warmupFraction: Double,
        newState: IsfShadowState
    ) {
        self.ratio = ratio
        self.raw = raw
        self.ema = ema
        self.warmupFraction = warmupFraction
        self.newState = newState
    }
}

public enum IsfShadowEma {
    // MARK: - Constants (matched exactly to BoostIsfShadow.kt)

    /// EMA time constant τ = 3 hours, in milliseconds (`tauMs = 3L * 60 * 60 * 1000L`).
    public static let tauMs: Double = 3.0 * 60.0 * 60.0 * 1000.0

    /// Cold-start window length in days (`coldStartDays = 5.0`).
    public static let coldStartDays: Double = 5.0

    /// Number of milliseconds in a day, used to convert elapsed ms to days.
    private static let dayMs: Double = 24.0 * 60.0 * 60.0 * 1000.0

    /// Compute the V4.4.2-style EMA-smoothed sensitivity ratio for the current cycle.
    ///
    /// Returns `nil` if either TDD value is missing or non-positive — mirroring the
    /// Kotlin guard `tddLast24H <= 0.0 || tdd7D <= 0.0` (V4.4.2 would also have
    /// skipped the overlay, so V1 and V4.4.2 agree for the cycle).
    ///
    /// - Parameters:
    ///   - tdd24h: tdd_24h in U (must be > 0 to compute).
    ///   - tdd7d:  tdd_7d in U (must be > 0 to compute).
    ///   - autosensMin: lower clamp from profile/settings.
    ///   - autosensMax: upper clamp from profile/settings.
    ///   - nowMs: current time in ms since epoch.
    ///   - state: prior persisted state.
    public static func computeShadow(
        tdd24h: Double?,
        tdd7d: Double?,
        autosensMin: Double,
        autosensMax: Double,
        nowMs: Double,
        state: IsfShadowState
    ) -> IsfShadowResult? {
        guard let tdd24h, let tdd7d, tdd24h > 0.0, tdd7d > 0.0 else {
            return nil
        }

        // Seed firstSeenMs on the first ever call (Kotlin: `if (firstSeenMs == 0L)`).
        let firstSeenMs = state.firstSeenMs ?? nowMs

        // V1 raw ratio, clamped to [autosensMin, autosensMax].
        let rawRatio = clamp(tdd24h / tdd7d, autosensMin, autosensMax)

        // Cold-start: linearly blend raw toward 1.0 over the first `coldStartDays` days.
        let daysSeen = (nowMs - firstSeenMs) / dayMs
        let warmup = clamp(daysSeen / coldStartDays, 0.0, 1.0)
        let warmedRatio = 1.0 + (rawRatio - 1.0) * warmup

        // EMA update with elapsed-time-aware α = 1 - exp(-Δt / τ).
        // Kotlin seeds on `lastUpdateMs == 0L`; here a `nil` lastUpdateMs is the seed.
        let ema: Double
        let newEmaState: Double
        if state.lastUpdateMs == nil {
            ema = warmedRatio
            newEmaState = warmedRatio
        } else {
            let priorEma = state.emaState ?? 1.0
            let dtMs = max(nowMs - (state.lastUpdateMs ?? 0.0), 0.0)
            let alpha = dtMs > 0.0 ? 1.0 - exp(-dtMs / tauMs) : 0.0
            newEmaState = priorEma + alpha * (warmedRatio - priorEma)
            ema = newEmaState
        }

        // Final autosens clamp on the smoothed value (Kotlin: `max(min(ema, max), min)`).
        let bounded = max(min(ema, autosensMax), autosensMin)

        let newState = IsfShadowState(
            emaState: newEmaState,
            lastUpdateMs: nowMs,
            firstSeenMs: firstSeenMs
        )

        return IsfShadowResult(
            ratio: bounded,
            raw: rawRatio,
            ema: ema,
            warmupFraction: warmup,
            newState: newState
        )
    }

    /// Matches Kotlin `Double.coerceIn(min, max)` for the inputs used here.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        max(lower, min(upper, value))
    }
}
