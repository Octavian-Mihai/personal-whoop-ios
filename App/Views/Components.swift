import SwiftUI
import Charts
import StrandAnalytics

extension Color {
    static func band(_ b: ChargeBand) -> Color { b.gradient[1] }
    static let screenBG = Color(.systemGroupedBackground)
    static let cardBG = Color(.secondarySystemGroupedBackground)
}

/// Set by the snapshot exporter so animated gauges render at their final value.
enum SnapshotMode { nonisolated(unsafe) static var on = false }

enum Palette {
    static let ink = Color(red: 0.17, green: 0.20, blue: 0.30)
    static let mint = [Color(red: 0.74, green: 0.92, blue: 0.82), Color(red: 0.55, green: 0.82, blue: 0.70)]
    static let butter = [Color(red: 0.99, green: 0.92, blue: 0.70), Color(red: 0.96, green: 0.80, blue: 0.58)]
    static let rose = [Color(red: 0.98, green: 0.78, blue: 0.78), Color(red: 0.92, green: 0.62, blue: 0.68)]
    static let sky = [Color(red: 0.76, green: 0.86, blue: 0.98), Color(red: 0.58, green: 0.72, blue: 0.93)]
    static let lavender = [Color(red: 0.84, green: 0.78, blue: 0.97), Color(red: 0.69, green: 0.62, blue: 0.90)]
    static let peach = [Color(red: 0.99, green: 0.82, blue: 0.70), Color(red: 0.95, green: 0.68, blue: 0.60)]
    static let aqua = [Color(red: 0.74, green: 0.92, blue: 0.93), Color(red: 0.55, green: 0.80, blue: 0.84)]
    // Fuller-bodied tones for the headline Charge / Effort / Rest gauges.
    static let mintRich = [Color(red: 0.38, green: 0.78, blue: 0.60), Color(red: 0.20, green: 0.60, blue: 0.46)]
    static let butterRich = [Color(red: 0.96, green: 0.76, blue: 0.32), Color(red: 0.86, green: 0.55, blue: 0.18)]
    static let roseRich = [Color(red: 0.94, green: 0.52, blue: 0.54), Color(red: 0.80, green: 0.30, blue: 0.42)]
    static let skyRich = [Color(red: 0.45, green: 0.66, blue: 0.96), Color(red: 0.25, green: 0.45, blue: 0.86)]
    static let lavenderRich = [Color(red: 0.66, green: 0.54, blue: 0.94), Color(red: 0.46, green: 0.32, blue: 0.82)]
    static let sage = Color(red: 0.42, green: 0.70, blue: 0.58)
    static let clay = Color(red: 0.90, green: 0.55, blue: 0.45)
}

extension ChargeBand {
    var gradient: [Color] { self == .green ? Palette.mintRich : (self == .yellow ? Palette.butterRich : Palette.roseRich) }
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
    var textColor: Color? = nil
    @State private var shown = 0.0

    init(value: Double?, color: Color, label: String, unit: String = "", size: CGFloat = 96) {
        self.value = value; self.colors = [color.opacity(0.7), color]; self.label = label; self.unit = unit; self.size = size
        _shown = State(initialValue: SnapshotMode.on ? (value ?? 0) : 0)
    }
    init(value: Double?, colors: [Color], label: String, unit: String = "", size: CGFloat = 96, onDark: Bool = false, textColor: Color? = nil) {
        self.value = value; self.colors = colors; self.label = label; self.unit = unit; self.size = size; self.onDark = onDark; self.textColor = textColor
        _shown = State(initialValue: SnapshotMode.on ? (value ?? 0) : 0)
    }

    var body: some View {
        let lw = lineWidth ?? size * 0.11
        let sweep = 0.75   // 270° gauge, opening at the bottom
        let fg = textColor ?? (onDark ? Color.white : Color.primary)
        ZStack {
            Circle().trim(from: 0, to: sweep)
                .stroke(onDark ? Color.white.opacity(0.35) : (colors.last ?? .gray).opacity(0.22), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: sweep * shown / 100)
                .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: (colors.last ?? .gray).opacity(onDark ? 0.0 : 0.30), radius: size * 0.06)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.system(size: size * 0.12, weight: .semibold)).opacity(0.7) }
            }
            .foregroundStyle(fg)
            .offset(y: -size * 0.02)
            if !label.isEmpty {
                Text(label.uppercased()).font(.system(size: max(9, size * 0.10), weight: .semibold)).tracking(1.2)
                    .foregroundStyle(fg.opacity(0.7))
                    .offset(y: size * 0.40)
            }
        }
        .frame(width: size, height: size)
        .padding(.bottom, size * 0.04)
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
                Capsule().fill(points >= 0 ? Palette.sage : Palette.clay)
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
                Circle().fill(Palette.lavender[0].opacity(0.25)).frame(width: g.size.width * 0.8).blur(radius: 80).offset(x: -g.size.width * 0.45, y: g.size.height * 0.30)
            }
        }
        .ignoresSafeArea()
    }
}

