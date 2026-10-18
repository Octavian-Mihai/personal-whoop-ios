import SwiftUI
import StrandAnalytics
import UIKit

struct BreatheView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = BreathProtocolCatalog.all[1]
    @State private var minutes = 5
    @State private var running = false
    @State private var elapsed = 0.0
    @State private var timer: Timer?
    @State private var lastStageIdx = -1

    var body: some View {
        Group {
            List {
                if running { runner }
                else {
                    Section("Protocol") {
                        Picker("Protocol", selection: $selected) {
                            ForEach(Dictionary(grouping: BreathProtocolCatalog.all, by: \.group).keys.sorted(), id: \.self) { g in
                                ForEach(BreathProtocolCatalog.all.filter { $0.group == g }) { Text($0.name).tag($0) }
                            }
                        }.pickerStyle(.navigationLink)
                        Text(selected.education).font(.footnote)
                        if let c = selected.caution { Label(c, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        if selected.playable { Text(String(format: "%.1f breaths/min", selected.breathsPerMinute)).font(.caption).foregroundStyle(.secondary) }
                        Stepper("\(minutes) min", value: $minutes, in: 1...30)
                        Button(selected.playable ? "Begin" : "Begin guided timer") { start() }.buttonStyle(.borderedProminent)
                    }
                    Section("Tools") {
                        NavigationLink("Spot HRV reading") { SpotHRVView() }
                        NavigationLink("HR-down relaxation metronome") { HRDownView() }
                        NavigationLink("Find my resonance pace") { ResonanceView() }
                    }
                }
            }
            .navigationTitle("Breathe")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { stop() }
        }
    }

    private var runner: some View {
        let tl = selected.timeline(durationSeconds: Double(minutes * 60))
        let idx = tl.lastIndex { $0.start <= elapsed } ?? 0
        let stage = tl.isEmpty ? BreathStage(kind: .text, seconds: 0) : tl[idx].stage
        let into = tl.isEmpty ? 0 : (elapsed - tl[idx].start) / max(0.1, stage.seconds)
        let scale: Double = stage.kind == .inhale ? 0.5 + 0.5 * into : (stage.kind == .exhale ? 1.0 - 0.5 * into : (idx > 0 && tl[idx - 1].stage.kind == .inhale ? 1.0 : 0.5))
        return Section {
            VStack(spacing: 16) {
                Circle().fill(Color.teal.opacity(0.5)).frame(width: 220 * scale, height: 220 * scale).frame(height: 230)
                Text(tl.isEmpty ? "Guided session" : stage.label).font(.largeTitle.bold())
                Text(fmtDuration(Double(minutes * 60 - Int(elapsed)) / 60)).foregroundStyle(.secondary)
                Button("End", role: .destructive) { stop() }
            }.frame(maxWidth: .infinity)
            .onChange(of: idx) { _, new in
                guard new != lastStageIdx else { return }
                lastStageIdx = new
                guard !tl.isEmpty else { return }
                // exhale onset = 2 pulses, inhale onset = 1; holds silent
                if stage.kind == .inhale { pulse(1) } else if stage.kind == .exhale { pulse(2) }
            }
        }
    }

    private func pulse(_ n: Int) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        for i in 1..<max(1, n) + 0 where n > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        }
        model.ble.buzz(loops: UInt8(n))
    }

    private func start() {
        running = true; elapsed = 0; lastStageIdx = -1
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                elapsed += 0.1
                if elapsed >= Double(minutes * 60) { stop() }
            }
        }
    }
    private func stop() { timer?.invalidate(); running = false; UIApplication.shared.isIdleTimerDisabled = false }
}

extension BreathProtocol: Hashable {
    public static func == (a: BreathProtocol, b: BreathProtocol) -> Bool { a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(name) }
}

struct SpotHRVView: View {
    @Environment(AppModel.self) private var model
    @State private var capturing = false
    @State private var rr: [Double] = []
    @State private var progress = 0.0
    @State private var outcome: SpotHrv.Outcome?

