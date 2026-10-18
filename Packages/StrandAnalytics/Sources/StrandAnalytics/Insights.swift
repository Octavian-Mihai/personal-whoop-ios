import Foundation

// MARK: - §12 Insights

public struct Correlation: Sendable { public var r: Double; public var slope: Double; public var t: Double; public var p: Double; public var n: Int }

func normalCDF(_ x: Double) -> Double { 0.5 * (1 + erf(x / 2.0.squareRoot())) }

public enum CorrelationEngine {
    public static func pearson(_ x: [Double], _ y: [Double]) -> Correlation? {
        let n = min(x.count, y.count)
        guard n >= 3 else { return nil }
        let xs = Array(x.prefix(n)), ys = Array(y.prefix(n))
        let mx = mean(xs), my = mean(ys)
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }, syy = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        guard sxx > 0, syy > 0 else { return nil }
        let r = sxy / (sxx * syy).squareRoot()
        let t = abs(r) >= 1 ? .infinity : r * (Double(n - 2) / (1 - r * r)).squareRoot()
        return Correlation(r: r, slope: sxy / sxx, t: t, p: 2 * (1 - normalCDF(abs(t))), n: n)
    }
    /// Pairs series a[i] with b[i+lag].
    public static func lagged(_ a: [Double?], _ b: [Double?], lag: Int) -> Correlation? {
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<a.count where i + lag < b.count { if let x = a[i], let y = b[i + lag] { xs.append(x); ys.append(y) } }
        return pearson(xs, ys)
    }
}

public struct BehaviorEffect: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var lag: Int
    public var cohenD: Double
    public var p: Double
    public var nWith: Int, nWithout: Int
    public var significant: Bool { p < 0.05 && min(nWith, nWithout) >= 5 }
    public var tier: ConfidenceTier { let m = min(nWith, nWithout); return m < 5 ? .calibrating : (m < 10 ? .building : .solid) }
}

public enum BehaviorInsights {
    public static func effect(with a: [Double], without b: [Double]) -> (d: Double, p: Double)? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let va = pow(stddev(a), 2), vb = pow(stddev(b), 2)
        let pooled = (((Double(a.count - 1) * va) + (Double(b.count - 1) * vb)) / Double(a.count + b.count - 2)).squareRoot()
        guard pooled > 0 else { return nil }
        let d = (mean(a) - mean(b)) / pooled
        let se = (va / Double(a.count) + vb / Double(b.count)).squareRoot()
        guard se > 0 else { return nil }
        return (d, 2 * (1 - normalCDF(abs((mean(a) - mean(b)) / se))))
    }
}

public enum EffectRanker {
    /// behaviours: name → set of day indices. outcome: per-day value.
    public static func rank(behaviours: [String: Set<Int>], outcome: [Double?]) -> [BehaviorEffect] {
        var out: [BehaviorEffect] = []
        for (name, days) in behaviours {
            var best: BehaviorEffect?
            for lag in 0...2 {
                var with: [Double] = [], without: [Double] = []
                for d in 0..<outcome.count where d + lag < outcome.count {
                    guard let v = outcome[d + lag] else { continue }
                    if days.contains(d) { with.append(v) } else { without.append(v) }
                }
                guard with.count >= 5, without.count >= 5, let e = BehaviorInsights.effect(with: with, without: without) else { continue }
                let cand = BehaviorEffect(name: name, lag: lag, cohenD: e.d, p: e.p, nWith: with.count, nWithout: without.count)
                if best == nil || abs(cand.cohenD) > abs(best!.cohenD) { best = cand }
            }
            if let b = best { out.append(b) }
        }
        return out.sorted {
            if $0.significant != $1.significant { return $0.significant }
            if abs($0.cohenD) != abs($1.cohenD) { return abs($0.cohenD) > abs($1.cohenD) }
            return $0.name < $1.name
        }
    }
}

public enum DoseResponse {
    public static func shrunk(userSlope: Double, priorSlope: Double, n: Int) -> (beta: Double, tier: String) {
        let w = Double(n) / (Double(n) + 8)
        return (w * userSlope + (1 - w) * priorSlope, n < 5 ? "Prior-dominated" : (n >= 12 ? "Solid" : "Building"))
    }
}

