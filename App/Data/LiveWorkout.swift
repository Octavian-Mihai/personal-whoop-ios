import SwiftUI
import Foundation
import Observation
import StrandAnalytics
import WhoopProtocol

enum WorkoutKind: String, CaseIterable, Identifiable {
    case run = "Run", walk = "Walk", cycle = "Cycle", strength = "Strength", hiit = "HIIT", swim = "Swim", yoga = "Yoga", other = "Other"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .run: return "figure.run"; case .walk: return "figure.walk"; case .cycle: return "figure.outdoor.cycle"
        case .strength: return "dumbbell.fill"; case .hiit: return "bolt.heart.fill"; case .swim: return "figure.pool.swim"
        case .yoga: return "figure.yoga"; case .other: return "figure.mixed.cardio"
        }
    }
    var colors: [Color] {
        switch self {
        case .run: return [Color(red: 1, green: 0.55, blue: 0.25), Color(red: 0.95, green: 0.25, blue: 0.3)]
        case .walk: return [Color(red: 0.3, green: 0.85, blue: 0.6), Color(red: 0.1, green: 0.6, blue: 0.5)]
        case .cycle: return [Color(red: 0.35, green: 0.75, blue: 1), Color(red: 0.15, green: 0.4, blue: 0.95)]
        case .strength: return [Color(red: 0.7, green: 0.45, blue: 1), Color(red: 0.45, green: 0.2, blue: 0.85)]
        case .hiit: return [Color(red: 1, green: 0.4, blue: 0.6), Color(red: 0.8, green: 0.1, blue: 0.4)]
        case .swim: return [Color(red: 0.3, green: 0.9, blue: 0.95), Color(red: 0.1, green: 0.55, blue: 0.85)]
        case .yoga: return [Color(red: 1, green: 0.8, blue: 0.4), Color(red: 0.95, green: 0.55, blue: 0.3)]
        case .other: return [Color(red: 0.6, green: 0.65, blue: 0.75), Color(red: 0.35, green: 0.4, blue: 0.55)]
        }
    }
    /// Target HR zone band (1…5) the coach holds you to.
    var targetZones: ClosedRange<Int> {
        switch self {
        case .run: return 2...4; case .walk: return 1...2; case .cycle: return 2...3; case .strength: return 1...4
        case .hiit: return 4...5; case .swim: return 2...3; case .yoga: return 0...1; case .other: return 1...4
        }
    }
    /// Strength and HIIT have deliberate rest, so being *below* the band isn't nagged.
    var nagsBelow: Bool { self != .strength && self != .hiit && self != .yoga }
    var lapName: String { self == .strength ? "Set" : (self == .hiit ? "Interval" : "Lap") }
    var hint: String {
        switch self {
        case .run: return "Steady aerobic: hold zones 2–4."
        case .walk: return "Easy pace: zones 1–2."
        case .cycle: return "Smooth effort: zones 2–3."
        case .strength: return "Tap Set after each set; recovery HR is captured 60 s later."
        case .hiit: return "Hard efforts in zones 4–5; tap Interval at each change."
        case .swim: return "Wrist HR can read low in water — treat as approximate."
        case .yoga: return "Stay in zones 0–1."
        case .other: return "General tracking, zones 1–4."
        }
    }
    var intervalMode: Bool { self == .hiit }
}

@Observable
@MainActor
final class LiveWorkout {
    let kind: WorkoutKind
    let startedAt = Date().timeIntervalSince1970
    private(set) var samples: [HRSample] = []
    private(set) var laps: [Lap] = []
    private(set) var elapsed = 0.0
    private(set) var bpm: Int?
    private(set) var kcal = 0.0
    private(set) var effort: Double?
    private(set) var cue: String?
    private(set) var simulated = false
    private(set) var zoneSeconds: [Int: Double] = [:]
    private(set) var pendingRest: (lapIndex: Int, at: Double)?

    private let profile: Profile
    private let rhr: Double
    private let hrMax: Double
    private let zones: HRZones
    private var latest: (bpm: Double, t: Double)?
    private var window: [Double] = []
    private var lapStart: Double
    private var outOfBandSince: Double?
    private var lastCue = -Double.infinity
    private var timer: Timer?
    private weak var ble: BLEManager?
    private var simPhase = 0.0

