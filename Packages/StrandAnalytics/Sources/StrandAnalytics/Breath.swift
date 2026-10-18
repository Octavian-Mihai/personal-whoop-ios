import Foundation

// MARK: - §18 Breathwork

public struct HapticCue: Sendable, Equatable { public var offsetMs: Int; public var pulses: Int }

public enum BreathPacer {
    public static func cues(bpm: Double, inhaleFraction: Double = 0.4, durationSeconds: Int) -> [HapticCue] {
        let pace = clamp(bpm, 3, 12)
        let cycle = 60000 / pace
        let inhale = cycle * clamp(inhaleFraction, 0.1, 0.9)
        var out: [HapticCue] = []
        var t = 0.0
        while Int(t) < durationSeconds * 1000 {
            out.append(HapticCue(offsetMs: Int(t.rounded()), pulses: 1))
            out.append(HapticCue(offsetMs: Int((t + inhale).rounded()), pulses: 2))
            t += cycle
        }
        return out.filter { $0.offsetMs < durationSeconds * 1000 }
    }
}

public struct BreathStage: Sendable, Equatable {
    public enum Kind: String, Sendable { case inhale, hold, exhale, text }
    public var kind: Kind
    public var seconds: Double
    public init(kind: Kind, seconds: Double) { self.kind = kind; self.seconds = seconds }
    public var label: String { kind.rawValue.capitalized }
}

public struct BreathProtocol: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var group: String
    public var stages: [BreathStage]
    public var education: String
    public var caution: String?
    public var playable: Bool { !stages.isEmpty }

    public func cycleSeconds() -> Double { stages.reduce(0) { $0 + $1.seconds } }
    public var breathsPerMinute: Double { cycleSeconds() > 0 ? 60 / cycleSeconds() : 0 }

    /// Repeat the stage cycle across a session.
    public func timeline(durationSeconds: Double) -> [(start: Double, stage: BreathStage)] {
        guard playable, cycleSeconds() > 0 else { return [] }
        var t = 0.0; var out: [(Double, BreathStage)] = []
        while t < durationSeconds {
            for s in stages { guard t < durationSeconds else { break }; out.append((t, s)); t += s.seconds }
        }
        return out
    }
}

public enum BreathProtocolCatalog {
    static func st(_ i: Double, _ e: Double, h1: Double = 0, h2: Double = 0) -> [BreathStage] {
        var s = [BreathStage(kind: .inhale, seconds: i)]
        if h1 > 0 { s.append(BreathStage(kind: .hold, seconds: h1)) }
        s.append(BreathStage(kind: .exhale, seconds: e))
        if h2 > 0 { s.append(BreathStage(kind: .hold, seconds: h2)) }
        return s
    }
    static let hold = "Avoid if pregnant or with cardiovascular issues; stop if dizzy."

