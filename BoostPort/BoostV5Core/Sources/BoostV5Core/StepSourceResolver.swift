import Foundation

/// StepSourceResolver — Boost activity-load source abstraction (Swift port of the AAPS
/// `StepSourceResolver.kt`, 2026-06-28).
///
/// Picks ONE active step source per cycle from whatever the user actually has — an Apple
/// Watch, a Garmin (when the user mirrors Garmin → Apple Health), the iPhone pedometer, or
/// any other HealthKit writer — with NO user-facing knob (resolution is automatic). On iOS the
/// canonical store is HealthKit; a "source" is an `HKSource`/`HKDevice` (mapped to a canonical id
/// by the caller and normalised here).
///
/// Two SEPARATE concerns (so a device switch never drops the user into a warmup):
///   - SELECTION (here): which source owns TODAY's cumulative count — highest-trust fresh source.
///   - COVERAGE (the bridging layer in `ActivityLoadTracker`): the rolling baseline window is filled
///     from the active source's days where present, and BRIDGED with the previous source's historic
///     days (scaled by overlap calibration) where not — so changing devices keeps coverage.
///
/// Trust ranking (best first): a worn watch beats an aggregator beats the phone —
/// Apple Watch > Garmin > other HealthKit writer > iPhone. Active source = the highest-trust source
/// whose feed is fresh; if none is fresh, the highest-trust source with any recent data; else none.
public enum StepSourceResolver {
    public static let appleWatch = "appleWatch"
    public static let garmin = "garmin"
    public static let iphone = "iphone"
    /// Any other HealthKit writer (Fitbit bridge, Withings, …) → "hk:<shortname>".
    public static let hkPrefix = "hk:"

    /// Map a raw source id (a canonical tag already, an `HKDevice.model`, or an `HKSource`
    /// bundle identifier) to its canonical id.
    public static func canonical(_ raw: String) -> String {
        if raw == appleWatch || raw == iphone { return raw }
        if raw.hasPrefix(hkPrefix) { return raw }
        let r = raw.lowercased()
        if r.contains("garmin") { return garmin }
        if r.contains("watch") { return appleWatch }
        if r.contains("iphone") || r.contains("phone") { return iphone }
        return hkPrefix + (raw.split(separator: ".").last.map(String.init) ?? raw)
    }

    /// Trust tier (lower = better). Unknown → after iPhone.
    public static func tier(_ canonicalSource: String) -> Int {
        if canonicalSource == appleWatch { return 0 }
        if canonicalSource == garmin { return 1 }
        if canonicalSource.hasPrefix(hkPrefix) { return 2 }
        if canonicalSource == iphone { return 3 }
        return 4
    }

    /// One candidate source's current state.
    public struct SourceState: Equatable, Sendable {
        public var source: String
        public var fresh: Bool
        public var coverageDays: Int
        public var stepsToday: Int

        public init(source: String, fresh: Bool, coverageDays: Int, stepsToday: Int) {
            self.source = source
            self.fresh = fresh
            self.coverageDays = coverageDays
            self.stepsToday = stepsToday
        }
    }

    public struct Resolution: Equatable, Sendable {
        /// Source that owns today's cumulative count; nil only when no source has any data.
        public var active: String?
        public var stepsToday: Int
        public var activeFresh: Bool
        /// Per-source diagnostics, best-trust first: "src(fresh,covDays)".
        public var note: String

        public init(active: String?, stepsToday: Int, activeFresh: Bool, note: String) {
            self.active = active
            self.stepsToday = stepsToday
            self.activeFresh = activeFresh
            self.note = note
        }
    }

    /// Pick today's active source. `states` need not be pre-sorted; ids need not be canonical
    /// (canonicalised + sorted by trust here). Selection does NOT gate on history — coverage is the
    /// bridging layer's job. Empty input → active = nil.
    public static func resolve(_ states: [SourceState]) -> Resolution {
        let ranked = states
            .map { SourceState(
                source: canonical($0.source),
                fresh: $0.fresh,
                coverageDays: $0.coverageDays,
                stepsToday: $0.stepsToday
            ) }
            .sorted { tier($0.source) < tier($1.source) }

        let chosen = ranked.first { $0.fresh }
            ?? ranked.first { $0.coverageDays > 0 || $0.stepsToday > 0 }

        let note = ranked.isEmpty ? "none" : ranked
            .map { "\($0.source)(\($0.fresh ? "f" : "-"),\($0.coverageDays)d)" }
            .joined(separator: " ")

        return Resolution(
            active: chosen?.source,
            stepsToday: chosen?.stepsToday ?? 0,
            activeFresh: chosen?.fresh ?? false,
            note: chosen == nil ? "none[\(note)]" : note
        )
    }
}
