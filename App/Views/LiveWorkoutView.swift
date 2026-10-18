import SwiftUI
import Charts
import StrandAnalytics

struct WorkoutStartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind = WorkoutKind.run

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ForEach(WorkoutKind.allCases) { k in
                        Button { kind = k } label: {
                            VStack(spacing: 6) {
                                Image(systemName: k.icon).font(.title2)
                                Text(k.rawValue).font(.caption)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(kind == k ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind == k ? Color.accentColor : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
                Text(kind.hint).font(.subheadline)
                Text("Target zones \(kind.targetZones.lowerBound)–\(kind.targetZones.upperBound) · tracked at 1 reading/second").font(.caption).foregroundStyle(.secondary)
                Label(model.ble.state == .connected ? "Strap connected — realtime HR will be requested" : "No strap connected — heart rate will be simulated and labelled as such",
                      systemImage: model.ble.state == .connected ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(model.ble.state == .connected ? .green : .orange)
                Spacer()
                Button { model.startWorkout(kind); dismiss() } label: { Text("Start").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding()
            .navigationTitle("New workout")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

func zoneColor(_ z: Int?) -> Color {
    switch z ?? 0 {
    case 0: return Color(red: 0.74, green: 0.76, blue: 0.82)
    case 1: return Palette.sky[1]
    case 2: return Palette.mint[1]
    case 3: return Palette.butter[1]
    case 4: return Palette.peach[1]
    default: return Palette.rose[1]
    }
}

struct LiveWorkoutView: View {
    @Environment(AppModel.self) private var model
    let live: LiveWorkout
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(live.kind.rawValue, systemImage: live.kind.icon).font(.headline)
                Spacer()
                Text(clock(live.elapsed)).font(.title2.monospacedDigit().bold())
            }
            VStack(spacing: 2) {
                Text(live.smoothedBPM.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(zoneColor(live.zone))
                Text("bpm · zone \(live.zone.map(String.init) ?? "—") · target \(live.kind.targetZones.lowerBound)–\(live.kind.targetZones.upperBound)")
                    .font(.subheadline).foregroundStyle(live.inTarget ? Color.secondary : .orange)
                if live.simulated { Text("Simulated HR — no strap connected").font(.caption).foregroundStyle(.orange) }
            }
            if let cue = live.cue { Text(cue).font(.headline).padding(8).frame(maxWidth: .infinity).background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 10)) }

            Chart {
                ForEach(live.series.suffix(300), id: \.t) { s in
                    LineMark(x: .value("t", Date(timeIntervalSince1970: s.t)), y: .value("bpm", s.bpm)).foregroundStyle(zoneColor(live.zone))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false)).frame(height: 120)

            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "Avg HR", value: live.avgHR.map { String(format: "%.0f", $0) } ?? "—")
                    Stat(label: "Peak", value: live.peakHR.map { String(format: "%.0f", $0) } ?? "—")
                    Stat(label: "Calories", value: String(format: "%.0f kcal", live.kcal))
                    Stat(label: "Effort", value: live.effort.map { String(format: "%.0f", $0) } ?? "—")
                }
            }
            zoneBars
            if !live.laps.isEmpty {
                ScrollView { VStack(spacing: 4) { ForEach(Array(live.laps.enumerated()), id: \.offset) { i, l in lapRow(i, l) } } }.frame(maxHeight: 110)
            }
            Spacer(minLength: 0)
            HStack {
                Button { live.markLap() } label: { Text(live.kind.lapName).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                Button(role: .destructive) { confirmEnd = true } label: { Text("Finish").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding()
        .confirmationDialog("End workout?", isPresented: $confirmEnd) {
            Button("Save workout") { model.finishWorkout(save: true) }
            Button("Discard", role: .destructive) { model.finishWorkout(save: false) }
            Button("Keep going", role: .cancel) {}
        }
    }

    private var zoneBars: some View {
        let total = max(1, live.zoneSeconds.values.reduce(0, +))
        return HStack(spacing: 2) {
            ForEach(0...5, id: \.self) { z in
                let f = (live.zoneSeconds[z] ?? 0) / total
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(zoneColor(z)).frame(height: max(3, 40 * f))
                    Text("Z\(z)").font(.caption2)
                }.frame(maxWidth: .infinity, maxHeight: 56, alignment: .bottom)
            }
        }
    }

    private func lapRow(_ i: Int, _ l: Lap) -> some View {
        HStack {
            Text("\(live.kind.lapName) \(i + 1)").font(.caption)
            Spacer()
            Text(clock(l.end - l.start)).font(.caption.monospacedDigit())
            Text(String(format: "avg %.0f · peak %.0f", l.avgHR, l.peakHR)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let r = l.restHR { Text(String(format: "rest %.0f", r)).font(.caption.monospacedDigit()).foregroundStyle(.green) }
        }
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

struct WorkoutDetailView: View {
    let workout: SavedWorkout
    var body: some View {
        List {
            Section {
                LabeledContent("Duration", value: fmtDuration((workout.end - workout.start) / 60))
                if let v = workout.avgHR { LabeledContent("Avg HR", value: String(format: "%.0f bpm", v)) }
                if let v = workout.peakHR { LabeledContent("Peak HR", value: String(format: "%.0f bpm", v)) }
                if let v = workout.kcal { LabeledContent("Calories", value: String(format: "%.0f kcal", v)) }
                if let v = workout.effort { LabeledContent("Effort", value: String(format: "%.0f", v)) }
                LabeledContent("Source", value: workout.source)
            }
            if let h = workout.hrSeries, h.count > 2 {
                Section("Heart rate") {
                    Chart(Array(h.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("min", Double(i) * 5 / 60), y: .value("bpm", v))
                    }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 160)
                }
            }
            if let z = workout.zoneSeconds, !z.isEmpty {
                Section("Time in zones") {
                    ForEach(0...5, id: \.self) { i in
                        if let s = z[i], s > 0 {
                            HStack { Circle().fill(zoneColor(i)).frame(width: 10, height: 10); Text("Zone \(i)"); Spacer(); Text(fmtDuration(s / 60)).monospacedDigit() }
                        }
                    }
                }
            }
            if let laps = workout.laps, !laps.isEmpty {
                Section("Laps / sets") {
                    ForEach(Array(laps.enumerated()), id: \.offset) { i, l in
                        HStack {
                            Text("#\(i + 1)")
                            Spacer()
                            Text(String(format: "avg %.0f · peak %.0f", l.avgHR, l.peakHR)).monospacedDigit().foregroundStyle(.secondary)
                            if let r = l.restHR { Text(String(format: "rest %.0f", r)).foregroundStyle(.green) }
                        }.font(.caption)
                    }
                }
            }
        }
        .navigationTitle(workout.sport)
    }
}
