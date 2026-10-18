import SwiftUI
import Charts
import StrandAnalytics

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showJournal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let ill = model.illness, ill.level == .raised { illnessBanner(ill) }
                    if let s = model.autoSuggestion { workoutSuggestion(s) }
                    scoreCard
                    if let r = model.chargeResult { driversCard(r) }
                    liveCard
                    if let f = model.forecast { forecastCard(f) }
                    stressCard
                    hydrationCard
                    if !model.readiness.isEmpty { readinessCard }
                    Disclaimer()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .navigationTitle("Today")
            .toolbar { Button { showJournal = true } label: { Image(systemName: "square.and.pencil") } }
            .sheet(isPresented: $showJournal) { JournalSheet() }
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

    private var scoreCard: some View {
        let t = model.today
        let band = t?.charge.map(ChargeBand.of) ?? .yellow
        let effort = t?.effort
        return Card {
            HStack(alignment: .top, spacing: 0) {
                Ring(value: t?.charge, color: .band(band), label: t?.charge == nil ? "Charge · Calibrating" : "Charge", unit: "%").frame(maxWidth: .infinity)
                Ring(value: model.settings.effortOn21Scale ? effort.map { StrainScorer.to21($0) / 21 * 100 } : effort, color: .blue, label: "Effort", unit: model.settings.effortOn21Scale ? "of 21" : "").frame(maxWidth: .infinity)
                Ring(value: t?.rest, color: .purple, label: "Rest", unit: "%").frame(maxWidth: .infinity)
            }
            HStack {
                Stat(label: "HRV", value: t?.hrv.map { String(format: "%.0f ms", $0) } ?? "—")
                Stat(label: "Resting HR", value: t?.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—")
                Stat(label: "Respiration", value: t?.respiration.map { String(format: "%.1f /min", $0) } ?? "—")
            }
            HStack {
                TierBadge(tier: ConfidenceTier.forNights(model.baselines?.hrv.count ?? 0))
                Text("\(model.baselines?.hrv.count ?? 0) nights of baseline").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if model.streak.current > 0 { Label("\(model.streak.current)-day streak", systemImage: "flame.fill").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func driversCard(_ r: ChargeResult) -> some View {
        Card(title: "Charge drivers", subtitle: "Points each input added or removed") {
            ForEach(r.drivers) { d in
                HStack {
                    Text(d.name).font(.subheadline)
                    Spacer()
                    Text(String(format: "%+.1f", d.points)).font(.subheadline.monospacedDigit())
                        .foregroundStyle(d.points >= 0 ? .green : .red)
                }
            }
        }
    }

    private var liveCard: some View {
        Card(title: "Live", subtitle: model.ble.state.rawValue) {
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
        Card(title: "Tomorrow's Charge", subtitle: "Evening estimate from known levers, not a measurement") {
            Text(String(format: "%.0f ± %.0f", f.value, f.band)).font(.title2.bold())
        }
    }

    private var stressCard: some View {
        Card(title: "Stress today", subtitle: "Waking hours vs your own calm; masked while moving") {
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
        Card(title: "Hydration") {
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
        Card(title: "Readiness signals") {
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

struct JournalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tags: Set<String> = []
    @State private var mood = 3
    @State private var caffeine = 0.0
    let all = ["Alcohol", "Late workout", "Caffeine after 2pm", "Meditation", "Sauna", "Stress", "Travel", "Sick"]
    var body: some View {
        NavigationStack {
            Form {
                Section("Today") {
                    ForEach(all, id: \.self) { t in
                        Toggle(t, isOn: Binding(get: { tags.contains(t) }, set: { if $0 { tags.insert(t) } else { tags.remove(t) } }))
                    }
                }
                Section("Mood") { Picker("Mood", selection: $mood) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented) }
                Section("Caffeine") { Slider(value: $caffeine, in: 0...600, step: 25); Text("\(Int(caffeine)) mg") }
            }
            .navigationTitle("Journal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.addJournal(JournalEntry(day: DayFormat.string(Date()), tags: Array(tags), mood: mood, caffeineMg: Int(caffeine)))
                        dismiss()
                    }
                }
            }
        }
    }
}
