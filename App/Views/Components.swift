import SwiftUI
import StrandAnalytics

extension Color {
    static func band(_ b: ChargeBand) -> Color { b == .green ? .green : (b == .yellow ? .yellow : .red) }
}

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Ring: View {
    var value: Double?          // 0…100
    var color: Color
    var label: String
    var unit: String = ""
    var size: CGFloat = 96
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 10)
                Circle().trim(from: 0, to: (value ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                    if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .frame(width: size, height: size)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    var label: String; var value: String; var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TierBadge: View {
    var tier: ConfidenceTier
    var body: some View {
        Text(tier.rawValue).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tier == .solid ? Color.green.opacity(0.2) : tier == .building ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2), in: Capsule())
    }
}

func fmtDuration(_ minutes: Double) -> String {
    let m = Int(minutes.rounded()); return "\(m / 60)h \(m % 60)m"
}
func fmtClock(_ t: Double) -> String {
    Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
}

struct Disclaimer: View {
    var body: some View {
        Text("Everything here is an on-device approximation, not a medical device and not WHOOP's scoring.")
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
    }
}
