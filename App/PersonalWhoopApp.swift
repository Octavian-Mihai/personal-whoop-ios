import SwiftUI

@main
struct PersonalWhoopApp: App {
    @State private var model = AppModel()

    private func show(_ t: AppTab) -> Bool { !model.ui.hiddenTabs.contains(t.rawValue) }

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Today", systemImage: "heart.circle.fill") }
                if show(.sleep) { SleepView().tabItem { Label("Sleep", systemImage: "bed.double.fill") } }
                if show(.trends) { TrendsView().tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") } }
                if show(.workouts) { WorkoutsView().tabItem { Label("Workouts", systemImage: "figure.run") } }
                if show(.breathe) { BreatheView().tabItem { Label("Breathe", systemImage: "wind") } }
                MoreView().tabItem { Label("More", systemImage: "ellipsis.circle") }
            }
            .environment(model)
            .task { if SnapshotExporter.requested { await SnapshotExporter.run(model: model) } }
            .tint(Color(red: 0.10, green: 0.75, blue: 0.65))
            .fullScreenCover(isPresented: Binding(get: { model.live != nil }, set: { _ in })) {
                if let l = model.live { LiveWorkoutView(live: l).environment(model) }
            }
        }
    }
}
