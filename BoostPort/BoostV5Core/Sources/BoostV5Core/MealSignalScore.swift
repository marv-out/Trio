import Foundation

public enum MealScoreConstants {
    public static let weightDelta = 0.30
    public static let weightDeltaAccl = 0.16
    public static let weightMlMealLikely = 0.20
    public static let weightNotRecentlyLow = 0.12
    public static let weightMealTimeOfDay = 0.10
    public static let weightNotExercising = 0.04
    public static let weightSustainedRise = 0.15
    public static let deltaNormalizeHiMgdl = 20.0
    public static let deltaAcclNormalizeHiPct = 30.0
    public static let sustainedRiseNormalizeLoMgdl = 20.0
    public static let sustainedRiseNormalizeHiMgdl = 60.0
    public static let mlMealRenormalizeAfterCycles = 3
    /// Sum of all seven signal weights. They do NOT sum to 1.0 (they sum to 1.07), so the
    /// ML-dropout renormalizer must divide by the real remaining total — not assume unity —
    /// otherwise the no-ML score is scaled onto a different basis than the with-ML score and
    /// biases the meal hypothesis toward earlier CONFIRMED. Referencing `totalWeight` keeps the
    /// degraded (no-ML) path on the same scale as the normal path regardless of the weight sum.
    public static let totalWeight = weightDelta + weightDeltaAccl + weightMlMealLikely
        + weightNotRecentlyLow + weightMealTimeOfDay + weightNotExercising + weightSustainedRise
    public static let mlMealRenormalizeFactor = totalWeight / (totalWeight - weightMlMealLikely)
    public static let notRecentlyLowFloor = 0.4
}

public struct ScoreComponents: Equatable, Sendable {
    public let deltaTerm, deltaAcclTerm, mlMealLikelyTerm, notRecentlyLowTerm: Double
    public let mealTimeOfDayTerm, notExercisingTerm, sustainedRiseTerm: Double
}

public struct ScoreResult: Equatable, Sendable {
    public let score: Double
    public let components: ScoreComponents
    public let mlWeightsRenormalized: Bool
}

public enum MealSignalScoreEngine {
    public static func mealSignalScore(
        delta: Double,
        deltaAccl: Double,
        mlMealLikely: Double?,
        recentLowBg: Double,
        hour: Int,
        exerciseActive: Bool,
        cumulativeRise30min: Double,
        mlMealLikelyNullStreak: Int = 0
    ) -> ScoreResult {
        let C = MealScoreConstants.self
        let deltaTerm = clipNormalize(delta, 0.0, C.deltaNormalizeHiMgdl)
        let deltaAcclTerm = clipNormalize(deltaAccl, 0.0, C.deltaAcclNormalizeHiPct)
        let notRecentlyLowTerm = notRecentlyLowPenalty(recentLowBg)
        let mealTimeOfDayTerm = mealTimeOfDayBump(hour)
        let notExercisingTerm = exerciseActive ? 0.0 : 1.0
        let sustainedRiseTerm = clipNormalize(cumulativeRise30min, C.sustainedRiseNormalizeLoMgdl, C.sustainedRiseNormalizeHiMgdl)

        let renormalize = mlMealLikely == nil && mlMealLikelyNullStreak >= C.mlMealRenormalizeAfterCycles
        let mlMealLikelyTerm = mlMealLikely ?? 0.0

        let rawScore: Double
        if renormalize {
            rawScore = C.mlMealRenormalizeFactor * (
                C.weightDelta * deltaTerm +
                    C.weightDeltaAccl * deltaAcclTerm +
                    C.weightNotRecentlyLow * notRecentlyLowTerm +
                    C.weightMealTimeOfDay * mealTimeOfDayTerm +
                    C.weightNotExercising * notExercisingTerm +
                    C.weightSustainedRise * sustainedRiseTerm
            )
        } else {
            rawScore =
                C.weightDelta * deltaTerm +
                C.weightDeltaAccl * deltaAcclTerm +
                C.weightMlMealLikely * mlMealLikelyTerm +
                C.weightNotRecentlyLow * notRecentlyLowTerm +
                C.weightMealTimeOfDay * mealTimeOfDayTerm +
                C.weightNotExercising * notExercisingTerm +
                C.weightSustainedRise * sustainedRiseTerm
        }

        let score = max(0.0, min(1.0, rawScore))
        return ScoreResult(
            score: score,
            components: ScoreComponents(
                deltaTerm: deltaTerm, deltaAcclTerm: deltaAcclTerm, mlMealLikelyTerm: mlMealLikelyTerm,
                notRecentlyLowTerm: notRecentlyLowTerm, mealTimeOfDayTerm: mealTimeOfDayTerm,
                notExercisingTerm: notExercisingTerm, sustainedRiseTerm: sustainedRiseTerm
            ),
            mlWeightsRenormalized: renormalize
        )
    }

    static func clipNormalize(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        if hi <= lo { return 0.0 }
        return max(0.0, min(1.0, (value - lo) / (hi - lo)))
    }

    static func notRecentlyLowPenalty(_ recentLowBg: Double) -> Double {
        max(MealScoreConstants.notRecentlyLowFloor, clipNormalize(recentLowBg, 70.0, 100.0))
    }

    static func mealTimeOfDayBump(_ hour: Int) -> Double {
        let centres = [8, 13, 19]
        let width = 2.0
        var maxBump = 0.0
        for centre in centres {
            let diff = Double(hour - centre)
            let bump = exp(-(diff * diff) / (2.0 * width * width))
            if bump > maxBump { maxBump = bump }
        }
        return maxBump
    }
}

// MARK: - Phase 2: action multiplier

public enum MealActionMultiplier {
    private static let multipliers: [MealHypothesis: Double] = [
        .idle: 1.0, .observing: 0.3, .confirmed: 1.8, .committed: 1.0, .recovering: 0.4
    ]

    /// Dose fraction for the state. The Aggression knob ∈ [0.7,1.6] scales CONFIRMED only.
    public static func value(for state: MealHypothesis, aggressionUserKnob: Double = 1.0) -> Double {
        let base = multipliers[state] ?? 1.0
        return state == .confirmed ? base * aggressionUserKnob : base
    }
}
