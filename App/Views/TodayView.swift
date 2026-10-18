import SwiftUI
import Charts
import StrandAnalytics

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    ForEach(TodayCard.allCases.filter { !model.ui.hiddenCards.contains($0.rawValue) }) { card in
                        cardView(card)
                    }
                    Disclaimer()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background { AmbientBackground(tint: (model.today?.charge.map(ChargeBand.of) ?? .yellow).gradient[0]) }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        let h = Calendar.current.component(.hour, from: Date())
        let greet = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greet).font(.largeTitle.bold())
                Text(Date().formatted(.dateTime.weekday(.wide).month().day())).foregroundStyle(.secondary)
            }
            Spacer()
            if model.streak.current > 0 {
                Label("\(model.streak.current)", systemImage: "flame.fill").font(.subheadline.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func cardView(_ c: TodayCard) -> some View {
        switch c {
        case .illness: if let ill = model.illness, ill.level == .raised { illnessBanner(ill) }
        case .workoutSuggestion: if let s = model.autoSuggestion { workoutSuggestion(s) }
        case .scores: scoreCard
        case .drivers: if let r = model.chargeResult { driversCard(r) }
        case .live: liveCard
        case .forecast: if let f = model.forecast { forecastCard(f) }
        case .stress: stressCard
        case .hydration: hydrationCard
        case .readiness: if !model.readiness.isEmpty { readinessCard }
        }
    }

    private func illnessBanner(_ r: IllnessResult) -> some View {
        Card {
            Label("A heads-up to rest", systemImage: "thermometer.medium").font(.headline).foregroundStyle(.orange)
            Text("\(r.firing.sorted().joined(separator: ", ")) are off your normal. On-device estimate (approximate), not a diagnosis.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func workoutSuggestion(_ s: (start: Double, end: Double)) -> some View {
        Card(title: "Did you just work out?") {
            Text("\(fmtClock(s.start))–\(fmtClock(s.end)) · \(fmtDuration((s.end - s.start) / 60)) of elevated heart rate").font(.footnote)
            Button("Save workout") {
                model.addWorkout(SavedWorkout(sport: "Workout", start: s.start, end: s.end, avgHR: nil, peakHR: nil, kcal: nil, effort: nil, distanceM: nil, source: "detected"))
            }.buttonStyle(.borderedProminent)
        }
    }

    private func series(_ kp: KeyPath<DailyMetric, Double?>) -> [Double] { model.days.suffix(14).compactMap { $0[keyPath: kp] } }

    private var scoreCard: some View {
        let t = model.today
        let band = t?.charge.map(ChargeBand.of)
        let effort = t?.effort
        let b = model.baselines
        return VStack(spacing: 14) {
            HeroCard(colors: (band ?? .yellow).gradient.reversed().map { $0 }) {
                HStack(spacing: 18) {
                    Ring(value: t?.charge, colors: [.white.opacity(0.85), .white], label: "", unit: "Charge", size: 150, onDark: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(band?.word ?? "Calibrating").font(.title2.bold()).foregroundStyle(.white)
                        Text(t?.charge == nil ? "Need a few more nights to learn your baseline." : "HRV, resting HR, sleep and recent strain, versus your own normal.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.85))
                        HStack(spacing: 6) {
                            Text(ConfidenceTier.forNights(b?.hrv.count ?? 0).rawValue).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.22), in: Capsule()).foregroundStyle(.white)
                            Text("\(b?.hrv.count ?? 0) nights").font(.caption2).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Card {
                    Ring(value: model.settings.effortOn21Scale ? effort.map { StrainScorer.to21($0) / 21 * 100 } : effort,
                         colors: [Color(red: 0.35, green: 0.65, blue: 1), Color(red: 0.15, green: 0.35, blue: 0.95)],
                         label: "Effort", unit: model.settings.effortOn21Scale ? "of 21" : "", size: 92).frame(maxWidth: .infinity)
                }
                Card {
                    Ring(value: t?.rest, colors: [Color(red: 0.75, green: 0.5, blue: 1), Color(red: 0.55, green: 0.25, blue: 0.9)],
                         label: "Rest", unit: "%", size: 92).frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 10) {
                MetricChip(icon: "waveform.path.ecg", label: "HRV", value: t?.hrv.map { String(format: "%.0f ms", $0) } ?? "—",
                           delta: t?.hrv.flatMap { v in b.map { v - $0.hrv.center } }, series: series(\.hrv), tint: .teal)
                MetricChip(icon: "heart.fill", label: "Resting HR", value: t?.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—",
                           delta: t?.restingHR.flatMap { v in b.map { v - $0.restingHR.center } }, higherIsBetter: false, series: series(\.restingHR), tint: .red)
                MetricChip(icon: "lungs.fill", label: "Resp.", value: t?.respiration.map { String(format: "%.1f", $0) } ?? "—",
                           delta: t?.respiration.flatMap { v in b.map { v - $0.respiration.center } }, deltaFormat: "%+.1f", higherIsBetter: false, series: series(\.respiration), tint: .cyan)
            }
        }
    }

    /// Real value for a driver: (today's reading, your baseline), formatted.
    private func driverValue(_ name: String) -> (value: String, baseline: String?)? {
        let t = model.today, b = model.baselines
        switch name {
        case "HRV": return t?.hrv.map { (String(format: "%.0f ms", $0), b.map { String(format: "norm %.0f", $0.hrv.center) }) }
        case "Resting HR": return t?.restingHR.map { (String(format: "%.0f bpm", $0), b.map { String(format: "norm %.0f", $0.restingHR.center) }) }
        case "Respiration": return t?.respiration.map { (String(format: "%.1f /min", $0), b.map { String(format: "norm %.1f", $0.respiration.center) }) }
        case "Rest quality": return t?.rest.map { (String(format: "%.0f%%", $0), nil) }
        case "Skin temp": return t?.skinTempDev.map { (String(format: "%+.2f °C", $0), "vs baseline") }
        case "Activity balance":
            let i = model.days.count - 2
            return i >= 0 ? model.days[i].effort.map { (String(format: "Effort %.0f", $0), nil) } : nil
        default: return nil
        }
    }

    private func driversCard(_ r: ChargeResult) -> some View {
        let mode = model.ui.driverDisplay
        let mx = max(5, r.drivers.map { abs($0.points) }.max() ?? 5)
        return Card(title: "Charge drivers", subtitle: mode == .change ? "What each input added or removed" : "Today's value and its effect on Charge", icon: "bolt.fill") {
            ForEach(r.drivers) { d in
                let dv = driverValue(d.name)
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.subheadline.weight(.medium))
                            if mode != .change, let b = dv?.baseline { Text(b).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if mode != .change, let v = dv?.value { Text(v).font(.subheadline.weight(.semibold).monospacedDigit()) }
                        if mode != .value {
                            Text(String(format: "%+.1f", d.points)).font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background((d.points >= 0 ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                                .foregroundStyle(d.points >= 0 ? .green : .orange)
                        }
                    }
                    if mode != .value { DriverBar(points: d.points, maxMagnitude: mx) }
                }
            }
        }
    }

    private var liveCard: some View {
        Card(title: "Live", subtitle: model.ble.state.rawValue, icon: "dot.radiowaves.left.and.right") {
            HStack(alignment: .firstTextBaseline) {
                Text(model.ble.heartRate.map(String.init) ?? "—").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text("bpm").foregroundStyle(.secondary)
                Spacer()
                if let b = model.ble.batteryPercent { Label(String(format: "%.0f%%", b), systemImage: "battery.75percent") }
            }
            Button(model.ble.state == .connected ? "Disconnect" : "Connect strap") {
                model.ble.state == .connected ? model.ble.disconnect() : model.ble.connect()
            }.buttonStyle(.bordered)
        }
    }

    private func forecastCard(_ f: ChargeForecast) -> some View {
        Card(title: "Tomorrow's Charge", subtitle: "Evening estimate from known levers, not a measurement", icon: "sunrise.fill") {
            Text(String(format: "%.0f ± %.0f", f.value, f.band)).font(.title2.bold())
        }
    }

    private var stressCard: some View {
        Card(title: "Stress today", subtitle: "Waking hours vs your own calm; masked while moving", icon: "brain.head.profile") {
            if model.stressHours.isEmpty { Text("Not enough heart-rate data yet").font(.footnote).foregroundStyle(.secondary) }
            else {
                Chart(model.stressHours) { h in
                    if let s = h.score {
                        BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.start), unit: .hour), y: .value("Stress", s))
                            .foregroundStyle(s >= 2 ? Color.orange : Color.teal)
                    }
                }
                .chartYScale(domain: 0...3).frame(height: 120)
                if DaytimeStress.sustainedHigh(model.stressHours) {
                    NavigationLink("Sustained high — try Breathe", destination: BreatheView())
                        .font(.footnote)
                }
            }
        }
    }

    private var hydrationCard: some View {
        Card(title: "Hydration", icon: "drop.fill") {
            let total = model.hydrationToday, goal = model.hydrationGoal
            ProgressView(value: min(1, Double(total) / Double(goal)))
            Text(String(format: "%.2f / %.1f L", Double(total) / 1000, Double(goal) / 1000)).font(.footnote)
            HStack {
                ForEach(HydrationGoal.quickLog, id: \.name) { q in
                    Button("\(q.name) \(q.ml)") { model.logHydration(q.ml) }.buttonStyle(.bordered).font(.caption)
                }
            }
        }
    }

    private var readinessCard: some View {
        Card(title: "Readiness signals", icon: "checkmark.seal.fill") {
            ForEach(model.readiness) { s in
                HStack {
                    Circle().fill(color(s.flag)).frame(width: 10, height: 10)
                    VStack(alignment: .leading) { Text(s.name).font(.subheadline); Text(s.note).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    if let z = s.z { Text(String(format: "%.2f", z)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func color(_ f: SignalFlag) -> Color { f == .good ? .green : f == .neutral ? .gray : f == .watch ? .orange : .red }
}
