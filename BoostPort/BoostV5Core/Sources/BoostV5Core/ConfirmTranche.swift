import Foundation

/// Splits the confirm commitment in two: part now, the rest ten minutes later if the rise continues.
///
/// The confirm shot is otherwise the same size whether the excursion turns out to be 20 mg/dL or
/// 100. Measured over 140 episodes the median delivered at the confirming cycle is 1.45 U for
/// excursions under 30 mg/dL and 1.45 U for those over 75, and the confirm cycle carries 61.7% of
/// the insulin delivered in the following ninety minutes. The only part of the response that scales
/// with what actually happens is the committed holds, and they contribute a median of 0.00 U on the
/// episodes that go nowhere.
///
/// It cannot be sized correctly at the moment it fires. Separating the episodes that reach 75 mg/dL
/// from those that stay under 30, the trace gives 0.730 at the confirming cycle and 0.893 ten
/// minutes later, a paired gain of +0.162 [+0.066, +0.264]. The gain is front-loaded, so one or two
/// cycles are worth more than everything from twenty to forty-five minutes combined. The design
/// therefore does not predict better; it commits less until it knows more, and the knowing arrives
/// quickly.
///
/// The release rule is a logistic on five quantities the loop already holds, derived over 764
/// confirm episodes from eleven participants with participants held out as folds, so no score came
/// from a rule that had seen that person. It reaches 0.882 [0.849, 0.911] across the population and
/// 0.798 to 0.934 per participant, with no failure case.
///
/// Only the threshold is personal. Best values run 0.30 to 0.65 with a median of 0.48, and correlate
/// only -0.32 with a participant's own share of large excursions, so it cannot be inferred. Raising
/// it withholds more, which is a tightening, so the existing raise-guard direction already points
/// the right way.
///
/// This can only deliver less than the engine would without it, never more. Over an episode the
/// immediate part plus any release is at most the confirm shot the engine sized, and a withheld
/// remainder that is never released is insulin not given; the committed cycles that follow are
/// unaffected. Its failure mode is delayed insulin on a real meal rather than extra insulin. On the
/// cycle itself the release is held to the bounds the rest of the V6 dose meets, through
/// `onCycleBounded` (AAPS a33752c9aa).
public final class ConfirmTranche {
    /// Fitted over eleven participants, held out by participant.
    public enum Coefficients {
        public static let intercept = 2.48631
        public static let bgAtConfirm = -0.014480
        public static let riseSince = -0.003822
        public static let maxRiseSince = 0.138821
        public static let slopeNow = 0.072499
        public static let bgNow = -0.018302
    }

    /// Half a cycle of slack on the hold boundary. Cycles do not land on it: a confirm at 14:52:11
    /// was followed by a cycle at 15:02:10, which is 9.991 minutes, so an exact comparison deferred
    /// the decision by a whole cycle. With five-minute cycles that misses roughly half the time,
    /// which is the normal behaviour of the check rather than a rare edge case.
    public static let holdSlackMin = 2.5

    public struct Pending: Equatable, Sendable {
        public var heldU: Double
        public var bgAtConfirm: Double
        public var confirmMs: Double
        public var maxBgSince: Double
    }

    /// Settable rather than fixed at construction, so changing the preference takes effect on the
    /// next cycle rather than at the next restart.
    public var immediateFraction: Double
    public var releaseThreshold: Double
    private let holdMinutes: Double
    private let expiryMinutes: Double

    private var pending: Pending?
    private var lastBg: Double?

    public init(
        immediateFraction: Double = 0.5,
        releaseThreshold: Double = 0.48,
        holdMinutes: Double = 10,
        expiryMinutes: Double = 30
    ) {
        precondition(holdMinutes > 0 && expiryMinutes > holdMinutes, "hold window must be positive and ordered")
        precondition(min(immediateFraction, releaseThreshold) >= 0, "fraction and threshold must be non-negative")
        self.immediateFraction = immediateFraction
        self.releaseThreshold = releaseThreshold
        self.holdMinutes = holdMinutes
        self.expiryMinutes = expiryMinutes
    }

    /// What is currently held back, for logging. Zero when nothing is pending.
    public var heldU: Double { pending?.heldU ?? 0 }

    /// Called on a confirming cycle. Returns what to deliver now; the rest is held. A confirm
    /// arriving while something is already pending replaces it, since the older hold belongs to a
    /// rise the engine has evidently stopped tracking.
    public func onConfirm(nowMs: Double, bg: Double, sizedDose: Double) -> Double {
        guard sizedDose > 0, bg.isFinite else { return sizedDose }
        let f = min(max(immediateFraction, 0), 1)
        let now = sizedDose * f
        let held = max(0, sizedDose - now)
        pending = held > 0 ? Pending(heldU: held, bgAtConfirm: bg, confirmMs: nowMs, maxBgSince: bg) : nil
        lastBg = bg
        return now
    }

