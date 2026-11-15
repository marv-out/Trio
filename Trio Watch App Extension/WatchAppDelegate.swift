import WatchKit

/// Keeps the complication fed while the app is closed. With the complication on the active face,
/// watchOS wakes the app for a background refresh a few times an hour; each one asks the phone
/// for the current values and books the next refresh.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// watchOS grants about four refreshes an hour to an app with a complication on the active face
    static let refreshInterval: TimeInterval = 15 * 60

    func applicationDidFinishLaunching() {
        Self.scheduleBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                WatchLogger.shared.debug(.lifecycle, "Background refresh for the complication")
                WatchState.shared.requestComplicationUpdate { _ in
                    Self.scheduleBackgroundRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            case let snapshot as WKSnapshotRefreshBackgroundTask:
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Books the next refresh; a later call moves the pending one
    static func scheduleBackgroundRefresh(after interval: TimeInterval = refreshInterval) {
        let preferredDate = Date().addingTimeInterval(interval)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferredDate, userInfo: nil) { error in
            if let error {
                WatchLogger.shared.warning(.lifecycle, "Scheduling a background refresh failed", error: error)
            }
        }
    }
}
