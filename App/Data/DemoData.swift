import Foundation
import StrandAnalytics

/// Synthetic raw streams so every engine can be exercised without a strap.
struct RawDay: @unchecked Sendable {
    var hr: [HRSample]
    var gravity: [GravitySample]
    var rr: [(t: Double, rr: Double)]
    var sleep: SleepSession?
    var workouts: [DetectedWorkout]
}

enum DemoData {
    // generation helpers are pure; safe off the main actor
    struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    }

    /// 60 days of nightly metrics. The last day carries no charge/effort so the live pipeline fills it.
    static func history(days n: Int = 60, now: Date = Date(), seed: UInt64 = 7) -> (days: [DailyMetric], journal: [JournalEntry]) {
        var rng = RNG(s: seed)
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
        let cal = Calendar.current
        var out: [DailyMetric] = []
        var journal: [JournalEntry] = []
        var prevEffort = 40.0
        for i in stride(from: n - 1, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -i, to: now)!
            let key = DayFormat.string(d)
            let drinking = Int(r(0, 100)) < 18
            let lateWorkout = Int(r(0, 100)) < 25
            let hrvBase = 62 - (drinking ? 14 : 0) - max(0, prevEffort - 60) * 0.25 + 4 * sin(Double(i) / 6)
            let hrv = max(20, hrvBase + r(-6, 6))
            let rhr = 54 + (drinking ? 4 : 0) + (prevEffort > 65 ? 2 : 0) + r(-1.5, 1.5)
            let dur = 7.3 * 60 + r(-70, 50) - (drinking ? 25 : 0)
            let inBed = dur / 0.92
            let deep = dur * r(0.10, 0.19) * (drinking ? 0.7 : 1)
            let rem = dur * r(0.18, 0.26) * (drinking ? 0.8 : 1)
            let light = dur - deep - rem
            let effort = clamp(r(18, 82) + (lateWorkout ? 8 : 0), 5, 95)
            var m = DailyMetric(day: key)
            m.hrv = hrv; m.restingHR = rhr; m.respiration = 14.2 + r(-0.6, 0.6)
            m.skinTempDev = r(-0.25, 0.25)
            m.asleepMin = dur; m.inBedMin = inBed; m.deepMin = deep; m.remMin = rem; m.lightMin = light; m.awakeMin = inBed - dur
            m.rest = RestScorer.score(asleepMin: dur, inBedMin: inBed, deepMin: deep, remMin: rem, needMin: 480, consistency: r(0.5, 0.95))
            m.effort = i == 0 ? nil : effort
            m.steps = Int(r(4500, 13500)); m.kcal = 2000 + effort * 9
            m.spo2 = r(95, 98.5)
            m.stress = clamp(1.4 + (drinking ? 0.5 : 0) + r(-0.7, 0.7), 0, 3)
            m.workouts = effort > 60 ? 1 : 0
            prevEffort = effort
            out.append(m)
            var tags: [String] = []
            if drinking { tags.append("Alcohol") }
            if lateWorkout { tags.append("Late workout") }
            if Int(r(0, 100)) < 30 { tags.append("Caffeine after 2pm") }
            if Int(r(0, 100)) < 40 { tags.append("Meditation") }
            if !tags.isEmpty { journal.append(JournalEntry(day: key, tags: tags, mood: Int(r(2, 5)), caffeineMg: Int(r(0, 300)))) }
        }
        return (out, journal)
    }

    /// ~31 h of synthetic raw samples ending now (20:00 yesterday → now), profiled by local clock hour:
    /// a night (23:00–06:50), a morning workout, a stressful desk block and an evening session.
    nonisolated static func rawDay(now: Date = Date(), seed: UInt64 = 11) -> RawDay {
        var rng = RNG(s: seed)
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now).timeIntervalSince1970
        let start = dayStart - 4 * 3600
        let nowT = now.timeIntervalSince1970
        var hr: [HRSample] = [], g: [GravitySample] = [], rr: [(Double, Double)] = []
        var t = start
        var gx = 0.0, gy = 0.0, gz = 1.0
        while t < nowT {
            var h = ((t - dayStart) / 3600).truncatingRemainder(dividingBy: 24)
            if h < 0 { h += 24 }
            var bpm: Double, motion: Double
            let night = h >= 23 || h < 6.8
            if night {
                let hrsIn = h >= 23 ? h - 23 : h + 1
                let cycle = 0.5 + 0.5 * sin(t / 2700)
                let deepPhase = cycle < 0.35 && hrsIn < 5
                let remPhase = cycle > 0.75 && hrsIn > 2
                bpm = 51 + 5 * cycle + (deepPhase ? r(-0.25, 0.25) - 3 : (remPhase ? r(-4, 4) : r(-1.2, 1.2))) + (hrsIn < 1 ? 4 : 0)
                motion = deepPhase ? 0.001 : (Int(r(0, 100)) < 3 ? 0.05 : 0.002)
            } else if h >= 7.5 && h < 8.2 { bpm = 150 + 12 * sin(t / 200) + r(-6, 6); motion = 0.6 }
            else if h >= 17 && h < 17.8 { bpm = 138 + 10 * sin(t / 240) + r(-6, 6); motion = 0.5 }
            else if h >= 14 && h < 16 { bpm = 84 + r(-5, 8); motion = 0.03 }
            else if h >= 22 { bpm = 62 + r(-3, 3); motion = 0.01 }
            else { bpm = 70 + r(-6, 8); motion = r(0.01, 0.12) }
            hr.append(HRSample(t: t, bpm: bpm))
            let d = motion * r(0.5, 1.5)
            gx += d * r(-1, 1); gy += d * r(-1, 1); gz = 1 + d * r(-0.5, 0.5)
            g.append(GravitySample(t: t, x: gx, y: gy, z: gz))
            rr.append((t, 60000 / bpm + (night ? r(-75, 75) : r(-15, 15))))
            t += 5
        }
        // Run the real engines over the raw night.
        var session: SleepSession?
        if let span = SleepDetector.detect(hr: hr, gravity: g).first {
            let segs = SleepStager.stage(start: span.start, end: span.end, hr: hr, gravity: g)
            let beats = rr.filter { $0.0 >= span.start && $0.0 <= span.end }.map { (t: $0.0, rr: $0.1) }
            session = SleepSession(start: span.start, end: span.end, segments: segs,
                                   restingHR: SleepStager.restingHR(hr: hr, start: span.start, end: span.end),
                                   hrv: HRVAnalyzer.nightlyRMSSD(beats))
        }
        return RawDay(hr: hr, gravity: g, rr: rr.map { (t: $0.0, rr: $0.1) }, sleep: session, workouts: [])
    }
}
