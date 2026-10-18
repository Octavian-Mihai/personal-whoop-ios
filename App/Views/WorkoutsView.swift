import SwiftUI
import Charts
import StrandAnalytics
import UIKit

struct WorkoutsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showStart = false

    private func kind(_ sport: String) -> WorkoutKind { WorkoutKind(rawValue: sport) ?? .other }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    startHero
                    intervalCard
                    weekSummary
                    heatmapCard
                    if !model.detected.isEmpty { detectedCard }
                    loggedCard
                    Disclaimer()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background { AmbientBackground(tint: Palette.peach[0]) }
            .navigationTitle("Workouts")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") } }
            .sheet(isPresented: $showAdd) { ManualWorkoutSheet() }
            .sheet(isPresented: $showStart) { WorkoutStartSheet() }
        }
    }

    private var startHero: some View {
        HeroCard(colors: [Palette.peach[0], Palette.rose[0], Palette.lavender[1]]) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to move?").font(.title2.bold()).foregroundStyle(Palette.ink)
                    Text("Live heart rate, zones and coaching tuned to the activity.").font(.footnote).foregroundStyle(Palette.ink.opacity(0.7))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(WorkoutKind.allCases) { k in
                            Button { model.startWorkout(k) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: k.icon).font(.title3)
                                    Text(k.rawValue).font(.caption2.weight(.medium))
                                }
                                .foregroundStyle(Palette.ink)
                                .frame(width: 66, height: 66)
                                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
                Button { showStart = true } label: {
                    Label("More options", systemImage: "slider.horizontal.3").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.white, in: Capsule()).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    private var weekSummary: some View {
        let cutoff = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        let w = model.snapshot.workouts.filter { $0.start >= cutoff }
        let mins = w.reduce(0) { $0 + ($1.end - $1.start) / 60 }
        let kcal = w.reduce(0) { $0 + ($1.kcal ?? 0) }
        return HStack(spacing: 12) {
            summaryTile("figure.run", "Workouts", "\(w.count)", Palette.peach)
            summaryTile("clock.fill", "Minutes", String(format: "%.0f", mins), Palette.sky)
            summaryTile("flame.fill", "Calories", String(format: "%.0f", kcal), Palette.rose)
        }
    }

    private func summaryTile(_ icon: String, _ label: String, _ value: String, _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.subheadline.bold()).foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            Text(value).font(.title2.bold().monospacedDigit())
            Text("\(label) · 7 d").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var heatmapCard: some View {
        Card(title: "Activity", subtitle: "Last 13 weeks, by active calories", icon: "square.grid.3x3.fill") { heatmap }
    }

    private var detectedCard: some View {
        Card(title: "Detected today", subtitle: "From heart rate and motion", icon: "waveform.path.ecg") {
            ForEach(model.detected) { w in
                HStack(spacing: 12) {
                    Image(systemName: "bolt.heart.fill").foregroundStyle(Palette.ink).frame(width: 38, height: 38)
                        .background(LinearGradient(colors: Palette.rose, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(fmtClock(w.start)) · \(fmtDuration(w.durationMin))").font(.subheadline.weight(.semibold))
                        Text(String(format: "avg %.0f · peak %.0f bpm · %.0f kcal", w.avgHR, w.peakHR, w.kcal)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let e = w.effort { Text(String(format: "%.0f", e)).font(.headline.monospacedDigit()).padding(8).background(Palette.sky[0].opacity(0.6), in: Circle()) }
                }
            }
        }
    }

    private var loggedCard: some View {
        Card(title: "History", icon: "list.bullet.rectangle.fill") {
            if model.snapshot.workouts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "figure.run.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No workouts yet — start one above.").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            ForEach(model.snapshot.workouts) { w in
                let k = kind(w.sport)
                NavigationLink { WorkoutDetailView(workout: w) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: k.icon).foregroundStyle(Palette.ink).frame(width: 42, height: 42)
                            .background(LinearGradient(colors: k.colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.sport).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(Date(timeIntervalSince1970: w.start).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(fmtDuration((w.end - w.start) / 60)).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                            if let k = w.kcal { Text(String(format: "%.0f kcal", k)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var intervalCard: some View {
        NavigationLink { IntervalTimerView() } label: {
            HStack(spacing: 14) {
                Image(systemName: "timer").font(.title2).foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interval timer").font(.headline).foregroundStyle(Palette.ink)
                    Text("Work / rest rounds with wrist buzzes").font(.caption).foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Palette.ink.opacity(0.5))
            }
            .padding(14)
            .background(LinearGradient(colors: Palette.rose, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Palette.rose[1].opacity(0.3), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    private var heatmap: some View {
        let cal = Calendar(identifier: .iso8601)
        let kcal = Dictionary(uniqueKeysWithValues: model.days.map { ($0.day, ($0.kcal ?? 0) - 2000 > 0 ? ($0.kcal ?? 0) - 2000 : 0) })
        let daily = Array(kcal.values)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<13, id: \.self) { w in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: (w - 12) * 7 + d, to: weekStart)!
                            let v = date > Date() ? nil : kcal[DayFormat.string(date)]
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(LinearGradient(colors: Palette.peach, startPoint: .top, endPoint: .bottom))
                                .opacity(v == nil ? 0 : [0.08, 0.3, 0.5, 0.75, 1][ActivityHeatmap.level(value: v ?? 0, daily: daily)])
                                .frame(height: 18)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 3).fill(Palette.peach[1].opacity([0.15, 0.35, 0.55, 0.75, 1][i])).frame(width: 12, height: 12) }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct ManualWorkoutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sport = "Run"
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()
    @State private var avgHR = ""
    @State private var kcal = ""
    @State private var km = ""
    @State private var error: String?
    let sports = ["Run", "Walk", "Cycle", "Strength", "Swim", "HIIT", "Yoga", "Ski", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Sport", selection: $sport) { ForEach(sports, id: \.self) { Text($0) } }
                DatePicker("Start", selection: $start)
                DatePicker("End", selection: $end)
                TextField("Average HR (bpm)", text: $avgHR).keyboardType(.numberPad)
                TextField("Calories (kcal)", text: $kcal).keyboardType(.numberPad)
                TextField("Distance (km)", text: $km).keyboardType(.decimalPad)
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Text("Strain stays empty until a heart-rate window exists — it's never invented.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Add workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        var w = ManualWorkout(sport: sport, start: start.timeIntervalSince1970, end: end.timeIntervalSince1970,
                              distanceM: Double(km).map { $0 * 1000 }, avgHR: Double(avgHR), kcal: Double(kcal))
        do { try w.validate() } catch { self.error = error.localizedDescription; return }
        if let raw = model.raw, let rhr = model.today?.restingHR {
            w = w.rescored(hr: raw.hr, restingHR: rhr, hrMax: 208 - 0.7 * model.settings.profile.age, profile: model.settings.profile)
        }
        model.addWorkout(SavedWorkout(sport: w.sport, start: w.start, end: w.end, avgHR: w.avgHR, peakHR: nil, kcal: w.kcal, effort: w.strain, distanceM: w.distanceM, source: "manual"))
        dismiss()
    }
}

struct IntervalTimerView: View {
    @Environment(AppModel.self) private var model
    @State private var plan = IntervalPlan()
    @State private var running = false
    @State private var paused = false
    @State private var phaseIdx = 0
    @State private var remaining = 0
    @State private var timer: Timer?

    var body: some View {
        Form {
            Section {
                Stepper("Work: \(plan.work) s", value: $plan.work, in: 5...300, step: 5).disabled(running && !paused)
                Stepper("Rest: \(plan.rest) s", value: $plan.rest, in: 0...300, step: 5).disabled(running && !paused)
                Stepper("Rounds: \(plan.rounds)", value: $plan.rounds, in: 1...30).disabled(running && !paused)
                Text("Total \(fmtDuration(Double(plan.totalSeconds) / 60))").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if running {
                    let p = plan.phases[phaseIdx]
                    VStack(spacing: 4) {
                        Text(p.isWork ? "WORK" : "REST").font(.title.bold()).foregroundStyle(p.isWork ? .red : .green)
                        Text("\(remaining)").font(.system(size: 80, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("Round \(p.round) of \(plan.rounds)").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                Button(running ? (paused ? "Resume" : "Pause") : "Start") { running ? togglePause() : start() }
                if running { Button("Stop", role: .destructive) { stop() } }
            }
        }
        .navigationTitle("Interval timer")
        .onDisappear { stop() }
    }

    private func start() {
        running = true; paused = false; phaseIdx = 0; remaining = plan.phases[0].seconds
        UIApplication.shared.isIdleTimerDisabled = true
        enter(phase: 0); schedule()
    }
    private func togglePause() { paused.toggle(); paused ? timer?.invalidate() : schedule() }
    private func stop() { timer?.invalidate(); running = false; UIApplication.shared.isIdleTimerDisabled = false }
    private func schedule() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
    }
    private func enter(phase i: Int) {
        let loops = plan.phases[i].isWork ? IntervalPlan.workLoops : IntervalPlan.restLoops
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        model.ble.buzz(loops: UInt8(loops))
    }
    private func tick() {
        remaining -= 1
        if remaining <= 3 && remaining > 0 { model.ble.buzz(loops: 1); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        if remaining <= 0 {
            if phaseIdx + 1 < plan.phases.count {
                phaseIdx += 1; remaining = plan.phases[phaseIdx].seconds; enter(phase: phaseIdx)
            } else {
                model.ble.buzz(loops: UInt8(IntervalPlan.finishLoops))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                stop()
            }
        }
    }
}
