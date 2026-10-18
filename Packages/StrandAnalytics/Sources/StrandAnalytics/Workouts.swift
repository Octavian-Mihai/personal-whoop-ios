import Foundation

public struct DetectedWorkout: Sendable, Identifiable, Equatable {
    public var id: Double { start }
    public var start: Double, end: Double
    public var avgHR: Double, peakHR: Double
    public var zone2PlusFraction: Double
    public var meanPctHRR: Double
    public var effort: Double?
    public var kcal: Double
    public var durationMin: Double { (end - start) / 60 }
}

/// §8.1 Retroactive detection: HR > RHR+15 and smoothed motion > 0.20.
public enum WorkoutDetector {
    public static func detect(hr: [HRSample], motion: [GravitySample], restingHR: Double?, hrMax: Double, profile: Profile) -> [DetectedWorkout] {
        guard hr.count > 60 else { return [] }
        let rhr = restingHR ?? percentile(hr.map(\.bpm), 0.10)
        // 10 s smoothed motion intensity keyed by second
        var motionAt: [Int: Double] = [:]
        if motion.count > 1 {
            for i in 1..<motion.count {
                let a = motion[i - 1], b = motion[i]
                let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).squareRoot()
                motionAt[Int(b.t / 10), default: 0] = max(motionAt[Int(b.t / 10), default: 0], d)
            }
        }
        let hasMotion = !motionAt.isEmpty
        let s = hr.sorted { $0.t < $1.t }
        var flags: [(t: Double, on: Bool)] = s.map { x in
            let moving = hasMotion ? (motionAt[Int(x.t / 10)] ?? 0) > 0.20 : true
            return (x.t, x.bpm > rhr + 15 && moving)
        }
        // runs
        var runs: [(Double, Double)] = []
        var start: Double?; var last = 0.0; var lastOnT = 0.0
        for f in flags {
            if f.on {
                if let st = start {
                    let gap = f.t - lastOnT
                    if gap >= 150 { runs.append((st, lastOnT)); start = f.t }
                } else { start = f.t }
                lastOnT = f.t
            }
            last = f.t
        }
        _ = last; flags = []
        if let st = start { runs.append((st, lastOnT)) }
        let hrr = max(1, hrMax - rhr)
        return runs.compactMap { r -> DetectedWorkout? in
            guard r.1 - r.0 >= 300 else { return nil }
            let w = s.filter { $0.t >= r.0 && $0.t <= r.1 }
            let pcts = w.map { clamp(($0.bpm - rhr) / hrr * 100, 0, 100) }
            let z2 = Double(pcts.filter { $0 >= 60 }.count) / Double(max(1, pcts.count))
            // Edwards zone 2+ means ≥ 60 %HRR
            guard z2 >= 0.5 || Double(pcts.filter { $0 >= 50 }.count) / Double(max(1, pcts.count)) >= 0.5 else { return nil }
            return DetectedWorkout(start: r.0, end: r.1, avgHR: mean(w.map(\.bpm)), peakHR: w.map(\.bpm).max() ?? 0,
                                   zone2PlusFraction: z2, meanPctHRR: mean(pcts),
                                   effort: StrainScorer.score(hr: w, restingHR: rhr, hrMax: hrMax),
                                   kcal: Calories.kcal(hr: w, restingHR: rhr, hrMax: hrMax, profile: profile, wholeDay: false))
        }
    }
}

