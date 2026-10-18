import Foundation

// MARK: - §9 Readiness, training load, forecast

public enum SignalFlag: String, Sendable { case good, neutral, watch, bad }

public struct ReadinessSignal: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var z: Double?
    public var flag: SignalFlag
    public var note: String
}

public enum ReadinessEngine {
    static func flag(_ z: Double) -> SignalFlag { z >= 0.5 ? .good : (z >= -0.5 ? .neutral : (z >= -1 ? .watch : .bad)) }

    public static func evaluate(hrv: [Double?], rhr: [Double?], resp: [Double?], effort: [Double?]) -> [ReadinessSignal] {
        var out: [ReadinessSignal] = []
        func z(_ series: [Double?], logDomain: Bool = false, invert: Bool = false) -> Double? {
            let vals = series.dropLast().suffix(30).compactMap { $0 }.map { logDomain ? log($0) : $0 }
            guard vals.count >= 7, let lastRaw = series.last ?? nil else { return nil }
            let last = logDomain ? log(lastRaw) : lastRaw
            let sd = max(stddev(vals), 1e-6)
            let zz = (last - mean(vals)) / sd
            return invert ? -zz : zz
        }
        if let v = z(hrv, logDomain: true) { out.append(.init(name: "HRV", z: v, flag: flag(v), note: "ln(RMSSD) vs your 30-day normal")) }
        if let v = z(rhr, invert: true) { out.append(.init(name: "Resting HR", z: v, flag: flag(v), note: "Lower is better")) }
        if let v = z(resp) {
            let f: SignalFlag = v >= 2.0 ? .bad : (v >= 1.5 ? .watch : .neutral)
            out.append(.init(name: "Respiration", z: v, flag: f, note: "Higher than usual is a watch item"))
        }
        let ef = effort.compactMap { $0 }
        if ef.count >= 14 {
            let acute = mean(Array(ef.suffix(7))), chronic = mean(Array(ef.suffix(28)))
            if chronic > 0 {
                let r = acute / chronic
                let (f, n): (SignalFlag, String) = r < 0.8 ? (.neutral, "Ramping down") : r <= 1.3 ? (.good, "Sweet spot") : r <= 1.5 ? (.watch, "Building fast") : (.bad, "Spiking")
                out.append(.init(name: "ACWR", z: r, flag: f, note: n))
            }
        }
        let last7 = effort.suffix(7).compactMap { $0 }
        if last7.count >= 4, stddev(last7) > 0 {
            let mono = mean(last7) / stddev(last7)
            out.append(.init(name: "Monotony", z: mono, flag: mono >= 2.0 ? .watch : .good, note: "Foster monotony, flagged ≥ 2.0"))
        }
        return out
    }
}

public struct TrainingLoadPoint: Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var fitness: Double, fatigue: Double
    public var form: Double { fitness - fatigue }
}

public enum TrainingLoadEngine {
    /// Longest contiguous observed run of daily Effort (nil = missing, never zero-filled).
    public static func compute(_ effort: [Double?]) -> [TrainingLoadPoint] {
        var best: Range<Int> = 0..<0, start: Int?
        for (i, e) in effort.enumerated() {
            if e != nil { if start == nil { start = i } }
            else if let s = start { if i - s > best.count { best = s..<i }; start = nil }
        }
        if let s = start, effort.count - s > best.count { best = s..<effort.count }
        let run = effort[best].compactMap { $0 }
        guard !run.isEmpty else { return [] }
        let seed = mean(Array(run.prefix(3)))
        var ctl = seed, atl = seed
        let ac = 1 - exp(-1.0 / 42), aa = 1 - exp(-1.0 / 7)
        return run.enumerated().map { i, load in
            ctl += ac * (load - ctl); atl += aa * (load - atl)
            return TrainingLoadPoint(index: best.lowerBound + i, fitness: ctl, fatigue: atl)
        }
    }
}

public struct ChargeForecast: Sendable { public var value: Double; public var band: Double }

public enum RecoveryForecast {
    public static func forecast(charge14: [Double], todayEffort: Double, meanEffort: Double, sleepHours: Double, needHours: Double, slopePerDay: Double) -> ChargeForecast? {
        guard charge14.count >= 5 else { return nil }
        let effortTerm = clamp(9 * (todayEffort - meanEffort) / 12, -12, 12)
        let sleepTerm = 14 * clamp(sleepHours / needHours - 1, -1, 0.25)
        let slopeTerm = clamp(1.0 * slopePerDay, -8, 8)
        let v = clamp(mean(charge14) - effortTerm + sleepTerm - slopeTerm, 0, 100)
        return ChargeForecast(value: v, band: charge14.count >= 10 ? 6 : 8)
    }
}

