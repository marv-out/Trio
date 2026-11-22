import Foundation

/// Pure-Swift inference for the Boost LightGBM models (hypo risk + meal likelihood),
/// a faithful port of AAPS `BoostRiskModel.kt`. The model is a JSON export of N trees
/// (depth 4); inference = sum of per-tree leaf values, then a sigmoid. No CoreML, no
/// native deps — just tree traversal. <5ms for 50 trees, matching the Kotlin.
///
/// Both models share the same 8 features, in this order:
///   0 cgm_mgdl, 1 iob_iob, 2 iob_basaliob, 3 bg_above_target,
///   4 direction_num, 5 hour, 6 iob_activity, 7 sug_insulinReq
public struct BoostTreeModel: Sendable {
    /// A decision-tree node: either a leaf (value) or an internal split (feature ≤ threshold).
    public indirect enum Node: Sendable {
        case leaf(Double)
        case split(feature: Int, threshold: Double, left: Node, right: Node)
    }

    public let featureNames: [String]
    public let trees: [Node]

    public init(featureNames: [String], trees: [Node]) {
        self.featureNames = featureNames
        self.trees = trees
    }

    /// Predict the model probability in [0, 1] for the given feature vector.
    /// Mirrors Kotlin: rawScore = Σ walkTree(tree); return 1/(1+e^-rawScore).
    public func predict(_ features: [Double]) -> Double {
        var raw = 0.0
        for tree in trees { raw += Self.walk(tree, features) }
        return 1.0 / (1.0 + exp(-raw))
    }

    static func walk(_ node: Node, _ features: [Double]) -> Double {
        switch node {
        case let .leaf(value):
            return value
        case let .split(feature, threshold, left, right):
            guard feature >= 0, feature < features.count else { return 0.0 }
            return features[feature] <= threshold ? walk(left, features) : walk(right, features)
        }
    }

    // MARK: - JSON loading

    /// Decode a model from the AAPS JSON export format:
    /// { "feature_names": [...], "trees": [ <node> ... ] }
    /// where a node is `{"leaf": Double}` or `{"feature":Int,"threshold":Double,"left":{},"right":{}}`.
    public static func from(jsonData data: Data) throws -> BoostTreeModel {
        let root = try JSONDecoder().decode(ModelDTO.self, from: data)
        return BoostTreeModel(featureNames: root.feature_names, trees: root.trees.map(\.node))
    }

    private struct ModelDTO: Decodable {
        let feature_names: [String]
        let trees: [NodeDTO]
    }

    /// Recursive node decoder: presence of `leaf` ⇒ leaf, else an internal split.
    private struct NodeDTO: Decodable {
        let node: Node

        private enum CodingKeys: String, CodingKey {
            case leaf
            case feature
            case threshold
            case left
            case right
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let leaf = try c.decodeIfPresent(Double.self, forKey: .leaf) {
                node = .leaf(leaf)
            } else {
                let feature = try c.decode(Int.self, forKey: .feature)
                let threshold = try c.decode(Double.self, forKey: .threshold)
                let left = try c.decode(NodeDTO.self, forKey: .left)
                let right = try c.decode(NodeDTO.self, forKey: .right)
                node = .split(feature: feature, threshold: threshold, left: left.node, right: right.node)
            }
        }
    }
}
