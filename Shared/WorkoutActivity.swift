import SwiftUI
import ActivityKit

/// Live Activity for a tracked workout (lock screen + Dynamic Island).
struct WorkoutAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var bpm: Int
        var zone: Int
        var kcal: Double
        var avgHR: Double?
        var effort: Double?
        var inTarget: Bool
        var cue: String?
        var simulated: Bool
    }
    var kind: String
    var icon: String
    var startedAt: Date
    var targetLow: Int
    var targetHigh: Int
}

extension WTheme {
    static func zone(_ z: Int) -> Color {
        switch z {
        case 0: return Color(red: 0.74, green: 0.76, blue: 0.82)
        case 1: return Color(red: 0.58, green: 0.72, blue: 0.93)
        case 2: return Color(red: 0.55, green: 0.82, blue: 0.70)
        case 3: return Color(red: 0.96, green: 0.80, blue: 0.58)
        case 4: return Color(red: 0.95, green: 0.68, blue: 0.60)
        default: return Color(red: 0.92, green: 0.62, blue: 0.68)
        }
    }
}

/// Lock-screen banner (also used in the app for previews).
struct WorkoutLiveView: View {
    var attrs: WorkoutAttributes
    var state: WorkoutAttributes.ContentState

    var body: some View {
        let zc = WTheme.zone(state.zone)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: attrs.icon).font(.subheadline.bold()).foregroundStyle(zc)
                Text(attrs.kind).font(.subheadline.weight(.bold))
                if state.simulated { Text("simulated HR").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.25), in: Capsule()) }
                Spacer()
                Text(timerInterval: attrs.startedAt...Date.distantFuture, countsDown: false).font(.title3.weight(.bold).monospacedDigit()).multilineTextAlignment(.trailing).frame(maxWidth: 90, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state.bpm > 0 ? "\(state.bpm)" : "—").font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(zc)
                Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Zone \(state.zone)").font(.caption.weight(.bold)).padding(.horizontal, 9).padding(.vertical, 3).background(zc.opacity(0.35), in: Capsule())
                    Text("target \(attrs.targetLow)–\(attrs.targetHigh)").font(.caption2).foregroundStyle(state.inTarget ? Color.secondary : Color.orange)
                }
            }
            HStack(spacing: 8) {
                stat(state.avgHR.map { String(format: "%.0f", $0) } ?? "—", "avg")
                stat(String(format: "%.0f", state.kcal), "kcal")
                stat(state.effort.map { String(format: "%.0f", $0) } ?? "—", "effort")
            }
            if let c = state.cue { Label(c, systemImage: "exclamationmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
        }
        .padding(14)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) { Text(v).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit(); Text(l).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
