import SwiftUI
import UIKit
import Charts
import StrandAnalytics

struct SleepView: View {
    @Environment(AppModel.self) private var model

    /// Evening and small hours open on "Tonight" (marks + alarm); the rest of the day opens on last night's data.
    @State private var tonight: Bool = { let h = Calendar.current.component(.hour, from: Date()); return h >= 19 || h < 4 }()

    var content: some View {
            VStack(spacing: 14) {
                Picker("", selection: $tonight) {
                    Text("Last night").tag(false)
                    Text("Tonight").tag(true)
                }.pickerStyle(.segmented)

                if tonight {
                    marksCard
                    alarmCard
                } else {
                    if let n = model.lastNight { hypnogram(n); metrics(n) }
                    else { Card { Text("No staged night yet — wear the strap overnight.").font(.footnote) } }
                    needDebt
                    stageTrend
                }
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

    private var marksCard: some View {
        let m = model.markedNight
        let asleep = model.isMarkedAsleep
        func t(_ x: Double) -> String { Date(timeIntervalSince1970: x).formatted(date: .omitted, time: .shortened) }
        return Card {
            HStack(spacing: 8) {
                Button { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); withAnimation { model.markBed() } } label: {
                    Label("Going to bed", systemImage: "bed.double.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Palette.lavenderRich[1]).controlSize(.small).disabled(asleep)
                Button { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); withAnimation { model.markWake() } } label: {
                    Label("I woke up", systemImage: "sun.max.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Palette.butterRich[1]).controlSize(.small)
            }
            HStack(spacing: 6) {
                Group {
                    if asleep, let b = m.bed { Label("Sleeping since \(t(b))", systemImage: "zzz") }
                    else if let b = m.bed, let w = m.wake { Label("Bed \(t(b)) · up \(t(w)) · \(fmtDuration((w - b) / 60))", systemImage: "checkmark.circle") }
                    else if let w = m.wake { Label("Woke up \(t(w))", systemImage: "checkmark.circle") }
                    else { Label("Mark when you sleep and wake to sharpen detection", systemImage: "moon.zzz") }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if !(model.snapshot.sleepMarks ?? []).isEmpty { Button("Undo") { model.undoLastMark() }.font(.caption2.weight(.semibold)) }
            }
        }
    }

    private var alarmCard: some View {
        let a = model.settings.alarm
        let next = model.nextAlarm
        return Card(title: "Morning alarm", subtitle: nil, icon: "alarm.fill") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Calendar.current.date(bySettingHour: a.wakeMinute / 60, minute: a.wakeMinute % 60, second: 0, of: Date())!, format: .dateTime.hour().minute())
                        .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(a.enabled ? Color.primary : Color.secondary)
                        .overlay {   // the big time is the picker: tap it to change the wake time
                            DatePicker("", selection: Binding(
                                get: { Calendar.current.date(bySettingHour: a.wakeMinute / 60, minute: a.wakeMinute % 60, second: 0, of: Date())! },
                                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); model.settings.alarm.wakeMinute = c.hour! * 60 + c.minute!; model.applyAlarm() }),
                                displayedComponents: .hourAndMinute).labelsHidden().colorMultiply(.clear)
                        }
                    Text(next.map { model.snoozeUntil != nil ? "Rings again \($0.formatted(date: .omitted, time: .shortened))" : "Next: \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "Off")
                        .font(.caption).foregroundStyle(model.snoozeUntil != nil ? Palette.clay : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { a.enabled }, set: { model.settings.alarm.enabled = $0; model.applyAlarm() })).labelsHidden()
            }
            WeekdayPicker()
            HStack {
                Label(a.snooze ? "Rings again \(a.snoozeMinutes) min after, up to \(SmartAlarm.maxSnoozes)×" : "No snooze", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.snoozeUntil != nil {
                    Button("Stop") { model.stopSnooze() }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    NavigationLink("More options") { AlarmView() }.font(.caption.weight(.semibold))
                }
            }
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
