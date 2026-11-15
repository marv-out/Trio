import Foundation

/// The values the complication shows. The watch app writes the newest one to the app group,
/// the widget extension reads it; neither side can reach the phone on its own.
struct ComplicationSnapshot: Codable, Equatable {
    /// A reading older than this is shown dimmed
    static let staleAfter: TimeInterval = 15 * 60

    /// When the phone built the values
    var date: Date
    /// Formatted in the user's units
    var glucose: String
    /// Nightscout direction name such as "FortyFiveUp"
    var trend: String?
    var delta: String?
    var iob: String?
    var cob: String?
    var glucoseColorHex: String?
    /// When the reading was taken; the age on the face comes from this
    var glucoseDate: Date?

    var readingDate: Date {
        glucoseDate ?? date
    }

    func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(readingDate) > Self.staleAfter
    }

    var trendArrow: String {
        switch trend {
        case "DoubleUp",
             "TripleUp":
            return "\u{2191}\u{2191}"
        case "SingleUp":
            return "\u{2191}"
        case "FortyFiveUp":
            return "\u{2197}"
        case "Flat":
            return "\u{2192}"
        case "FortyFiveDown":
            return "\u{2198}"
        case "SingleDown":
            return "\u{2193}"
        case "DoubleDown",
             "TripleDown":
            return "\u{2193}\u{2193}"
        default:
            return ""
        }
    }
}

/// App group storage shared by the watch app and the widget extension
enum ComplicationStore {
    static let key = "ComplicationSnapshot.latest"
    static let widgetKind = "TrioWatchComplication"

    /// The app group from Info.plist; nil when the target was built without one
    static var defaults: UserDefaults? {
        guard let suite = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String, !suite.isEmpty
        else { return nil }
        return UserDefaults(suiteName: suite)
    }

    static func load(from defaults: UserDefaults? = ComplicationStore.defaults) -> ComplicationSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }

    /// Keeps the newer snapshot. Returns true when the stored one changed.
    @discardableResult static func save(
        _ snapshot: ComplicationSnapshot,
        to defaults: UserDefaults? = ComplicationStore.defaults
    ) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return false }
        if let current = load(from: defaults), current.date >= snapshot.date { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
