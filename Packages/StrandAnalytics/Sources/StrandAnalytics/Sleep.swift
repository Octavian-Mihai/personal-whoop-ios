import Foundation

public struct HRSample: Sendable, Codable, Equatable {
    public var t: Double      // unix seconds
    public var bpm: Double
    public init(t: Double, bpm: Double) { self.t = t; self.bpm = bpm }
}

public struct GravitySample: Sendable, Codable, Equatable {
    public var t: Double
    public var x: Double, y: Double, z: Double
    public init(t: Double, x: Double, y: Double, z: Double) { self.t = t; self.x = x; self.y = y; self.z = z }
}

public enum SleepStage: String, Codable, Sendable, CaseIterable { case awake, light, rem, deep }

public struct SleepSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var stage: SleepStage
    public init(start: Double, end: Double, stage: SleepStage) { self.start = start; self.end = end; self.stage = stage }
    public var minutes: Double { (end - start) / 60 }
}

public struct SleepSession: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var segments: [SleepSegment]
    public var restingHR: Double?
    public var hrv: Double?

    public init(start: Double, end: Double, segments: [SleepSegment], restingHR: Double? = nil, hrv: Double? = nil) {
        self.start = start; self.end = end; self.segments = segments; self.restingHR = restingHR; self.hrv = hrv
    }

    public func minutes(_ stage: SleepStage) -> Double {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }
    }
    public var inBedMinutes: Double { (end - start) / 60 }
    public var asleepMinutes: Double { inBedMinutes - minutes(.awake) }
    public var efficiency: Double { inBedMinutes > 0 ? asleepMinutes / inBedMinutes : 0 }
}

/// §3.1 Sleep detection from gravity stillness, confirmed by heart rate.
public enum SleepDetector {
    public static let stillThreshold = 0.01
    public static let stillFraction = 0.70
    public static let minSleepMin = 60.0
    public static let maxSpanH = 16.0

    public static func detect(hr: [HRSample], gravity: [GravitySample], calendar: Calendar = .current) -> [(start: Double, end: Double)] {
        guard gravity.count > 20, hr.count >= 30 else { return hrOnly(hr) }
        let baselineHR = median(hr.map(\.bpm))
        // per-record movement
        var still = [Bool](repeating: true, count: gravity.count)
        for i in 1..<gravity.count {
            let a = gravity[i - 1], b = gravity[i]
            let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).squareRoot()
            still[i] = d < stillThreshold
        }
        let gaps = zip(gravity, gravity.dropFirst()).map { $1.t - $0.t }
        let spacing = max(1, median(gaps))
        let win = max(3, Int(15 * 60 / spacing))
        // centered window → sleep class
        var prefix = [0]
        for s in still { prefix.append(prefix.last! + (s ? 1 : 0)) }
        var asleep = [Bool](repeating: false, count: gravity.count)
        for i in 0..<gravity.count {
            let lo = max(0, i - win / 2), hi = min(gravity.count, i + win / 2 + 1)
            asleep[i] = Double(prefix[hi] - prefix[lo]) / Double(hi - lo) >= stillFraction
        }
        // runs, break on class change or gap > 20 min
        var runs: [(s: Double, e: Double, sleep: Bool)] = []
        var cur = (s: gravity[0].t, e: gravity[0].t, sleep: asleep[0])
        for i in 1..<gravity.count {
            if asleep[i] != cur.sleep || gravity[i].t - gravity[i - 1].t > 20 * 60 {
                runs.append(cur); cur = (gravity[i].t, gravity[i].t, asleep[i])
            } else { cur.e = gravity[i].t }
        }
        runs.append(cur)
        // absorb runs < 15 min into neighbours
        var merged: [(s: Double, e: Double, sleep: Bool)] = []
        for r in runs {
            if (r.e - r.s) < 15 * 60, let last = merged.last { merged[merged.count - 1].e = r.e; _ = last }
            else if let last = merged.last, last.sleep == r.sleep { merged[merged.count - 1].e = r.e }
            else { merged.append(r) }
        }
        var out: [(Double, Double)] = []
        for r in merged where r.sleep {
            let dur = (r.e - r.s) / 60
            guard dur > minSleepMin, dur / 60 <= maxSpanH else { continue }
            let inRun = hr.filter { $0.t >= r.s && $0.t <= r.e }.map(\.bpm)
            guard inRun.count >= 30 else { continue }
            let med = median(inRun)
            guard med <= baselineHR * 1.05 else { continue }
            let center = Date(timeIntervalSince1970: (r.s + r.e) / 2)
            let hour = calendar.component(.hour, from: center)
            if (11..<20).contains(hour) {
                guard dur >= 90, med <= baselineHR * 0.95 else { continue }
            }
            out.append((r.s, r.e))
        }
        return out
    }

    /// Folds the user's own "going to bed" / "I woke up" marks into detected sleep spans.
    /// - Both marks (wake after bed, ≤ 16 h): the user's window wins, clipped to the data we have.
    /// - Only a bed mark: the first span's start snaps to it if it was within 3 h.
    /// - Only a wake mark: the last span's end snaps to it if it was within 3 h.
    /// Marks far from anything detected are ignored rather than trusted blindly.
    public static func refine(detected: [(start: Double, end: Double)], bed: Double?, wake: Double?,
                              dataRange: ClosedRange<Double>) -> [(start: Double, end: Double)] {
        let tol = 3 * 3600.0
        if let b = bed, let w = wake, w > b, w - b <= maxSpanH * 3600 {
            let s = max(b, dataRange.lowerBound), e = min(w, dataRange.upperBound)
            if e - s > 30 * 60 { return [(s, e)] }
            return detected
        }
        var out = detected
        if let b = bed, let first = out.first, abs(first.start - b) <= tol, b < first.end { out[0].start = b }
        if let w = wake, let last = out.last, abs(last.end - w) <= tol, w > last.start { out[out.count - 1].end = w }
        return out
    }

    /// HR-only fallback: anchor = 10th percentile, asleep ≤ anchor × 1.05, 60 s epochs. Under-reads on purpose.
    public static func hrOnly(_ hr: [HRSample]) -> [(start: Double, end: Double)] {
        guard hr.count >= 120 else { return [] }
        let anchor = percentile(hr.map(\.bpm), 0.10)
        var epochs: [Int: [Double]] = [:]
        for s in hr { epochs[Int(s.t / 60), default: []].append(s.bpm) }
        let keys = epochs.keys.sorted()
        var runs: [(Int, Int)] = []
        var start: Int?; var last = 0
        for k in keys {
            let asleep = mean(epochs[k]!) <= anchor * 1.05
            if asleep {
                if start == nil { start = k }
                else if k - last > 15 { runs.append((start!, last)); start = k }
                last = k
            }
        }
        if let s = start { runs.append((s, last)) }
        return runs.filter { Double($0.1 - $0.0) > minSleepMin }
            .map { (Double($0.0) * 60, Double($0.1) * 60) }
    }
}

