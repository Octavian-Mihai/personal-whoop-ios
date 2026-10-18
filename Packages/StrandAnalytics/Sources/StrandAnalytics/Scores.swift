import Foundation

// MARK: - §4 Rest

public enum RestScorer {
    public static func score(asleepMin: Double, inBedMin: Double, deepMin: Double, remMin: Double,
                             needMin: Double, consistency: Double? = nil) -> Double? {
        guard inBedMin > 0, asleepMin > 0, needMin > 0 else { return nil }
        let duration = clamp01(asleepMin / needMin)
        let efficiency = clamp01(asleepMin / inBedMin)
        let deepShare = deepMin / asleepMin
        let deepFactor = 0.5 + 0.5 * clamp01(deepShare / 0.13)
        let restorative = clamp01(((deepMin + remMin) / asleepMin) / 0.50) * deepFactor
        let cons = clamp01(consistency ?? 0.5)
        return 100 * (0.50 * duration + 0.20 * efficiency + 0.20 * restorative + 0.10 * cons)
    }
}

// MARK: - §5 Charge

public enum ChargeBand: String, Sendable {
    case red, yellow, green
    public static func of(_ c: Double) -> ChargeBand { c < 34 ? .red : (c < 67 ? .yellow : .green) }
}

public struct ChargeInputs: Sendable {
    public var hrv: Double?, restingHR: Double?, rest: Double?, respiration: Double?, skinTempDev: Double?
    public var rhrSlopePerHour: Double?, previousEffort: Double?, previousEffortBaseline: Double?
    public var spo2: Double?
    public init(hrv: Double? = nil, restingHR: Double? = nil, rest: Double? = nil, respiration: Double? = nil,
                skinTempDev: Double? = nil, rhrSlopePerHour: Double? = nil, previousEffort: Double? = nil,
                previousEffortBaseline: Double? = nil, spo2: Double? = nil) {
        self.hrv = hrv; self.restingHR = restingHR; self.rest = rest; self.respiration = respiration
        self.skinTempDev = skinTempDev; self.rhrSlopePerHour = rhrSlopePerHour
        self.previousEffort = previousEffort; self.previousEffortBaseline = previousEffortBaseline; self.spo2 = spo2
    }
}

public struct ChargeBaselines: Sendable {
    public var hrv: Baseline, restingHR: Baseline, respiration: Baseline
    public init(hrv: Baseline, restingHR: Baseline, respiration: Baseline) {
        self.hrv = hrv; self.restingHR = restingHR; self.respiration = respiration
    }
}

public struct ChargeDriver: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var points: Double
}

public struct ChargeResult: Sendable {
    public var score: Double
    public var band: ChargeBand
    public var drivers: [ChargeDriver]
}

public enum RecoveryScorer {
    typealias Term = (name: String, weight: Double, z: Double)

    static func terms(_ i: ChargeInputs, _ b: ChargeBaselines) -> [Term] {
        var t: [Term] = []
        if let v = i.hrv { t.append(("HRV", 0.55, b.hrv.z(v))) }
        if let v = i.restingHR { t.append(("Resting HR", 0.20, -b.restingHR.z(v))) }
        if let v = i.rest { t.append(("Rest quality", 0.15, (v / 100 - 0.85) / 0.12)) }
        if let v = i.respiration, b.respiration.isUsable { t.append(("Respiration", 0.05, -b.respiration.z(v))) }
        if let v = i.skinTempDev { t.append(("Skin temp", 0.05, -abs(v) / 1.0)) }
        if let v = i.rhrSlopePerHour { t.append(("Overnight HR decline", 0.05, -v / 2.0)) }
        if let e = i.previousEffort, let eb = i.previousEffortBaseline { t.append(("Activity balance", 0.05, -(e - eb) / 20)) }
        return t
    }

    static func logistic(_ ts: [Term]) -> Double? {
        let w = ts.reduce(0) { $0 + $1.weight }
        guard w > 0 else { return nil }
        let z = ts.reduce(0) { $0 + $1.weight * $1.z } / w
        return 100 / (1 + exp(-1.6 * (z + 0.20)))
    }

    public static func score(_ i: ChargeInputs, baselines b: ChargeBaselines) -> ChargeResult? {
        guard b.hrv.isUsable, i.hrv != nil else { return nil }   // cold start → Calibrating
        let ts = terms(i, b)
        guard var s = logistic(ts) else { return nil }
        if let sp = i.spo2, sp < 95 { s = max(0, s - (95 - sp) * 2) }
        let drivers = ts.map { t -> ChargeDriver in
            let without = logistic(ts.filter { $0.name != t.name }) ?? s
            return ChargeDriver(name: t.name, points: s - without)
        }.sorted { abs($0.points) > abs($1.points) }
        return ChargeResult(score: s, band: .of(s), drivers: drivers)
    }
}

// MARK: - §6 Effort

public enum TRIMPMethod { case edwards, banister(male: Bool) }

public enum StrainScorer {
    public static func hrMax(age: Double, observedHRs: [Double]) -> Double {
        let tanaka = 208 - 0.7 * age
        if observedHRs.count >= 600 { return max(tanaka, percentile(observedHRs, 0.995)) }
        return tanaka
    }

