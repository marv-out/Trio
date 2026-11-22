@testable import BoostV5Core
import XCTest

final class PostExerciseRecoveryTests: XCTestCase {
    private let hourMs: Double = 3_600_000.0
    private let minuteMs: Double = 60000.0

    private func enabledConfig() -> PostExerciseConfig {
        PostExerciseConfig(
            recoveryHours: 2.0,
            recoveryTargetMgdl: 144.0,
            recoveryScale: 0.5,
            minDurationMin: 10,
            enabled: true
        )
    }

    // MARK: - Defaults

    func testConfigDefaults() {
        let c = PostExerciseConfig()
        XCTAssertEqual(c.recoveryHours, 2.0)
        XCTAssertEqual(c.recoveryTargetMgdl, 144.0)
        XCTAssertEqual(c.recoveryScale, 0.5)
        XCTAssertEqual(c.minDurationMin, 10)
        XCTAssertFalse(c.enabled)
    }

    // MARK: - Multipliers per exercise type

    func testMultipliersVigorousAerobic() {
        let m = PostExerciseRecovery.multipliers(forExerciseType: "vigorousAerobic")
        XCTAssertEqual(m.window, 1.25)
        XCTAssertEqual(m.smb, 0.8)
        XCTAssertEqual(m.targetOffset, 0.0)
        // Kotlin uppercase form maps identically.
        let mk = PostExerciseRecovery.multipliers(forExerciseType: "VIGOROUS_AEROBIC")
        XCTAssertEqual(mk.window, 1.25)
        XCTAssertEqual(mk.smb, 0.8)
        XCTAssertEqual(mk.targetOffset, 0.0)
    }

    func testMultipliersResistance() {
        let m = PostExerciseRecovery.multipliers(forExerciseType: "resistance")
        XCTAssertEqual(m.window, 1.5)
        XCTAssertEqual(m.smb, 1.2)
        XCTAssertEqual(m.targetOffset, 10.0)
    }

    func testMultipliersLightAerobic() {
        let m = PostExerciseRecovery.multipliers(forExerciseType: "lightAerobic")
        XCTAssertEqual(m.window, 0.5)
        XCTAssertEqual(m.smb, 1.4)
        XCTAssertEqual(m.targetOffset, 0.0)
    }

    func testMultipliersModerateAndDefault() {
        for t in ["moderateAerobic", "MODERATE_AEROBIC", "active", "ACTIVE", "unknown"] {
            let m = PostExerciseRecovery.multipliers(forExerciseType: t)
            XCTAssertEqual(m.window, 1.0, "window for \(t)")
            XCTAssertEqual(m.smb, 1.0, "smb for \(t)")
            XCTAssertEqual(m.targetOffset, 0.0, "offset for \(t)")
        }
    }

    // MARK: - Disabled

    func testDisabledIsNoOp() {
        let config = PostExerciseConfig() // enabled = false
        let r = PostExerciseRecovery.step(
            nowMs: 1_000_000,
            exerciseActive: true,
            exerciseType: "vigorousAerobic",
            config: config,
            state: RecoveryState()
        )
        XCTAssertFalse(r.inRecoveryWindow)
        XCTAssertEqual(r.smbScale, 1.0)
        XCTAssertEqual(r.targetOffsetMgdl, 0.0)
        XCTAssertEqual(r.newState.recoveryWindowEndMs, 0.0)
    }

    // MARK: - No recovery if exercise shorter than minDuration

    func testNoRecoveryWhenExerciseTooBrief() {
        let config = enabledConfig()
        let start: Double = 1_000_000

        // Exercise starts.
        let r1 = PostExerciseRecovery.step(
            nowMs: start,
            exerciseActive: true,
            exerciseType: "vigorousAerobic",
            config: config,
            state: RecoveryState()
        )
        XCTAssertEqual(r1.newState.exerciseStartMs, start)
        XCTAssertFalse(r1.inRecoveryWindow)

        // Exercise ends after 5 minutes (< 10 min minimum).
        let r2 = PostExerciseRecovery.step(
            nowMs: start + 5 * minuteMs,
            exerciseActive: false,
            exerciseType: "vigorousAerobic",
            config: config,
            state: r1.newState
        )
        XCTAssertFalse(r2.inRecoveryWindow)
        XCTAssertEqual(r2.newState.recoveryWindowEndMs, 0.0, "no window should open")
        XCTAssertEqual(r2.smbScale, 1.0)
    }

    // MARK: - Window opens on transition out

    func testWindowOpensOnTransitionOut() {
        let config = enabledConfig()
        let start: Double = 5_000_000

        let r1 = PostExerciseRecovery.step(
            nowMs: start,
            exerciseActive: true,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: RecoveryState()
        )
        let endTime = start + 20 * minuteMs // 20 min ≥ 10 min minimum
        let r2 = PostExerciseRecovery.step(
            nowMs: endTime,
            exerciseActive: false,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: r1.newState
        )
        // MODERATE → baseline multipliers: window = 2.0h, scale = 0.5, offset = 0.
        let expectedEnd = endTime + 2.0 * hourMs * 1.0
        XCTAssertEqual(r2.newState.recoveryWindowEndMs, expectedEnd, accuracy: 1E-6)
        XCTAssertTrue(r2.inRecoveryWindow)
        XCTAssertEqual(r2.smbScale, 0.5, accuracy: 1E-9)
        XCTAssertEqual(r2.targetOffsetMgdl, 0.0)
    }