/// §8.2 "Did you just work out?"
public enum AutoWorkoutDetector {
    public static func suggest(hr: [HRSample], restingHR: Double?, savedWorkouts: [(Double, Double)]) -> (start: Double, end: Double)? {
        let rhr = restingHR ?? 60
        let s = hr.sorted { $0.t < $1.t }
        var winStart: Double?; var lastHigh = 0.0
        var wins: [(Double, Double)] = []
        for x in s {
            if x.bpm >= rhr + 30 {
                if winStart == nil { winStart = x.t } else if x.t - lastHigh > 90 { wins.append((winStart!, lastHigh)); winStart = x.t }
                lastHigh = x.t
            }
        }
        if let w = winStart { wins.append((w, lastHigh)) }
        var merged: [(Double, Double)] = []
        for w in wins {
            if let l = merged.last, w.0 - l.1 < 300 { merged[merged.count - 1].1 = w.1 } else { merged.append(w) }
        }
        return merged.filter { $0.1 - $0.0 >= 12 * 60 }
            .filter { w in !savedWorkouts.contains { $0.0 < w.1 && $0.1 > w.0 } }
            .last.map { (start: $0.0, end: $0.1) }
    }
}

public enum WorkoutType: String, Sendable, CaseIterable { case walk, run, strength, cycle, ski, other }

public struct WorkoutFeatures: Sendable {
    public var pctHRR: Double?, hrCV: Double, stillFrac: Double, walkFrac: Double, runFrac: Double
    public var tickCoverage: Double, motionVar: Double, kcalPerMin: Double
    public init(pctHRR: Double?, hrCV: Double, stillFrac: Double, walkFrac: Double, runFrac: Double,
                tickCoverage: Double, motionVar: Double, kcalPerMin: Double) {
        self.pctHRR = pctHRR; self.hrCV = hrCV; self.stillFrac = stillFrac; self.walkFrac = walkFrac
        self.runFrac = runFrac; self.tickCoverage = tickCoverage; self.motionVar = motionVar; self.kcalPerMin = kcalPerMin
    }
}

/// §8.3 Coarse type: advisory only.
public enum WorkoutTypeClassifier {
    static func up(_ x: Double, _ lo: Double, _ hi: Double) -> Double { clamp01((x - lo) / (hi - lo)) }
    static func down(_ x: Double, _ lo: Double, _ hi: Double) -> Double { 1 - up(x, lo, hi) }
    static func plateau(_ x: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { min(up(x, a, b), down(x, c, d)) }

    public static func scores(_ f: WorkoutFeatures) -> [WorkoutType: Double] {
        let rel = clamp01((f.tickCoverage - 0.045) / (0.15 - 0.045))
        let hrr = f.pctHRR
        let noGait = up(f.stillFrac, 0.40, 0.75)
        func blend(_ tick: Double, _ fallback: Double) -> Double { rel * tick + (1 - rel) * fallback }

        let run = blend(0.55 * up(f.runFrac, 0.15, 0.55) + 0.25 * up(hrr ?? 0, 45, 75) + 0.15 * plateau(f.motionVar, 0.05, 0.10, 0.35, 0.60) + 0.05 * down(f.hrCV, 0.05, 0.12),
                        0.45 * up(hrr ?? 0, 45, 75) + 0.35 * plateau(f.motionVar, 0.05, 0.10, 0.35, 0.60) + 0.20 * down(f.hrCV, 0.05, 0.12))
        let walk = blend(0.60 * up(f.walkFrac, 0.15, 0.55) + 0.25 * plateau(hrr ?? 0, 5, 15, 35, 55) + 0.15 * plateau(f.motionVar, 0.005, 0.02, 0.07, 0.12),
                         0.55 * plateau(hrr ?? 0, 5, 15, 35, 55) + 0.45 * plateau(f.motionVar, 0.005, 0.02, 0.07, 0.12))
        let strength = 0.45 * up(f.hrCV, 0.06, 0.16) + 0.20 * noGait + 0.20 * down(f.motionVar, 0.01, 0.05) + 0.10 * plateau(hrr ?? 0, 15, 30, 80, 100) + 0.05 * down(f.kcalPerMin, 6, 11)
        let cycle = 0.30 * noGait + 0.30 * down(f.hrCV, 0.04, 0.10) + 0.25 * up(hrr ?? 0, 35, 65) + 0.15 * down(f.motionVar, 0.005, 0.03)
        let ski = 0.30 * noGait + 0.30 * plateau(f.motionVar, 0.06, 0.14, 0.45, 0.70) + 0.20 * plateau(hrr ?? 0, 20, 35, 85, 100) + 0.20 * plateau(f.hrCV, 0.05, 0.09, 0.20, 0.32)
        return [.run: run, .walk: walk, .strength: strength, .cycle: cycle, .ski: ski]
    }

    public static func classify(_ f: WorkoutFeatures) -> (type: WorkoutType, confidence: Double) {
        let sc = scores(f).sorted { $0.value > $1.value }
        guard let top = sc.first, sc.count > 1 else { return (.other, 0) }
        let margin = top.value - sc[1].value
        guard top.value >= 0.40, margin >= 0.05 else { return (.other, 0.2) }
        let completeness = 0.70 + (f.pctHRR != nil ? 0.15 : 0) + (f.tickCoverage >= 0.15 ? 0.15 : 0)
        return (top.key, top.value * (0.5 + 0.5 * min(1, margin)) * completeness)
    }
}

/// §8.4 Live session coach.
public struct LiveSessionCoach: Sendable {
    public enum Cue: String, Sendable { case push = "PUSH", easeOff = "EASE OFF" }
    public var restingHR: Double, hrMax: Double, charge: Double?
    var window: [(t: Double, bpm: Double)] = []
    var startedAt: Double?
    var belowSince: Double?, aboveSince: Double?
    var lastCue: Double = -.infinity
    var lastData: Double = 0