// MARK: - §10 Illness

public struct IllnessResult: Sendable {
    public enum Level: String, Sendable { case clear, mild, raised, suppressed, alreadyUnwell }
    public var score: Double
    public var level: Level
    public var firing: [String]
    public var explanation: String?
}

public enum IllnessSignalEngine {
    public enum Confounder: String, Sendable { case alcohol, workout, sick }

    public static func evaluate(zs: [String: Double], baselineTrusted: Bool, confounders: Set<Confounder>, nights: Int) -> IllnessResult {
        guard baselineTrusted, nights >= 14 else { return .init(score: 0, level: .clear, firing: [], explanation: nil) }
        let firing = zs.filter { $0.value >= 2.0 }
        guard firing.count >= 2 else { return .init(score: 0, level: .clear, firing: Array(firing.keys), explanation: nil) }
        var score = min(100, firing.values.reduce(0) { $0 + min(40, 22 * ($1 - 2)) })
        if confounders.contains(.sick) { return .init(score: score, level: .alreadyUnwell, firing: Array(firing.keys), explanation: "You logged feeling unwell") }
        if !confounders.isDisjoint(with: [.alcohol, .workout]) {
            score *= 0.45
            return .init(score: score, level: .suppressed, firing: Array(firing.keys),
                         explanation: "Suppressed — explained by \(confounders.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        return .init(score: score, level: score >= 50 ? .raised : (score >= 25 ? .mild : .clear), firing: Array(firing.keys), explanation: nil)
    }

    /// Mahalanobis band only; never gates.
    public static func distance(_ x: [Double], correlation: [[Double]]? = nil) -> Double {
        guard let c = correlation, c.count == x.count else { return (x.reduce(0) { $0 + $1 * $1 }).squareRoot() }
        let inv = invert(c.enumerated().map { i, row in row.enumerated().map { j, v in i == j ? v + 1e-6 : v } })
            ?? c.enumerated().map { i, _ in (0..<c.count).map { $0 == i ? 1 / c[i][i] : 0 } }
        var d2 = 0.0
        for i in 0..<x.count { for j in 0..<x.count { d2 += x[i] * inv[i][j] * x[j] } }
        return max(0, d2).squareRoot()
    }

    static func invert(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        var a = m.enumerated().map { i, r in r + (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            let d = a[c][c]; a[c] = a[c].map { $0 / d }
            for r in 0..<n where r != c { let f = a[r][c]; a[r] = zip(a[r], a[c]).map { $0 - f * $1 } }
        }
        return a.map { Array($0[n...]) }
    }
}

// MARK: - §11 Vitality, Fitness Age, Cycle

public struct VitalityResult: Sendable { public var bodyAge: Double; public var vitality: Double; public var factors: Int }

public enum VitalityEngine {
    public static func hrvNorm(age: Double) -> Double { 47 + (20 - 47) * clamp((age - 20) / 60, 0, 1) }

    public static func compute(age: Double, rhr: Double?, vo2: Double?, expectedVO2: Double?, sleepHours: Double?,
                               regularity: Double?, rmssd: Double?, steps: Double?) -> VitalityResult? {
        var terms: [Double] = []
        if let r = rhr { terms.append((r - 65) / 10 * 0.100) }
        if let v = vo2, let e = expectedVO2 { terms.append(clamp((e - v) / 3.5, -4, 4) * 0.130) }
        if let h = sleepHours { terms.append(clamp(max(0, abs(h - 7.5) - 0.5), 0, 3) * 0.110) }
        if let c = regularity { terms.append((0.75 - clamp01(c)) * 0.450) }
        if let r = rmssd { let n = hrvNorm(age: age); terms.append(clamp((n - r) / n, -1, 1) * 0.160) }
        if let s = steps { terms.append(clamp((7000 - clamp(s, 0, 11000)) / 1000, -4, 4) * 0.064) }
        guard terms.count >= 3 else { return nil }
        let sum = terms.reduce(0, +)
        let body = clamp(age + sum * 0.75 / 0.0866, 20, 90)
        return VitalityResult(bodyAge: body, vitality: clamp(50 + (age - body) * 2.5, 0, 100), factors: terms.count)
    }
}

public enum FitnessAgeEngine {
    /// Nes 2011 non-exercise VO₂max, waist variant.
    public static func vo2max(male: Bool, age: Double, paIndex: Double, waistCm: Double, rhr: Double) -> Double {
        male ? 100.27 - 0.296 * age + 0.226 * paIndex - 0.369 * waistCm - 0.155 * rhr
             : 74.74 - 0.247 * age + 0.198 * paIndex - 0.259 * waistCm - 0.114 * rhr
    }
    /// Invert against the reference peer (RHR 65, PA 5) so body-size terms cancel.
    public static func fitnessAge(male: Bool, age: Double, rhr: Double, paIndex: Double) -> Double {
        let rhrC = male ? 0.155 : 0.114, ageC = male ? 0.296 : 0.247, paC = male ? 0.226 : 0.198
        // VO2 deviation vs peer at same age = paC*(pa-5) + rhrC*(65-rhr); each year of age costs ageC
        let delta = paC * (paIndex - 5) + rhrC * (65 - rhr)
        return clamp(age - delta / ageC, 18, 95)
    }
}

public struct CycleEstimate: Sendable {
    public enum Phase: String, Sendable { case follicular, periOvulatory = "Peri-ovulatory", luteal, unknown, learning }
    public var phase: Phase
    public var cycleLength: Int?
    public var confidence: String
    public var cycleDay: Int?
}

/// Wellness awareness only, not contraception or fertility prediction.
public enum CyclePhaseEngine {
    public static func estimate(tempZ: [Double?], rhrZ: [Double?], hrvZ: [Double?], loggedPeriodStartIndex: Int? = nil) -> CycleEstimate {
        let n = tempZ.count
        var idx: [Double?] = []
        for i in 0..<n {
            var num = 0.0, den = 0.0
            if let t = tempZ[i] { num += 0.6 * t; den += 0.6 }
            if i < rhrZ.count, let r = rhrZ[i] { num += 0.2 * r; den += 0.2 }
            if i < hrvZ.count, let h = hrvZ[i] { num += 0.2 * -h; den += 0.2 }
            idx.append(den > 0 ? num / den : nil)
        }
        let vals = idx.compactMap { $0 }
        guard vals.count >= 42 else { return .init(phase: .learning, cycleLength: nil, confidence: "Learning", cycleDay: nil) }
        let med = median(vals)
        let mad = max(median(vals.map { abs($0 - med) }), 1e-6)
        let elevated = idx.map { $0.map { $0 - med >= 0.5 * mad } ?? false }
        guard elevated.contains(true) else { return .init(phase: .unknown, cycleLength: nil, confidence: "Building", cycleDay: nil) }
        var onsets: [Int] = []
        for i in 1..<n where elevated[i] && !elevated[i - 1] { onsets.append(i) }
        let gaps = zip(onsets, onsets.dropFirst()).map { Double($1 - $0) }
        let len = gaps.isEmpty ? nil : Int(median(gaps).rounded())
        let validLen = len.flatMap { (21...40).contains($0) ? $0 : nil }
        guard let lastOnset = onsets.last else { return .init(phase: .unknown, cycleLength: nil, confidence: "Building", cycleDay: nil) }
        let since = n - 1 - lastOnset
        let phase: CycleEstimate.Phase = since <= 2 ? .periOvulatory : (elevated[n - 1] ? .luteal : .follicular)
        let day: Int?
        if let l = loggedPeriodStartIndex { day = n - 1 - l + 1 } else { day = (validLen ?? 28) / 2 + since + 1 }
        return .init(phase: phase, cycleLength: validLen, confidence: validLen != nil ? "Solid" : "Building", cycleDay: day)
    }
}

// MARK: - §11.4 Energy balance

public enum AdaptiveExpenditure {
    public static func tdee(intakeKcalPerDay: [Double?], weightsKg: [(day: Int, kg: Double)]) -> (low: Double, high: Double)? {
        let intake = intakeKcalPerDay.compactMap { $0 }
        guard intakeKcalPerDay.count >= 21, intakeKcalPerDay.count <= 42, intake.count >= 14,
              Double(intake.count) / Double(intakeKcalPerDay.count) >= 0.7, weightsKg.count >= 6 else { return nil }
        let xs = weightsKg.map { Double($0.day) }, ys = weightsKg.map(\.kg)
        let mx = mean(xs), my = mean(ys)
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / max(1e-9, xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) })
        let est = mean(intake) - slope * 7700
        return (est * 0.93, est * 1.07)
    }
}
