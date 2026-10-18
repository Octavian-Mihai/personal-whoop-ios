import SwiftUI
import StrandAnalytics

struct LiftLogView: View {
    @Environment(AppModel.self) private var model
    @State private var session: LiftSession?
    @State private var showSession = false

    var body: some View {
        List {
            Section {
                Button("Start session") { startSession() }
            }
            Section("History") {
                if model.snapshot.lifts.isEmpty { Text("No lifts yet").foregroundStyle(.secondary) }
                ForEach(model.snapshot.lifts) { l in
                    NavigationLink {
                        LiftDetail(log: l)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(l.title).font(.headline)
                            Text(Date(timeIntervalSince1970: l.date).formatted(date: .abbreviated, time: .omitted) +
                                 String(format: " · %.0f kg volume", l.exercises.reduce(0) { $0 + LiftMetrics.volumeLoad($1.sets) }))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Weekly sets per muscle") {
                let recent = model.snapshot.lifts.filter { $0.date > Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970 }
                let per = LiftMetrics.setsPerMuscle(recent.flatMap(\.exercises))
                if per.isEmpty { Text("Log a session to see fractional sets").font(.footnote) }
                ForEach(per.sorted { $0.value > $1.value }, id: \.key) { m, v in
                    LabeledContent(m.rawValue.capitalized, value: String(format: "%.1f", v))
                }
                Text(LiftMetrics.referenceBand).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Lift Log")
        .sheet(isPresented: $showSession) {
            if let s = session { LiftSessionView(session: s) { showSession = false } }
        }
    }

    private func startSession() {
        session = LiftSession(plan: [("Back Squat", 4, 100, 5), ("Bench Press", 3, 80, 8), ("Barbell Row", 3, 70, 8)], now: Date().timeIntervalSince1970)
        showSession = true
    }
}

struct LiftDetail: View {
    let log: LiftWorkoutLog
    var body: some View {
        List {
            ForEach(log.exercises) { e in
                Section(e.name) {
                    ForEach(Array(e.sets.enumerated()), id: \.offset) { i, s in
                        HStack {
                            Text("Set \(i + 1)\(s.isWarmup ? " (warm-up)" : "")")
                            Spacer()
                            Text("\(s.weightKg.map { String(format: "%.1f", $0) } ?? "—") kg × \(s.reps.map(String.init) ?? "—")")
                                .monospacedDigit()
                        }
                    }
                    if let b = LiftMetrics.bestSet(e.sets), let w = b.weightKg, let r = b.reps, let e1 = LiftMetrics.epley(weight: w, reps: r) {
                        Text(String(format: "Est. 1RM %.1f kg · Volume %.0f kg", e1, LiftMetrics.volumeLoad(e.sets))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let rpe = log.rpe, let load = LiftMetrics.sessionLoad(rpe: rpe, minutes: log.minutes) {
                Text(String(format: "Session load (sRPE × min): %.0f", load))
            }
        }
        .navigationTitle(log.title)
    }
}

struct LiftSessionView: View {
    @Environment(AppModel.self) private var model
    @State var session: LiftSession
    var onDone: () -> Void
    @State private var weight = ""
    @State private var reps = ""
    @State private var rpe = ""
    @State private var tick = Date()
    @State private var buzzed = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if session.restRemaining(now: tick.timeIntervalSince1970) > 0 {
                    Section { Label("Rest \(Int(session.restRemaining(now: tick.timeIntervalSince1970))) s", systemImage: "timer").font(.title2.bold()) }
                }
                if let c = session.current {
                    let slot = session.slots[c]
                    Section("Now") {
                        Text("\(slot.exercise) · set \(slot.setIndex + 1)").font(.headline)
                        if let w = slot.targetWeight, let r = slot.targetReps { Text("Suggested \(Int(w)) kg × \(r)").foregroundStyle(.gray) }
                        TextField("Weight kg", text: $weight).keyboardType(.decimalPad)
                        TextField("Reps", text: $reps).keyboardType(.numberPad)
                        TextField("RPE (optional)", text: $rpe).keyboardType(.decimalPad)
                        Button("Record set") { record(slot) }.buttonStyle(.borderedProminent)
                    }
                }
                Section("Sheet — start any pending set") {
                    ForEach(Array(session.slots.enumerated()), id: \.element.id) { i, s in
                        Button {
                            session.start(slot: i)
                        } label: {
                            HStack {
                                Text("\(s.exercise) #\(s.setIndex + 1)")
                                Spacer()
                                if let d = s.done { Text("\(d.weightKg.map { String(format: "%.0f", $0) } ?? "—") × \(d.reps.map(String.init) ?? "—")").foregroundStyle(.green) }
                                else if i == session.current { Image(systemName: "arrowtriangle.right.fill") }
                            }
                        }.tint(.primary)
                    }
                }
                Section {
                    Button("Finish & save") { finish() }
                    Button("Discard", role: .destructive) { onDone() }
                }
            }
            .navigationTitle("Session")
            .onReceive(timer) { tick = $0
                let rem = session.restRemaining(now: tick.timeIntervalSince1970)
                if rem > 0 && rem <= 5 && !buzzed { buzzed = true; model.ble.buzz(loops: 3) }
                if rem == 0 { buzzed = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .strapDoubleTap)) { _ in
                // double-tap with filter: records the pre-filled suggestion
                if let c = session.current, let w = session.slots[c].targetWeight, let r = session.slots[c].targetReps, weight.isEmpty {
                    session.record(LiftSet(weightKg: w, reps: r), now: Date().timeIntervalSince1970); model.ble.buzz(loops: 1)
                }
            }
        }
    }

    private func record(_ slot: LiftSession.Slot) {
        let s = LiftSet(weightKg: Double(weight) ?? slot.targetWeight, reps: Int(reps) ?? slot.targetReps, rpe: Double(rpe))
        session.record(s, now: Date().timeIntervalSince1970)
        weight = ""; reps = ""; rpe = ""
    }

    private func finish() {
        var by: [String: [LiftSet]] = [:]
        var order: [String] = []
        for s in session.slots { if by[s.exercise] == nil { order.append(s.exercise) }; if let d = s.done { by[s.exercise, default: []].append(d) } }
        let ex = order.map { LiftExercise(name: $0, direct: muscles($0).0, indirect: muscles($0).1, sets: by[$0] ?? []) }
        let mins = (Date().timeIntervalSince1970 - session.startedAt) / 60
        let rpes = session.slots.compactMap { $0.done?.rpe }
        model.addLift(LiftWorkoutLog(date: session.startedAt, title: "Strength session", rpe: rpes.isEmpty ? nil : mean(rpes), minutes: mins, exercises: ex))
        onDone()
    }

    private func muscles(_ n: String) -> ([Muscle], [Muscle]) {
        switch n {
        case "Back Squat": return ([.quads, .glutes], [.hamstrings, .adductors, .lowerBack])
        case "Bench Press": return ([.chest], [.frontDelts, .triceps])
        case "Barbell Row": return ([.lats, .upperBack], [.biceps, .rearDelts, .forearms])
        default: return ([], [])
        }
    }
}
