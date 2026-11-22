import Foundation

/// BoostMlFeatureBuilder — builds the 53-feature vector the v12 hypo-risk model expects from
/// on-cycle algorithm state, and maintains a 6-cycle ring buffer for the windowed lookback
/// features. Faithful 1:1 port of AAPS `BoostMlFeatureBuilder` (Boost-V6-mealtime-alpha).
///
/// v12 feature schema (order matters — must match assets/boost/hypo_risk_model.json):
///   0..7   v9 base:     cgm_mgdl, iob_iob, iob_basaliob, bg_above_target, direction_num,
///                       hour, iob_activity, sug_insulinReq
///   8..16  v10 extended: sug_COB, sug_eventualBG, sug_expectedDelta, sug_minDelta, sug_TDD,
///                       iob_bolusiob, iob_netbasalinsulin, recent_smb_units_60m,
///                       time_since_last_smb_min
///   17..52 v12 windowed lookback (lag0..lag5) for: cgm_mgdl, iob_iob, iob_activity,
///                       sug_eventualBG, recent_smb_units_60m, sug_minDelta
///
/// On cold start (buffer shorter than the requested lag) the lag value defaults to the current
/// cycle's value — matching AAPS's `ring.lagged(lag) ?: current`.
public enum BoostMlFeatureBuilder {
    public static let lookback = 6

    /// The span the lookback window claims to represent, plus one cycle of slack so an ordinary
    /// late reading does not discard usable history. Six cycles on the five-minute grid is thirty
    /// minutes, so anything older than thirty-five is not the preceding six cycles and must not be
    /// presented to the model as though it were. (AAPS `STALE_AFTER_MS`, 2026-08-14.)
    public static let staleAfterMs: Double = 35 * 60 * 1000

    /// Spacing the lookback window assumes between snapshots. The lag COUNT is part of the model:
    /// six lags were trained on five-minute spacing, so at a one-minute cadence the same six lags
    /// would span six minutes rather than thirty and the model would extrapolate from inputs unlike
    /// anything it saw in training. This is the one count-based window in the one-minute work that
    /// must not simply be retimed, so the input is resampled instead. (AAPS 2026-08-01.)
    public static let lagSpacingMs: Double = 5 * 60 * 1000
    private static let lagSpacingToleranceMs: Double = 30 * 1000
    public static let lookbackFeatures = [
        "cgm_mgdl", "iob_iob", "iob_activity",
        "sug_eventualBG", "recent_smb_units_60m", "sug_minDelta"
    ]

    /// One ring-buffer row — current-cycle values for the 6 lookback features.
    public struct CycleSnapshot: Codable, Equatable, Sendable {
        public var ts: Double
        public var cgmMgdl: Double
        public var iobIob: Double
        public var iobActivity: Double
        public var sugEventualBG: Double
        public var recentSmbUnits60m: Double
        public var sugMinDelta: Double

        public init(
            ts: Double, cgmMgdl: Double, iobIob: Double, iobActivity: Double,
            sugEventualBG: Double, recentSmbUnits60m: Double, sugMinDelta: Double
        ) {
            self.ts = ts
            self.cgmMgdl = cgmMgdl
            self.iobIob = iobIob
            self.iobActivity = iobActivity
            self.sugEventualBG = sugEventualBG
            self.recentSmbUnits60m = recentSmbUnits60m
            self.sugMinDelta = sugMinDelta
        }

        public func valueOf(_ name: String) -> Double {
            switch name {
            case "cgm_mgdl": return cgmMgdl
            case "iob_iob": return iobIob
            case "iob_activity": return iobActivity
            case "sug_eventualBG": return sugEventualBG
            case "recent_smb_units_60m": return recentSmbUnits60m
            case "sug_minDelta": return sugMinDelta
            default: return 0.0
            }
        }
    }

    public struct RingBuffer: Codable, Equatable, Sendable {
        public var snapshots: [CycleSnapshot]
        public init(snapshots: [CycleSnapshot] = []) { self.snapshots = snapshots }

