import SwiftUI
import Charts
import StrandAnalytics
import UIKit

struct WorkoutsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Heatmap · last 13 weeks") { heatmap }
                if !model.detected.isEmpty {
                    Section("Detected today") {
                        ForEach(model.detected) { w in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(fmtClock(w.start)) · \(fmtDuration(w.durationMin))").font(.headline)
                                Text(String(format: "avg %.0f · peak %.0f bpm · %.0f kcal · effort %.0f", w.avgHR, w.peakHR, w.kcal, w.effort ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Logged") {
                    if model.snapshot.workouts.isEmpty { Text("Nothing logged yet").foregroundStyle(.secondary) }
                    ForEach(model.snapshot.workouts) { w in
                        VStack(alignment: .leading) {
                            Text("\(w.sport) · \(fmtDuration((w.end - w.start) / 60))").font(.headline)
                            Text(Date(timeIntervalSince1970: w.start).formatted(date: .abbreviated, time: .shortened) + (w.kcal.map { String(format: " · %.0f kcal", $0) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Tools") {
                    NavigationLink("Interval timer") { IntervalTimerView() }
                    NavigationLink("Lift Log") { LiftLogView() }
                    NavigationLink("Live session coach") { LiveCoachView() }
                }
            }
            .navigationTitle("Workouts")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showAdd) { ManualWorkoutSheet() }
        }
    }

    private var heatmap: some View {
        let cal = Calendar(identifier: .iso8601)
        let kcal = Dictionary(uniqueKeysWithValues: model.days.map { ($0.day, ($0.kcal ?? 0) - 2000 > 0 ? ($0.kcal ?? 0) - 2000 : 0) })
        let daily = Array(kcal.values)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return HStack(spacing: 3) {
            ForEach(0..<13, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        let date = cal.date(byAdding: .day, value: (w - 12) * 7 + d, to: weekStart)!
                        let v = date > Date() ? nil : kcal[DayFormat.string(date)]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v == nil ? Color.clear : Color.green.opacity([0.08, 0.3, 0.5, 0.75, 1][ActivityHeatmap.level(value: v ?? 0, daily: daily)]))
                            .frame(height: 14)
                    }
                }
            }
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

struct LiveCoachView: View {
    @Environment(AppModel.self) private var model
    @State private var coach: LiveSessionCoach?
    @State private var cue: String = "Warming up"

    var body: some View {
        VStack(spacing: 16) {
            Text(model.ble.heartRate.map(String.init) ?? "—").font(.system(size: 90, weight: .bold, design: .rounded))
            Text(cue).font(.title2.bold())
            if let c = coach {
                Text(String(format: "Target %.0f–%.0f%% of HRR", c.band.lowerBound * 100, c.band.upperBound * 100)).foregroundStyle(.secondary)
            }
            Text("Needs a connected strap. Coaching starts after a 60 s warm-up and stays silent unless you're out of band for 25 s.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        }
        .navigationTitle("Live coach")
        .onAppear {
            coach = LiveSessionCoach(restingHR: model.today?.restingHR ?? 58, hrMax: 208 - 0.7 * model.settings.profile.age, charge: model.today?.charge)
        }
        .onChange(of: model.ble.heartRate) { _, bpm in
            guard let bpm, var c = coach else { return }
            if let q = c.ingest(t: Date().timeIntervalSince1970, bpm: Double(bpm)) {
                cue = q.rawValue
                model.ble.buzz(loops: q == .push ? 2 : 1)
            }
            coach = c
        }
    }
}