    public static let all: [BreathProtocol] = [
        .init(name: "Relax 4-6", group: "Common pacing", stages: st(4, 6), education: "Longer exhale than inhale to engage the parasympathetic response.", caution: nil),
        .init(name: "Coherence 5.5", group: "Common pacing", stages: st(5.5, 5.5), education: "≈5.5 breaths/min maximises respiratory sinus arrhythmia.", caution: nil),
        .init(name: "Coherent 6-6", group: "Common pacing", stages: st(6, 6), education: "Even 6 s in, 6 s out.", caution: nil),
        .init(name: "Box 4-4-4-4", group: "Common pacing", stages: st(4, 4, h1: 4, h2: 4), education: "Square breathing used for focus.", caution: hold),
        .init(name: "Deep 4-2-6", group: "Common pacing", stages: st(4, 6, h1: 2), education: "Slow deep breath with a short pause.", caution: nil),
        .init(name: "Diaphragmatic 4-2-6", group: "Common pacing", stages: st(4, 6, h1: 2), education: "Belly breathing: hand on abdomen rises on the inhale.", caution: nil),
        .init(name: "Alternate nostril", group: "Traditional", stages: st(4, 4, h1: 4), education: "Alternate nostrils each phase.", caution: nil),
        .init(name: "4-7-8", group: "Traditional", stages: st(4, 8, h1: 7), education: "Inhale 4, hold 7, exhale 8.", caution: hold),
        .init(name: "Buteyko", group: "Traditional", stages: st(3, 3, h2: 5), education: "Gentle nasal breathing with a pause.", caution: hold),
        .init(name: "Ujjayi", group: "Traditional", stages: st(5, 5), education: "Slight throat constriction, audible ocean sound.", caution: nil),
        .init(name: "Bhastrika", group: "Traditional", stages: st(1, 1), education: "Bellows breath — rapid and forceful.", caution: hold),
        .init(name: "Qigong", group: "Traditional", stages: st(4, 6, h1: 2), education: "Slow rhythmic abdominal breathing.", caution: nil),
        .init(name: "Soma", group: "Traditional", stages: st(5, 5, h2: 2), education: "Slow breathing with a rest at the end.", caution: nil),
        .init(name: "Tummo", group: "Traditional", stages: st(2, 2), education: "Vigorous breathing followed by retention.", caution: hold),
        .init(name: "Presence Regular", group: "Presence Process", stages: st(3.8, 3.8), education: "≈7.8 br/min continuous loop.", caution: nil),
        .init(name: "Presence Mid", group: "Presence Process", stages: st(2.4, 2.4), education: "≈12.4 br/min continuous loop.", caution: nil),
        .init(name: "Presence Punching", group: "Presence Process", stages: st(1.9, 1.9), education: "Fast continuous loop.", caution: nil),
        .init(name: "Kapalabhati", group: "Guided only", stages: [], education: "Forceful exhales with passive inhales. Technique varies, so no auto-pacer.", caution: hold),
        .init(name: "Holotropic", group: "Guided only", stages: [], education: "Extended intense breathing session.", caution: hold),
        .init(name: "Wim Hof", group: "Guided only", stages: [], education: "30 power breaths then retention. Never practise in or near water.", caution: hold),
        .init(name: "Shamanic", group: "Guided only", stages: [], education: "Free-form rhythmic breathing.", caution: hold),
    ]
}

/// §18.3 Buzz-below-heart-rate pacer.
public struct HRDownPacer: Sendable {
    public enum Outcome: Sendable { case running, settled, timeout, aborted }
    public private(set) var startedAt: Double?
    public private(set) var target: Double?
    public private(set) var startHR: Double?
    var lastRecompute: Double = -.infinity
    public init() {}

    public mutating func ingest(t: Double, smoothedHR: Double) -> (target: Double, outcome: Outcome) {
        guard (30...220).contains(smoothedHR) else { return (target ?? 0, .aborted) }
        if startedAt == nil { startedAt = t; startHR = smoothedHR }
        let el = t - startedAt!
        if smoothedHR <= 60 { return (target ?? smoothedHR, .settled) }
        if el >= 180 { return (target ?? smoothedHR, .timeout) }
        if t - lastRecompute >= 15 || target == nil {
            lastRecompute = t
            let delta = 3 + 5 * min(1, el / 120)
            target = min(smoothedHR - 1, max(50, smoothedHR - delta))
        }
        return (target!, .running)
    }
}

public enum ResonanceEngine {
    /// per-pace list of per-cycle peak-to-trough HR swings, 30 s transient already dropped by caller.
    public static func best(swingsByPace: [Double: [Double]]) -> Double {
        let scored = swingsByPace.filter { $0.value.count >= 3 }.map { ($0.key, mean($0.value)) }
        guard scored.count >= 3, let b = scored.max(by: { $0.1 < $1.1 }) else { return 5.5 }
        return b.0
    }
    public static let sweep: [Double] = stride(from: 4.5, through: 7.0, by: 0.5).map { $0 }
}

// MARK: - §19 Lift Log

public struct LiftSet: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var weightKg: Double?
    public var reps: Int?
    public var rpe: Double?
    public var isWarmup = false
    public init(weightKg: Double? = nil, reps: Int? = nil, rpe: Double? = nil, isWarmup: Bool = false) {
        self.weightKg = weightKg; self.reps = reps; self.rpe = rpe; self.isWarmup = isWarmup
    }
    public var performed: Bool { reps != 0 }
}