    init(kind: WorkoutKind, profile: Profile, restingHR: Double, ble: BLEManager) {
        self.kind = kind; self.profile = profile; self.rhr = restingHR; self.ble = ble
        hrMax = profile.hrMaxOverride ?? 208 - 0.7 * profile.age
        zones = HRZones(age: profile.age, override: profile.hrMaxOverride)
        lapStart = startedAt
        // Ask the strap for its realtime HR stream (~1 Hz) while we are tracking.
        if ble.state == .connected { ble.send(.toggleRealtimeHR, payload: [0x01]) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var smoothedBPM: Int? { window.isEmpty ? nil : Int(median(window).rounded()) }
    var zone: Int? { smoothedBPM.map { zones.zone(for: Double($0)) } }
    var avgHR: Double? { samples.isEmpty ? nil : mean(samples.map(\.bpm)) }
    var peakHR: Double? { samples.map(\.bpm).max() }
    var inTarget: Bool { zone.map { kind.targetZones.contains($0) } ?? true }
    var series: [HRSample] { samples.count > 600 ? stride(from: 0, to: samples.count, by: samples.count / 600).map { samples[$0] } : samples }

    /// Real strap reading.
    func ingest(bpm: Int) {
        guard (30...220).contains(bpm) else { return }
        latest = (Double(bpm), Date().timeIntervalSince1970)
        simulated = false
    }

    private func simulate(now: Double) -> Double {
        // Demo HR when no strap is connected: random walk inside the type's target band.
        simPhase += 1
        let band = kind.targetZones
        let mid = (Double(band.lowerBound) + Double(band.upperBound) + 1) / 2 * 0.1 + 0.45
        let base = hrMax * mid
        let wave = kind == .hiit ? (Int(simPhase / 30) % 2 == 0 ? 22.0 : -25.0) : (kind == .strength ? (Int(simPhase / 45) % 2 == 0 ? 18.0 : -20.0) : 6 * sin(simPhase / 40))
        let warm = min(1, simPhase / 90)
        return rhr + (base + wave - rhr) * warm + Double.random(in: -2...2)
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        elapsed = now - startedAt
        var value: Double?
        if let l = latest, now - l.t < 6 { value = l.bpm }
        else if ble?.state != .connected { value = simulate(now: now); simulated = true }
        guard let v = value else { return }
        let s = HRSample(t: now, bpm: v)
        samples.append(s)
        window.append(v); if window.count > 10 { window.removeFirst() }
        bpm = Int(v.rounded())
        zoneSeconds[zones.zone(for: v), default: 0] += 1
        // kcal: Keytel above the active gate, resting rate below it
        let gate = rhr + 0.30 * (hrMax - rhr)
        let perMin = v >= gate ? Calories.keytelPerMinute(hr: v, profile) : Calories.bmrPerMinute(profile)
        kcal += perMin / 60
        if samples.count % 5 == 0 { effort = StrainScorer.score(hr: samples, restingHR: rhr, hrMax: hrMax, requireGates: false) }
        resolveRest(now: now)
        coach(now: now)
    }

    private func coach(now: Double) {
        guard elapsed >= 60, let z = zone else { return }
        let band = kind.targetZones
        let above = z > band.upperBound, below = z < band.lowerBound && kind.nagsBelow
        if above || below {
            if outOfBandSince == nil { outOfBandSince = now }
            if now - outOfBandSince! >= 30, now - lastCue >= 60 {
                lastCue = now
                cue = above ? "Ease off — above zone \(band.upperBound)" : "Push a little — below zone \(band.lowerBound)"
                ble?.buzz(loops: above ? 1 : 2)
            }
        } else { outOfBandSince = nil; if now - lastCue > 8 { cue = nil } }
    }

    // MARK: laps / sets
    func markLap() {
        let now = Date().timeIntervalSince1970
        let w = samples.filter { $0.t >= lapStart && $0.t <= now }.map(\.bpm)
        guard !w.isEmpty else { return }
        laps.append(Lap(start: lapStart, end: now, avgHR: mean(w), peakHR: w.max()!, restHR: nil))
        lapStart = now
        if kind == .strength { pendingRest = (laps.count - 1, now + 60) }
    }

    private func resolveRest(now: Double) {
        guard let p = pendingRest, now >= p.at else { return }
        let w = samples.filter { abs($0.t - p.at) <= 5 }.map(\.bpm)
        if !w.isEmpty { laps[p.lapIndex].restHR = mean(w) }
        pendingRest = nil
    }

    // MARK: finish
    func finish() -> SavedWorkout? {
        timer?.invalidate()
        if ble?.state == .connected { ble?.send(.toggleRealtimeHR, payload: [0x00]) }
        guard samples.count >= 10 else { return nil }
        let now = Date().timeIntervalSince1970
        if laps.isEmpty || lapStart < now - 5, kind != .strength { markLap() }
        let series = stride(from: 0, to: samples.count, by: 5).map { samples[$0].bpm }
        return SavedWorkout(laps: laps, zoneSeconds: zoneSeconds, hrSeries: series, sport: kind.rawValue, start: startedAt, end: now,
                            avgHR: avgHR, peakHR: peakHR, kcal: kcal,
                            effort: StrainScorer.score(hr: samples, restingHR: rhr, hrMax: hrMax, requireGates: false),
                            distanceM: nil, source: simulated ? "live (simulated HR)" : "live", typeGuess: nil)
    }

    func cancel() {
        timer?.invalidate()
        if ble?.state == .connected { ble?.send(.toggleRealtimeHR, payload: [0x00]) }
    }
}
