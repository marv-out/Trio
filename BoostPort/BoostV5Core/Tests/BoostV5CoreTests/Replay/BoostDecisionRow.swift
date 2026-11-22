import Foundation
import XCTest

/// One exported `boost_decisions` cycle (NDJSON). Real AndroidAPS Boost v4.1.5 output for the
/// branch maintainer's own pump, used as a golden master for the Swift port. All fields are
/// optional — the export carries raw columns and many are null on any given cycle; the
/// authoritative numbers for the DynISF replay live in `consoleError`, parsed by `ConsoleFields`.
struct BoostDecisionRow: Decodable {
    let user_id: String?
    let ts_utc: String?
    let ts_epoch: Double?
    let variant: String?
    let cgm_mgdl: Double?

    // Engine-replay context (structured columns; may be null on any cycle).
    let iob_iob: Double?
    let sug_eventualbg: Double?
    let sug_current_target: Double?
    let sug_insulinreq: Double?
    let reason_minguardbg: Double?

    // Structured outputs (units vary by variant — prefer the console-parsed values for asserts).
    let tdd: Double?
    let tdd_blended: Double?
    let tdd_adj_factor: Double?
    let tdd_ratio: Double?
    let delta_acceleration: Double?
    let sens_normal_target: Double?
    let variable_sens: Double?
    let dynamic_isf: Double?
    let prediction_isf: Double?

    let boost_tier: String?
    let boost_tier_top: String?
    let boost_active_top: Bool?
    let boost_active_console: Bool?

    let console_error: String?

    /// Flatten to a `ReplayCycle`, parsing the console and dropping the large raw string. Done at
    /// load time so the in-memory dataset stays small (the console dump is ~5 KB/row × 266k rows).
    func toCycle() -> ReplayCycle? {
        guard let userId = user_id, let bg = cgm_mgdl else { return nil }
        return ReplayCycle(
            userId: userId, tsEpoch: ts_epoch, variant: variant, cgmMgdl: bg,
            iobIob: iob_iob, sugEventualbg: sug_eventualbg, sugCurrentTarget: sug_current_target,
            sugInsulinreq: sug_insulinreq, reasonMinguardbg: reason_minguardbg,
            console: ConsoleFields(console_error)
        )
    }
}

/// A flattened, memory-light cycle: the columns the replay needs plus the parsed `ConsoleFields`
/// (which retains only numbers, not the raw console text).
struct ReplayCycle {
    let userId: String
    let tsEpoch: Double?
    let variant: String?
    let cgmMgdl: Double
    let iobIob: Double?
    let sugEventualbg: Double?
    let sugCurrentTarget: Double?
    let sugInsulinreq: Double?
    let reasonMinguardbg: Double?
    let console: ConsoleFields?
}

/// The numbers we need from the per-cycle console dump, parsed and normalised to mg/dL.
///
/// The console is internally consistent in mg/dL for ISF/BG values and prints both the DynISF
/// inputs and the intermediate/final outputs, e.g.:
///
///   Boost v4.1.5 (Kotlin) | Profile: 140%
///   BG: 121.0 mg/dl | Delta: -0.3 | Short avg: 0.8 | Long avg: 2.8
///   Delta acceleration: -143.42%
///   min=84.6 max=84.6 target=84.6 (TT: false)
///   Profile sens: 90.5 | Variable sens: 78.0 | sensNormalTarget: 89.3
///   DynISF: normalTarget=99.0 | velocity=1.0 | bgCap=210.6 | bgCapped=121.0
///   TDD data: 7D=28.0 | 1D=22.8 | 24H=22.4 | 4H=5.4 | 8-4H=2.4
///   Blended TDD=26.0
///   Final TDD=18.2 (adj factor 70%)
///   TDD ISF at target: 89.3 mg/dl/U (profile was 126.7)
///   Circadian ISF: false
struct ConsoleFields {
    // DynISF line
    let normalTarget: Double // mg/dL (mmol values <25 are scaled ×18)
    let velocity: Double // fraction (console prints 1.0 == 100%)
    let bgCap: Double // mg/dL
    let bgCapped: Double // mg/dL

    // ISF line (expected outputs)
    let profileSens: Double?
    let variableSens: Double? // mg/dL — the recorded DynISF output
    let sensNormalTarget: Double? // mg/dL — ISF at normal target (already ×globalScale)

