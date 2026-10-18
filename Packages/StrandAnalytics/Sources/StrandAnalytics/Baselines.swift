import Foundation

/// §1.1 Personal baselines: winsorized EWMA centre + spread.
public enum BaselineStatus: String, Codable, Sendable {
    case calibrating, provisional, trusted, stale
}

public enum BaselineMetric: String, Codable, CaseIterable, Sendable {
    case hrv, restingHR, respiration, skinTemp

    public var validRange: ClosedRange<Double> {
        switch self {
        case .hrv: return 5...250
        case .restingHR: return 30...120
        case .respiration: return 4...40
        case .skinTemp: return 20...42
        }
    }
    public var floorSpread: Double {
        switch self {
        case .hrv: return 5.0
        case .restingHR: return 2.0
        case .respiration: return 0.5
        case .skinTemp: return 0.3
        }
    }
}

public struct Baseline: Codable, Sendable, Equatable {
    public var center: Double
    public var spread: Double
    public var count: Int
    public var nightsSinceUpdate: Int
    public var floorSpread: Double
    public var range: ClosedRange<Double>

    public static let centerHalfLife = 14.0
    public static let spreadHalfLife = 21.0

    public init(metric: BaselineMetric) {
        center = 0
        spread = metric.floorSpread
        count = 0
        nightsSinceUpdate = 0
        floorSpread = metric.floorSpread
        range = metric.validRange
    }

    public init(floorSpread: Double, range: ClosedRange<Double>) {
        center = 0; spread = floorSpread; count = 0; nightsSinceUpdate = 0
        self.floorSpread = floorSpread; self.range = range
    }

    public var status: BaselineStatus {
        if count < 4 { return .calibrating }
        if nightsSinceUpdate > 14 { return .stale }
        return count >= 14 ? .trusted : .provisional
    }

    public var isUsable: Bool { count >= 4 }

    /// Fold one nightly value. Out-of-range values are skipped; wild outliers are seen but not folded.
    public mutating func fold(_ value: Double) {
        guard range.contains(value), value.isFinite else { return }
        nightsSinceUpdate = 0
        if count == 0 {
            center = value; spread = floorSpread; count = 1
            return
        }
        count += 1
        if abs(value - center) > 5 * spread { return }
        let lc = 1 - pow(0.5, 1 / Self.centerHalfLife)
        let ls = 1 - pow(0.5, 1 / Self.spreadHalfLife)
        let clamped = min(max(value, center - 3 * spread), center + 3 * spread)
        let dev = abs(clamped - center)
        center += lc * (clamped - center)
        spread = max(floorSpread, spread + ls * (dev - spread))
    }

    public mutating func skipNight() { nightsSinceUpdate += 1 }

    /// Robust z: (value − centre) / (1.253 · spread).
    public func z(_ value: Double) -> Double {
        (value - center) / (1.253 * max(spread, 1e-6))
    }

    /// Build from a chronological series.
    public static func build(_ metric: BaselineMetric, from values: [Double?]) -> Baseline {
        var b = Baseline(metric: metric)
        for v in values {
            if let v { b.fold(v) } else { b.skipNight() }
        }
        return b
    }
}

/// §1.2 Vital banding.
public enum VitalBand: String, Sendable { case inRange, high, low, unknown }

public enum VitalBands {
    public static func band(value: Double, baseline: Baseline, fallback: ClosedRange<Double>) -> VitalBand {
        if baseline.status == .trusted {
            let z = baseline.z(value)
            return abs(z) <= 2 ? .inRange : (z > 0 ? .high : .low)
        }
        if fallback.contains(value) { return .inRange }
        return value > fallback.upperBound ? .high : .low
    }
}

public enum ConfidenceTier: String, Codable, Sendable {
    case calibrating = "Calibrating", building = "Building", solid = "Solid"
    public static func forNights(_ n: Int) -> ConfidenceTier {
        n < 4 ? .calibrating : (n < 14 ? .building : .solid)
    }
}
