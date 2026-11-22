@testable import BoostV5Core
import XCTest

final class MealSignalScoreTests: XCTestCase {
    typealias M = MealSignalScoreEngine

    func testScoreInRange() {
        let r = M.mealSignalScore(
            delta: 10,
            deltaAccl: 15,
            mlMealLikely: 0.5,
            recentLowBg: 100,
            hour: 13,
            exerciseActive: false,
            cumulativeRise30min: 40
        )
        XCTAssertGreaterThanOrEqual(r.score, 0.0)
        XCTAssertLessThanOrEqual(r.score, 1.0)
    }

    func testStrongMealHighScore() {
        let r = M.mealSignalScore(
            delta: 20,
            deltaAccl: 30,
            mlMealLikely: 1.0,
            recentLowBg: 120,
            hour: 13,
            exerciseActive: false,
            cumulativeRise30min: 60
        )
        XCTAssertGreaterThan(r.score, 0.55) // should clear CONFIRM_SCORE
    }

    func testFlatNoMealLowScore() {
        let r = M.mealSignalScore(
            delta: 0,
            deltaAccl: 0,
            mlMealLikely: 0.0,
            recentLowBg: 120,
            hour: 3,
            exerciseActive: false,
            cumulativeRise30min: 0
        )
        XCTAssertLessThan(r.score, 0.44) // below ENTER_OBSERVING
    }

    func testExerciseZeroesNotExercisingTerm() {
        let r = M.mealSignalScore(
            delta: 10,
            deltaAccl: 10,
            mlMealLikely: 0.3,
            recentLowBg: 110,
            hour: 13,
            exerciseActive: true,
            cumulativeRise30min: 20
        )
        XCTAssertEqual(r.components.notExercisingTerm, 0.0)
    }

    func testRecentLowFloorIsPointFour() {
        let r = M.mealSignalScore(
            delta: 5,
            deltaAccl: 5,
            mlMealLikely: 0.2,
            recentLowBg: 60,
            hour: 13,
            exerciseActive: false,
            cumulativeRise30min: 10
        )
        XCTAssertEqual(r.components.notRecentlyLowTerm, 0.4, accuracy: 1E-9)
    }

    func testMlRenormalizeWhenNullStreak() {
        let r = M.mealSignalScore(
            delta: 10,
            deltaAccl: 10,
            mlMealLikely: nil,
            recentLowBg: 110,
            hour: 13,
            exerciseActive: false,
            cumulativeRise30min: 20,
            mlMealLikelyNullStreak: 3
        )
        XCTAssertTrue(r.mlWeightsRenormalized)
    }

    func testMealTimeOfDayPeaksAtMealHours() {
        XCTAssertEqual(M.mealTimeOfDayBump(13), 1.0, accuracy: 1E-9) // exact centre
        XCTAssertLessThan(M.mealTimeOfDayBump(3), 0.05) // middle of night
    }

    // action multiplier
    func testActionMultipliers() {
        XCTAssertEqual(MealActionMultiplier.value(for: .idle), 1.0)
        XCTAssertEqual(MealActionMultiplier.value(for: .observing), 0.3)
        XCTAssertEqual(MealActionMultiplier.value(for: .confirmed), 1.8)
        XCTAssertEqual(MealActionMultiplier.value(for: .committed), 1.0)
        XCTAssertEqual(MealActionMultiplier.value(for: .recovering), 0.4)
    }

    func testAggressionKnobScalesConfirmedOnly() {
        XCTAssertEqual(MealActionMultiplier.value(for: .confirmed, aggressionUserKnob: 1.3), 1.8 * 1.3, accuracy: 1E-9)
        XCTAssertEqual(MealActionMultiplier.value(for: .observing, aggressionUserKnob: 1.3), 0.3, accuracy: 1E-9)
    }
}