/// Full-colour hero container.
struct HeroCard<Content: View>: View {
    var colors: [Color]
    var stars = false
    var decor = true
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background {
                ZStack {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    if decor {
                        Circle().fill(Color.white.opacity(0.10)).frame(width: 220).offset(x: 130, y: -90)
                        Circle().fill(Color.white.opacity(0.06)).frame(width: 160).offset(x: -140, y: 110)
                    }
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

/// One-line vital: icon, value, delta vs norm. Used in compact layouts.
struct VitalRow: View {
    var icon: String
    var label: String
    var value: String
    var delta: Double?
    var deltaFormat: String = "%+.0f"
    var higherIsBetter = true
    var onDark = false
    /// Filled white chip with the metric's own colour (used on top of the green Charge card).
    var chip = false
    var tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(chip ? tint : tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(chip ? tint.opacity(0.85) : (onDark ? Color.white.opacity(0.8) : .secondary))
                Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(chip ? Palette.ink : (onDark ? Color.white : Color.primary))
            }
            Spacer(minLength: 2)
            if let d = delta, abs(d) > 0.0001 {
                let good = (d > 0) == higherIsBetter
                Label(String(format: deltaFormat, d), systemImage: d > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(chip ? (good ? Palette.sage : Palette.clay) : (onDark ? Color.white : (good ? Palette.sage : Palette.clay)))
            }
        }
        .padding(.horizontal, chip ? 10 : 0).padding(.vertical, chip ? 5 : 0)
        .background { if chip { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.92)) } }
        .contentShape(Rectangle())
    }
}
/// Strap battery at a glance. Shows the live value when connected, otherwise the last reading with its age.
struct BatteryPill: View {
    var percent: Double?
    var live: Bool
    var lastSeen: Date?
    var hoursLeft: Double?

    private var symbol: String {
        guard let p = percent else { return "battery.0percent" }
        return p > 87 ? "battery.100percent" : (p > 62 ? "battery.75percent" : (p > 37 ? "battery.50percent" : (p > 12 ? "battery.25percent" : "battery.0percent")))
    }
    private var tint: Color {
        guard let p = percent else { return .secondary }
        return p <= 15 ? Palette.clay : (p <= 30 ? Palette.butterRich[1] : Palette.sage)
    }
    static func format(_ h: Double) -> String {
        h >= 48 ? String(format: "%.1f d", h / 24) : String(format: "%.0f h", max(1, h))
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(tint)
            if let p = percent {
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.0f%%", p)).font(.subheadline.weight(.semibold).monospacedDigit())
                    if let h = hoursLeft {
                        Text("~\(Self.format(h)) to 0%").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if !live, let t = lastSeen {
                        Text("seen ") .font(.system(size: 9)).foregroundStyle(.secondary)
                            + Text(t, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(live ? "Reading…" : "Connect").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(.primary)
    }
}

/// Heart-rate evolution over a time window (a day, or a night), bucket-averaged so long ranges stay light.
struct HeartRateChart: View {
    var samples: [HRSample]
    var from: Date
    var to: Date
    var emptyText = "No heart-rate data for this period yet."

    private var points: [(t: Date, bpm: Double)] {
        let s = samples.filter { $0.t >= from.timeIntervalSince1970 && $0.t <= to.timeIntervalSince1970 && $0.bpm > 25 && $0.bpm < 230 }
        let bucket = max(60, (to.timeIntervalSince(from) / 240).rounded())
        var sums: [Int: (n: Double, sum: Double)] = [:]
        for x in s { let k = Int((x.t - from.timeIntervalSince1970) / bucket); sums[k, default: (0, 0)].n += 1; sums[k, default: (0, 0)].sum += x.bpm }
        return sums.keys.sorted().map { k in (from.addingTimeInterval((Double(k) + 0.5) * bucket), sums[k]!.sum / sums[k]!.n) }
    }

    var body: some View {
        let pts = points
        if pts.count < 2 {
            Text(emptyText).font(.footnote).foregroundStyle(.secondary)
        } else {
            let lo = pts.map(\.bpm).min()!, hi = pts.map(\.bpm).max()!
            let avg = pts.map(\.bpm).reduce(0, +) / Double(pts.count)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stat(label: "Low", value: String(format: "%.0f", lo))
                    Stat(label: "Average", value: String(format: "%.0f", avg))
                    Stat(label: "High", value: String(format: "%.0f", hi))
                }
                Chart(pts, id: \.t) { p in
                    LineMark(x: .value("Time", p.t), y: .value("bpm", p.bpm)).interpolationMethod(.monotone).foregroundStyle(Color.red.gradient)
                }
                .chartXScale(domain: from...to)
                .chartYScale(domain: max(30, lo - 8)...(hi + 8))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 160)
            }
        }
    }
}
