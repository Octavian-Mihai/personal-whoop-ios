import Foundation

// MARK: - §7.3 Stress

public enum StressMath {
    /// Daily 0–3 stress against the previous 30 days.
    public static func daily(rhr: Double, hrv: Double, historyRHR: [Double], historyHRV: [Double]) -> Double? {
        let hr = Array(historyRHR.suffix(30)), hv = Array(historyHRV.suffix(30))
        guard hr.count >= 4, hv.count >= 4 else { return nil }
        var raw = 0.0
        let sdR = stddev(hr), sdV = stddev(hv)
        if sdR > 0.0001 { raw += (rhr - mean(hr)) / sdR }
        if sdV > 0.0001 { raw += (mean(hv) - hrv) / sdV }
        return 3 / (1 + exp(-raw))
    }
}

public struct StressHour: Sendable, Identifiable {
    public var id: Double { start }
    public var start: Double
    public var score: Double?     // nil = masked or insufficient
    public var masked: Bool
}

public enum DaytimeStress {
    /// Hourly timeline, day-relative reference (default mode). `motion` is gravity intensity samples.
    public static func timeline(hr: [HRSample], motion: [GravitySample], calendar: Calendar = .current,
                                personalBaseline: Double? = nil) -> [StressHour] {
        guard let first = hr.first else { return [] }
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: first.t)).timeIntervalSince1970
        var hours: [(start: Double, mean: Double, ambulatory: Double)] = []
        for h in 6..<22 {
            let a = day + Double(h) * 3600, b = a + 3600
            let v = hr.filter { $0.t >= a && $0.t < b }.map(\.bpm)
            guard v.count >= 300 else { continue }
            let m = motion.filter { $0.t >= a && $0.t < b }
            var amb = 0.0
            if m.count > 1 {
                var hit = 0
                for i in 1..<m.count {
                    let p = m[i - 1], q = m[i]
                    let d = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z)).squareRoot()
                    if d > 0.20 { hit += 1 }
                }
                amb = Double(hit) / Double(m.count - 1)
            }
            hours.append((a, mean(v), amb))
        }
        guard !hours.isEmpty else { return [] }
        // mask ambulatory hours and the cool-down hour after
        var masked = hours.map { $0.ambulatory >= 0.30 }
        let calm = hours.enumerated().filter { !masked[$0.offset] }.map { $0.element.mean }
        let ref: Double, sd: Double
        if let pb = personalBaseline {
            ref = pb; sd = 15 / -log(1.5 - 1)
        } else {
            guard calm.count >= 2 else { return hours.map { StressHour(start: $0.start, score: nil, masked: true) } }
            ref = calm.count < 4 ? mean(calm) : percentile(calm, 0.25)
            sd = max(stddev(calm), 2.0)
        }
        for i in 1..<hours.count where masked[i - 1] && hours[i].mean - ref >= 8 { masked[i] = true }
        return hours.enumerated().map { i, h in
            masked[i] ? StressHour(start: h.start, score: nil, masked: true)
                      : StressHour(start: h.start, score: 3 / (1 + exp(-(h.mean - ref) / sd)), masked: false)
        }
    }

    public static func sustainedHigh(_ hours: [StressHour]) -> Bool {
        let scored = hours.compactMap(\.score)
        return scored.count >= 3 && scored.suffix(3).allSatisfy { $0 >= 2.0 }
    }
    public static func highStressMinutes(_ hours: [StressHour]) -> Int { hours.compactMap(\.score).filter { $0 >= 2 }.count * 60 }
}

/// §7.3 live check-in nudge.
public struct StressOnsetDetector: Sendable {
    public var emaBaseline: Double?
    public var dipStart: Double?
    public var lastNudge: Double = -.infinity
    public init() {}

    public mutating func ingest(now: Double, rr60: [Double], hr: Double, still: Bool, quietHours: Bool) -> Bool {
        guard let fast = HRVAnalyzer.analyze(rr60)?.rmssd else { return false }
        guard let base = emaBaseline else { emaBaseline = fast; return false }
        emaBaseline = 0.98 * base + 0.02 * fast
        let inBand = (55...100).contains(hr) && still
        if fast < 0.6 * base && inBand {
            if dipStart == nil { dipStart = now }
            if now - dipStart! >= 60, now - lastNudge >= 900, !quietHours { lastNudge = now; dipStart = nil; return true }
        } else { dipStart = nil }
        return false
    }
}

// MARK: - §7.4 Sedentary

public struct SedentaryDetector: Sendable {
    public var walkThreshold = 0.15
    public var minBoutSeconds = 3600.0
    public var renudgeSeconds = 1800.0
    public var activeHours = 9..<17
    public var boutStart: Double?
    public var lastNudge: Double = -.infinity
    public init() {}

    public mutating func ingest(t: Double, smoothedMotion: Double, hour: Int) -> Bool {
        if smoothedMotion > walkThreshold { boutStart = nil; return false }
        if boutStart == nil { boutStart = t }
        guard activeHours.contains(hour), t - boutStart! >= minBoutSeconds, t - lastNudge >= renudgeSeconds else { return false }
        lastNudge = t
        return true
    }
}

// MARK: - §7.5 Steps estimate