public enum ActivityCost {
    public static func cost(restDayMeanCharge: Double, nextMorningCharges: [Double]) -> Double? {
        guard nextMorningCharges.count >= 4 else { return nil }
        return restDayMeanCharge - mean(nextMorningCharges)
    }
}

// MARK: - §16 Reports

public struct MetricSummary: Sendable {
    public var n: Int, mean: Double, median: Double, min: Double, max: Double, sd: Double, slope: Double
}

public enum Summary {
    public static func of(_ xs: [Double]) -> MetricSummary? {
        guard !xs.isEmpty else { return nil }
        let idx = xs.indices.map(Double.init)
        let mx = mean(idx), my = mean(xs)
        let sxx = idx.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let slope = sxx > 0 ? zip(idx, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx : 0
        return MetricSummary(n: xs.count, mean: my, median: median(xs), min: xs.min()!, max: xs.max()!, sd: stddev(xs), slope: slope)
    }
}

public enum TrendDirection: String, Sendable { case up, down, flat }

public enum RangeReport {
    public static let slopeThresholds: [String: Double] = [
        "workouts": 0.03, "stress": 0.02, "charge": 0.5, "effort": 0.5, "sleep": 0.05, "hrv": 0.4, "rhr": 0.2, "resp": 0.1, "skinTemp": 0.03,
    ]
    public static func trend(_ metric: String, values: [Double]) -> TrendDirection {
        guard let s = Summary.of(values), let th = slopeThresholds[metric] else { return .flat }
        return s.slope > th ? .up : (s.slope < -th ? .down : .flat)
    }
    public static func halves(_ xs: [Double]) -> (first: Double, second: Double)? {
        guard xs.count >= 2 else { return nil }
        let mid = xs.count / 2
        return (mean(Array(xs[..<mid])), mean(Array(xs[mid...])))
    }
}

public struct WeeklyDigest: Sendable {
    public struct Mover: Sendable { public var metric: String; public var delta: Double; public var spreads: Double }
    public var movers: [Mover]
    public var balance: String
    public var focal: [String]

    public static let typicalSpread: [String: Double] = ["Charge": 12, "Effort": 12, "Rest": 12, "Resting HR": 4, "HRV": 8]

    public static func build(thisWeek: [String: [Double]], lastWeek: [String: [Double]]) -> WeeklyDigest {
        var movers: [Mover] = []
        for (m, spread) in typicalSpread {
            guard let a = thisWeek[m], let b = lastWeek[m], a.count >= 3, b.count >= 3 else { continue }
            let delta = mean(a) - mean(b)
            if abs(delta) / spread >= 0.5 { movers.append(Mover(metric: m, delta: delta, spreads: delta / spread)) }
        }
        movers.sort { abs($0.spreads) > abs($1.spreads) }
        var balance = "Insufficient"
        if let e = thisWeek["Effort"], let c = thisWeek["Charge"], e.count >= 3, c.count >= 3 {
            let d = mean(e) - mean(c)
            balance = d > 10 ? "Overreaching" : (d < -10 ? "Underloaded" : "Balanced")
        }
        var focal: [String] = []
        if let top = movers.first {
            focal.append("\(top.metric) \(top.delta > 0 ? "rose" : "fell") by \(String(format: "%.1f", abs(top.delta))) vs last week.")
        }
        if balance == "Overreaching" || balance == "Underloaded" { focal.append("Effort vs Charge reads \(balance.lowercased()).") }
        else if movers.count > 1 { focal.append("\(movers[1].metric) \(movers[1].delta > 0 ? "rose" : "fell") by \(String(format: "%.1f", abs(movers[1].delta))).") }
        if focal.isEmpty { focal.append("A steady week — nothing moved enough to call a trend.") }
        return WeeklyDigest(movers: movers, balance: balance, focal: focal)
    }
}

public enum StreakCalculator {
    /// Days are "yyyy-MM-dd" strings.
    public static func streaks(days: Set<String>, today: String) -> (current: Int, longest: Int) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let nums = days.compactMap { f.date(from: $0).map { Int($0.timeIntervalSince1970 / 86400) } }.sorted()
        guard !nums.isEmpty, let t = f.date(from: today).map({ Int($0.timeIntervalSince1970 / 86400) }) else { return (0, 0) }
        var longest = 1, run = 1
        for i in 1..<nums.count { if nums[i] == nums[i - 1] + 1 { run += 1 } else if nums[i] != nums[i - 1] { run = 1 }; longest = max(longest, run) }
        let set = Set(nums)
        var cur = 0
        var d = set.contains(t) ? t : t - 1
        while set.contains(d) { cur += 1; d -= 1 }
        return (cur, longest)
    }
}

