import SwiftUI

@main
struct PersonalWhoopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Today", systemImage: "heart.circle.fill") }
                SleepView().tabItem { Label("Sleep", systemImage: "bed.double.fill") }
                TrendsView().tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
                WorkoutsView().tabItem { Label("Workouts", systemImage: "figure.run") }
                BreatheView().tabItem { Label("Breathe", systemImage: "wind") }
                MoreView().tabItem { Label("More", systemImage: "ellipsis.circle") }
            }
            .environment(model)
        }
    }
}
