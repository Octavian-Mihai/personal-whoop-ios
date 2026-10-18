import SwiftUI
import WidgetKit

/// 270° gauge used by the home-screen widgets.
struct WGauge: View {
    var value: Double?
    var colors: [Color]
    var label: String
    var size: CGFloat
    var onDark = false
    var body: some View {
        let lw = size * 0.12
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(onDark ? Color.white.opacity(0.3) : colors[1].opacity(0.22), style: StrokeStyle(lineWidth: lw, lineCap: .round)).rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * min(1, max(0, (value ?? 0) / 100)))
                .stroke(onDark ? Color.white : colors[1], style: StrokeStyle(lineWidth: lw, lineCap: .round)).rotationEffect(.degrees(135))
            Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: size * 0.34, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(onDark ? .white : .primary).offset(y: -size * 0.02)
            Text(label.uppercased()).font(.system(size: max(8, size * 0.105), weight: .semibold)).tracking(1)
                .foregroundStyle(onDark ? Color.white.opacity(0.8) : .secondary).offset(y: size * 0.40)
        }
        .frame(width: size, height: size)
    }
}

struct BatteryLabel: View {
    var percent: Double?
    var at: Date?
    var onDark = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: WTheme.batterySymbol(percent)).foregroundStyle(onDark ? Color.white : WTheme.battery(percent))
            if let p = percent { Text(String(format: "%.0f%%", p)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(onDark ? Color.white : Color.primary).lineLimit(1).fixedSize() }
            else { Text("—").font(.caption) }
        }
    }
}

/// Body of the "Today" widget for every supported size.
struct TodayWidgetContent: View {
    var snap: WidgetSnapshot
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            WGauge(value: snap.charge, colors: WTheme.mint, label: "Charge", size: 104, onDark: true)
            HStack { BatteryLabel(percent: snap.batteryPercent, at: snap.batteryAt, onDark: true); Spacer() }
        }
    }

    private var medium: some View {
        HStack(spacing: 10) {
            WGauge(value: snap.charge, colors: WTheme.mint, label: "Charge", size: 104, onDark: true)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    mini(snap.effort, "Effort")
                    mini(snap.rest, "Rest")
                }
                HStack {
                    BatteryLabel(percent: snap.batteryPercent, at: snap.batteryAt, onDark: true)
                    Spacer()
                    if let h = snap.hrv { Text("HRV \(Int(h))").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9)) }
                    if let r = snap.restingHR { Text("RHR \(Int(r))").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9)) }
                }
            }
        }
    }

    private func mini(_ v: Double?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v.map { String(format: "%.0f", $0) } ?? "—").font(.title2.bold().monospacedDigit()).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var circular: some View {
        Gauge(value: (snap.charge ?? 0) / 100) { Text("CHG") } currentValueLabel: { Text(snap.charge.map { String(format: "%.0f", $0) } ?? "—") }
            .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.caption2)
                Text("Charge \(snap.charge.map { String(format: "%.0f%%", $0) } ?? "—")").font(.headline)
            }
            Text("Effort \(snap.effort.map { String(format: "%.0f", $0) } ?? "—") · Rest \(snap.rest.map { String(format: "%.0f%%", $0) } ?? "—")").font(.caption)
            HStack(spacing: 3) {
                Image(systemName: WTheme.batterySymbol(snap.batteryPercent)).font(.caption2)
                Text(snap.batteryPercent.map { String(format: "Strap %.0f%%", $0) } ?? "Strap —").font(.caption)
            }
        }
    }

    private var inline: some View {
        Text("Charge \(snap.charge.map { String(format: "%.0f%%", $0) } ?? "—") · Strap \(snap.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
    }
}

/// Body of the "Strap" widget: battery and next alarm.
struct StrapWidgetContent: View {
    var snap: WidgetSnapshot
    var family: WidgetFamily

    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: (snap.batteryPercent ?? 0) / 100) { Image(systemName: "applewatch") } currentValueLabel: {
                Text(snap.batteryPercent.map { String(format: "%.0f", $0) } ?? "—")
            }.gaugeStyle(.accessoryCircular)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: WTheme.batterySymbol(snap.batteryPercent)).font(.title2).foregroundStyle(WTheme.battery(snap.batteryPercent))
                    Text(snap.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                }
                if let at = snap.batteryAt { Text("Strap · seen ") .font(.caption2).foregroundStyle(.secondary) + Text(at, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Image(systemName: "alarm.fill").font(.caption).foregroundStyle(WTheme.lavender[1])
                    if let a = snap.nextAlarm { Text(a, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption.weight(.semibold)) }
                    else { Text("No alarm").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