    // TDD breakdown
    let tdd7d: Double?
    let tdd1d: Double?
    let tdd4h: Double?
    let tdd8to4h: Double?
    let blendedTdd: Double?
    let finalTdd: Double?
    let adjFactorPct: Double? // e.g. 70
    let tddIsfAtTarget: Double? // "TDD ISF at target: X" — pure isfTargetV1 × globalScale,
    // BEFORE the TT / autosens sensitivity-ratio division

    // Glucose line
    let delta: Double?
    let shortAvgDelta: Double?
    let longAvgDelta: Double?
    let deltaAcceleration: Double? // percent

    // Context
    let profilePercent: Double? // e.g. 140 → globalScale = 100/140
    let ttSet: Bool? // "(TT: true/false)"
    let circadianEnabled: Bool?

    /// globalScale = 100 / profilePercent (AAPS profile-% inverse ISF scaling). 1.0 if unknown.
    var globalScale: Double { (profilePercent.map { $0 > 0 ? 100.0 / $0 : 1.0 }) ?? 1.0 }

    init?(_ raw: String?) {
        guard let raw, raw.contains("normalTarget=") else { return nil }
        // The export stores console_error with literal "\n" escapes preserved as backslash-n by
        // some pipelines; JSONDecoder already turns JSON \n into real newlines, so handle both.
        let text = raw.replacingOccurrences(of: "\\n", with: "\n")

        func d(_ pattern: String) -> Double? { Self.firstDouble(in: text, pattern: pattern) }

        // DynISF line is mandatory for a usable row.
        guard
            let nt = d(#"normalTarget=([-0-9]+(?:[.,][0-9]+)?)"#),
            let vel = d(#"velocity=([-0-9]+(?:[.,][0-9]+)?)"#),
            let cap = d(#"bgCap=([-0-9]+(?:[.,][0-9]+)?)"#),
            let capped = d(#"bgCapped=([-0-9]+(?:[.,][0-9]+)?)"#)
        else { return nil }

        // mmol→mg/dL: targets/caps under 25 are clearly mmol.
        normalTarget = nt < 25 ? nt * 18.0 : nt
        bgCap = cap < 25 ? cap * 18.0 : cap
        bgCapped = capped < 25 ? capped * 18.0 : capped
        velocity = vel

        profileSens = d(#"Profile sens: ([-0-9]+(?:[.,][0-9]+)?)"#)
        variableSens = d(#"Variable sens: ([-0-9]+(?:[.,][0-9]+)?)"#)
        sensNormalTarget = d(#"sensNormalTarget: ([-0-9]+(?:[.,][0-9]+)?)"#)

        tdd7d = d(#"7D=([-0-9]+(?:[.,][0-9]+)?)"#)
        tdd1d = d(#"1D=([-0-9]+(?:[.,][0-9]+)?)"#)
        // Anchor "4H=" so it doesn't match inside "24H=" (preceded by a digit) or "8-4H=" (a dash).
        tdd4h = d(#"(?<![0-9-])4H=([-0-9]+(?:[.,][0-9]+)?)"#)
        tdd8to4h = d(#"8-4H=([-0-9]+(?:[.,][0-9]+)?)"#)
        blendedTdd = d(#"Blended TDD=([-0-9]+(?:[.,][0-9]+)?)"#)
        finalTdd = d(#"Final TDD=([-0-9]+(?:[.,][0-9]+)?)"#)
        adjFactorPct = d(#"adj factor ([-0-9]+(?:[.,][0-9]+)?)%"#)
        tddIsfAtTarget = d(#"TDD ISF at target: ([-0-9]+(?:[.,][0-9]+)?)"#)

        delta = d(#"\bDelta: ([-0-9]+(?:[.,][0-9]+)?)"#)
        shortAvgDelta = d(#"Short avg: ([-0-9]+(?:[.,][0-9]+)?)"#)
        longAvgDelta = d(#"Long avg: ([-0-9]+(?:[.,][0-9]+)?)"#)
        deltaAcceleration = d(#"Delta acceleration: ([-0-9]+(?:[.,][0-9]+)?)"#)

        profilePercent = d(#"Profile: ([-0-9]+(?:[.,][0-9]+)?)%"#)
        if let m = Self.firstMatch(in: text, pattern: #"\(TT: (true|false)\)"#) {
            ttSet = (m == "true")
        } else { ttSet = nil }
        if let m = Self.firstMatch(in: text, pattern: #"Circadian ISF: (true|false|on|off)"#) {
            circadianEnabled = (m == "true" || m == "on")
        } else { circadianEnabled = nil }
    }

    // MARK: - regex helpers

    // Compiled-regex cache — parsing 266k rows × ~18 patterns means we must not recompile per call.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(re, forKey: pattern as NSString)
        return re
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        // Some users' consoles use European comma decimals (e.g. "normalTarget=5,5"); normalise.
        firstMatch(in: text, pattern: pattern).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }
}

/// Loads the replay fixture. Resolution order:
///   1. `BOOST_REPLAY_FIXTURE` env var (absolute path)
///   2. the default `Tests/BoostV5CoreTests/Fixtures/boost_decisions.ndjson` (relative to this file)
///
/// Throws `XCTSkip` when the fixture is absent so the suite is a no-op without it (it is gitignored;
/// generate it with `BoostPort/sim/export_boost_decisions.sh`). Honours `BOOST_REPLAY_LIMIT` to cap
/// the number of rows for quick local runs.
enum ReplayFixture {
    /// All cycles across all users, flattened and parsed (raw console discarded).
    static func load(file: StaticString = #filePath) throws -> [ReplayCycle] {
        let env = ProcessInfo.processInfo.environment

        let url: URL
        if let path = env["BOOST_REPLAY_FIXTURE"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = defaultFixtureURL(relativeTo: file)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("""
            Replay fixture not found at \(url.path).
            Generate it with:  bash BoostPort/sim/export_boost_decisions.sh
            (or set BOOST_REPLAY_FIXTURE to an NDJSON export of boost_decisions).
            """)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var cycles: [ReplayCycle] = []
        cycles.reserveCapacity(300_000)

        let limit = env["BOOST_REPLAY_LIMIT"].flatMap { Int($0) }

        // NDJSON: one JSON object per line. Decode transiently and flatten to a memory-light cycle so
        // the 1+ GB of raw console text isn't retained.
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var lineStart = buf.startIndex
            let newline = UInt8(ascii: "\n")
            for i in buf.indices {
                if buf[i] == newline {
                    if i > lineStart {
                        let slice = Data(
                            bytes: buf.baseAddress!.advanced(by: lineStart),
                            count: i - lineStart
                        )
                        if let row = try? decoder.decode(BoostDecisionRow.self, from: slice),
                           let cycle = row.toCycle()
                        {
                            cycles.append(cycle)
                        }
                    }
                    lineStart = i + 1
                    if let limit, cycles.count >= limit { break }
                }
            }
        }

        if cycles.isEmpty {
            throw XCTSkip("Replay fixture at \(url.path) decoded to 0 rows.")
        }
        return cycles
    }

    /// Cycles grouped by user, each group sorted chronologically (stable for state replay).
    static func loadByUser(file: StaticString = #filePath) throws -> [(user: String, cycles: [ReplayCycle])] {
        let all = try load(file: file)
        let grouped = Dictionary(grouping: all, by: { $0.userId })
        return grouped
            .map { (user: $0.key, cycles: $0.value.sorted { ($0.tsEpoch ?? 0) < ($1.tsEpoch ?? 0) }) }
            .sorted { $0.user < $1.user }
    }

    /// Path to the V5-shadow fixture (deviceStatus boostV5_* cycles). Honours `BOOST_V5SHADOW_FIXTURE`.
    static func v5ShadowURL(file: StaticString = #filePath) -> URL {
        if let p = ProcessInfo.processInfo.environment["BOOST_V5SHADOW_FIXTURE"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // Replay/
            .deletingLastPathComponent() // BoostV5CoreTests/
            .appendingPathComponent("Fixtures/v5_shadow.ndjson")
    }

    private static func defaultFixtureURL(relativeTo file: StaticString) -> URL {
        // .../Tests/BoostV5CoreTests/Replay/BoostDecisionRow.swift
        //  -> .../Tests/BoostV5CoreTests/Fixtures/boost_decisions.ndjson
        let thisFile = URL(fileURLWithPath: "\(file)")
        return thisFile
            .deletingLastPathComponent() // Replay/
            .deletingLastPathComponent() // BoostV5CoreTests/
            .appendingPathComponent("Fixtures/boost_decisions.ndjson")
    }
}