        /// Append, then drop anything the window no longer covers, by age as well as by count.
        ///
        /// The buffer is persisted across process restarts and the decision series is interrupted
        /// often. Trimming by length alone leaves pre-gap snapshots in place, so a cycle arriving
        /// two hours after the last one was scored with lag features two hours old presented as the
        /// preceding five cycles. AAPS established this by replay rather than inspection: scoring a
        /// rebuilt feature vector with the exported model reproduces the published hypo risk on
        /// contiguous cycles to a median absolute error of 0.003 to 0.006, and on post-gap cycles
        /// the carried snapshots explained the published score better than either a cleared buffer
        /// or the true contiguous history, for all nine users. A third of scored cycles follow such
        /// a break, and between 100 and 160 mg/dL they crossed the 0.30 damper threshold on 8.6% of
        /// cycles against 3.9% for the rest. (AAPS 2026-08-14.)
        public mutating func push(_ s: CycleSnapshot) {
            // Admit a snapshot only once per lag interval, so the buffer holds five-minute steps
            // even when called every minute. Replace the newest when called again too soon, so the
            // freshest reading within the interval is the one kept.
            //
            // The slot keeps the timestamp that OPENED the interval rather than taking the
            // replacement's. This is a deliberate divergence from the Kotlin, which assigns the
            // whole snapshot and so moves the anchor forward on every replacement: the spacing is
            // then measured from the most recent replacement and never reaches the interval, so a
            // feed arriving every minute replaces one slot indefinitely and no second slot is ever
            // opened. Every lag then resolves to nil and the caller falls back to the current
            // cycle, which is the opposite of what the resampling exists to achieve. Anchoring on
            // the interval's opening timestamp makes a one-minute feed accumulate six slots five
            // minutes apart, which is the spacing the model was trained on.
            //
            // A five-minute feed is unaffected: each push opens its own slot, so no replacement
            // happens and the anchor question does not arise.
            if let last = snapshots.last,
               s.ts - last.ts < BoostMlFeatureBuilder.lagSpacingMs - BoostMlFeatureBuilder.lagSpacingToleranceMs
            {
                var replacement = s
                replacement.ts = last.ts
                snapshots[snapshots.count - 1] = replacement
                return
            }
            snapshots.append(s)
            let oldest = s.ts - BoostMlFeatureBuilder.staleAfterMs
            snapshots.removeAll { $0.ts < oldest }
            while snapshots.count > BoostMlFeatureBuilder.lookback { snapshots.removeFirst() }
        }

        /// Snapshot `lag` cycles ago (0 = most recent). nil if the buffer is too short.
        public func lagged(_ lag: Int) -> CycleSnapshot? {
            let idx = snapshots.count - 1 - lag
            return (idx >= 0 && idx < snapshots.count) ? snapshots[idx] : nil
        }
    }

    /// Serialize the ring buffer to a JSON string for persistence (mirrors AAPS serializeBuffer).
    public static func serialize(_ b: RingBuffer) -> String {
        guard let data = try? JSONEncoder().encode(b.snapshots),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Deserialize a persisted ring buffer; empty/corrupt → empty buffer (matches AAPS).
    public static func deserialize(_ raw: String) -> RingBuffer {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let snaps = try? JSONDecoder().decode([CycleSnapshot].self, from: data)
        else { return RingBuffer() }
        var b = RingBuffer()
        for s in snaps { b.push(s) }
        return b
    }

    /// Build the full feature vector ordered to match the model's declared `featureNames`.
    /// Static (non-windowed) features come from `staticValues`; `*_lagN` features come from
    /// the ring buffer (falling back to `current` when the buffer is too short).
    public static func build(
        featureNames: [String],
        current: CycleSnapshot,
        ring: RingBuffer,
        staticValues: [String: Double]
    ) -> [Double] {
        featureNames.map { name in
            if let lagMarker = name.range(of: "_lag") {
                let baseName = String(name[name.startIndex ..< lagMarker.lowerBound])
                let lag = Int(name[lagMarker.upperBound...]) ?? 0
                let snap = ring.lagged(lag) ?? current
                return snap.valueOf(baseName)
            }
            return staticValues[name] ?? 0.0
        }
    }
}
