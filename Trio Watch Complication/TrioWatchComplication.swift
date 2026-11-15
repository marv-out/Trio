import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot?
    /// The reading is older than `ComplicationSnapshot.staleAfter` at this entry's date
    let isStale: Bool

    static let placeholder = TrioWatchComplicationEntry(date: Date(), snapshot: .sample, isStale: false)
}

extension ComplicationSnapshot {
    static let sample = ComplicationSnapshot(
        date: Date(),
        glucose: "112",
        trend: "FortyFiveUp",
        delta: "+4",
        iob: "1.25",
        cob: "24",
        glucoseColorHex: "#ffffff",
        glucoseDate: Date()
    )

    /// The phone sends white while in range and a warning color outside it
    var glucoseColor: Color? {
        guard let hex = glucoseColorHex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        guard !context.isPreview else {
            completion(.placeholder)
            return
        }
        completion(Self.entries(at: Date()).first ?? .placeholder)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        // The watch app reloads this timeline whenever newer values arrive; nothing to poll here
        completion(Timeline(entries: Self.entries(at: Date()), policy: .never))
    }

    /// The stored values, plus the moment they turn stale
    static func entries(
        at now: Date,
        snapshot: ComplicationSnapshot? = ComplicationStore.load()
    ) -> [TrioWatchComplicationEntry] {
        guard let snapshot else {
            return [TrioWatchComplicationEntry(date: now, snapshot: nil, isStale: true)]
        }
        let staleAt = snapshot.readingDate.addingTimeInterval(ComplicationSnapshot.staleAfter)
        guard staleAt > now else {
            return [TrioWatchComplicationEntry(date: now, snapshot: snapshot, isStale: true)]
        }
        return [
            TrioWatchComplicationEntry(date: now, snapshot: snapshot, isStale: false),
            TrioWatchComplicationEntry(date: staleAt, snapshot: snapshot, isStale: true)
        ]
    }
}

// MARK: - Views

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryRectangular:
            TrioAccessoryRectangularView(entry: entry)
        case .accessoryInline:
            TrioAccessoryInlineView(entry: entry)
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        #if os(watchOS)
            case .accessoryCorner:
                TrioAccessoryCornerView(entry: entry)
        #endif
        default:
            TrioComplicationIcon()
        }
    }
}

/// The app icon, shown until the first values arrive
struct TrioComplicationIcon: View {
    var body: some View {
        Image("ComplicationIcon")
            .resizable()
            .widgetAccentable()
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// Bottom slot of the Modular faces: glucose with trend and age, IOB and COB below
struct TrioAccessoryRectangularView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var entry: TrioWatchComplicationEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.glucose)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(glucoseColor(for: snapshot))
                    Text(snapshot.trendArrow)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    if let delta = snapshot.delta, !delta.isEmpty {
                        Text(delta)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                    Text(snapshot.readingDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    Label(amount(snapshot.iob, unit: "U"), systemImage: "syringe.fill")
                    Label(amount(snapshot.cob, unit: "g"), systemImage: "fork.knife")
                }
                .font(.caption)
                .lineLimit(1)
            }
            .widgetAccentable()
            .opacity(entry.isStale ? 0.55 : 1)
            .widgetBackground(backgroundView: Color.clear)
        } else {
            HStack(spacing: 6) {
                TrioComplicationIcon()
                    .frame(width: 20, height: 20)
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .widgetBackground(backgroundView: Color.clear)
        }
    }

    private func glucoseColor(for snapshot: ComplicationSnapshot) -> Color {
        guard renderingMode == .fullColor, let color = snapshot.glucoseColor else { return .primary }
        return color
    }

    private func amount(_ value: String?, unit: String) -> String {
        "\(value ?? "--") \(unit)"
    }
}

/// Single text line at the top of a face
struct TrioAccessoryInlineView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            Text("\(snapshot.glucose)\(snapshot.trendArrow) IOB \(snapshot.iob ?? "--") COB \(snapshot.cob ?? "--")")
                .widgetBackground(backgroundView: Color.clear)
        } else {
            Text("Trio")
                .widgetBackground(backgroundView: Color.clear)
        }
    }
}

/// Circular Complication
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text(snapshot.glucose)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.6)
                    Text(snapshot.trendArrow)
                        .font(.caption)
                }
                .lineLimit(1)
                .padding(.horizontal, 2)
            }
            .widgetAccentable()
            .opacity(entry.isStale ? 0.55 : 1)
            .widgetBackground(backgroundView: Color.clear)
        } else {
            TrioComplicationIcon()
        }
    }
}

#if os(watchOS)
    /// Corner Complication: glucose in the corner, IOB and COB along the edge
    struct TrioAccessoryCornerView: View {
        var entry: TrioWatchComplicationEntry

        var body: some View {
            if let snapshot = entry.snapshot {
                Text("\(snapshot.glucose)\(snapshot.trendArrow)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .widgetCurvesContent()
                    .widgetLabel {
                        Text("IOB \(snapshot.iob ?? "--")  COB \(snapshot.cob ?? "--")")
                    }
                    .widgetAccentable()
                    .opacity(entry.isStale ? 0.55 : 1)
                    .widgetBackground(backgroundView: Color.clear)
            } else {
                TrioComplicationIcon()
                    .widgetLabel {
                        Text("Trio")
                    }
            }
        }
    }
#endif

// MARK: - Widget Configuration

@main struct TrioWatchComplication: Widget {
    let kind: String = ComplicationStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio")
        .description("Shows glucose, IOB and COB from Trio")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCorner, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}

#if os(watchOS)
    #Preview("Rectangular", as: .accessoryRectangular) {
        TrioWatchComplication()
    } timeline: {
        TrioWatchComplicationEntry(date: Date(), snapshot: .sample, isStale: false)
        TrioWatchComplicationEntry(date: Date(), snapshot: .sample, isStale: true)
        TrioWatchComplicationEntry(date: Date(), snapshot: nil, isStale: true)
    }

    #Preview("Circular", as: .accessoryCircular) {
        TrioWatchComplication()
    } timeline: {
        TrioWatchComplicationEntry(date: Date(), snapshot: .sample, isStale: false)
    }
#endif
