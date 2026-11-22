import Foundation

/// HrSourceResolver — Boost HR source visibility (Swift port of the AAPS `HrSourceResolver.kt`,
/// 2026-06-28).
///
/// HR (unlike steps) is ALREADY a unified multi-source feed on iOS: an Apple Watch, a Garmin
/// (mirrored to Apple Health), and any other writer all land in HealthKit, and consumers read it
/// source-agnostically. A BPM is a BPM, so — unlike step counts — sources need no calibration or
/// single-source selection. What's missing is VISIBILITY: which device is feeding HR now, and whether
/// the feed has silently died. This resolver groups recent readings by source, reports per-source
/// freshness/recency for telemetry, and names the live "primary" — without changing any consumer.
public enum HrSourceResolver {
    public static let garmin = "garmin"
    public static let appleWatch = "appleWatch"
    /// Another HealthKit HR writer keyed by source/device tag.
    public static let hkPrefix = "hk:"

    /// A feed is "live" if its newest reading is within this window (seconds).
    public static let freshWindow: TimeInterval = 12 * 60

    public static func canonical(_ device: String) -> String {
        let d = device.trimmingCharacters(in: .whitespaces)
        let r = d.lowercased()
        if r.contains("garmin") { return garmin }
        if r.contains("watch") { return appleWatch }
        if d.hasPrefix(hkPrefix) { return d }
        if d.isEmpty { return hkPrefix + "unknown" }
        return hkPrefix + (d.split(separator: ".").last.map(String.init) ?? d)
    }

    /// Trust tier (lower = better): a realtime worn feed beats other HealthKit writers.
    public static func tier(_ canonicalSource: String) -> Int {
        if canonicalSource == appleWatch { return 0 }
        if canonicalSource == garmin { return 0 }
        if canonicalSource.hasPrefix(hkPrefix) { return 1 }
        return 2
    }

    /// Minimal view of an HR sample (decoupled from HealthKit for testability).
    public struct Reading: Equatable, Sendable {
        public var device: String
        public var timestamp: Date
        public init(device: String, timestamp: Date) {
            self.device = device
            self.timestamp = timestamp
        }
    }

    public struct SourceState: Equatable, Sendable {
        public var source: String
        public var count: Int
        public var age: TimeInterval
        public var fresh: Bool { age <= freshWindow }
    }

    public struct Resolution: Equatable, Sendable {
        /// The live HR source (highest-trust fresh); nil when nothing is fresh (feed died/absent).
        public var active: String?
        public var anyFresh: Bool
        /// Per-source diagnostics, best-trust first: "src(fresh,count,ageMin)".
        public var note: String
        public var states: [SourceState]
    }

    public static func resolve(_ readings: [Reading], now: Date) -> Resolution {
        if readings.isEmpty { return Resolution(active: nil, anyFresh: false, note: "none", states: []) }
        let grouped = Dictionary(grouping: readings) { canonical($0.device) }
        let states = grouped
            .map { src, rs -> SourceState in
                let newest = rs.map(\.timestamp).max() ?? now
                return SourceState(source: src, count: rs.count, age: now.timeIntervalSince(newest))
            }
            .sorted { ($0.source == $1.source) ? false : (tier($0.source), $0.age) < (tier($1.source), $1.age) }

        let active = states.filter(\.fresh)
            .min { (tier($0.source), $0.age) < (tier($1.source), $1.age) }

        let note = states
            .map { "\($0.source)(\($0.fresh ? "f" : "-"),\($0.count),\(Int($0.age / 60))m)" }
            .joined(separator: " ")

        return Resolution(active: active?.source, anyFresh: active != nil, note: note, states: states)
    }
}
