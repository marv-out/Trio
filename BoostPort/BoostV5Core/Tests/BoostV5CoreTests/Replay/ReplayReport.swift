import Foundation

/// Accumulates per-row numeric comparisons and prints a divergence report. A "match" is within
/// `tolerance` of the recorded value (AndroidAPS rounds ISF→0.1, delta-accel→0.01, TDD→0.1, so the
/// tolerance absorbs rounding while still catching real formula drift).
struct ReplayReport {
    let name: String
    let tolerance: Double
    /// Optional relative tolerance (fraction of |expected|). A row matches if it is within the
    /// absolute OR the relative tolerance — needed where the console rounds inputs to 1 dp and the
    /// derived value is large (ISF) or sensitive to near-zero denominators.
    let relTolerance: Double
    private(set) var checked = 0
    private(set) var matched = 0
    private(set) var worstErr = 0.0
    private var sumErr = 0.0
    private var worstSamples: [(err: Double, expected: Double, got: Double, ctx: String)] = []

    init(_ name: String, tolerance: Double, relTolerance: Double = 0) {
        self.name = name
        self.tolerance = tolerance
        self.relTolerance = relTolerance
    }

    mutating func record(expected: Double, got: Double, ctx: @autoclosure () -> String = "") {
        checked += 1
        let err = abs(got - expected)
        sumErr += err
        let ok = err <= tolerance || (relTolerance > 0 && err <= relTolerance * abs(expected))
        if ok { matched += 1 }
        if err > worstErr { worstErr = err }
        if !ok {
            worstSamples.append((err, expected, got, ctx()))
            if worstSamples.count > 200 { // keep memory bounded; trim to top-20 occasionally
                worstSamples.sort { $0.err > $1.err }
                worstSamples.removeLast(worstSamples.count - 20)
            }
        }
    }

    var matchFraction: Double { checked == 0 ? 1.0 : Double(matched) / Double(checked) }
    var meanErr: Double { checked == 0 ? 0.0 : sumErr / Double(checked) }
    var failures: Int { checked - matched }

    func printSummary() {
        print("── Replay: \(name) ───────────────────────────────")
        let relStr = relTolerance > 0 ? String(format: " (or %.1f%%)", relTolerance * 100) : ""
        print(String(
            format: "   checked=%d  matched=%d (%.3f%%)  tol=±%g%@  meanErr=%.4f  worstErr=%.4f",
            checked,
            matched,
            matchFraction * 100,
            tolerance,
            relStr,
            meanErr,
            worstErr
        ))
        if failures > 0 {
            var top = worstSamples
            top.sort { $0.err > $1.err }
            print("   top divergences (expected vs got, err):")
            for s in top.prefix(10) {
                print(String(format: "     exp=%.3f got=%.3f err=%.3f  %@", s.expected, s.got, s.err, s.ctx))
            }
        }
    }
}