public enum Muscle: String, Codable, CaseIterable, Sendable {
    case chest, frontDelts, sideDelts, rearDelts, triceps, lats, upperBack, traps, biceps, forearms
    case quads, hamstrings, glutes, adductors, abductors, calves, abs, obliques, lowerBack, neck
}

public struct LiftExercise: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var direct: [Muscle]
    public var indirect: [Muscle]
    public var sets: [LiftSet]
    public init(name: String, direct: [Muscle] = [], indirect: [Muscle] = [], sets: [LiftSet] = []) {
        self.name = name; self.direct = direct; self.indirect = indirect; self.sets = sets
    }
}

public enum LiftMetrics {
    public static func volumeLoad(_ sets: [LiftSet]) -> Double {
        sets.filter { !$0.isWarmup && $0.performed }.reduce(0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) }
    }
    public static func sessionLoad(rpe: Double?, minutes: Double) -> Double? { rpe.map { $0 * minutes } }
    public static func epley(weight: Double, reps: Int) -> Double? {
        guard (1...12).contains(reps) else { return nil }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }
    public static func bestSet(_ sets: [LiftSet]) -> LiftSet? {
        let w = sets.filter { !$0.isWarmup && $0.performed && $0.weightKg != nil }
        return w.max { (epley(weight: $0.weightKg!, reps: $0.reps ?? 0) ?? $0.weightKg!) < (epley(weight: $1.weightKg!, reps: $1.reps ?? 0) ?? $1.weightKg!) }
    }
    public static func setsPerMuscle(_ exercises: [LiftExercise]) -> [Muscle: Double] {
        var out: [Muscle: Double] = [:]
        for e in exercises {
            let n = Double(e.sets.filter { !$0.isWarmup && $0.performed }.count)
            for m in e.direct { out[m, default: 0] += n }
            for m in e.indirect { out[m, default: 0] += 0.5 * n }
        }
        return out
    }
    public static let referenceBand = "Strength improves from ~1 set/week and plateaus near 4; hypertrophy isn't reliably detectable below ~4 and has no identified ceiling."
}

/// §19.2 Session: sheet of slots, rest as absolute end instant.
public struct LiftSession: Codable, Sendable {
    public struct Slot: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var exercise: String
        public var setIndex: Int
        public var targetWeight: Double?
        public var targetReps: Int?
        public var done: LiftSet?
    }
    public var slots: [Slot]
    public var current: Int?
    public var restEndsAt: Double?
    public var restSeconds = 120.0
    public var startedAt: Double

    public init(plan: [(exercise: String, sets: Int, weight: Double?, reps: Int?)], now: Double) {
        slots = plan.flatMap { p in (0..<p.sets).map { Slot(exercise: p.exercise, setIndex: $0, targetWeight: p.weight, targetReps: p.reps, done: nil) } }
        current = slots.indices.first
        startedAt = now
    }

    /// Next uncompleted set of the same exercise, then first uncompleted in plan order.
    mutating func advance() {
        guard let c = current else { current = slots.firstIndex { $0.done == nil }; return }
        let ex = slots[c].exercise
        current = slots.indices.first { slots[$0].done == nil && slots[$0].exercise == ex } ?? slots.firstIndex { $0.done == nil }
    }

    public mutating func record(_ set: LiftSet, now: Double) {
        guard let c = current else { return }
        slots[c].done = set
        restEndsAt = now + restSeconds
        advance()
    }
    public mutating func start(slot: Int) { if slots.indices.contains(slot), slots[slot].done == nil { current = slot } }
    public func restRemaining(now: Double) -> Double { max(0, (restEndsAt ?? now) - now) }
    public var finished: Bool { slots.allSatisfy { $0.done != nil } }
}

/// §19.2 Double tap: ignore taps within 5 s of the previous one.
public struct DoubleTapFilter: Sendable {
    var last: Double = -.infinity
    public init() {}
    public mutating func accept(_ t: Double) -> Bool { defer { last = t }; return t - last >= 5 }
}
