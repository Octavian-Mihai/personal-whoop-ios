import SwiftUI
import Charts
import StrandAnalytics

struct SleepView: View {
    @Environment(AppModel.self) private var model

    var content: some View {
            VStack(spacing: 14) {
                if let n = model.lastNight { hypnogram(n); metrics(n) }
                else { Card { Text("No staged night yet — wear the strap overnight.").font(.footnote) } }
                needDebt
                stageTrend
                Disclaimer()
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
    }

    var snapshot = false

    var body: some View {
        if snapshot { content } else { regular }
    }

    private var regular: some View {
        NavigationStack {
            ScrollView { content }
            .background { AmbientBackground(tint: Palette.lavenderRich[0]) }
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func level(_ s: SleepStage) -> Double { [SleepStage.awake: 3, .rem: 2, .light: 1, .deep: 0][s] ?? 1 }
    private func color(_ s: SleepStage) -> Color { [SleepStage.awake: Color(red: 0.98, green: 0.66, blue: 0.48), .rem: Color(red: 0.80, green: 0.60, blue: 0.98), .light: Color(red: 0.45, green: 0.72, blue: 0.98), .deep: Color(red: 0.42, green: 0.45, blue: 0.92)][s] ?? .gray }

    private func hypnogram(_ n: SleepSession) -> some View {
        let m = HypnogramMetrics(session: n)
        return HeroCard(colors: [Color(red: 0.10, green: 0.13, blue: 0.32), Color(red: 0.30, green: 0.22, blue: 0.58)], stars: true, decor: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Last night", systemImage: "moon.stars.fill").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        Text(fmtDuration(m.tst)).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("\(fmtClock(n.start)) – \(fmtClock(n.end)) · \(String(format: "%.0f%%", m.efficiency * 100)) efficient")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Ring(value: model.today?.rest, colors: [Palette.lavender[0], .white], label: "Rest", unit: "%", size: 96, onDark: true)
                }
                Chart(Array(n.segments.enumerated()), id: \.offset) { _, s in
                    RectangleMark(xStart: .value("s", Date(timeIntervalSince1970: s.start)), xEnd: .value("e", Date(timeIntervalSince1970: s.end)),
                                  yStart: .value("l", level(s.stage)), yEnd: .value("h", level(s.stage) + 0.8))
                        .foregroundStyle(color(s.stage)).cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(values: [0.4, 1.4, 2.4, 3.4]) { v in
                        AxisValueLabel { Text(["Deep", "Light", "REM", "Awake"][min(3, Int(v.as(Double.self) ?? 0))]).foregroundStyle(.white.opacity(0.7)) }
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.7)) } }
                .chartYScale(domain: 0...4).frame(height: 150)
                HStack(spacing: 14) {
                    ForEach([SleepStage.awake, .rem, .light, .deep], id: \.self) { st in
                        HStack(spacing: 5) { Circle().fill(color(st)).frame(width: 8, height: 8); Text(st.rawValue.capitalized).font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                    }
                }
            }
        }
    }

    private func metrics(_ n: SleepSession) -> some View {
        let m = HypnogramMetrics(session: n)
        let rest = model.today?.rest
        return Card(title: "Night metrics") {
            HStack {
                Stat(label: "Rest", value: rest.map { String(format: "%.0f%%", $0) } ?? "—")
                Stat(label: "Asleep", value: fmtDuration(m.tst))
                Stat(label: "Efficiency", value: String(format: "%.0f%%", m.efficiency * 100))
            }
            HStack {
                Stat(label: "Deep", value: fmtDuration(n.minutes(.deep)), sub: pct(n.minutes(.deep), m.tst))
                Stat(label: "REM", value: fmtDuration(n.minutes(.rem)), sub: pct(n.minutes(.rem), m.tst))
                Stat(label: "Light", value: fmtDuration(n.minutes(.light)), sub: pct(n.minutes(.light), m.tst))
            }
            Divider()
            moreMetrics(n, m)
        }
    }

    @ViewBuilder private func moreMetrics(_ n: SleepSession, _ m: HypnogramMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Stat(label: "Latency", value: String(format: "%.0f min", m.sol))
                Stat(label: "REM latency", value: m.remLatency.map { String(format: "%.0f min", $0) } ?? "—")
                Stat(label: "WASO", value: String(format: "%.0f min", m.waso))
                Stat(label: "Wakes", value: "\(m.disturbances)")
            }
            HStack {
                Stat(label: "Resting HR", value: n.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—")
                Stat(label: "Night HRV", value: n.hrv.map { String(format: "%.0f ms", $0) } ?? "—")
            }
            Text("Deep vs light is the weakest staging output — treat it as an estimate.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pct(_ x: Double, _ total: Double) -> String { total > 0 ? String(format: "%.0f%%", x / total * 100) : "" }

    private var needDebt: some View {
        Card(title: "Sleep need & debt") {
            HStack {
                Stat(label: "Need", value: fmtDuration(model.sleepNeedMin))
                Stat(label: "Debt", value: model.sleepDebtMin == 0 ? "Balanced" : fmtDuration(model.sleepDebtMin))
            }
            Text("Need is the 75th percentile of your recent nights (floored at 8 h, capped at 9.5 h).").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var stageTrend: some View {
        Card(title: "Last 14 nights") {
            Chart {
                ForEach(model.days.suffix(14)) { d in
                    if let v = d.deepMin { BarMark(x: .value("Day", d.date, unit: .day), y: .value("min", v)).foregroundStyle(by: .value("Stage", "Deep")) }
                    if let v = d.remMin { BarMark(x: .value("Day", d.date, unit: .day), y: .value("min", v)).foregroundStyle(by: .value("Stage", "REM")) }
                    if let v = d.lightMin { BarMark(x: .value("Day", d.date, unit: .day), y: .value("min", v)).foregroundStyle(by: .value("Stage", "Light")) }
                }
            }
            .chartForegroundStyleScale(["Deep": Color.indigo, "REM": Color.purple, "Light": Color.blue])
            .frame(height: 180)
        }
    }
}
