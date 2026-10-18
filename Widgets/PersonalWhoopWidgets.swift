import WidgetKit
import SwiftUI
import ActivityKit

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

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutAttributes.self) { ctx in
            WorkoutLiveView(attrs: ctx.attributes, state: ctx.state)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.92))
        } dynamicIsland: { ctx in
            let zc = WTheme.zone(ctx.state.zone)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.attributes.kind, systemImage: ctx.attributes.icon).font(.caption.bold()).foregroundStyle(zc)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false).font(.caption.monospacedDigit()).frame(maxWidth: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ctx.state.bpm > 0 ? "\(ctx.state.bpm)" : "—").font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(zc)
                        Text("bpm · Z\(ctx.state.zone)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(String(format: "%.0f kcal", ctx.state.kcal)).font(.caption.bold())
                        Spacer()
                        Text("target \(ctx.attributes.targetLow)–\(ctx.attributes.targetHigh)").font(.caption2).foregroundStyle(ctx.state.inTarget ? Color.secondary : Color.orange)
                        Spacer()
                        Text(ctx.state.effort.map { String(format: "effort %.0f", $0) } ?? "effort —").font(.caption.bold())
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.attributes.icon).foregroundStyle(zc)
            } compactTrailing: {
                Text(ctx.state.bpm > 0 ? "\(ctx.state.bpm)" : "—").font(.caption.bold().monospacedDigit()).foregroundStyle(zc)
            } minimal: {
                Text(ctx.state.bpm > 0 ? "\(ctx.state.bpm)" : "—").font(.caption2.bold().monospacedDigit()).foregroundStyle(zc)
            }
        }
    }
}

@main
struct PersonalWhoopWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        SleepWidget()
        StrapWidget()
        WorkoutLiveActivity()
    }
}