    /// Score from timestamped HR. Each reading credited with time to next, capped at 2 min.
    public static func score(hr: [HRSample], restingHR: Double, hrMax: Double, method: TRIMPMethod = .edwards, requireGates: Bool = true) -> Double? {
        let s = hr.sorted { $0.t < $1.t }
        let dense = s.count >= 600
        let sparse = s.count >= 20 && ((s.last?.t ?? 0) - (s.first?.t ?? 0)) >= 600
        guard (dense || sparse || (!requireGates && s.count >= 2)), hrMax > restingHR else { return nil }
        let hrr = hrMax - restingHR
        var trimp = 0.0
        for i in 0..<s.count {
            let dt = i + 1 < s.count ? min(s[i + 1].t - s[i].t, 120) : 1
            let pct = clamp((s[i].bpm - restingHR) / hrr * 100, 0, 100)
            switch method {
            case .edwards:
                let w: Double = pct >= 90 ? 5 : pct >= 80 ? 4 : pct >= 70 ? 3 : pct >= 60 ? 2 : pct >= 50 ? 1 : 0
                trimp += w * dt / 60
            case .banister(let male):
                let x = pct / 100, b = male ? 1.92 : 1.67
                trimp += dt / 60 * x * 0.64 * exp(b * x)
            }
        }
        return 100 * log(trimp + 1) / log(7201)
    }

    /// Imported WHOOP Day Strain 0–21 → 0–100.
    public static func fromWhoop21(_ v: Double) -> Double { v * 100 / 21 }
    /// Display axis conversion.
    public static func to21(_ effort: Double) -> Double { effort * 21 / 100 }

    /// "Never visibly drops".
    public static func displayed(live: Double?, stored: Double?) -> Double? {
        switch (live, stored) {
        case let (l?, s?): return max(l, s)
        case let (l?, nil): return l
        case let (nil, s?): return s
        default: return nil
        }
    }
}

// MARK: - §7.2 HR zones

public struct HRZones: Sendable {
    public var hrMax: Double
    public init(age: Double, override: Double? = nil) { hrMax = override ?? (208 - 0.7 * age) }

    public func zone(for bpm: Double) -> Int {
        let p = bpm / hrMax
        return p >= 0.9 ? 5 : p >= 0.8 ? 4 : p >= 0.7 ? 3 : p >= 0.6 ? 2 : p >= 0.5 ? 1 : 0
    }
    public func timeInZones(_ hr: [HRSample]) -> [Int: Double] {
        let s = hr.sorted { $0.t < $1.t }
        guard s.count > 1 else { return [:] }
        var gaps = zip(s, s.dropFirst()).map { $1.t - $0.t }
        let med = median(gaps)
        gaps.append(med)
        var out: [Int: Double] = [:]
        for (i, x) in s.enumerated() { out[zone(for: x.bpm), default: 0] += gaps[i] }
        return out
    }
}

public enum ZoneCoach {
    public enum Cue: Sendable { case enteredTop, dropped }
    public static func cue(previous: Int, current: Int) -> (cue: Cue, loops: Int)? {
        if current == 5 && previous < 5 { return (.enteredTop, 3) }
        if current <= 1 && previous > 1 { return (.dropped, 1) }
        return nil
    }
}

// MARK: - §7.6 Calories

public struct Profile: Codable, Sendable, Equatable {
    public var age: Double = 30
    public var weightKg: Double = 70
    public var heightCm: Double = 170
    public var male: Bool? = nil
    public var waistCm: Double? = nil
    public var hrMaxOverride: Double? = nil
    public init() {}
}

public enum Calories {
    public static func bmrPerMinute(_ p: Profile) -> Double {
        let bmr: Double
        if p.male == false {
            bmr = 447.593 + 9.247 * p.weightKg + 3.098 * p.heightCm - 4.330 * p.age
        } else {
            bmr = 88.362 + 13.397 * p.weightKg + 4.799 * p.heightCm - 5.677 * p.age
        }
        return bmr / 1440
    }

    /// Keytel 2005, kcal/min.
    public static func keytelPerMinute(hr: Double, _ p: Profile) -> Double {
        let kj: Double
        if p.male == false {
            kj = -20.4022 + 0.4472 * hr - 0.1263 * p.weightKg + 0.074 * p.age
        } else {
            kj = -55.0969 + 0.6309 * hr + 0.1988 * p.weightKg + 0.2017 * p.age
        }
        return max(0, kj / 4.184)
    }

    public static func kcal(hr: [HRSample], restingHR: Double, hrMax: Double, profile: Profile, wholeDay: Bool) -> Double {
        let s = hr.sorted { $0.t < $1.t }
        guard s.count > 1 else { return 0 }
        let hrr = hrMax - restingHR
        let gate = restingHR + (wholeDay ? 0.50 : 0.30) * hrr
        let rest = bmrPerMinute(profile)
        var total = 0.0
        for i in 0..<(s.count - 1) {
            let dt = min(s[i + 1].t - s[i].t, 150) / 60
            let active = s[i].bpm >= gate ? keytelPerMinute(hr: s[i].bpm, profile) : 0
            total += wholeDay ? (rest + max(0, active - rest)) * dt : (active > 0 ? active : rest) * dt
        }
        return total
    }
}

// MARK: - §7.10 Hydration

public enum HydrationGoal {
    public static func goalML(male: Bool?, effort: Double?) -> Int {
        let base: Double = male == true ? 3700 : (male == false ? 2700 : 3200)
        let bump = effort.map { clamp(($0 / 100 * 700).rounded(), 0, 700) } ?? 0
        return Int(((base + bump) / 50).rounded() * 50)
    }
    public static let quickLog: [(name: String, ml: Int)] = [("Sip", 30), ("Cup", 237), ("Bottle", 500)]
}
