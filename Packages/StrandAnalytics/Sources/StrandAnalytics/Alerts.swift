import Foundation

// MARK: - §13 Alarm scheduling

public enum SmartAlarm {
    /// First strictly-future instant matching wake minute-of-day on an enabled weekday.
    /// weekdays: Calendar weekday numbers (1=Sunday…7). Empty = every day. overrides: weekday → minute-of-day.
    public static func next(after now: Date, wakeMinute: Int, weekdays: Set<Int>, overrides: [Int: Int] = [:], calendar: Calendar = .current) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if !weekdays.isEmpty && !weekdays.contains(wd) { continue }
            let minute = overrides[wd] ?? wakeMinute
            var c = calendar.dateComponents([.year, .month, .day], from: day)
            c.hour = minute / 60; c.minute = minute % 60; c.second = 0
            if let d = calendar.date(from: c), d > now { return d }
        }
        return nil
    }

    public static let snoozeDelays = [3, 4, 5, 10]
    public static let maxSnoozes = 3
    public static func snoozeInstant(firedAt: Date, delayMinutes: Int, count: Int) -> Date? {
        guard count < maxSnoozes else { return nil }
        let t = firedAt.timeIntervalSince1970 + Double(delayMinutes * 60)
        return Date(timeIntervalSince1970: (t / 60).rounded(.up) * 60)
    }
}

public enum WindDownNudge {
    /// Minute-of-day = wake − need − lead, wrapped.
    public static func minuteOfDay(wakeMinute: Int, needMinutes: Int = 480, leadMinutes: Int = 30) -> (minute: Int, previousDay: Bool) {
        let raw = wakeMinute - needMinutes - leadMinutes
        return (((raw % 1440) + 1440) % 1440, raw < 0)
    }
}

// MARK: - §20 Notification policies

public enum StrainTarget {
    public static func band(charge: Double?) -> ClosedRange<Double>? {
        guard let c = charge else { return nil }
        return c >= 67 ? 14...18 : (c >= 34 ? 10...14 : 4...10)
    }
    public static func reached(effort100: Double, charge: Double?) -> Bool {
        guard let b = band(charge: charge) else { return false }
        return StrainScorer.to21(effort100) >= b.lowerBound
    }
}

public struct BatteryAlertState: Codable, Sendable {
    public var lowFired = false, fullFired = false, runtimeFired = false, criticalFired = false
    public init() {}
}

public enum BatteryAlert: String, Sendable { case low, full, runtime, critical, bedtime }

public enum BatteryNotifier {
    public static func evaluate(soc: Double, charging: Bool?, runtimeHours: Double?, state: inout BatteryAlertState,
                                hoursToBed: Double? = nil, typicalSleepHours: Double = 8) -> [BatteryAlert] {
        var out: [BatteryAlert] = []
        if soc >= 25 { state.lowFired = false; state.criticalFired = false }
        if soc < 100 { state.fullFired = false }
        if let r = runtimeHours, r >= 36 { state.runtimeFired = false }
        if charging != true {
            if soc <= 12, !state.criticalFired { state.criticalFired = true; out.append(.critical) }
            if soc <= 15, !state.lowFired { state.lowFired = true; out.append(.low) }
            if let r = runtimeHours, r <= 24, !state.runtimeFired { state.runtimeFired = true; out.append(.runtime) }
            if let h = hoursToBed, h <= 3, let r = runtimeHours, r < h + typicalSleepHours + 1 { out.append(.bedtime) }
        }
        if soc >= 100, !state.fullFired { state.fullFired = true; out.append(.full) }
        return out
    }
}

public enum BatteryEstimator {
    public static func daysLeft(series: [(t: Double, soc: Double)], ratedHours: Double) -> Double? {
        let s = series.sorted { $0.t < $1.t }
        guard let current = s.last else { return nil }
        // run since the most recent ≥90 % charge, a rise > 1 pt marks a charge
        var startIdx = 0
        for i in 1..<max(1, s.count) where s[i].soc - s[i - 1].soc > 1 { startIdx = i }
        let run = Array(s[startIdx...])
        let usableSoc = max(0, current.soc - 10)
        if let f = run.first, f.soc >= 90, current.t - f.t >= 7200, f.soc - current.soc >= 2 {
            let slope = (f.soc - current.soc) / ((current.t - f.t) / 3600)
            let rated = ratedHours > 0 ? 100 / ratedHours : slope
            let capped = max(slope, rated / 1.5)
            return usableSoc / capped / 24
        }
        return usableSoc / (100 / ratedHours) / 24
    }
    /// Hours until the strap reaches 0 %, from the current discharge run (falls back to the rated runtime).
    public static func hoursToEmpty(series: [(t: Double, soc: Double)], ratedHours: Double) -> Double? {
        let s = series.sorted { $0.t < $1.t }
        guard let current = s.last, current.soc > 0 else { return nil }
        var startIdx = 0
        for i in 1..<max(1, s.count) where s[i].soc - s[i - 1].soc > 1 { startIdx = i }
        let run = s[startIdx...]
        let rated = ratedHours > 0 ? 100 / ratedHours : 0
        if let f = run.first, current.t - f.t >= 7200, f.soc - current.soc >= 2 {
            let slope = (f.soc - current.soc) / ((current.t - f.t) / 3600)
            let capped = max(slope, rated / 1.5)
            return current.soc / capped
        }
        return rated > 0 ? current.soc / rated : nil
    }
    public static let ratedHours4: Double = 108
    public static let ratedHours5: Double = 288
}

// MARK: - §15 Sync policy

public struct BackfillPolicy: Sendable {
    public enum Trigger: Sendable { case periodic, event, manual, connect, foreground, autoContinue }
    public var consecutiveEmpty = 0
    public var lastAutomatic: Double = -.infinity
    public init() {}

    public func floor(for t: Trigger) -> Double {
        let mult = consecutiveEmpty >= 3 ? min(4.0, pow(2.0, Double(consecutiveEmpty - 2))) : 1
        switch t {
        case .periodic: return 15 * 60 * mult
        case .event: return 90 * mult
        default: return 0
        }
    }
    public func allowed(_ t: Trigger, now: Double, strapFutureDated: Bool) -> Bool {
        switch t {
        case .periodic, .event:
            if strapFutureDated { return false }
            return now - lastAutomatic >= floor(for: t)
        default: return true
        }
    }
}

public struct SyncEstimate: Sendable, Codable {
    public var rate: Double?
    public init() {}
    public mutating func record(gapSeconds: Double, durationSeconds: Double) {
        guard gapSeconds >= 600, durationSeconds >= 5 else { return }
        let sample = clamp(gapSeconds / durationSeconds, 5, 20000)
        rate = rate.map { 0.6 * $0 + 0.4 * sample } ?? sample
    }
    public func estimateSeconds(gap: Double) -> Double? { rate.map { max(gap / $0, 1) } }
}
