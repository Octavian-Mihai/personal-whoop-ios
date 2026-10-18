import SwiftUI
import Charts
import StrandAnalytics

enum MetricKind: String, Identifiable {
    case charge, effort, rest, hrv, restingHR, respiration, skinTemp, activityBalance
    var id: String { rawValue }

    init?(driverName: String) {
        switch driverName {
        case "HRV": self = .hrv
        case "Resting HR": self = .restingHR
        case "Respiration": self = .respiration
        case "Rest quality": self = .rest
        case "Skin temp": self = .skinTemp
        case "Activity balance": self = .activityBalance
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .charge: return "Charge"; case .effort: return "Effort"; case .rest: return "Rest"
        case .hrv: return "Heart-rate variability"; case .restingHR: return "Resting heart rate"
        case .respiration: return "Respiration"; case .skinTemp: return "Skin temperature"; case .activityBalance: return "Activity balance"
        }
    }
    var icon: String {
        switch self {
        case .charge: return "bolt.fill"; case .effort: return "flame.fill"; case .rest: return "moon.zzz.fill"
        case .hrv: return "waveform.path.ecg"; case .restingHR: return "heart.fill"; case .respiration: return "lungs.fill"
        case .skinTemp: return "thermometer.medium"; case .activityBalance: return "scalemass.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .charge: return Palette.mintRich; case .effort: return Palette.skyRich; case .rest: return Palette.lavenderRich
        case .hrv: return Palette.aqua; case .restingHR: return Palette.rose; case .respiration: return Palette.sky
        case .skinTemp: return Palette.peach; case .activityBalance: return Palette.butter
        }
    }
    var unit: String {
        switch self {
        case .charge, .rest: return "%"; case .effort: return ""; case .hrv: return " ms"; case .restingHR: return " bpm"
        case .respiration: return " /min"; case .skinTemp: return " °C"; case .activityBalance: return ""
        }
    }
    var keyPath: KeyPath<DailyMetric, Double?> {
        switch self {
        case .charge: return \.charge; case .effort, .activityBalance: return \.effort; case .rest: return \.rest
        case .hrv: return \.hrv; case .restingHR: return \.restingHR; case .respiration: return \.respiration; case .skinTemp: return \.skinTempDev
        }
    }
    var isRich: Bool { self == .charge || self == .effort || self == .rest }
    var higherIsBetter: Bool? {
        switch self { case .charge, .rest, .hrv: return true; case .restingHR, .respiration: return false; default: return nil }
    }
    var howItWorks: String {
        switch self {
        case .charge: return "A weighted z-score of tonight's HRV (55 %), resting HR (20 %), Rest (15 %), respiration, skin temperature and the previous day's Effort, each compared with your own 14-night baseline, then squeezed through a logistic curve. A z of 0 lands near 58 %. Bands: below 34 low, 34–66 steady, 67+ primed. Missing inputs are dropped and the rest re-weighted; with fewer than 4 baseline nights it reads Calibrating."
        case .effort: return "Cardiovascular load over the day. Each heart-rate reading is placed in a %HRR zone (Karvonen) and weighted 1–5 for zones from 50 % up (Edwards TRIMP), then log-compressed: 100 · ln(TRIMP + 1) / ln(7201). Easy days sit low; reaching 100 needs zone-5 effort all day. Each reading counts for at most 2 minutes so a dropout can't invent load, and the number never visibly drops during the day."
        case .rest: return "100 × (50 % sleep duration vs your need + 20 % efficiency + 20 % restorative sleep + 10 % consistency). Restorative is deep + REM relative to 50 % of sleep, scaled down by up to half if deep sleep is under 13 %. Your need is the 75th percentile of recent nights, floored at 8 h."
        case .hrv: return "Nightly HRV is the mean RMSSD over 5-minute windows of the night after range and ectopic-beat cleaning. It is compared with your own EWMA baseline (14-night half-life) as a robust z-score, not with a population cutoff. Higher than your norm generally means better recovery."
        case .restingHR: return "The lowest 5-minute average heart rate during your main sleep. Compared with your personal baseline; lower than your norm generally means better recovery, a sustained rise can flag strain or illness."
        case .respiration: return "Breaths per minute during sleep, from the rhythm in beat-to-beat intervals. It's very stable night to night, so small rises against your norm are worth noticing."
        case .skinTemp: return "Nightly wrist skin temperature as a deviation from your own baseline. Charge applies a symmetric penalty for large swings in either direction; sustained rises also feed the illness heads-up."
        case .activityBalance: return "Yesterday's Effort versus your own average Effort. Much harder days than usual pull Charge down a little the next morning; easier days push it up."
        }
    }
}

struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: MetricKind
    @State private var range = 30

    private var days: [DailyMetric] { Array(model.days.suffix(range)) }
    private var values: [Double] { days.compactMap { $0[keyPath: kind.keyPath] } }
    private var today: Double? { model.today?[keyPath: kind.keyPath] }
    private var baseline: Baseline? {
        switch kind {
        case .hrv: return model.baselines?.hrv; case .restingHR: return model.baselines?.restingHR
        case .respiration: return model.baselines?.respiration; default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    chartCard
                    statsCard
                    specifics
                    Card(title: "How it's calculated", icon: "function") {
                        Text(kind.howItWorks).font(.footnote).foregroundStyle(.secondary)
                    }
                    Disclaimer()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background { AmbientBackground(tint: kind.colors[0]) }
            .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func fmt(_ v: Double) -> String {
        switch kind {
        case .respiration: return String(format: "%.1f", v)
        case .skinTemp: return String(format: "%+.2f", v)
        default: return String(format: "%.0f", v)
        }
    }

    private var hero: some View {
        HeroCard(colors: kind.colors) {
            HStack(spacing: 14) {
                Image(systemName: kind.icon).font(.title).foregroundStyle(kind.isRich ? Color.white : Palette.ink)
                    .frame(width: 56, height: 56).background(.white.opacity(0.45), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(today.map { fmt($0) + kind.unit } ?? "—").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(kind.isRich ? Color.white : Palette.ink)
                    Text(verdict).font(.subheadline).foregroundStyle((kind.isRich ? Color.white.opacity(0.85) : Palette.ink.opacity(0.75)))
                }
            }
        }
    }

    private var verdict: String {
        guard let t = today else { return "No reading yet" }
        if kind == .charge { return ChargeBand.of(t).word }
        if let b = baseline, b.isUsable {
            let z = b.z(t)
            let better = kind.higherIsBetter == true ? z > 0.5 : (kind.higherIsBetter == false ? z < -0.5 : false)
            let worse = kind.higherIsBetter == true ? z < -0.5 : (kind.higherIsBetter == false ? z > 0.5 : false)
            return better ? "Better than your norm" : (worse ? "Worse than your norm" : "Close to your norm")
        }
        return "Today"
    }

    private var chartCard: some View {
        Card(title: "Trend", subtitle: "Last \(range) days", icon: "chart.xyaxis.line") {
            Picker("Range", selection: $range) { Text("7d").tag(7); Text("14d").tag(14); Text("30d").tag(30); Text("60d").tag(60) }.pickerStyle(.segmented)
            Chart {
                ForEach(days) { d in
                    if let v = d[keyPath: kind.keyPath] {
                        AreaMark(x: .value("Day", d.date), yStart: .value("Floor", domain.lowerBound), yEnd: .value(kind.title, v))
                            .foregroundStyle(LinearGradient(colors: [kind.colors[1].opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Day", d.date), y: .value(kind.title, v)).foregroundStyle(kind.colors[1]).interpolationMethod(.catmullRom)
                    }
                }
                if let b = baseline, b.isUsable {
                    RuleMark(y: .value("Norm", b.center)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) { Text("norm").font(.caption2).foregroundStyle(.secondary) }
                } else if !values.isEmpty {
                    RuleMark(y: .value("Mean", mean(values))).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) { Text("average").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .chartYScale(domain: domain).frame(height: 180)
        }
    }

    private var domain: ClosedRange<Double> {
        var lo = values.min() ?? 0, hi = values.max() ?? 1
        if let b = baseline { lo = min(lo, b.center); hi = max(hi, b.center) }
        let pad = max((hi - lo) * 0.25, 0.5)
        return (lo - pad)...(hi + pad)
    }

    private var statsCard: some View {
        let s = Summary.of(values)
        return Card(title: "Numbers", icon: "number") {
            if let s {
                HStack {
                    Stat(label: "Average", value: fmt(s.mean))
                    Stat(label: "Lowest", value: fmt(s.min))
                    Stat(label: "Highest", value: fmt(s.max))
                }
                HStack {
                    Stat(label: "Typical swing", value: "± " + fmt(s.sd))
                    Stat(label: "Direction", value: s.slope > 0.05 * max(1, s.sd) ? "Rising" : (s.slope < -0.05 * max(1, s.sd) ? "Falling" : "Flat"))
                    Stat(label: "Days", value: "\(s.n)")
                }
            } else { Text("Not enough data yet").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var specifics: some View {
        switch kind {
        case .charge:
            if let r = model.chargeResult {
                Card(title: "What shaped it", icon: "bolt.fill") {
                    ForEach(r.drivers) { d in
                        HStack { Text(d.name).font(.subheadline); Spacer()
                            Text(String(format: "%+.1f", d.points)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(d.points >= 0 ? Palette.sage : Palette.clay) }
                    }
                    Text("Points are what each input added or removed versus leaving it out; the score is logistic, so they don't sum to the headline.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let f = model.forecast { Card(title: "Tomorrow", icon: "sunrise.fill") { Text(String(format: "Estimated %.0f ± %.0f from today's Effort, sleep and trend.", f.value, f.band)).font(.footnote) } }
        case .effort:
            zonesCard
        case .rest:
            if let n = model.lastNight {
                Card(title: "Last night", icon: "bed.double.fill") {
                    HStack {
                        Stat(label: "Asleep", value: fmtDuration(n.asleepMinutes))
                        Stat(label: "Need", value: fmtDuration(model.sleepNeedMin))
                        Stat(label: "Debt", value: model.sleepDebtMin == 0 ? "None" : fmtDuration(model.sleepDebtMin))
                    }
                    HStack {
                        Stat(label: "Deep", value: fmtDuration(n.minutes(.deep)))
                        Stat(label: "REM", value: fmtDuration(n.minutes(.rem)))
                        Stat(label: "Efficiency", value: String(format: "%.0f%%", n.efficiency * 100))
                    }
                }
            }
        case .hrv, .restingHR, .respiration:
            if let b = baseline {
                Card(title: "Your norm", icon: "scope") {
                    HStack {
                        Stat(label: "Norm", value: fmt(b.center) + kind.unit)
                        Stat(label: "Typical swing", value: "± " + fmt(b.spread))
                        Stat(label: "Baseline", value: b.status.rawValue.capitalized)
                    }
                    if let t = today { Text(String(format: "Today's z-score: %+.2f (within ±2 counts as in range)", b.z(t))).font(.caption).foregroundStyle(.secondary) }
                    Text("Based on \(b.count) nights. Trusted after 14.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .skinTemp, .activityBalance:
            EmptyView()
        }
    }

    @ViewBuilder private var zonesCard: some View {
        if let raw = model.raw {
            let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let hr = raw.hr.filter { $0.t >= start }
            let z = HRZones(age: model.settings.profile.age, override: model.settings.profile.hrMaxOverride).timeInZones(hr)
            Card(title: "Time in zones today", subtitle: "Zones from your max heart rate", icon: "heart.text.square.fill") {
                ForEach(1...5, id: \.self) { i in
                    let m = (z[i] ?? 0) / 60
                    HStack {
                        Circle().fill(zoneColor(i)).frame(width: 10, height: 10)
                        Text("Zone \(i)").font(.subheadline)
                        Spacer()
                        Text(fmtDuration(m)).font(.subheadline.monospacedDigit())
                    }
                }
                if let p = hr.map(\.bpm).max() { Text(String(format: "Peak heart rate: %.0f bpm", p)).font(.caption).foregroundStyle(.secondary) }
                if let k = model.today?.kcal { Text(String(format: "Estimated energy today: %.0f kcal", k)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
