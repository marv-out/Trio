import Foundation

/// The AAPS Boost release this port is synced to (AAPS `Versions.boostVersion`). Trio's own
/// APP_VERSION belongs to the upstream project, so the Boost version is carried separately.
public enum BoostVersion {
    public static let synced = "6.3.3"
}

public enum BoostMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off // stock Trio only
    case shadow // run V5, log what it would do, do NOT change dosing
    case active // V5 drives the SMB

    public var id: String { rawValue }

    /// Human-facing label for the settings picker.
    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .shadow: return "Shadow (log only)"
        case .active: return "Active (doses)"
        }
    }
}

public final class BoostV5Store: @unchecked Sendable {
    public static let shared = BoostV5Store()
    private let modeKey = "boost_v5_mode"
    private let stateKey = "boost_v5_persisted_state"
    private let defaults: UserDefaults
    // Serializes access to the persisted state. NOTE: loadState()/saveState() each take this lock
    // only for their own call, so calling them as a pair does NOT make the read-modify-write atomic.
    // Use mutateState(_:) for the load→decide→save cycle — it holds the lock across the whole span,
    // which is what guards against an overlap between the scheduled loop and a manual determine call.
    private let lock = NSLock()
    /// Most recent persisted state, held in memory (guarded by `lock`). Mirrors the AAPS
    /// V5StateStore in-memory cache: reads prefer the cache (always-current within process),
    /// falling back to UserDefaults only on cold start. This is also what carries the
    /// deliberately-non-serialized `lastCycleScore` across cycles (2026-07-03 sustained-score
    /// early confirm, AAPS 242a6e179d): a process restart drops it — fails safe to legacy
    /// confirm timing — while a normal 5-min cycle sees it.
    private var cached: V5PersistedState?
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Decode from UserDefaults (cold-start path). Callers must hold `lock`.
    /// A corrupt blob is CLEARED so it doesn't silently re-parse-and-fail on every cold start
    /// (AAPS d91a6a2617 quality pass — falls back to IDLE, safer than carrying unknown state).
    private func decodeFromDefaults() -> V5PersistedState {
        guard let data = defaults.data(forKey: stateKey) else { return V5PersistedState() }
        guard let state = try? JSONDecoder().decode(V5PersistedState.self, from: data) else {
            defaults.removeObject(forKey: stateKey)
            return V5PersistedState()
        }
        return state
    }

    public var mode: BoostMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return BoostMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .shadow
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue.rawValue, forKey: modeKey)
        }
    }

    public func loadState() -> V5PersistedState {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let state = decodeFromDefaults()
        cached = state
        return state
    }

    public func saveState(_ state: V5PersistedState) {
        lock.lock()
        defer { lock.unlock() }
        cached = state // synchronous, before the defaults write — same-process reads always current
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    /// Atomically load → mutate → save the persisted state under a single critical section.
    /// `body` receives the current state `inout`; whatever it leaves in `state` is persisted.
    /// This is the only safe way to run the load→decide→save cycle when a scheduled loop and a
    /// manual determine call can overlap, since it prevents a lost-update (last-writer-wins) race.
    public func mutateState<T>(_ body: (inout V5PersistedState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        // Cache-first (AAPS V5StateStore idiom): within-process reads see the last save —
        // including the non-Codable lastCycleScore — falling back to UserDefaults on cold start.
        var state = cached ?? decodeFromDefaults()
        let result = body(&state)
        cached = state
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
        return result
    }
}
