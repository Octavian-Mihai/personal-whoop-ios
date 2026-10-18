import SwiftUI
import Charts
import StrandAnalytics

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @State private var range = 30
    @State private var detail: MetricKind?

    private var slice: [DailyMetric] { Array(model.days.suffix(range)) }

    var content: some View {
            VStack(spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("7d").tag(7); Text("14d").tag(14); Text("30d").tag(30); Text("60d").tag(60)
                }.pickerStyle(.segmented)

                tileGrid
                loadCard
                digestCard
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
            .background { AmbientBackground(tint: Palette.mint[0]) }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $detail) { MetricDetailView(kind: $0).environment(model) }
        }
    }

    private var tileGrid: some View {
        let kinds: [MetricKind] = [.charge, .rest, .effort, .hrv, .restingHR, .respiration]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(kinds) { k in
                let vals = slice.compactMap { $0[keyPath: k.keyPath] }
                let s = Summary.of(vals)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: k.icon).font(.caption2).foregroundStyle(k.colors[1])
                        Text(k.title.replacingOccurrences(of: "Heart-rate variability", with: "HRV").replacingOccurrences(of: "Resting heart rate", with: "Resting HR")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(s.map { String(format: k == .respiration ? "%.1f" : "%.0f", $0.mean) + k.unit } ?? "—").font(.title3.weight(.semibold).monospacedDigit())
                    if vals.count > 1 { Sparkline(values: vals, color: k.colors[1]).frame(height: 34) }
                else { Text("No data yet").font(.caption2).foregroundStyle(.tertiary).frame(height: 34, alignment: .bottomLeading) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .contentShape(Rectangle()).onTapGesture { detail = k }
            }
        }
    }

    private var loadCard: some View {
        Card(title: "Fitness · Fatigue · Form", subtitle: "Banister model on daily Effort (τ 42 d / 7 d)") {
            if model.trainingLoad.isEmpty { Text("Needs a contiguous run of scored days").font(.footnote) }
            else {
                Chart {
                    ForEach(model.trainingLoad) { p in
                        LineMark(x: .value("Day", p.index), y: .value("v", p.fitness), series: .value("s", "Fitness")).foregroundStyle(Palette.skyRich[1]).interpolationMethod(.catmullRom)
                        LineMark(x: .value("Day", p.index), y: .value("v", p.fatigue), series: .value("s", "Fatigue")).foregroundStyle(Palette.peach[1]).interpolationMethod(.catmullRom)
                    }
                }.frame(height: 140)
                HStack(spacing: 14) {
                    HStack(spacing: 5) { Circle().fill(Palette.skyRich[1]).frame(width: 8, height: 8); Text("Fitness (42 d)").font(.caption2).foregroundStyle(.secondary) }
                    HStack(spacing: 5) { Circle().fill(Palette.peach[1]).frame(width: 8, height: 8); Text("Fatigue (7 d)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    if let l = model.trainingLoad.last { Text(String(format: "Form %+.1f", l.form)).font(.footnote.weight(.semibold).monospacedDigit()) }
                }
            }
        }
    }

    private var digestCard: some View {
        Card(title: "Week in review") {
            if let d = model.digest {
                ForEach(d.focal, id: \.self) { Text($0).font(.subheadline) }
                Text("Balance: \(d.balance)").font(.caption).foregroundStyle(.secondary)
                ForEach(d.movers, id: \.metric) { m in
                    HStack { Text(m.metric); Spacer(); Text(String(format: "%+.1f", m.delta)).monospacedDigit() }.font(.caption)
                }
            }
        }
    }
}
