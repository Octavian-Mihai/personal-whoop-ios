import SwiftUI
import Charts
import StrandAnalytics

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @State private var range = 30
    @State private var detail: MetricKind?
    private var compact: Bool { model.isCompact("trends") }

    private var slice: [DailyMetric] { Array(model.days.suffix(range)) }

    var content: some View {
            VStack(spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("30d").tag(30); Text("60d").tag(60)
                }.pickerStyle(.segmented)

                if compact { tileGrid } else {
                    line("Charge", \.charge, .green, "charge")
                    line("HRV (ms)", \.hrv, .teal, "hrv")
                    line("Resting HR (bpm)", \.restingHR, .red, "rhr")
                    line("Effort", \.effort, .blue, "effort")
                    line("Rest", \.rest, .purple, "")
                }
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
                    Sparkline(values: vals, color: k.colors[1]).frame(height: 34)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .contentShape(Rectangle()).onTapGesture { detail = k }
            }
        }
    }

    private func line(_ title: String, _ kp: KeyPath<DailyMetric, Double?>, _ color: Color, _ key: String) -> some View {
        let vals = slice.compactMap { $0[keyPath: kp] }
        let s = Summary.of(vals)
        let dir = key.isEmpty ? TrendDirection.flat : RangeReport.trend(key, values: vals)
        return Card(title: title, subtitle: s.map { String(format: "mean %.1f · min %.0f · max %.0f", $0.mean, $0.min, $0.max) }) {
            Chart(slice) { d in
                if let v = d[keyPath: kp] { LineMark(x: .value("Day", d.date), y: .value(title, v)).foregroundStyle(color).interpolationMethod(.catmullRom) }
            }
            .chartYScale(domain: .automatic(includesZero: false)).frame(height: 120)
            if !key.isEmpty {
                let lowerBetter = key == "rhr"
                let good = (dir == .up && !lowerBetter) || (dir == .down && lowerBetter)
                Label(dir == .flat ? "Flat" : (dir == .up ? "Trending up" : "Trending down"),
                      systemImage: dir == .flat ? "arrow.right" : (dir == .up ? "arrow.up.right" : "arrow.down.right"))
                    .font(.caption).foregroundStyle(dir == .flat ? Color.secondary : (good ? .green : .orange))
            }
        }
    }

    private var loadCard: some View {
        Card(title: "Fitness · Fatigue · Form", subtitle: "Banister model on daily Effort (τ 42 d / 7 d)") {
            if model.trainingLoad.isEmpty { Text("Needs a contiguous run of scored days").font(.footnote) }
            else {
                Chart {
                    ForEach(model.trainingLoad) { p in
                        LineMark(x: .value("Day", p.index), y: .value("v", p.fitness), series: .value("s", "Fitness")).foregroundStyle(.blue)
                        LineMark(x: .value("Day", p.index), y: .value("v", p.fatigue), series: .value("s", "Fatigue")).foregroundStyle(.orange)
                    }
                }.frame(height: 140)
                if let l = model.trainingLoad.last { Text(String(format: "Form (TSB): %+.1f", l.form)).font(.footnote.monospacedDigit()) }
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