    public init(restingHR: Double, hrMax: Double, charge: Double?) { self.restingHR = restingHR; self.hrMax = hrMax; self.charge = charge }

    public var band: ClosedRange<Double> {
        let ceiling = 0.60 + 0.22 * clamp01((charge ?? 50) / 100)
        let floor = max(0.40, ceiling - 0.15)
        return floor...ceiling
    }

    public mutating func ingest(t: Double, bpm: Double) -> Cue? {
        guard (30...220).contains(bpm) else { return nil }
        if startedAt == nil { startedAt = t }
        if t - lastData > 8, lastData > 0 { belowSince = nil; aboveSince = nil }
        lastData = t
        window.append((t, bpm)); window.removeAll { t - $0.t > 12 }
        let med = median(window.map(\.bpm))
        let frac = (med - restingHR) / max(1, hrMax - restingHR)
        guard t - startedAt! >= 60 else { return nil }
        let b = band
        if frac < b.lowerBound - 0.02 { belowSince = belowSince ?? t } else { belowSince = nil }
        if frac > b.upperBound + 0.02 { aboveSince = aboveSince ?? t } else { aboveSince = nil }
        guard t - lastCue >= 50 else { return nil }
        if let s = belowSince, t - s >= 25 { lastCue = t; belowSince = nil; return .push }
        if let s = aboveSince, t - s >= 25 { lastCue = t; aboveSince = nil; return .easeOff }
        return nil
    }
}

/// §8.5 Heart-rate recovery.
public struct HRRecovery: Sendable {
    public var cessation: Double
    public var oneMin: Double?, twoMin: Double?, fiveMin: Double?
    public static func compute(hr: [HRSample], workoutEnd: Double, hrMax: Double) -> HRRecovery? {
        let s = hr.filter { (30...250).contains($0.bpm) }.sorted { $0.t < $1.t }
        let tail = s.filter { $0.t >= workoutEnd - 300 && $0.t <= workoutEnd }
        // eligibility: ≥120 s continuous ≥ 70 % HRmax, no gap > 10 s
        var best = 0.0, runStart: Double?, prev = 0.0
        for x in tail {
            if x.bpm >= 0.7 * hrMax && (runStart == nil || x.t - prev <= 10) {
                if runStart == nil { runStart = x.t }
                best = max(best, x.t - runStart!)
            } else if x.bpm >= 0.7 * hrMax { runStart = x.t } else { runStart = nil }
            prev = x.t
        }
        guard best >= 120 else { return nil }
        let final = s.filter { $0.t >= workoutEnd - 30 && $0.t <= workoutEnd }
        guard final.count >= 3 else { return nil }
        let cess = final.map(\.bpm).max()!
        func at(_ m: Double) -> Double? {
            let w = s.filter { abs($0.t - (workoutEnd + m * 60)) <= 15 }.map(\.bpm)
            guard w.count >= 3 else { return nil }
            return cess - median(w)
        }
        let r = HRRecovery(cessation: cess, oneMin: at(1), twoMin: at(2), fiveMin: at(5))
        return (r.oneMin ?? r.twoMin ?? r.fiveMin) == nil ? nil : r
    }
}

/// §8.6 Manual workouts.
public struct ManualWorkout: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var sport: String
    public var start: Double
    public var end: Double
    public var distanceM: Double?
    public var avgHR: Double?
    public var kcal: Double?
    public var strain: Double?

