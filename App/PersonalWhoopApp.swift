import SwiftUI

@main
struct PersonalWhoopApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tick = Date()   // re-evaluates "By time of day" once a minute

    private func show(_ t: AppTab) -> Bool { !model.ui.hiddenTabs.contains(t.rawValue) }

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Today", systemImage: "heart.circle.fill") }
                if show(.sleep) { SleepView().tabItem { Label("Sleep", systemImage: "bed.double.fill") } }
                if show(.trends) { TrendsView().tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") } }
                if show(.workouts) { WorkoutsView().tabItem { Label("Workouts", systemImage: "figure.run") } }
                MoreView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .environment(model)
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.stopSnooze() } }
            .task { if SnapshotExporter.requested { await SnapshotExporter.run(model: model) } }
            .preferredColorScheme(model.colorScheme(at: tick))
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { tick = $0 }
            .tint(Color(red: 0.10, green: 0.75, blue: 0.65))
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)   // grows with the user's text size, but not past layouts that still fit
            .fullScreenCover(isPresented: Binding(get: { model.needsOnboarding && !SnapshotExporter.requested }, set: { _ in })) {
                OnboardingView().environment(model)
            }
            .fullScreenCover(isPresented: Binding(get: { model.live != nil }, set: { _ in })) {
                if let l = model.live { LiveWorkoutView(live: l).environment(model) }
            }
        }
    }
}
