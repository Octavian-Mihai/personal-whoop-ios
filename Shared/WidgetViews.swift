import SwiftUI
import WidgetKit

// MARK: - building blocks

/// 270° gauge.
struct WGauge: View {
    var value: Double?
    var colors: [Color]
    var label: String
    var size: CGFloat
    var onDark = false
    var unit = ""
    var body: some View {
        let lw = size * 0.12
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(onDark ? Color.white.opacity(0.3) : colors[1].opacity(0.22), style: StrokeStyle(lineWidth: lw, lineCap: .round)).rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * min(1, max(0, (value ?? 0) / 100)))
                .stroke(onDark ? Color.white : colors[1], style: StrokeStyle(lineWidth: lw, lineCap: .round)).rotationEffect(.degrees(135))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: size * 0.34, weight: .bold, design: .rounded)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.system(size: size * 0.13, weight: .semibold)).opacity(0.7) }
            }
            .foregroundStyle(onDark ? .white : .primary).offset(y: -size * 0.02)
            Text(label.uppercased()).font(.system(size: max(7, size * 0.105), weight: .bold)).tracking(0.8)
                .foregroundStyle(onDark ? Color.white.opacity(0.85) : .secondary).offset(y: size * 0.40)
        }
        .frame(width: size, height: size)
    }
}

/// Smooth-ish line for a short series (nil days are skipped).
struct WSpark: View {
    var values: [Double?]
    var color: Color
    var body: some View {
        GeometryReader { g in
            let pts = points(g.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in p.move(to: CGPoint(x: pts[0].x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath() }
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(color).frame(width: 5, height: 5).position(pts.last!)
                }
            }
        }
    }
    private func points(_ size: CGSize) -> [CGPoint] {
        let present = values.enumerated().compactMap { i, v in v.map { (i, $0) } }
        guard present.count > 1, let lo = present.map(\.1).min(), let hi = present.map(\.1).max() else { return [] }
        let span = max(hi - lo, 1), n = max(values.count - 1, 1)
        return present.map { i, v in CGPoint(x: size.width * CGFloat(i) / CGFloat(n), y: size.height - 3 - (size.height - 8) * CGFloat((v - lo) / span)) }
    }
}

/// Seven small bars with weekday initials; today is the last bar.
struct WBars: View {
    var values: [Double?]
    var color: Color
    var body: some View {
        let cal = Calendar.current
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                let day = cal.date(byAdding: .day, value: i - (values.count - 1), to: Date()) ?? Date()
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15))
                        if let v { RoundedRectangle(cornerRadius: 3).fill(i == values.count - 1 ? color : color.opacity(0.55)).frame(height: max(3, 46 * min(1, v / 100))) }
                    }.frame(height: 46)
                    Text(String(day.formatted(.dateTime.weekday(.narrow)))).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Deep / REM / light / awake proportions.
struct WStageBar: View {
    var snap: WidgetSnapshot
    var height: CGFloat = 8
    var body: some View {
        let parts: [(Double, Color)] = [(snap.deepMin ?? 0, WTheme.deep), (snap.remMin ?? 0, WTheme.rem), (snap.lightMin ?? 0, WTheme.light), (snap.awakeMin ?? 0, WTheme.awake)]
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 { RoundedRectangle(cornerRadius: 2).fill(p.1).frame(width: max(2, (g.size.width - 6) * CGFloat(p.0 / total))) }
                }
            }
        }.frame(height: height)
    }
}

struct BatteryLabel: View {
    var percent: Double?
    var onDark = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: WTheme.batterySymbol(percent)).foregroundStyle(onDark ? Color.white : WTheme.battery(percent))
            Text(percent.map { String(format: "%.0f%%", $0) } ?? "—").font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(onDark ? Color.white : Color.primary).lineLimit(1).fixedSize()
        }
    }
}