    public init(sport: String, start: Double, end: Double, distanceM: Double? = nil, avgHR: Double? = nil, kcal: Double? = nil, strain: Double? = nil) {
        self.sport = sport; self.start = start; self.end = end; self.distanceM = distanceM
        self.avgHR = avgHR; self.kcal = kcal; self.strain = strain
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case emptySport, badDuration, future, badHR, badKcal, badDistance
        public var errorDescription: String? {
            switch self {
            case .emptySport: return "Pick a sport"
            case .badDuration: return "Duration must be 1 minute – 24 hours"
            case .future: return "Workout can't end in the future"
            case .badHR: return "Average HR must be 25–250 bpm"
            case .badKcal: return "Calories must be 0–20,000"
            case .badDistance: return "Distance must be 0–1,000 km"
            }
        }
    }

    public func validate(now: Double = Date().timeIntervalSince1970) throws {
        if sport.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.emptySport }
        let d = end - start
        if d < 60 || d > 86400 { throw ValidationError.badDuration }
        if end > now + 60 { throw ValidationError.future }
        if let h = avgHR, !(25...250).contains(h) { throw ValidationError.badHR }
        if let k = kcal, !(0...20000).contains(k) { throw ValidationError.badKcal }
        if let m = distanceM, !(0...1_000_000).contains(m) { throw ValidationError.badDistance }
    }

    /// §8.6 re-score after denser HR arrives; only ever improves.
    public func rescored(hr: [HRSample], restingHR: Double, hrMax: Double, profile: Profile) -> ManualWorkout {
        guard (kcal ?? 0) <= 5 || strain == nil else { return self }
        let w = hr.filter { $0.t >= start && $0.t <= end }
        guard w.count >= 20 else { return self }
        var out = self
        let newKcal = Calories.kcal(hr: w, restingHR: restingHR, hrMax: hrMax, profile: profile, wholeDay: false)
        if newKcal >= (kcal ?? 0) + 1 { out.kcal = newKcal; out.avgHR = mean(w.map(\.bpm)) }
        if strain == nil { out.strain = StrainScorer.score(hr: w, restingHR: restingHR, hrMax: hrMax) }
        return out
    }
}

/// §8.7 Interval timer.
public struct IntervalPlan: Sendable, Equatable {
    public var work = 30, rest = 15, rounds = 8
    public init(work: Int = 30, rest: Int = 15, rounds: Int = 8) { self.work = work; self.rest = rest; self.rounds = rounds }
    public var totalSeconds: Int { work * rounds + rest * max(0, rounds - 1) }
    public struct Phase: Sendable, Equatable { public var isWork: Bool; public var round: Int; public var seconds: Int }
    public var phases: [Phase] {
        var out: [Phase] = []
        for r in 1...max(1, rounds) {
            out.append(Phase(isWork: true, round: r, seconds: work))
            if r < rounds { out.append(Phase(isWork: false, round: r, seconds: rest)) }
        }
        return out
    }
    public static let workLoops = 3, restLoops = 1, finishLoops = 5
}