public enum ActivityHeatmap {
    public static func level(value: Double, daily: [Double]) -> Int {
        guard value > 0 else { return 0 }
        let scale = max(250, percentile(daily.filter { $0 > 0 }, 0.9))
        return min(4, max(1, Int(ceil(value / scale * 4))))
    }
}

// MARK: - §17 Fusion

public enum FusionMetric: String, Sendable {
    case restingHR, hr, hrv, spo2, skinTemp, steps, sleep, calories

    var tolerances: (agree: Double, minor: Double, relative: Bool) {
        switch self {
        case .restingHR: return (3, 8, false)
        case .hr: return (5, 12, false)
        case .hrv: return (8, 20, false)
        case .spo2: return (2, 4, false)
        case .skinTemp: return (0.5, 1.5, false)
        case .sleep: return (20, 60, false)
        case .steps: return (0.10, 0.30, true)
        case .calories: return (0.15, 0.40, true)
        }
    }
}

public enum DataSource: String, Sendable, CaseIterable {
    case whoopImport, noopComputed, appleHealth, miBand, cache

    var order: Int { [DataSource.whoopImport, .noopComputed, .appleHealth, .miBand, .cache].firstIndex(of: self)! }
}

public enum Agreement: String, Sendable { case single, agree, minorDelta, conflict }

public struct FusionResult: Sendable {
    public var winner: (source: DataSource, value: Double, reason: String)
    public var agreement: Agreement
}

public enum FusionResolver {
    static func tier(_ m: FusionMetric, _ s: DataSource) -> Int {
        switch m {
        case .restingHR, .hr, .hrv, .spo2, .skinTemp:
            switch s { case .whoopImport, .miBand: return 0; case .noopComputed: return 1; case .appleHealth: return 2; case .cache: return 3 }
        case .steps:
            switch s { case .miBand, .appleHealth: return 0; case .whoopImport, .noopComputed, .cache: return 3 }
        case .sleep:
            switch s { case .whoopImport: return 0; case .noopComputed, .miBand: return 1; case .appleHealth: return 2; case .cache: return 3 }
        case .calories:
            return s == .appleHealth ? 2 : 4
        }
    }
    static func reason(_ m: FusionMetric, _ s: DataSource) -> String {
        switch (m, s) {
        case (.steps, .whoopImport), (.steps, .noopComputed): return "step estimate"
        case (.steps, _): return "counts directly"
        case (.sleep, .whoopImport): return "best stager"
        case (_, .appleHealth): return "phone aggregate"
        case (_, .cache): return "cached"
        default: return "direct sensor"
        }
    }

    public static func resolve(_ m: FusionMetric, inputs: [(DataSource, Double)]) -> FusionResult? {
        guard !inputs.isEmpty else { return nil }
        let sorted = inputs.sorted { (tier(m, $0.0), $0.0.order) < (tier(m, $1.0), $1.0.order) }
        let w = sorted[0]
        let tol = m.tolerances
        var worst = Agreement.single
        for o in sorted.dropFirst() {
            let diff = tol.relative ? abs(o.1 - w.1) / max(abs(w.1), 1e-9) : abs(o.1 - w.1)
            let a: Agreement = diff <= tol.agree ? .agree : (diff <= tol.minor ? .minorDelta : .conflict)
            if rank(a) > rank(worst) { worst = a }
        }
        return FusionResult(winner: (w.0, w.1, reason(m, w.0)), agreement: worst)
    }
    static func rank(_ a: Agreement) -> Int { switch a { case .single: return 0; case .agree: return 1; case .minorDelta: return 2; case .conflict: return 3 } }
}