/// Value over label, optionally on a frosted chip.
struct WStat: View {
    var value: String
    var label: String
    var tint: Color = .primary
    var onDark = false
    var chip = false
    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(onDark ? Color.white : tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(onDark ? Color.white.opacity(0.85) : Color.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background { if chip { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(onDark ? Color.white.opacity(0.2) : tint.opacity(0.12)) } }
    }
}

func wDur(_ minutes: Double?) -> String { guard let m = minutes else { return "—" }; return "\(Int(m.rounded()) / 60)h \(Int(m.rounded()) % 60)m" }
/// "48m" under an hour, otherwise "1h 05m" — for tight spaces.
func wShort(_ minutes: Double?) -> String {
    guard let m = minutes else { return "—" }
    let t = Int(m.rounded()); return t < 60 ? "\(t)m" : "\(t / 60)h \(String(format: "%02d", t % 60))m"
}
func wPct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }
func wNum(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
func wTime(_ d: Date?) -> String { d.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—" }

// MARK: - Today widget

struct TodayWidgetContent: View {
    var snap: WidgetSnapshot
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .systemLarge: large
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    // 158 × 158
    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                WGauge(value: snap.charge, colors: WTheme.mint, label: "Charge", size: 68, onDark: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WTheme.band(snap.charge)).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    line("Effort", wNum(snap.effort))
                    line("Rest", wNum(snap.rest))
                }
            }
            WSpark(values: snap.chargeSeries ?? [], color: .white).frame(height: 24)
            HStack(spacing: 6) {
                Text("HRV \(wNum(snap.hrv))").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                Text("RHR \(wNum(snap.restingHR))").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                BatteryLabel(percent: snap.batteryPercent, onDark: true)
            }
        }
        .padding(12)
    }

    private func line(_ l: String, _ v: String) -> some View {
        HStack(spacing: 4) { Text(l).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85)); Spacer(minLength: 0); Text(v).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white) }
    }

    // 338 × 158
    private var medium: some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                WGauge(value: snap.charge, colors: WTheme.mint, label: "Charge", size: 92, onDark: true)
                Text(WTheme.band(snap.charge)).font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                HStack(spacing: 5) { WStat(value: wNum(snap.effort), label: "Effort", onDark: true, chip: true); WStat(value: wPct(snap.rest), label: "Rest", onDark: true, chip: true); WStat(value: snap.stress.map { String(format: "%.1f", $0) } ?? "—", label: "Stress", onDark: true, chip: true) }
                HStack(spacing: 5) { WStat(value: wNum(snap.hrv), label: "HRV ms", onDark: true, chip: true); WStat(value: wNum(snap.restingHR), label: "RHR", onDark: true, chip: true); WStat(value: snap.respiration.map { String(format: "%.1f", $0) } ?? "—", label: "Resp", onDark: true, chip: true) }
                HStack(spacing: 8) {
                    WSpark(values: snap.chargeSeries ?? [], color: .white).frame(height: 20)
                    BatteryLabel(percent: snap.batteryPercent, onDark: true)
                    if let a = snap.nextAlarm { HStack(spacing: 2) { Image(systemName: "alarm.fill").font(.system(size: 9)); Text(a, format: .dateTime.hour().minute()).font(.caption2.weight(.bold)) }.foregroundStyle(.white).fixedSize() }
                }
            }
        }
        .padding(12)
    }

    // 338 × 354, on a light background
    private var large: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Today").font(.headline)
                Text(Date().formatted(.dateTime.weekday(.abbreviated).month().day())).font(.caption).foregroundStyle(.secondary)
                if let s = snap.streak, s > 0 { Label("\(s)", systemImage: "flame.fill").font(.caption2.weight(.bold)).foregroundStyle(WTheme.clay) }
                Spacer()
                BatteryLabel(percent: snap.batteryPercent)
                if let a = snap.nextAlarm { HStack(spacing: 2) { Image(systemName: "alarm.fill").font(.system(size: 10)).foregroundStyle(WTheme.lavender[1]); Text(a, format: .dateTime.hour().minute()).font(.caption2.weight(.bold)) } }
            }
            HStack(spacing: 6) {
                WGauge(value: snap.charge, colors: WTheme.mint, label: "Charge", size: 90, unit: "%").frame(maxWidth: .infinity)
                WGauge(value: snap.effort, colors: WTheme.sky, label: "Effort", size: 90).frame(maxWidth: .infinity)
                WGauge(value: snap.rest, colors: WTheme.lavender, label: "Rest", size: 90, unit: "%").frame(maxWidth: .infinity)
            }
            HStack(spacing: 5) {
                WStat(value: wNum(snap.hrv), label: "HRV ms", tint: WTheme.teal, chip: true)
                WStat(value: wNum(snap.restingHR), label: "Resting HR", tint: WTheme.rose, chip: true)
                WStat(value: snap.respiration.map { String(format: "%.1f", $0) } ?? "—", label: "Resp /min", tint: WTheme.blue, chip: true)
                WStat(value: snap.stress.map { String(format: "%.1f", $0) } ?? "—", label: "Stress 0–3", tint: WTheme.clay, chip: true)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Charge · 7 days").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    WBars(values: snap.chargeSeries ?? [], color: WTheme.mint[1])
                }
                VStack(alignment: .leading, spacing: 5) {
                    row("shoeprints.fill", snap.steps.map { "\($0.formatted()) steps" } ?? "— steps")
                    row("flame.fill", snap.kcal.map { String(format: "%.0f kcal", $0) } ?? "— kcal")
                    row("drop.fill", "\(String(format: "%.1f", Double(snap.hydrationML ?? 0) / 1000)) / \(String(format: "%.1f", Double(snap.hydrationGoalML ?? 0) / 1000)) L")
                    if let f = snap.forecast { row("sunrise.fill", String(format: "Tomorrow ~%.0f%%", f)) }
                }.frame(width: 118)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "moon.stars.fill").font(.caption2).foregroundStyle(WTheme.lavender[1])
                    Text("Slept \(wDur(snap.asleepMin))").font(.caption.weight(.bold))
                    Text("· need \(wDur(snap.sleepNeedMin))").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let d = snap.sleepDebtMin, d > 0 { Text("debt \(wDur(d))").font(.caption2.weight(.semibold)).foregroundStyle(WTheme.clay) }
                }
                WStageBar(snap: snap)
            }
        }
        .padding(14)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(WTheme.mint[1]).frame(width: 14); Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
    }

    // lock screen
    private var circular: some View {
        Gauge(value: (snap.charge ?? 0) / 100) { Text("CHG") } currentValueLabel: { Text(wNum(snap.charge)) }.gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Charge \(wPct(snap.charge)) · Effort \(wNum(snap.effort))").font(.system(size: 13, weight: .bold))
            Text("Rest \(wPct(snap.rest)) · HRV \(wNum(snap.hrv)) · RHR \(wNum(snap.restingHR))").font(.system(size: 11))
            HStack(spacing: 3) {
                Image(systemName: WTheme.batterySymbol(snap.batteryPercent)).font(.system(size: 10))
                Text("Strap \(wPct(snap.batteryPercent))").font(.system(size: 11))
                if let a = snap.nextAlarm { Image(systemName: "alarm.fill").font(.system(size: 9)); Text(a, format: .dateTime.hour().minute()).font(.system(size: 11)) }
            }
        }
    }

    private var inline: some View {
        Text("Charge \(wPct(snap.charge)) · Effort \(wNum(snap.effort)) · Strap \(wPct(snap.batteryPercent))")
    }
}

