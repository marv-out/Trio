@testable import BoostV5Core
import XCTest

final class NightModeTests: XCTestCase {
    // Convenience: a simple non-wrapping window 01:00–05:00, offset 27 (AAPS default).
    private func config(
        enabled: Bool = true,
        start: Int = 60,
        end: Int = 300,
        bgOffset: Double = 27,
        disableWithCob: Bool = false,
        disableWithLowTt: Bool = false,
        autoBySleep: Bool = false
    ) -> NightModeConfig {
        NightModeConfig(
            enabled: enabled,
            startMinute: start,
            endMinute: end,
            bgOffsetMgdl: bgOffset,
            disableWithCob: disableWithCob,
            disableWithLowTt: disableWithLowTt,
            autoBySleep: autoBySleep
        )
    }

    private func inputs(
        now: Int = 120, // 02:00, inside default window
        bg: Double = 100,
        target: Double = 100,
        cob: Double = 0,
        tt: Double? = nil,
        sleepActive: Bool = false,
        sleepInActive: Bool = false,
        config: NightModeConfig
    ) -> NightModeInputs {
        NightModeInputs(
            nowMinuteOfDay: now,
            bg: bg,
            profileTargetMgdl: target,
            cob: cob,
            activeTempTargetMgdl: tt,
            sleepActive: sleepActive,
            sleepInActive: sleepInActive,
            config: config
        )
    }

    // MARK: Disabled

    func testInactiveWhenDisabled() {
        let r = NightMode.evaluate(inputs(config: config(enabled: false)))
        XCTAssertFalse(r.active)
        XCTAssertFalse(r.suppressSmb)
        XCTAssertEqual(r.targetMgdl, 100)
        XCTAssertEqual(r.reason, "disabled")
    }

    // MARK: Active inside window, bg below threshold

    func testActiveInsideWindowBgBelowThreshold() {
        // target 100, offset 27 -> threshold 127; bg 120 < 127.
        let r = NightMode.evaluate(inputs(bg: 120, target: 100, config: config()))
        XCTAssertTrue(r.active)
        XCTAssertTrue(r.suppressSmb)
        // Faithful port: target is NOT lowered.
        XCTAssertEqual(r.targetMgdl, 100)
        XCTAssertEqual(r.reason, "active")
    }

    // MARK: BG above (target + offset) -> inactive

    func testBgAboveThresholdInactive() {
        // threshold 127; bg 130 >= 127.
        let r = NightMode.evaluate(inputs(bg: 130, target: 100, config: config()))
        XCTAssertFalse(r.active)
        XCTAssertFalse(r.suppressSmb)
        XCTAssertEqual(r.reason, "bg-high")
    }

    func testBgExactlyAtThresholdInactive() {
        // strict `<`: bg == threshold is inactive.
        let r = NightMode.evaluate(inputs(bg: 127, target: 100, config: config()))
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.reason, "bg-high")
    }

    // MARK: Midnight-wrap window 22:00–07:00

    func testMidnightWrapWindowActiveAcrossMidnight() {
        let cfg = config(start: 22 * 60, end: 7 * 60) // 1320 -> 420
        // 23:30 (1410) is inside.
        XCTAssertTrue(NightMode.evaluate(inputs(now: 1410, bg: 100, config: cfg)).active)
        // 03:00 (180) is inside.
        XCTAssertTrue(NightMode.evaluate(inputs(now: 180, bg: 100, config: cfg)).active)
        // 12:00 (720) is outside.
        let mid = NightMode.evaluate(inputs(now: 720, bg: 100, config: cfg))
        XCTAssertFalse(mid.active)
        XCTAssertEqual(mid.reason, "outside-window")
        // 07:00 (420) is the exclusive end -> outside.
        XCTAssertFalse(NightMode.evaluate(inputs(now: 420, bg: 100, config: cfg)).active)
        // 22:00 (1320) is the inclusive start -> inside.
        XCTAssertTrue(NightMode.evaluate(inputs(now: 1320, bg: 100, config: cfg)).active)
    }

    // MARK: disableWithCob

    func testDisableWithCobCancelsWhenCobPositive() {
        let cfg = config(disableWithCob: true)
        let r = NightMode.evaluate(inputs(bg: 100, cob: 5, config: cfg))
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.reason, "cob")
        // With cob 0, still active.
        XCTAssertTrue(NightMode.evaluate(inputs(bg: 100, cob: 0, config: cfg)).active)
    }

    // MARK: disableWithLowTt

    func testDisableWithLowTtCancelsWhenTtBelowTarget() {
        let cfg = config(disableWithLowTt: true)
        // TT 80 < target 100 -> cancel.
        let r = NightMode.evaluate(inputs(bg: 100, target: 100, tt: 80, config: cfg))
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.reason, "low-tt")
        // TT at/above target does not cancel.
        XCTAssertTrue(NightMode.evaluate(inputs(bg: 100, target: 100, tt: 100, config: cfg)).active)
        XCTAssertTrue(NightMode.evaluate(inputs(bg: 100, target: 100, tt: 120, config: cfg)).active)
        // No active TT does not cancel.
        XCTAssertTrue(NightMode.evaluate(inputs(bg: 100, target: 100, tt: nil, config: cfg)).active)
    }

    // MARK: sleepActive + autoBySleep activates outside the clock window

    func testSleepActiveWithAutoBySleepActivatesOutsideWindow() {
        // now 12:00 (720) is outside the 01:00–05:00 window.
        let cfg = config(autoBySleep: true)
        let r = NightMode.evaluate(inputs(now: 720, bg: 100, sleepActive: true, config: cfg))
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.reason, "active")
    }

    // MARK: sleepInActive (morning lie-in) activates outside the window, ungated by autoBySleep

    func testSleepInActiveActivatesOutsideWindowRegardlessOfAutoBySleep() {
        // Outside the clock window (12:00) with autoBySleep OFF: a step-based lie-in still enables
        // night mode so its SMB rules apply during the lie-in. (2026-07-02)
        let cfg = config(autoBySleep: false)
        let r = NightMode.evaluate(inputs(now: 720, bg: 100, sleepActive: false, sleepInActive: true, config: cfg))
        XCTAssertTrue(r.active)
        XCTAssertTrue(r.suppressSmb)
    }

    func testNoSleepInActiveOutsideWindowStaysInactive() {
        let cfg = config(autoBySleep: false)
        let r = NightMode.evaluate(inputs(now: 720, bg: 100, sleepActive: false, sleepInActive: false, config: cfg))
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.reason, "outside-window")
    }

    func testSleepActiveIgnoredWhenAutoBySleepOff() {
        // autoBySleep off -> sleepActive cannot enable outside the window.
        let cfg = config(autoBySleep: false)
        let r = NightMode.evaluate(inputs(now: 720, bg: 100, sleepActive: true, config: cfg))
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.reason, "outside-window")
    }

    // MARK: minuteInWindow edge cases

    func testStartEqualsEndIsEmptyWindow() {
        // 2026-07-02 (AAPS 8ecaf7bbd9): start==end is an EMPTY clock window (was always-active, which
        // silently made V6 never dose). Sleep detection still governs the night via the caller.
        XCTAssertFalse(NightMode.minuteInWindow(now: 100, start: 100, end: 100))
        XCTAssertFalse(NightMode.minuteInWindow(now: 0, start: 100, end: 100))
        XCTAssertFalse(NightMode.minuteInWindow(now: 720, start: 100, end: 100))
    }
}
