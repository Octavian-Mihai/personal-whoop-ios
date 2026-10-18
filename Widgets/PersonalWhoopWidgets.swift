import WidgetKit
import SwiftUI

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snap: context.isPreview ? .sample : (WidgetSnapshot.load() ?? .empty)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app pushes fresh values and reloads timelines; this is only a fallback refresh.
        completion(Timeline(entries: [SnapshotEntry(date: Date(), snap: WidgetSnapshot.load() ?? .empty)], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: SnapshotProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Charge, Effort, Rest, vitals, 7-day trend, sleep and strap battery.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        TodayWidgetContent(snap: entry.snap, family: family)
            .containerBackground(for: .widget) {
                switch family {
                case .systemSmall, .systemMedium: LinearGradient(colors: WTheme.mint, startPoint: .topLeading, endPoint: .bottomTrailing)
                case .systemLarge: Color(.systemBackground)
                default: Color.clear
                }
            }
    }
}

struct SleepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SleepWidget", provider: SnapshotProvider()) { entry in
            SleepWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sleep")
        .description("Last night's sleep, stages, Rest, sleep debt and your next alarm.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct SleepWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        SleepWidgetContent(snap: entry.snap, family: family)
            .containerBackground(for: .widget) { LinearGradient(colors: WTheme.indigo, startPoint: .topLeading, endPoint: .bottomTrailing) }
    }
}

struct StrapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StrapWidget", provider: SnapshotProvider()) { entry in
            StrapWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Strap")
        .description("Battery, heart rate, next alarm and water.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
        .contentMarginsDisabled()
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
        SleepWidget()
        StrapWidget()
    }
}
