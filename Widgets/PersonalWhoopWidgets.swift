import WidgetKit
import SwiftUI

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snap: context.isPreview ? .sample : (WidgetSnapshot.load() ?? .sample)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snap = WidgetSnapshot.load() ?? WidgetSnapshot(charge: nil, effort: nil, rest: nil, hrv: nil, restingHR: nil, batteryPercent: nil,
                                                          batteryAt: nil, nextAlarm: nil, updated: Date(), isDemo: false)
        // The app pushes fresh values and reloads timelines; this is only a fallback refresh.
        completion(Timeline(entries: [SnapshotEntry(date: Date(), snap: snap)], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: SnapshotProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Charge · Effort · Rest")
        .description("Today's scores and your strap battery.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        TodayWidgetContent(snap: entry.snap, family: family)
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium {
                    LinearGradient(colors: WTheme.mint, startPoint: .topLeading, endPoint: .bottomTrailing)
                } else { Color.clear }
            }
    }
}

struct StrapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StrapWidget", provider: SnapshotProvider()) { entry in
            StrapWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Strap")
        .description("Strap battery and your next alarm.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct StrapWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        StrapWidgetContent(snap: entry.snap, family: family)
            .containerBackground(for: .widget) { family == .systemSmall ? Color(.secondarySystemBackground) : Color.clear }
    }
}

@main
struct PersonalWhoopWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        StrapWidget()
    }
}
