import SwiftUI
import Charts
import StrandAnalytics

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var detail: MetricKind?
    @State private var allDrivers = false
    private var compact: Bool { model.isCompact("today") }

    var content: some View {
            VStack(spacing: 16) {
                header
                ForEach(TodayCard.allCases.filter { !model.ui.hiddenCards.contains($0.rawValue) }) { card in
                    cardView(card)
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
            .background { AmbientBackground(tint: (model.today?.charge.map(ChargeBand.of) ?? .yellow).gradient[0]) }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $detail) { MetricDetailView(kind: $0).environment(model) }
        }
    }

    private var header: some View {
        let h = Calendar.current.component(.hour, from: Date())
        let greet = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greet).font(compact ? .title2.bold() : .largeTitle.bold())
                Text(Date().formatted(.dateTime.weekday(.wide).month().day())).font(compact ? .caption : .body).foregroundStyle(.secondary)
            }
            Spacer()
            if model.streak.current > 0 {
                Label("\(model.streak.current)", systemImage: "flame.fill").font(.subheadline.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.peach[0].opacity(0.5), in: Capsule()).foregroundStyle(Palette.clay)
            }
        }
        .padding(.top, compact ? 0 : 4)
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
            Label("A heads-up to rest", systemImage: "thermometer.medium").font(.headline).foregroundStyle(Palette.clay)
            Text("\(r.firing.sorted().joined(separator: ", ")) are off your normal. On-device estimate (approximate), not a diagnosis.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func workoutSuggestion(_ s: (start: Double, end: Double)) -> some View {
        Card(title: "Did you just work out?") {
            Text("\(fmtClock(s.start))–\(fmtClock(s.end)) · \(fmtDuration((s.end - s.start) / 60)) of elevated heart rate").font(.footnote)
            HStack(spacing: 10) {
                Button {
                    model.addWorkout(SavedWorkout(sport: "Workout", start: s.start, end: s.end, avgHR: nil, peakHR: nil, kcal: nil, effort: nil, distanceM: nil, source: "detected"))
                } label: { Label("Yes, save it", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { withAnimation { model.dismissSuggestion() } } label: { Label("No workout", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            Text("Elevated heart rate can also come from stress, caffeine or a hot shower — saying no teaches nothing to your scores, it just hides this window.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func series(_ kp: KeyPath<DailyMetric, Double?>) -> [Double] { model.days.suffix(14).compactMap { $0[keyPath: kp] } }

    private var scoreCard: AnyView {
        let t = model.today
        let band = t?.charge.map(ChargeBand.of)
        let effort = t?.effort
        let b = model.baselines
        if compact { return AnyView(compactScoreCard(t: t, band: band, effort: effort, b: b)) }
        return AnyView(VStack(spacing: 14) {
            HeroCard(colors: (band ?? .yellow).gradient) {
                HStack(spacing: 18) {
                    Ring(value: t?.charge, colors: [.white.opacity(0.85), .white], label: "Charge", unit: "%", size: 160, onDark: true, textColor: Color.white)
                        .onTapGesture { detail = .charge }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(band?.word ?? "Calibrating").font(.title2.bold()).foregroundStyle(Color.white)
                        Text(t?.charge == nil ? "Need a few more nights to learn your baseline." : "HRV, resting HR, sleep and recent strain, versus your own normal.")
                            .font(.footnote).foregroundStyle(Color.white.opacity(0.88))
                        HStack(spacing: 6) {
                            Text(ConfidenceTier.forNights(b?.hrv.count ?? 0).rawValue).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.25), in: Capsule()).foregroundStyle(Color.white)
                            Text("\(b?.hrv.count ?? 0) nights").font(.caption2).foregroundStyle(Color.white.opacity(0.8))
                        }
                        Label("Tap for details", systemImage: "chevron.right.circle").font(.caption2).foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            }
            .contentShape(Rectangle()).onTapGesture { detail = .charge }
            HStack(spacing: 12) {
                Card {
                    Ring(value: model.settings.effortOn21Scale ? effort.map { StrainScorer.to21($0) / 21 * 100 } : effort,
                         colors: Palette.skyRich, label: "Effort", unit: model.settings.effortOn21Scale ? "/21" : "", size: 110).frame(maxWidth: .infinity)
                }
                .contentShape(Rectangle()).onTapGesture { detail = .effort }
                Card {
                    Ring(value: t?.rest, colors: Palette.lavenderRich, label: "Rest", unit: "%", size: 110).frame(maxWidth: .infinity)
                }
                .contentShape(Rectangle()).onTapGesture { detail = .rest }
            }
            HStack(spacing: 10) {
                MetricChip(icon: "waveform.path.ecg", label: "HRV", value: t?.hrv.map { String(format: "%.0f ms", $0) } ?? "—",
                           delta: t?.hrv.flatMap { v in b.map { v - $0.hrv.center } }, series: series(\.hrv), tint: Palette.aqua[1])
                    .onTapGesture { detail = .hrv }
                MetricChip(icon: "heart.fill", label: "Resting HR", value: t?.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—",
                           delta: t?.restingHR.flatMap { v in b.map { v - $0.restingHR.center } }, higherIsBetter: false, series: series(\.restingHR), tint: Palette.rose[1])
                    .onTapGesture { detail = .restingHR }
                MetricChip(icon: "lungs.fill", label: "Resp.", value: t?.respiration.map { String(format: "%.1f", $0) } ?? "—",
                           delta: t?.respiration.flatMap { v in b.map { v - $0.respiration.center } }, deltaFormat: "%+.1f", higherIsBetter: false, series: series(\.respiration), tint: Palette.sky[1])
                    .onTapGesture { detail = .respiration }
            }
        })
    }

    private func compactScoreCard(t: DailyMetric?, band: ChargeBand?, effort: Double?, b: ChargeBaselines?) -> some View {
        VStack(spacing: 12) {
            HeroCard(colors: (band ?? .yellow).gradient) {
                HStack(spacing: 14) {
                    Ring(value: t?.charge, colors: [.white.opacity(0.85), .white], label: "Charge", unit: "%", size: 118, onDark: true, textColor: .white)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(band?.word ?? "Calibrating").font(.title3.bold()).foregroundStyle(.white)
                        Text("\(ConfidenceTier.forNights(b?.hrv.count ?? 0).rawValue) · \(b?.hrv.count ?? 0) nights").font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle()).onTapGesture { detail = .charge }
            Card {
                HStack(spacing: 10) {
                    Ring(value: model.settings.effortOn21Scale ? effort.map { StrandAnalytics.StrainScorer.to21($0) / 21 * 100 } : effort,
                         colors: Palette.skyRich, label: "Effort", size: 84).onTapGesture { detail = .effort }
                    Ring(value: t?.rest, colors: Palette.lavenderRich, label: "Rest", unit: "%", size: 84).onTapGesture { detail = .rest }
                    VStack(spacing: 8) {
                        VitalRow(icon: "waveform.path.ecg", label: "HRV", value: t?.hrv.map { String(format: "%.0f ms", $0) } ?? "—",
                                 delta: t?.hrv.flatMap { v in b.map { v - $0.hrv.center } }, tint: Palette.aqua[1]).onTapGesture { detail = .hrv }
                        VitalRow(icon: "heart.fill", label: "Resting HR", value: t?.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—",
                                 delta: t?.restingHR.flatMap { v in b.map { v - $0.restingHR.center } }, higherIsBetter: false, tint: Palette.rose[1]).onTapGesture { detail = .restingHR }
                        VitalRow(icon: "lungs.fill", label: "Respiration", value: t?.respiration.map { String(format: "%.1f /min", $0) } ?? "—",
                                 delta: t?.respiration.flatMap { v in b.map { v - $0.respiration.center } }, deltaFormat: "%+.1f", higherIsBetter: false, tint: Palette.sky[1]).onTapGesture { detail = .respiration }
                    }
                }
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
        let shown = compact && !allDrivers ? Array(r.drivers.prefix(3)) : r.drivers
        return Card(title: "Charge drivers", subtitle: mode == .change ? "What each input added or removed" : "Today's value and its effect on Charge", icon: "bolt.fill") {
            ForEach(shown) { d in
                let dv = driverValue(d.name)
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.subheadline.weight(.medium))
                            if mode != .change, !compact, let b = dv?.baseline { Text(b).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if mode != .change, let v = dv?.value { Text(v).font(.subheadline.weight(.semibold).monospacedDigit()) }
                        if mode != .value {
                            Text(String(format: "%+.1f", d.points)).font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background((d.points >= 0 ? Palette.sage : Palette.clay).opacity(0.18), in: Capsule())
                                .foregroundStyle(d.points >= 0 ? Palette.sage : Palette.clay)
                        }
                    }
                    if mode != .value { DriverBar(points: d.points, maxMagnitude: mx) }
                }
                .contentShape(Rectangle())
                .onTapGesture { detail = MetricKind(driverName: d.name) }
            }
            if compact && r.drivers.count > 3 {
                Button(allDrivers ? "Show fewer" : "Show all \(r.drivers.count)") { withAnimation { allDrivers.toggle() } }.font(.footnote.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var liveCard: some View {
        if compact { liveStrip } else { liveFull }
    }

    private var liveStrip: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Live").font(.subheadline.weight(.semibold))
                    Text(model.ble.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.ble.heartRate.map(String.init) ?? "—").font(.title3.bold().monospacedDigit())
                Button(model.ble.state == .connected ? "Disconnect" : "Connect") {
                    model.ble.state == .connected ? model.ble.disconnect() : model.ble.connect()
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var liveFull: some View {
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
        Card(title: "Stress today", subtitle: compact ? nil : "Waking hours vs your own calm; masked while moving", icon: "brain.head.profile") {
            if model.stressHours.isEmpty { Text("Not enough heart-rate data yet").font(.footnote).foregroundStyle(.secondary) }
            else {
                Chart(model.stressHours) { h in
                    if let s = h.score {
                        BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.start), unit: .hour), y: .value("Stress", s))
                            .foregroundStyle(s >= 2 ? Palette.clay : Palette.aqua[1])
                    }
                }
                .chartYScale(domain: 0...3).frame(height: compact ? 70 : 120)
                if DaytimeStress.sustainedHigh(model.stressHours) {
                    NavigationLink("Sustained high — try Breathe", destination: BreatheView())
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder private var hydrationCard: some View {
        if compact { hydrationRow } else { hydrationFull }
    }

    private var hydrationRow: some View {
        let total = model.hydrationToday, goal = model.hydrationGoal
        return Card {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Hydration  %.2f / %.1f L", Double(total) / 1000, Double(goal) / 1000)).font(.subheadline.weight(.medium))
                    ProgressView(value: min(1, Double(total) / Double(goal)))
                }
                if SnapshotMode.on { Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint) } else {
                Menu {
                    ForEach(HydrationGoal.quickLog, id: \.name) { q in Button("\(q.name) \(q.ml) ml") { model.logHydration(q.ml) } }
                } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                }
            }
        }
    }

    private var hydrationFull: some View {
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

    @ViewBuilder private var readinessCard: some View {
        if compact {
            Card(title: "Readiness", icon: "checkmark.seal.fill") {
                let chips = HStack(spacing: 8) {
                    ForEach(model.readiness) { s in
                        HStack(spacing: 5) { Circle().fill(color(s.flag)).frame(width: 8, height: 8); Text(s.name).font(.caption.weight(.medium)) }
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Color.gray.opacity(0.1), in: Capsule())
                    }
                }
                if SnapshotMode.on { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
            }
        } else { readinessFull }
    }

    private var readinessFull: some View {
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