/// §3.2 V2-style stager: 30 s epochs → deep / REM / light / awake with Viterbi smoothing.
public enum SleepStager {
    public static let epoch = 30.0

    public static func stage(start: Double, end: Double, hr: [HRSample], gravity: [GravitySample],
                             respReg: ((Double) -> Double?)? = nil) -> [SleepSegment] {
        let n = Int((end - start) / epoch)
        guard n > 10 else { return [] }
        var hrBy = [[Double]](repeating: [], count: n)
        for s in hr where s.t >= start && s.t < end { hrBy[min(n - 1, Int((s.t - start) / epoch))].append(s.bpm) }
        var jerk = [[Double]](repeating: [], count: n)
        let g = gravity.filter { $0.t >= start && $0.t < end }
        for i in 1..<max(1, g.count) {
            let a = g[i - 1], b = g[i]
            let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).squareRoot()
            jerk[min(n - 1, Int((b.t - start) / epoch))].append(d)
        }
        let allJerk = jerk.flatMap { $0 }
        let floor = max(median(allJerk), 0.002)
        var hrMean = [Double](repeating: .nan, count: n)
        for i in 0..<n where !hrBy[i].isEmpty { hrMean[i] = mean(hrBy[i]) }
        // fill gaps with last known
        var last = hrMean.first(where: { !$0.isNaN }) ?? 60
        for i in 0..<n { if hrMean[i].isNaN { hrMean[i] = last } else { last = hrMean[i] } }

        func windowStd(_ i: Int, _ half: Int) -> Double {
            stddev(Array(hrMean[max(0, i - half)..<min(n, i + half + 1)]))
        }
        var hrVar = (0..<n).map { windowStd($0, 5) }
        var flat = (0..<n).map { windowStd($0, 11) }
        var move = (0..<n).map { i -> Double in
            let j = jerk[i]; guard !j.isEmpty else { return 0 }
            return Double(j.filter { $0 > floor * 38 }.count) / Double(j.count)
        }
        let jerkMax = (0..<n).map { jerk[$0].max() ?? 0 }
        let resp = (0..<n).map { respReg?(start + Double($0) * epoch) ?? 0 }