    /// Called on every non-confirming cycle. Returns the remainder if the rule releases it, or zero.
    ///
    /// The hold is cleared once its window has passed, so a remainder is either released on its
    /// cycle or not at all. Carrying it further would reintroduce the thing being removed, a
    /// commitment made on evidence that has since gone stale.
    public func onCycle(nowMs: Double, bg: Double?) -> Double {
        guard var p = pending else { return 0 }
        guard let bg, bg.isFinite else { return 0 }
        p.maxBgSince = max(p.maxBgSince, bg)
        pending = p
        let prev = lastBg
        lastBg = bg
        let mins = (nowMs - p.confirmMs) / 60000.0
        if mins < holdMinutes - Self.holdSlackMin { return 0 }
        if mins > expiryMinutes {
            pending = nil
            return 0
        }
        let slope = prev.map { bg - $0 } ?? 0
        let probability = Self.sigmoid(
            Coefficients.intercept
                + Coefficients.bgAtConfirm * p.bgAtConfirm
                + Coefficients.riseSince * (bg - p.bgAtConfirm)
                + Coefficients.maxRiseSince * (p.maxBgSince - p.bgAtConfirm)
                + Coefficients.slopeNow * slope
                + Coefficients.bgNow * bg
        )
        pending = nil
        return probability > releaseThreshold ? p.heldU : 0
    }

    /// The probability the rule would produce right now, for logging without acting.
    public func probeProbability(bg: Double?) -> Double? {
        guard let p = pending, let bg, bg.isFinite else { return nil }
        let slope = lastBg.map { bg - $0 } ?? 0
        return Self.sigmoid(
            Coefficients.intercept
                + Coefficients.bgAtConfirm * p.bgAtConfirm
                + Coefficients.riseSince * (bg - p.bgAtConfirm)
                + Coefficients.maxRiseSince * (max(p.maxBgSince, bg) - p.bgAtConfirm)
                + Coefficients.slopeNow * slope
                + Coefficients.bgNow * bg
        )
    }

    /// The bounds that apply to a release on this cycle, supplied from outside the controller (AAPS
    /// a33752c9aa, audit item 1). The release rule reads glucose shape only, which is why these sit
    /// outside it.
    public struct ReleaseBounds: Equatable, Sendable {
        /// V6's state is COMMITTED this cycle. A CONFIRMED cycle replaces the hold via `onConfirm`.
        public var inMealState: Bool
        /// A V6 phase-3 hard gate zeroed the dose this cycle.
        public var hardGateFired: Bool
        /// Inside the post-rescue window (45-minute low below the shared threshold).
        public var postRescueWindow: Bool
        /// The most the release may add this cycle; see `releaseCeiling`.
        public var ceilingU: Double

        public init(inMealState: Bool, hardGateFired: Bool, postRescueWindow: Bool, ceilingU: Double) {
            self.inMealState = inMealState
            self.hardGateFired = hardGateFired
            self.postRescueWindow = postRescueWindow
            self.ceilingU = ceilingU
        }
    }

    /// `onCycle` under `bounds` (AAPS a33752c9aa, audit item 1). Returns the units to add and a short
    /// note for the reason line, empty when nothing was bounded.
    ///
    /// The hold is dropped, not deferred, when the state has left COMMITTED, a hard gate fired or the
    /// post-rescue window is open. Each is the engine deciding against more insulin, and a hold
    /// carried past it would be released on evidence that predates it. In the AAPS field data a
    /// release of 1.675 U landed in RECOVERING with V6's own dose at 0 and eventualBG 65. A release
    /// the rule grants is clamped to the ceiling.
    public func onCycleBounded(nowMs: Double, bg: Double?, bounds: ReleaseBounds) -> (units: Double, note: String) {
        guard pending != nil else { return (0, "") }
        let dropReason: String? = !bounds.inMealState ? "state"
            : bounds.hardGateFired ? "hard-gate"
            : bounds.postRescueWindow ? "post-rescue"
            : nil
        if let dropReason {
            let held = heldU
            reset()
            return (0, "dropped:\(dropReason),\(Self.roundMilli(held))")
        }
        let granted = onCycle(nowMs: nowMs, bg: bg)
        if granted <= 0 { return (0, "") }
        let ceiling = max(0, bounds.ceilingU)
        if granted > ceiling {
            return (ceiling, "clamped:\(Self.roundMilli(granted))->\(Self.roundMilli(ceiling))")
        }
        return (granted, "")
    }

    /// The most a release may add on this cycle (AAPS a33752c9aa, audit item 1): what is left of the
    /// maxIOB headroom and of the CONFIRMED per-cycle cap after the cycle's own dose. Both bounds are
    /// what the confirm shot itself was held to, so the held remainder can never take a cycle above a
    /// dose the engine would have been allowed to give in one go. Never negative.
    public static func releaseCeiling(cycleDoseU: Double, maxIobU: Double, iobU: Double, confirmedCapU: Double) -> Double {
        max(0, min(maxIobU - iobU - cycleDoseU, confirmedCapU - cycleDoseU))
    }

    private static func roundMilli(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// Drops any hold. Used when the engine leaves a meal state entirely.
    public func reset() {
        pending = nil
        lastBg = nil
    }

    private static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-z)) }
}
