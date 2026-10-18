import Foundation

public struct HRVResult: Sendable, Equatable {
    public var rmssd: Double
    public var sdnn: Double
    public var pnn50: Double
    public var meanNN: Double
    public var cleanCount: Int
    public var inputCount: Int
    public var meanHR: Double { 60000 / meanNN }
    public var rejectedFraction: Double {
        inputCount == 0 ? 0 : Double(inputCount - cleanCount) / Double(inputCount)
    }
}

/// §2 HRV: time domain, cleaning, nightly, spot, stress index, frequency domain.
public enum HRVAnalyzer {
    public static let minClean = 20

    /// Range filter 300–2000 ms then Malik 20 % ectopic rejection (centered 5-beat median).
    public static func clean(_ rr: [Double]) -> [Double] {
        let ranged = rr.filter { $0 >= 300 && $0 <= 2000 }
        guard ranged.count >= 5 else { return ranged }
        var out: [Double] = []
        for i in 0..<ranged.count {
            let lo = max(0, i - 2), hi = min(ranged.count - 1, i + 2)
            let med = median(Array(ranged[lo...hi]))
            if abs(ranged[i] - med) <= 0.2 * med { out.append(ranged[i]) }
        }
        return out
    }

    public static func analyze(_ rr: [Double]) -> HRVResult? {
        let nn = clean(rr)
        guard nn.count >= minClean else { return nil }
        var sumSq = 0.0
        var over50 = 0
        for i in 0..<(nn.count - 1) {
            let d = nn[i + 1] - nn[i]
            sumSq += d * d
            if abs(d) > 50 { over50 += 1 }
        }
        let n1 = Double(nn.count - 1)
        let mean = nn.reduce(0, +) / Double(nn.count)
        let varSum = nn.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return HRVResult(
            rmssd: (sumSq / n1).squareRoot(),
            sdnn: (varSum / Double(nn.count - 1)).squareRoot(),
            pnn50: 100 * Double(over50) / n1,
            meanNN: mean, cleanCount: nn.count, inputCount: rr.count)
    }

    /// §2.2 Nightly HRV: mean RMSSD over 5-minute tumbling windows. Input: (time seconds, rr ms).
    public static func nightlyRMSSD(_ beats: [(t: Double, rr: Double)], windowSeconds: Double = 300) -> Double? {
        guard let first = beats.first?.t else { return nil }
        var buckets: [Int: [Double]] = [:]
        for b in beats { buckets[Int((b.t - first) / windowSeconds), default: []].append(b.rr) }
        let vals = buckets.keys.sorted().compactMap { analyze(buckets[$0]!)?.rmssd }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}

public enum SpotHrv {
    public static let maxRejectedFraction = 0.35
    public enum Outcome: Sendable, Equatable {
        case reading(HRVResult)
        case insufficient(clean: Int, needed: Int, input: Int)
    }
    public static func evaluate(_ rr: [Double]) -> Outcome {
        guard let r = HRVAnalyzer.analyze(rr), r.rejectedFraction <= maxRejectedFraction else {
            let c = HRVAnalyzer.clean(rr).count
            return .insufficient(clean: c, needed: HRVAnalyzer.minClean, input: rr.count)
        }
        return .reading(r)
    }
}

/// §2.7 Baevsky Stress Index.
public enum StressIndex {
    public static func compute(_ rr: [Double]) -> Double? {
        let nn = HRVAnalyzer.clean(rr)
        guard nn.count >= HRVAnalyzer.minClean,
              Double(rr.count - nn.count) / Double(rr.count) <= SpotHrv.maxRejectedFraction else { return nil }
        var bins: [Int: Int] = [:]
        for v in nn { bins[Int(v / 50), default: 0] += 1 }
        guard let best = bins.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        let mo = (Double(best.key) * 50 + 25) / 1000
        let amo = 100 * Double(best.value) / Double(nn.count)
        let mx = (nn.max()! - nn.min()!) / 1000
        guard mx > 0, mo > 0 else { return nil }
        return amo / (2 * mo * mx)
    }
}

/// §2.3 Lomb–Scargle band powers (relative, variance-normalised).
public struct HRVFrequency: Sendable {
    public var hf: Double
    public var lf: Double?
    public var vlf: Double?
    public var lfhf: Double?

    public static func compute(_ rr: [Double]) -> HRVFrequency? {
        let nn = HRVAnalyzer.clean(rr)
        guard nn.count >= HRVAnalyzer.minClean else { return nil }
        var t: [Double] = []; var acc = 0.0
        for v in nn { acc += v / 1000; t.append(acc) }
        let span = t.last! - t.first!
        guard span >= 60 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        let y = nn.map { $0 - mean }
        let variance = y.reduce(0) { $0 + $1 * $1 } / Double(y.count)
        guard variance > 0 else { return nil }

        func power(_ f: Double) -> Double {
            let w = 2 * Double.pi * f
            var s2 = 0.0, c2 = 0.0
            for ti in t { s2 += sin(2 * w * ti); c2 += cos(2 * w * ti) }
            let tau = atan2(s2, c2) / (2 * w)
            var yc = 0.0, ys = 0.0, cc = 0.0, ss = 0.0
            for (i, ti) in t.enumerated() {
                let c = cos(w * (ti - tau)), s = sin(w * (ti - tau))
                yc += y[i] * c; ys += y[i] * s; cc += c * c; ss += s * s
            }
            let p = 0.5 * ((cc > 0 ? yc * yc / cc : 0) + (ss > 0 ? ys * ys / ss : 0))
            return p / variance
        }
        func band(_ lo: Double, _ hi: Double) -> Double {
            let step = 0.005
            var total = 0.0
            var f = lo
            var prev = power(f)
            while f + step <= hi + 1e-9 {
                let next = power(f + step)
                total += 0.5 * (prev + next) * step
                prev = next; f += step
            }
            return total
        }
        let hf = band(0.15, 0.40)
        guard span >= 250 else { return HRVFrequency(hf: hf, lf: nil, vlf: nil, lfhf: nil) }
        let lf = band(0.04, 0.15)
        let vlf = band(0.0033, 0.04)
        return HRVFrequency(hf: hf, lf: lf, vlf: vlf, lfhf: hf > 0 ? lf / hf : nil)
    }
}

/// §2.4 HRV readiness tier on ln(RMSSD).
public enum HRVReadinessTier: String, Sendable { case primed, normal, suppressed }

public enum HRVReadiness {
    public static func tier(nightlyRMSSD: [Double]) -> HRVReadinessTier? {
        let ln = nightlyRMSSD.filter { $0 > 0 }.map { Foundation.log($0) }
        guard ln.count >= 14 else { return nil }
        let long = Array(ln.suffix(60))
        let mean = long.reduce(0, +) / Double(long.count)
        let sd = (long.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, long.count - 1))).squareRoot()
        let recent = ln.suffix(7)
        let base = recent.reduce(0, +) / Double(recent.count)
        if base > mean + 0.5 * sd { return .primed }
        if base < mean - 0.5 * sd { return .suppressed }
        return .normal
    }
}

// MARK: - Shared math

public func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

public func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

public func stddev(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let m = mean(xs)
    return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)).squareRoot()
}

public func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let idx = p * Double(s.count - 1)
    let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (idx - Double(lo))
}

public func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
public func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