        func z(_ xs: [Double]) -> [Double] {
            let m = mean(xs), s = max(stddev(xs), 1e-6)
            return xs.map { ($0 - m) / s }
        }
        let zHr = z(hrMean), zVar = z(hrVar), zMove = z(move), zResp = z(resp)
        let flatSorted = flat.sorted()
        func flatPct(_ v: Double) -> Double {
            Double(flatSorted.firstIndex(where: { $0 >= v }) ?? 0) / Double(max(1, n - 1))
        }
        hrVar = [] ; move = []; _ = flat; flat = []

        // emissions
        var emit = [[Double]](repeating: [0, 0, 0, 0], count: n) // order: deep, rem, light, awake
        let onset = 0
        for i in 0..<n {
            let c = Double(i) / Double(n)
            let gate = 5 * max(0, (1 - flatPct(windowStd(i, 11))) - 0.25)
            var deep = -1.1 * zVar[i] - 0.5 * zMove[i] - gate + log(0.15) + 1.2 * max(0, 1 - c / 0.55)
            var rem = 0.6 * zVar[i] - 0.6 * zMove[i] + 0.4 * zHr[i] + log(0.22) + 1.0 * c
            let light = log(0.50)
            var cardiac = 0.8 * zVar[i] + 0.4 * zHr[i]
            if jerkMax[i] <= floor * 3 { cardiac = min(cardiac, 0) }
            var awake = 1.0 * zMove[i] + cardiac + log(0.10) + (jerkMax[i] > floor * 55 ? 2.0 : 0)
            deep += 0.6 * zResp[i]; rem -= 0.6 * zResp[i]
            let sinceOnset = Double(i - onset) * epoch / 60
            if sinceOnset < 60 { rem -= 3.0 * (1 - sinceOnset / 60) }
            deep = deep.isNaN ? -10 : deep; rem = rem.isNaN ? -10 : rem; awake = awake.isNaN ? -10 : awake
            emit[i] = [deep, rem, light, awake]
        }
        // sticky transitions, order: deep, rem, light, awake
        let stay = [0.88, 0.88, 0.90, 0.85]
        func trans(_ a: Int, _ b: Int) -> Double {
            if a == b { return log(stay[a]) }
            if (a == 3 && (b == 0 || b == 1)) { return -.infinity }
            return log((1 - stay[a]) / 3)
        }
        var score = emit[0]
        var back = [[Int]](repeating: [0, 0, 0, 0], count: n)
        for i in 1..<n {
            var next = [Double](repeating: -.infinity, count: 4)
            for b in 0..<4 {
                var best = -Double.infinity, arg = 0
                for a in 0..<4 {
                    let v = score[a] + trans(a, b)
                    if v > best { best = v; arg = a }
                }
                next[b] = best + emit[i][b]; back[i][b] = arg
            }
            score = next
        }
        var state = score.indices.max(by: { score[$0] < score[$1] })!
        var labels = [Int](repeating: 2, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) { labels[i] = state; state = back[i][state] }
        let map: [SleepStage] = [.deep, .rem, .light, .awake]
        var segs: [SleepSegment] = []
        for i in 0..<n {
            let st = map[labels[i]]
            let s = start + Double(i) * epoch, e = s + epoch
            if let l = segs.last, l.stage == st { segs[segs.count - 1].end = e }
            else { segs.append(SleepSegment(start: s, end: e, stage: st)) }
        }
        return segs
    }

    /// §3.3: lowest 5-minute-bin mean of HR in the session.
    public static func restingHR(hr: [HRSample], start: Double, end: Double) -> Double? {
        var bins: [Int: [Double]] = [:]
        for s in hr where s.t >= start && s.t <= end { bins[Int(s.t / 300), default: []].append(s.bpm) }
        let means = bins.values.filter { $0.count >= 5 }.map(mean).filter { $0 >= 25 }
        if let m = means.min() { return m }
        let any = bins.values.map(mean)
        return any.min()
    }
}

/// §3.3 AASM-style metrics.
public struct HypnogramMetrics: Sendable {
    public var tib: Double, tst: Double, spt: Double, sol: Double, waso: Double
    public var remLatency: Double?
    public var efficiency: Double
    public var disturbances: Int

