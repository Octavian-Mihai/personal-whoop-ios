import Foundation
import StrandAnalytics

struct HistoryAnalysis {
    var raw: RawDay?
    var days: [DailyMetric] = []
    var nights: [SleepSession] = []
}

/// Turns stored strap history into sleep nights, daily rows and a "raw day" for the live pipeline. Pure; run it off the main thread.
enum HistoryAnalyzer {
    static func analyze(_ records: [HistoryRecord], profile: Profile, now: Date = Date()) -> HistoryAnalysis {
        let usable = records.filter { $0.wrist != 1 && ($0.hr >= 30 || $0.hr == 0) }
        guard usable.count >= 600 else { return HistoryAnalysis() }
        var hr: [HRSample] = [], grav: [GravitySample] = [], rr: [(t: Double, rr: Double)] = []
        hr.reserveCapacity(usable.count)
        for r in usable {
            let t = Double(r.unix)
            if r.hr >= 30 { hr.append(HRSample(t: t, bpm: Double(r.hr))) }
            if let g = r.gravity { grav.append(GravitySample(t: t, x: Double(g.0), y: Double(g.1), z: Double(g.2))) }
            for (i, v) in r.rr.enumerated() { rr.append((t: t + Double(i) * 0.25, rr: Double(v))) }
        }
        guard hr.count >= 600 else { return HistoryAnalysis() }

        var out = HistoryAnalysis()
        var daily: [String: DailyMetric] = [:]

        // sleep nights
        for span in SleepDetector.detect(hr: hr, gravity: grav) {
            let segs = SleepStager.stage(start: span.start, end: span.end, hr: hr, gravity: grav)
            guard !segs.isEmpty else { continue }
            let beats = rr.filter { $0.t >= span.start && $0.t <= span.end }
            let night = SleepSession(start: span.start, end: span.end, segments: segs,
                                     restingHR: SleepStager.restingHR(hr: hr, start: span.start, end: span.end),
                                     hrv: HRVAnalyzer.nightlyRMSSD(beats))
            out.nights.append(night)
            let day = DayFormat.string(Date(timeIntervalSince1970: span.end))
            var m = daily[day] ?? DailyMetric(day: day)
            m.asleepMin = night.asleepMinutes; m.inBedMin = night.inBedMinutes
            m.deepMin = night.minutes(.deep); m.remMin = night.minutes(.rem); m.lightMin = night.minutes(.light); m.awakeMin = night.minutes(.awake)
            m.restingHR = night.restingHR; m.hrv = night.hrv
            m.rest = RestScorer.score(asleepMin: night.asleepMinutes, inBedMin: night.inBedMinutes, deepMin: night.minutes(.deep),
                                      remMin: night.minutes(.rem), needMin: 480, consistency: 0.7)
            daily[day] = m
        }

        // Effort + energy for each fully covered calendar day
        let cal = Calendar.current
        let byDay = Dictionary(grouping: hr) { DayFormat.string(Date(timeIntervalSince1970: $0.t)) }
        let hrMax = profile.hrMaxOverride ?? StrainScorer.hrMax(age: profile.age, observedHRs: hr.map(\.bpm))
        for (day, samples) in byDay where samples.count >= 600 {
            var m = daily[day] ?? DailyMetric(day: day)
            let rhr = m.restingHR ?? percentile(samples.map(\.bpm), 0.10)
            m.effort = StrainScorer.score(hr: samples, restingHR: rhr, hrMax: hrMax)
            m.kcal = Calories.kcal(hr: samples, restingHR: rhr, hrMax: hrMax, profile: profile, wholeDay: true)
            daily[day] = m
        }
        out.days = daily.values.sorted { $0.day < $1.day }

        // raw day for the live pipeline: the last 48 h
        let start = now.addingTimeInterval(-48 * 3600).timeIntervalSince1970
        let recent = hr.filter { $0.t >= start }
        if recent.count > 60 {
            out.raw = RawDay(hr: recent, gravity: grav.filter { $0.t >= start }, rr: rr.filter { $0.t >= start }.map { (t: $0.t, rr: $0.rr) },
                             sleep: out.nights.last, workouts: [])
        }
        _ = cal
        return out
    }
}
