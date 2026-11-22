import Foundation
import HealthKit
import Testing
@testable import Trio

/// Which HealthKit step-read errors mean the step feed is unavailable (AAPS StepFeed, 2026-11-20). A
/// locked iPhone fails every read with errorDatabaseInaccessible, and the windows must then read as
/// unknown, not 0 steps. A window with no samples fails with errorNoData, which is 0 steps.
@Suite("BoostStepReadTests") struct BoostStepReadTests {
    private func hk(_ code: HealthKit.HKError.Code) -> Error {
        NSError(domain: HKErrorDomain, code: code.rawValue)
    }

    @Test("A locked phone's read failure makes the steps unavailable") func lockedIsUnavailable() {
        #expect(BaseBoostActivityMonitor.stepReadFailed(hk(.errorDatabaseInaccessible)))
    }

    @Test("An empty window and a successful read are 0 steps, not unavailable") func emptyIsZero() {
        #expect(!BaseBoostActivityMonitor.stepReadFailed(hk(.errorNoData)))
        #expect(!BaseBoostActivityMonitor.stepReadFailed(nil as Error?))
    }

    @Test("Any other error is unavailable, which can only withhold the raise") func otherErrors() {
        #expect(BaseBoostActivityMonitor.stepReadFailed(hk(.errorAuthorizationNotDetermined)))
        #expect(
            BaseBoostActivityMonitor
                .stepReadFailed(NSError(domain: NSCocoaErrorDomain, code: HealthKit.HKError.Code.errorNoData.rawValue))
        )
    }
}
