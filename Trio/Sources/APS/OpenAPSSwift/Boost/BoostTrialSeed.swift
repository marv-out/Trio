import Foundation

/// The install seed for the pre-registered post-rescue tight-ramp trial.
///
/// Generated once per install and never changed, so the day-level arm assignment is stable and an
/// offline analysis can reproduce every arm from the seed alone rather than trusting a logged flag.
/// UserDefaults rather than Preferences, so an exported settings file cannot carry one install's
/// randomisation onto another device.
enum BoostTrialSeed {
    private static let key = "boost.trial.seed"
    private static let lock = NSLock()

    static var seed: String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
