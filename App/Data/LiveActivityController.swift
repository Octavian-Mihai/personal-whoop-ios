import Foundation
import ActivityKit

/// Shows a tracked workout on the lock screen and in the Dynamic Island.
@MainActor
final class LiveActivityController {
    private var activity: Activity<WorkoutAttributes>?

    func start(kind: String, icon: String, startedAt: Date, zones: ClosedRange<Int>, state: WorkoutAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = WorkoutAttributes(kind: kind, icon: icon, startedAt: startedAt, targetLow: zones.lowerBound, targetHigh: zones.upperBound)
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
    }

    func update(_ state: WorkoutAttributes.ContentState) {
        guard let a = activity else { return }
        Task { await a.update(.init(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    func end(_ state: WorkoutAttributes.ContentState) {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60))) }
    }
}
