import Foundation

public enum AggressionBudgetConstants {
    public static let budgetFloorFraction = 0.30
    public static let mlHypoRiskThreshold = 0.30
    public static let mlHypoRiskFloor = 0.50
    public static let postExerciseRecoveryScale = 0.50
}

public struct AggressionBudgetResult: Equatable, Sendable {
    public let budget: Double
    public let mlHypoRiskScale: Double
    public let postExerciseRecoveryScale: Double
    public let aggressionModifier: Double
    public let rawBudget: Double
    public let floorBudget: Double
}

public enum AggressionBudgetEngine {
    public static func aggressionBudget(
        baseInsulinReq: Double,
        mlHypoRisk: Double?,
        inPostExerciseWindow: Bool,
        hypoCautionUserKnob: Double = 1.0,
        sensitivityUserKnob: Double = 1.0
    ) -> AggressionBudgetResult {
        let mlScale = mlHypoRiskScale(mlHypoRisk, hypoCautionKnob: hypoCautionUserKnob)
        let postExScale = postExerciseRecoveryModifier(inPostExerciseWindow)
        let sensitivity = min(max(sensitivityUserKnob, 0.8), 1.2)
        let aggressionModifier = mlScale * postExScale * sensitivity
        let rawBudget = baseInsulinReq * aggressionModifier
        // The floor falls with Hypo Caution as the ML floor does; held at 0.30 it overrode the deeper
        // cut above Hypo Caution 1.67 (AAPS Boost 6.3.0, 4a3c7a4341). Unchanged at Hypo Caution 1.0.
        let floorBudget = AggressionBudgetConstants.budgetFloorFraction / max(hypoCautionUserKnob, 1.0) * baseInsulinReq
        let budget = max(floorBudget, rawBudget)
        return AggressionBudgetResult(
            budget: budget, mlHypoRiskScale: mlScale, postExerciseRecoveryScale: postExScale,
            aggressionModifier: aggressionModifier, rawBudget: rawBudget, floorBudget: floorBudget
        )
    }

    /// Graduated hypo-risk damper. 1.0 below threshold; ramps down toward `floor` as risk → 1.0.
    /// Higher hypoCaution knob = MORE backoff and a LOWER floor (0.50@1.0 → 0.25@2.0). 2026-06-15 fix.
    public static func mlHypoRiskScale(_ mlHypoRisk: Double?, hypoCautionKnob: Double = 1.0) -> Double {
        guard let risk = mlHypoRisk else { return 1.0 }
        let C = AggressionBudgetConstants.self
        if risk <= C.mlHypoRiskThreshold { return 1.0 }
        let span = 1.0 - C.mlHypoRiskThreshold
        if span <= 0.0 { return C.mlHypoRiskFloor }
        let knob = max(hypoCautionKnob, 1.0)
        let reduction = min(max((risk - C.mlHypoRiskThreshold) / span * knob, 0.0), 1.0)
        let floor = C.mlHypoRiskFloor / knob
        return max(floor, 1.0 - reduction)
    }

    public static func postExerciseRecoveryModifier(_ inPostExerciseWindow: Bool) -> Double {
        inPostExerciseWindow ? AggressionBudgetConstants.postExerciseRecoveryScale : 1.0
    }
}