public enum StepsEstimate {
    public static func fitK(days: [(phoneSteps: Double, motion: Double)]) -> (k: Double, confidence: Double)? {
        let ok = days.filter { $0.motion >= 1.0 && $0.phoneSteps > 0 }
        guard ok.count >= 3 else { return nil }
        let pairs = ok.map { (ratio: $0.phoneSteps / $0.motion, w: $0.motion) }.sorted { $0.ratio < $1.ratio }
        let total = pairs.reduce(0) { $0 + $1.w }
        var acc = 0.0
        var k = pairs.last!.ratio
        for p in pairs { acc += p.w; if acc >= total / 2 { k = p.ratio; break } }
        return (k, min(1, Double(ok.count) / 14))
    }
    public static func steps(motionVolume: Double, k: Double) -> Int { Int(min(60_000, k * motionVolume)) }
    public static func tier(_ c: Double) -> String { c < 0.34 ? "Low" : (c < 0.67 ? "Medium" : "High") }
}

/// §7.9 step counter from strap motion counter.
public enum StepsCounter {
    public static func total(samples: [(t: Double, counter: UInt16, activityClass: Int?)]) -> Int {
        var total = 0
        let hasClass = samples.contains { $0.activityClass != nil }
        for i in 1..<max(1, samples.count) {
            let delta = Int((samples[i].counter &- samples[i - 1].counter) & 0xFFFF)
            let dt = max(1, samples[i].t - samples[i - 1].t)
            guard delta >= 1, delta < 512, Double(delta) <= 4 * dt else { continue }
            if hasClass, let c = samples[i].activityClass, c != 1 && c != 2 { continue }
            total += delta
        }
        return total
    }
}

// MARK: - §7.7 Circadian

public struct CircadianEstimate: Sendable {
    public enum Alignment: String, Sendable { case aligned = "Well-aligned", later = "Later (night-owl lean)", earlier = "Earlier (morning-lark lean)", unreadable = "Hard to read right now" }
    public var amplitude: Double, mesor: Double, acrophase: Double
    public var alignment: Alignment
    public var offsetMinutes: Double
    public var solid: Bool
    public var tempMin: Double
}

public enum CircadianEngine {
    public static func cosinor(_ bins: [(hour: Double, value: Double)]) -> (mesor: Double, amplitude: Double, acrophase: Double)? {
        guard bins.count >= 3 else { return nil }
        let w = 2 * Double.pi / 24
        var n = 0.0, sc = 0.0, ss = 0.0, scc = 0.0, sss = 0.0, scs = 0.0, sy = 0.0, syc = 0.0, sys = 0.0
        for b in bins {
            let c = cos(w * b.hour), s = sin(w * b.hour)
            n += 1; sc += c; ss += s; scc += c * c; sss += s * s; scs += c * s
            sy += b.value; syc += b.value * c; sys += b.value * s
        }
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let A = [[n, sc, ss], [sc, scc, scs], [ss, scs, sss]]
        let d = det(A)
        guard abs(d) > 1e-9 else { return nil }
        let rhs = [sy, syc, sys]
        func replaced(_ col: Int) -> Double {
            var m = A; for r in 0..<3 { m[r][col] = rhs[r] }; return det(m) / d
        }
        let M = replaced(0), beta = replaced(1), gamma = replaced(2)
        var ac = atan2(gamma, beta) / w
        ac = ac.truncatingRemainder(dividingBy: 24); if ac < 0 { ac += 24 }
        return (M, (beta * beta + gamma * gamma).squareRoot(), ac)
    }

    public static func estimate(bins: [(hour: Double, value: Double)], days: Int, habitualWakeHour: Double) -> CircadianEstimate? {
        guard let f = cosinor(bins) else { return nil }
        let rel = f.mesor != 0 ? f.amplitude / abs(f.mesor) : 0
        let rhythmic = rel >= 0.10 || f.amplitude >= 4.5
        var tempMin = (f.acrophase - 12).truncatingRemainder(dividingBy: 24); if tempMin < 0 { tempMin += 24 }
        guard days >= 7, rhythmic else {
            return CircadianEstimate(amplitude: f.amplitude, mesor: f.mesor, acrophase: f.acrophase, alignment: .unreadable, offsetMinutes: 0, solid: false, tempMin: tempMin)
        }
        let reference = habitualWakeHour - 2.5
        var diff = (tempMin - reference).truncatingRemainder(dividingBy: 24)
        if diff > 12 { diff -= 24 } else if diff < -12 { diff += 24 }
        let off = diff * 60
        let al: CircadianEstimate.Alignment = off > 20 ? .later : (off < -20 ? .earlier : .aligned)
        return CircadianEstimate(amplitude: f.amplitude, mesor: f.mesor, acrophase: f.acrophase, alignment: al,
                                 offsetMinutes: off, solid: days >= 14 && rel >= 0.10, tempMin: tempMin)
    }

    public enum Chronotype: String, Sendable { case morning, intermediate, evening }
    public static func chronotype(tempMin: Double) -> Chronotype {
        let diff = tempMin - 4.5
        return diff < -1 ? .morning : (diff > 1 ? .evening : .intermediate)
    }

    public struct ShiftDay: Sendable { public var day: Int; public var sleepHour: Double; public var wakeHour: Double; public var light: String }
    public static func planShift(hours: Double, currentBed: Double, currentWake: Double) -> [ShiftDay] {
        guard abs(hours) >= 0.5 else { return [] }
        let days = Int(ceil(abs(hours)))
        let dir = hours > 0 ? 1.0 : -1.0
        return (1...days).map { d in
            let step = dir * Double(d)
            let advance = hours < 0
            let light = advance ? "Bright light for 2 h after waking; dim lights 2 h before sleep"
                                : "Bright light 3–1 h before sleep; dim after waking"
            return ShiftDay(day: d, sleepHour: (currentBed + step + 24).truncatingRemainder(dividingBy: 24),
                            wakeHour: (currentWake + step + 24).truncatingRemainder(dividingBy: 24), light: "Consider: " + light)
        }
    }
}