// MARK: - Sleep widget

struct SleepWidgetContent: View {
    var snap: WidgetSnapshot
    var family: WidgetFamily

    var body: some View {
        if family == .systemMedium { medium } else { small }
    }

    // 158 × 158, dark
    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Last night", systemImage: "moon.stars.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Text(wDur(snap.asleepMin)).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
            Text("\(wTime(snap.sleepStart)) – \(wTime(snap.sleepEnd))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
            WStageBar(snap: snap)
            HStack(spacing: 6) {
                tag("Rest", wPct(snap.rest))
                tag("Debt", (snap.sleepDebtMin ?? 0) > 0 ? wShort(snap.sleepDebtMin) : "none")
            }
            if let a = snap.nextAlarm { Label(a.formatted(.dateTime.weekday(.abbreviated).hour().minute()), systemImage: "alarm.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white) }
        }
        .padding(12)
    }

    // 338 × 158, dark
    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Last night", systemImage: "moon.stars.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text(wDur(snap.asleepMin)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
                Text("\(wTime(snap.sleepStart)) – \(wTime(snap.sleepEnd))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                WStageBar(snap: snap, height: 10)
                HStack(spacing: 6) { tag("Need", wShort(snap.sleepNeedMin)); tag("Debt", (snap.sleepDebtMin ?? 0) > 0 ? wShort(snap.sleepDebtMin) : "none") }
            }
            VStack(spacing: 6) {
                WGauge(value: snap.rest, colors: WTheme.lavender, label: "Rest", size: 72, onDark: true, unit: "%")
                VStack(alignment: .leading, spacing: 2) {
                    stage(WTheme.deep, "Deep", snap.deepMin); stage(WTheme.rem, "REM", snap.remMin); stage(WTheme.light, "Light", snap.lightMin)
                }
            }.frame(width: 110)
        }
        .padding(12)
    }

