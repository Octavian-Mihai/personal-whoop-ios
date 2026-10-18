import SwiftUI
import Charts
import StrandAnalytics

extension Color {
    static func band(_ b: ChargeBand) -> Color { b == .green ? .green : (b == .yellow ? .yellow : .red) }
    static let screenBG = Color(.systemGroupedBackground)
    static let cardBG = Color(.secondarySystemGroupedBackground)
}

extension ChargeBand {
    var gradient: [Color] {
        switch self {
        case .green: return [Color(red: 0.20, green: 0.85, blue: 0.55), Color(red: 0.10, green: 0.70, blue: 0.35)]
        case .yellow: return [Color(red: 1.0, green: 0.85, blue: 0.25), Color(red: 0.95, green: 0.65, blue: 0.10)]
        case .red: return [Color(red: 1.0, green: 0.45, blue: 0.40), Color(red: 0.85, green: 0.20, blue: 0.25)]
        }
    }
    var word: String { self == .green ? "Primed" : (self == .yellow ? "Steady" : "Take it easy") }
}

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var icon: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon { Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.tint) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
    }
}

/// Animated gradient progress ring.
struct Ring: View {
    var value: Double?          // 0…100
    var colors: [Color]
    var label: String
    var unit: String = ""
    var size: CGFloat = 96
    var lineWidth: CGFloat? = nil
    var onDark = false
    @State private var shown = 0.0

    init(value: Double?, color: Color, label: String, unit: String = "", size: CGFloat = 96) {
        self.value = value; self.colors = [color.opacity(0.7), color]; self.label = label; self.unit = unit; self.size = size
    }
    init(value: Double?, colors: [Color], label: String, unit: String = "", size: CGFloat = 96, onDark: Bool = false) {
        self.value = value; self.colors = colors; self.label = label; self.unit = unit; self.size = size; self.onDark = onDark
    }

    var body: some View {
        let lw = lineWidth ?? size * 0.11
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(onDark ? Color.white.opacity(0.22) : (colors.last ?? .gray).opacity(0.15), lineWidth: lw)
                Circle().trim(from: 0, to: shown / 100)
                    .stroke(AngularGradient(colors: colors + [colors.last ?? .gray], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, shown / 100))),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: (colors.last ?? .gray).opacity(onDark ? 0.0 : 0.45), radius: size * 0.08)
                VStack(spacing: 0) {
                    Text(value.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(onDark ? .white : .primary)
                    if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(onDark ? Color.white.opacity(0.8) : .secondary) }
                }
            }
            .frame(width: size, height: size)
            if !label.isEmpty { Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = value ?? 0 } }
        .onChange(of: value) { _, v in withAnimation(.easeOut(duration: 0.6)) { shown = v ?? 0 } }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color = .accentColor
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).interpolationMethod(.catmullRom)
            AreaMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(LinearGradient(colors: [color.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

/// Metric tile: value, delta vs. your norm, 14-day sparkline.
struct MetricChip: View {
    var icon: String
    var label: String
    var value: String
    var delta: Double?          // today − norm
    var deltaFormat: String = "%+.0f"
    var higherIsBetter: Bool = true
    var series: [Double]
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
            if let d = delta, abs(d) > 0.0001 {
                let good = (d > 0) == higherIsBetter
                Label(String(format: deltaFormat, d), systemImage: d > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(good ? .green : .orange)
            } else { Text(" ").font(.caption2) }
            Sparkline(values: series, color: tint).frame(height: 28)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// Diverging bar: left of centre = hurt Charge, right = helped.
struct DriverBar: View {
    var points: Double
    var maxMagnitude: Double
    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2
            let w = min(half, half * abs(points) / max(maxMagnitude, 1))
            ZStack(alignment: .center) {
                Capsule().fill(Color.gray.opacity(0.12))
                Capsule().fill(points >= 0 ? Color.green : Color.orange)
                    .frame(width: max(4, w))
                    .offset(x: points >= 0 ? max(4, w) / 2 : -max(4, w) / 2)
                Rectangle().fill(Color.gray.opacity(0.4)).frame(width: 1)
            }
        }
        .frame(height: 8)
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

/// Soft colour blobs behind a screen.
struct AmbientBackground: View {
    var tint: Color = .teal
    var body: some View {
        ZStack {
            Color.screenBG
            GeometryReader { g in
                Circle().fill(tint.opacity(0.28)).frame(width: g.size.width * 0.95).blur(radius: 70).offset(x: g.size.width * 0.35, y: -g.size.width * 0.35)
                Circle().fill(Color.purple.opacity(0.12)).frame(width: g.size.width * 0.8).blur(radius: 80).offset(x: -g.size.width * 0.45, y: g.size.height * 0.30)
            }
        }
        .ignoresSafeArea()
    }
}

/// Full-colour hero container.
struct HeroCard<Content: View>: View {
    var colors: [Color]
    var stars = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background {
                ZStack {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color.white.opacity(0.10)).frame(width: 220).offset(x: 130, y: -90)
                    Circle().fill(Color.white.opacity(0.06)).frame(width: 160).offset(x: -140, y: 110)
                    if stars { Starfield() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .shadow(color: (colors.last ?? .black).opacity(0.35), radius: 18, y: 8)
    }
}

struct Starfield: View {
    var body: some View {
        Canvas { ctx, size in
            var g = SystemRandomNumberGenerator()
            var seed: UInt64 = 42
            func r() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            _ = g.next()
            for _ in 0..<40 {
                let x = r() * size.width, y = r() * size.height, d = 1 + r() * 1.8
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(.white.opacity(0.25 + r() * 0.5)))
            }
        }
    }
}