    var body: some View {
        Form {
            Section {
                Text("Sit still for 60 seconds. Needs a connected strap that sends R-R intervals.").font(.footnote)
                if capturing { ProgressView(value: progress); Text("\(rr.count) beats captured") }
                Button(capturing ? "Capturing…" : "Take reading") { start() }.disabled(capturing || model.ble.state != .connected)
            }
            if let o = outcome {
                Section("Result") {
                    switch o {
                    case .reading(let r):
                        LabeledContent("RMSSD", value: String(format: "%.0f ms", r.rmssd))
                        LabeledContent("Mean HR", value: String(format: "%.0f bpm", r.meanHR))
                        LabeledContent("pNN50", value: String(format: "%.0f%%", r.pnn50))
                        if let si = StressIndex.compute(rr) { LabeledContent("Stress index", value: String(format: "%.0f", si)) }
                        if let f = HRVFrequency.compute(rr), let lh = f.lfhf { LabeledContent("LF/HF (relative)", value: String(format: "%.2f", lh)) }
                        Text("A 60 s spot reading is not your overnight baseline. Optical R-R is noisier than a chest strap.").font(.caption2)
                    case .insufficient(let c, let need, let input):
                        Text("Only \(c) clean beats of \(input) (need \(need)). Sit still and try again.").foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Spot HRV")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        rr = []; outcome = nil; capturing = true; progress = 0
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor in
                rr += model.ble.lastRR; model.ble.lastRR = []
                t += 1; progress = t / 60
                if t >= 60 { timer.invalidate(); capturing = false; outcome = SpotHrv.evaluate(rr) }
            }
        }
    }
}

struct HRDownView: View {
    @Environment(AppModel.self) private var model
    @State private var pacer = HRDownPacer()
    @State private var running = false
    @State private var target = 0.0
    @State private var status = "Ready"
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 14) {
            Text("Heart rate \(model.ble.heartRate.map(String.init) ?? "—")").font(.title)
            Text(running ? String(format: "Pacing at %.0f bpm", target) : status).foregroundStyle(.secondary)
            Button(running ? "Stop" : "Start") { running ? stop("Stopped") : start() }.buttonStyle(.borderedProminent)
                .disabled(model.ble.heartRate == nil)
            Text("A relaxation metronome — one light buzz per beat, a few bpm under your heart rate. It never claims to lower your heart rate.")
                .font(.caption).multilineTextAlignment(.center).padding()
        }
        .navigationTitle("HR-down")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { timer?.invalidate() }
    }

    private func start() {
        pacer = HRDownPacer(); running = true
        scheduleBeat()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                guard running, let hr = model.ble.heartRate else { return }
                let r = pacer.ingest(t: Date().timeIntervalSince1970, smoothedHR: Double(hr))
                target = r.target
                if r.outcome != .running { t.invalidate(); stop(r.outcome == .settled ? "Settled under 60 bpm" : (r.outcome == .timeout ? "Finished — heart rate didn't fall much" : "Stopped")) }
            }
        }
    }
    private func scheduleBeat() {
        timer?.invalidate()
        guard target > 0 || running else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 / max(50, target == 0 ? 70 : target), repeats: false) { _ in
            Task { @MainActor in
                guard running else { return }
                model.ble.buzz(loops: 1); scheduleBeat()
            }
        }
    }
    private func stop(_ s: String) { running = false; timer?.invalidate(); status = s }
}

struct ResonanceView: View {
    @State private var best: Double?
    var body: some View {
        Form {
            Text("Sweeps 4.5–7.0 breaths/min and scores each pace by the heart-rate swing per breath cycle (respiratory sinus arrhythmia), dropping a 30 s transient. Needs ≥ 3 cycles on ≥ 3 paces; otherwise it falls back to 5.5/min.")
                .font(.footnote)
            Text("Paces: " + ResonanceEngine.sweep.map { String(format: "%.1f", $0) }.joined(separator: " · ")).font(.caption)
            LabeledContent("Your pace", value: String(format: "%.1f br/min", best ?? 5.5))
        }
        .navigationTitle("Resonance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
