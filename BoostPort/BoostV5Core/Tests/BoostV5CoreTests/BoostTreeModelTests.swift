@testable import BoostV5Core
import XCTest

/// Verifies the pure-Swift LightGBM inference (port of AAPS BoostRiskModel): JSON decode of
/// the leaf/split node format, tree traversal (≤ threshold → left), and the sigmoid squash.
final class BoostTreeModelTests: XCTestCase {
    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }

    func testSingleLeafIsSigmoidOfLeaf() throws {
        let json = """
        { "feature_names": ["f0"], "trees": [ { "leaf": 0.0 } ] }
        """.data(using: .utf8)!
        let model = try BoostTreeModel.from(jsonData: json)
        XCTAssertEqual(model.predict([0]), 0.5, accuracy: 1E-9) // sigmoid(0)
    }

    func testSplitRoutesOnThreshold() throws {
        // feature 0 <= 100 ? leaf -1 : leaf +1
        let json = """
        { "feature_names": ["cgm_mgdl"], "trees": [
          { "feature": 0, "threshold": 100.0, "decision_type": "<=",
            "left": { "leaf": -1.0 }, "right": { "leaf": 1.0 } } ] }
        """.data(using: .utf8)!
        let model = try BoostTreeModel.from(jsonData: json)
        XCTAssertEqual(model.predict([50]), sigmoid(-1.0), accuracy: 1E-9) // ≤ → left
        XCTAssertEqual(model.predict([150]), sigmoid(1.0), accuracy: 1E-9) // > → right
        XCTAssertEqual(model.predict([100]), sigmoid(-1.0), accuracy: 1E-9) // boundary ≤ → left
    }

    func testMultipleTreesSumBeforeSigmoid() throws {
        let json = """
        { "feature_names": ["f0"], "trees": [ { "leaf": 0.5 }, { "leaf": 0.5 }, { "leaf": -1.0 } ] }
        """.data(using: .utf8)!
        let model = try BoostTreeModel.from(jsonData: json)
        XCTAssertEqual(model.predict([0]), 0.5, accuracy: 1E-9) // Σ = 0 → sigmoid(0)
        XCTAssertEqual(model.featureNames, ["f0"])
        XCTAssertEqual(model.trees.count, 3)
    }

    func testOutputAlwaysInUnitInterval() throws {
        let json = """
        { "feature_names": ["f0"], "trees": [ { "leaf": 100.0 }, { "leaf": -100.0 } ] }
        """.data(using: .utf8)!
        let big = try BoostTreeModel.from(jsonData: json)
        XCTAssertGreaterThanOrEqual(big.predict([0]), 0.0)
        XCTAssertLessThanOrEqual(big.predict([0]), 1.0)
    }
}