    // MARK: - inRecoveryWindow true until end then false

    func testInRecoveryWindowTrueUntilEndThenFalse() {
        let config = enabledConfig()
        let start: Double = 0

        let r1 = PostExerciseRecovery.step(
            nowMs: start,
            exerciseActive: true,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: RecoveryState()
        )
        let endExercise = start + 15 * minuteMs
        let r2 = PostExerciseRecovery.step(
            nowMs: endExercise,
            exerciseActive: false,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: r1.newState
        )
        let windowEnd = r2.newState.recoveryWindowEndMs
        XCTAssertTrue(r2.inRecoveryWindow)

        // Just before window end → still inside.
        let rBefore = PostExerciseRecovery.step(
            nowMs: windowEnd - 1,
            exerciseActive: false,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: r2.newState
        )
        XCTAssertTrue(rBefore.inRecoveryWindow)
        XCTAssertEqual(rBefore.smbScale, 0.5, accuracy: 1E-9)

        // Exactly at window end → outside (Kotlin uses strict `now < end`).
        let rAt = PostExerciseRecovery.step(
            nowMs: windowEnd,
            exerciseActive: false,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: rBefore.newState
        )
        XCTAssertFalse(rAt.inRecoveryWindow)
        XCTAssertEqual(rAt.smbScale, 1.0)
        XCTAssertEqual(rAt.targetOffsetMgdl, 0.0)

        // After window end → outside.
        let rAfter = PostExerciseRecovery.step(
            nowMs: windowEnd + 60 * minuteMs,
            exerciseActive: false,
            exerciseType: "MODERATE_AEROBIC",
            config: config,
            state: rAt.newState
        )
        XCTAssertFalse(rAfter.inRecoveryWindow)
        XCTAssertEqual(rAfter.smbScale, 1.0)
    }

    // MARK: - RESISTANCE: +10 offset & 1.2× scale

    func testResistanceOffsetAndScale() {
        let config = enabledConfig()
        let start: Double = 100_000

        let r1 = PostExerciseRecovery.step(
            nowMs: start,
            exerciseActive: true,
            exerciseType: "RESISTANCE",
            config: config,
            state: RecoveryState()
        )
        let endExercise = start + 30 * minuteMs
        let r2 = PostExerciseRecovery.step(
            nowMs: endExercise,
            exerciseActive: false,
            exerciseType: "RESISTANCE",
            config: config,
            state: r1.newState
        )
        // scale = 0.5 * 1.2 = 0.6 (within [0.1, 1.0]); offset = +10.
        XCTAssertTrue(r2.inRecoveryWindow)
        XCTAssertEqual(r2.smbScale, 0.6, accuracy: 1E-9)
        XCTAssertEqual(r2.targetOffsetMgdl, 10.0)
        // window = 2.0h * 1.5 = 3.0h.
        XCTAssertEqual(r2.newState.recoveryWindowEndMs, endExercise + 3.0 * hourMs, accuracy: 1E-6)
        XCTAssertEqual(r2.newState.activeRecoveryScale, 0.6, accuracy: 1E-9)
        XCTAssertEqual(r2.newState.activeRecoveryTargetOffset, 10.0)
    }

    // MARK: - Scale clamp (coerceIn 0.1...1.0)

    func testScaleClampLowerBound() {
        // recoveryScale 0.05 * lightAerobic 1.4 = 0.07 → clamped to 0.1.
        var config = enabledConfig()
        config.recoveryScale = 0.05
        let start: Double = 0
        let r1 = PostExerciseRecovery.step(
            nowMs: start, exerciseActive: true, exerciseType: "lightAerobic",
            config: config, state: RecoveryState()
        )
        let r2 = PostExerciseRecovery.step(
            nowMs: start + 20 * minuteMs, exerciseActive: false, exerciseType: "lightAerobic",
            config: config, state: r1.newState
        )
        XCTAssertEqual(r2.smbScale, 0.1, accuracy: 1E-9)
    }

    func testScaleClampUpperBound() {
        // recoveryScale 1.0 * resistance 1.2 = 1.2 → clamped to 1.0.
        var config = enabledConfig()
        config.recoveryScale = 1.0
        let start: Double = 0
        let r1 = PostExerciseRecovery.step(
            nowMs: start, exerciseActive: true, exerciseType: "resistance",
            config: config, state: RecoveryState()
        )
        let r2 = PostExerciseRecovery.step(
            nowMs: start + 20 * minuteMs, exerciseActive: false, exerciseType: "resistance",
            config: config, state: r1.newState
        )
        XCTAssertEqual(r2.smbScale, 1.0, accuracy: 1E-9)
    }

    // MARK: - Codable round-trip

    func testStateCodableRoundTrip() throws {
        let state = RecoveryState(
            recoveryWindowEndMs: 12_345_678.0,
            activeRecoveryScale: 0.6,
            activeRecoveryTargetOffset: 10.0,
            wasExerciseActive: true,
            exerciseStartMs: 9000.0
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RecoveryState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testStateCodableRoundTripNilStart() throws {
        let state = RecoveryState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RecoveryState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.exerciseStartMs)
    }
}