    private func stage(_ c: Color, _ n: String, _ m: Double?) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(n).font(.system(size: 9)).foregroundStyle(.white.opacity(0.85)); Spacer(minLength: 0); Text(wDur(m)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
    }

    private func tag(_ l: String, _ v: String) -> some View {
        HStack(spacing: 3) { Text(l).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)); Text(v).font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.18), in: Capsule()).lineLimit(1).fixedSize()
    }
}

// MARK: - Strap widget

struct StrapWidgetContent: View {
    var snap: WidgetSnapshot
    var family: WidgetFamily

    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: (snap.batteryPercent ?? 0) / 100) { Image(systemName: "applewatch") } currentValueLabel: { Text(wNum(snap.batteryPercent)) }.gaugeStyle(.accessoryCircular)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: WTheme.batterySymbol(snap.batteryPercent)).font(.title3).foregroundStyle(WTheme.battery(snap.batteryPercent))
                    Text(wPct(snap.batteryPercent)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                }
                if let at = snap.batteryAt { Text("Strap · seen ").font(.system(size: 9)).foregroundStyle(.secondary) + Text(at, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.system(size: 9)).foregroundStyle(.secondary) }
                Divider()
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(WTheme.rose)
                    if let hr = snap.liveHR, let at = snap.liveHRAt, Date().timeIntervalSince(at) < 600 { Text("\(hr) bpm").font(.system(size: 13, weight: .bold, design: .rounded)) }
                    else { Text("Resting \(wNum(snap.restingHR))").font(.system(size: 12, weight: .semibold)) }
                }
                HStack(spacing: 5) {
                    Image(systemName: "alarm.fill").font(.caption).foregroundStyle(WTheme.lavender[1])
                    if let a = snap.nextAlarm { Text(a, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 12, weight: .semibold)) }
                    else { Text("No alarm").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 5) {
                    Image(systemName: "drop.fill").font(.caption).foregroundStyle(WTheme.blue)
                    Text("\(String(format: "%.1f", Double(snap.hydrationML ?? 0) / 1000)) / \(String(format: "%.1f", Double(snap.hydrationGoalML ?? 0) / 1000)) L").font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(12)
        }
    }
}