    public init(session: SleepSession) {
        tib = session.inBedMinutes
        tst = session.asleepMinutes
        let segs = session.segments
        let firstSleep = segs.first(where: { $0.stage != .awake })
        let lastSleep = segs.last(where: { $0.stage != .awake })
        sol = firstSleep.map { ($0.start - session.start) / 60 } ?? tib
        spt = (firstSleep != nil && lastSleep != nil) ? (lastSleep!.end - firstSleep!.start) / 60 : 0
        waso = max(0, spt - tst)
        remLatency = segs.first(where: { $0.stage == .rem }).flatMap { r in firstSleep.map { (r.start - $0.start) / 60 } }
        efficiency = tib > 0 ? tst / tib : 0
        var d = 0
        if let f = firstSleep, let l = lastSleep {
            d = segs.filter { $0.stage == .awake && $0.start > f.start && $0.end < l.end }.count
        }
        disturbances = d
    }
}

/// §3.4 Main-night choice.
public enum MainNight {
    public static func pick(_ sessions: [SleepSession], habitualMidsleepHour: Double = 3.5, calendar: Calendar = .current) -> SleepSession? {
        func score(_ s: SleepSession) -> Double {
            let mid = Date(timeIntervalSince1970: (s.start + s.end) / 2)
            let h = Double(calendar.component(.hour, from: mid)) + Double(calendar.component(.minute, from: mid)) / 60
            var diff = abs(h - habitualMidsleepHour); diff = min(diff, 24 - diff)
            let bonus = diff <= 2 ? 90 : (diff >= 5 ? 0 : 90 * (5 - diff) / 3)
            return s.asleepMinutes + bonus
        }
        return sessions.max(by: { score($0) < score($1) })
    }
}

/// §3.5 Sleep need + debt.
public enum SleepNeed {
    public static func need(recentDurationsMin: [Double], age: Int = 30) -> Double {
        let target = age < 18 ? 540.0 : 480.0
        guard recentDurationsMin.count >= 7 else { return target }
        return min(570, max(target, percentile(recentDurationsMin, 0.75)))
    }
}

public enum SleepDebt {
    /// Each night: asleep minutes (nil = no data, skipped). Returns debt minutes.
    public static func debt(nights: [Double?], baseNeed: Double) -> Double {
        var debt = 0.0
        for n in nights.suffix(14) {
            guard let slept = n else { continue }
            debt = 0.55 * max(0, baseNeed + debt - slept)
        }
        return debt < 10 ? 0 : debt
    }
}

/// §3.6 Edit guards.
public enum SleepEditGuard {
    public enum Result: Equatable { case ok(bed: Double, wake: Double), refused(String), needsConfirm(bed: Double, wake: Double) }
    public static func validate(bed: Double, wake: Double, nightStart: Double, nightEnd: Double, now: Double) -> Result {
        var bed = bed
        if bed >= wake || bed > now, wake - (bed - 86400) <= 16 * 3600 { bed -= 86400 }
        if wake > now + 300 { return .refused("Wake can't be in the future") }
        if wake <= bed || wake - bed > 86400 { return .refused("Invalid window") }
        if wake < nightStart || bed > nightEnd { return .needsConfirm(bed: bed, wake: wake) }
        return .ok(bed: bed, wake: wake)
    }
}

public enum SleepWindowReclip {
    public static func reclip(_ segs: [SleepSegment], newStart: Double, newEnd: Double) -> [SleepSegment] {
        var out: [SleepSegment] = []
        for s in segs where s.end > newStart && s.start < newEnd {
            out.append(SleepSegment(start: max(s.start, newStart), end: min(s.end, newEnd), stage: s.stage))
        }
        if out.isEmpty { return [SleepSegment(start: newStart, end: newEnd, stage: .awake)] }
        if let l = out.last, l.end < newEnd { out.append(SleepSegment(start: l.end, end: newEnd, stage: .awake)) }
        return out
    }
}

/// §3.6 Sleep-vs-wake HR contrast. Descriptive only.
public struct SleepHeartRateContrast: Sendable {
    public var sleepMinusWake: Double
    public var sleepReduction: Double
    public static func compute(sleep: [Double], wake: [Double]) -> SleepHeartRateContrast? {
        let s = sleep.filter { (30...220).contains($0) }, w = wake.filter { (30...220).contains($0) }
        guard s.count >= 30, w.count >= 30 else { return nil }
        let sm = mean(s), wm = mean(w)
        return SleepHeartRateContrast(sleepMinusWake: sm - wm, sleepReduction: 100 * (wm - sm) / wm)
    }
}
