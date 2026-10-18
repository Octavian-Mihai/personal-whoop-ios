import Foundation
import Observation
import StrandAnalytics

@Observable
@MainActor
final class AppModel {
    var snapshot = Snapshot()
    var raw: RawDay?
    var baselines: ChargeBaselines?
    var chargeResult: ChargeResult?
    var forecast: ChargeForecast?
    var readiness: [ReadinessSignal] = []
    var trainingLoad: [TrainingLoadPoint] = []
    var illness: IllnessResult?
    var vitality: VitalityResult?
    var stressHours: [StressHour] = []
    var detected: [DetectedWorkout] = []
    var autoSuggestion: (start: Double, end: Double)?
    var circadian: CircadianEstimate?
    var cycle: CycleEstimate?
    var digest: WeeklyDigest?
    var streak: (current: Int, longest: Int) = (0, 0)
    var fitnessAge: Double?
    var sleepDebtMin: Double = 0
    var sleepNeedMin: Double = 480
    var lastNight: SleepSession?
    var liveEffort: Double?
    var live: LiveWorkout?

    let ble = BLEManager()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personalwhoop.json")
    }()

    func isCompact(_ screen: String) -> Bool { ui.compact.contains(screen) }
    var ui: UISettings { get { snapshot.ui ?? UISettings() } set { snapshot.ui = newValue; save() } }
    var settings: AppSettings { get { snapshot.settings } set { snapshot.settings = newValue; save() } }
    var days: [DailyMetric] { snapshot.days }
    var today: DailyMetric? { snapshot.days.last }

    init() {
        load()
        // Dev hooks for comparing layouts: -compactAll / -compactNone
        if CommandLine.arguments.contains("-compactAll") { var u = ui; u.compact = ["today", "sleep", "workouts", "trends", "more"]; snapshot.ui = u }
        if CommandLine.arguments.contains("-compactNone") { var u = ui; u.compact = []; snapshot.ui = u }
        ble.onHR = { [weak self] bpm, rr in self?.ingestLive(bpm: bpm, rr: rr) }
        recompute()
        loadRawAsync()
    }

    // MARK: persistence
    func load() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Snapshot.self, from: d), !s.days.isEmpty {
            snapshot = s
        } else {
            snapshot.days = DemoData.history()
        }
    }
    /// Raw synthetic streams are generated off the main thread so the first frame isn't blocked.
    func loadRawAsync(seed: UInt64 = 11) {
        guard settings.useDemoData else { return }
        Task {
            let r = await Task.detached(priority: .userInitiated) { DemoData.rawDay(seed: seed) }.value
            raw = r
            recompute()
        }
    }
    func save() { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) } }

    func resetDemo() {
        snapshot.days = DemoData.history(seed: UInt64.random(in: 1...9999))
        snapshot.workouts.removeAll(); snapshot.hydration.removeAll()
        raw = nil
        recompute()
        loadRawAsync(seed: UInt64.random(in: 1...9999))
    }

    // MARK: analysis pipeline (per spec §1: raw → analyzeDay → DailyMetric)
    func recompute() {
        let s = settings.profile
        var hrvB = Baseline(metric: .hrv), rhrB = Baseline(metric: .restingHR), respB = Baseline(metric: .respiration)
        var effortHist: [Double] = []
        var updated = snapshot.days
        // fold today's raw-derived night into the last row
        if let raw, let night = raw.sleep, !updated.isEmpty {
            lastNight = night
            var m = updated[updated.count - 1]
            if let h = night.hrv { m.hrv = h }
            if let r = night.restingHR { m.restingHR = r }
            let asleep = night.asleepMinutes
            m.asleepMin = asleep; m.inBedMin = night.inBedMinutes
            m.deepMin = night.minutes(.deep); m.remMin = night.minutes(.rem); m.lightMin = night.minutes(.light); m.awakeMin = night.minutes(.awake)
            m.rest = RestScorer.score(asleepMin: asleep, inBedMin: night.inBedMinutes, deepMin: m.deepMin ?? 0, remMin: m.remMin ?? 0, needMin: sleepNeedMin, consistency: 0.7)
            updated[updated.count - 1] = m
        }
        let durations = updated.compactMap(\.asleepMin)
        sleepNeedMin = SleepNeed.need(recentDurationsMin: durations, age: Int(s.age))
        sleepDebtMin = SleepDebt.debt(nights: updated.map(\.asleepMin), baseNeed: sleepNeedMin)

        for i in updated.indices {
            var m = updated[i]
            let prevEffort = i > 0 ? updated[i - 1].effort : nil
            let chargeBase = ChargeBaselines(hrv: hrvB, restingHR: rhrB, respiration: respB)
            if let prev = prevEffort { effortHist.append(prev) }
            let inputs = ChargeInputs(hrv: m.hrv, restingHR: m.restingHR, rest: m.rest, respiration: m.respiration,
                                      skinTempDev: m.skinTempDev, previousEffort: prevEffort,
                                      previousEffortBaseline: effortHist.isEmpty ? nil : mean(effortHist), spo2: m.spo2)
            let res = RecoveryScorer.score(inputs, baselines: chargeBase)
            m.charge = res?.score
            if i == updated.count - 1 { chargeResult = res }
            if let v = m.hrv { hrvB.fold(v) } else { hrvB.skipNight() }
            if let v = m.restingHR { rhrB.fold(v) } else { rhrB.skipNight() }
            if let v = m.respiration { respB.fold(v) } else { respB.skipNight() }
            updated[i] = m
        }
        baselines = ChargeBaselines(hrv: hrvB, restingHR: rhrB, respiration: respB)

        // today's live effort / stress / workouts from raw HR
        if let raw, !updated.isEmpty {
            let rhr = updated.last?.restingHR ?? 60
            let hrMax = settings.profile.hrMaxOverride ?? StrainScorer.hrMax(age: s.age, observedHRs: raw.hr.map(\.bpm))
            let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let dayHR = raw.hr.filter { $0.t >= dayStart }
            let dayMotion = raw.gravity.filter { $0.t >= dayStart }
            liveEffort = StrainScorer.score(hr: dayHR, restingHR: rhr, hrMax: hrMax)
            var last = updated[updated.count - 1]
            last.effort = StrainScorer.displayed(live: liveEffort, stored: last.effort)
            last.kcal = Calories.kcal(hr: dayHR, restingHR: rhr, hrMax: hrMax, profile: s, wholeDay: true)
            stressHours = DaytimeStress.timeline(hr: dayHR, motion: dayMotion)
            let hv = updated.compactMap(\.hrv), hr = updated.compactMap(\.restingHR)
            last.stress = StressMath.daily(rhr: rhr, hrv: last.hrv ?? 0, historyRHR: Array(hr.dropLast()), historyHRV: Array(hv.dropLast()))
            detected = WorkoutDetector.detect(hr: dayHR, motion: dayMotion, restingHR: rhr, hrMax: hrMax, profile: s)
            last.workouts = detected.count
            let dismissed = snapshot.dismissedSuggestions ?? []
            autoSuggestion = AutoWorkoutDetector.suggest(hr: dayHR, restingHR: rhr, savedWorkouts: snapshot.workouts.map { ($0.start, $0.end) })
                .flatMap { s in dismissed.contains { abs($0 - s.start) < 1800 } ? nil : s }
            updated[updated.count - 1] = last
        }
        snapshot.days = updated

        // longitudinal
        let efforts = updated.map(\.effort)
        readiness = ReadinessEngine.evaluate(hrv: updated.map(\.hrv), rhr: updated.map(\.restingHR), resp: updated.map(\.respiration), effort: efforts)
        trainingLoad = TrainingLoadEngine.compute(efforts)
        let ch = updated.compactMap(\.charge)
        if ch.count >= 5, let t = updated.last {
            let slope = Summary.of(Array(ch.suffix(7)))?.slope ?? 0
            forecast = RecoveryForecast.forecast(charge14: Array(ch.suffix(14)), todayEffort: t.effort ?? 40,
                                                 meanEffort: mean(efforts.compactMap { $0 }), sleepHours: (t.asleepMin ?? 420) / 60,
                                                 needHours: sleepNeedMin / 60, slopePerDay: slope)
        }
        updateIllness()
        updateVitality()
        updateCircadian()
        updateInsights()
        let qualifying = Set(updated.filter { $0.charge != nil }.map(\.day))
        streak = StreakCalculator.streaks(days: qualifying, today: DayFormat.string(Date()))
        save()
    }

    private func updateIllness() {
        guard settings.illnessWatch, days.count >= 14, let b = baselines else { illness = nil; return }
        let recent = Array(days.suffix(2))
        func zOf(_ vals: [Double?], _ base: Baseline, sign: Double) -> Double? {
            let zs = vals.compactMap { $0 }.map { sign * base.z($0) }
            guard let last = zs.last else { return nil }
            return min(mean(zs), last)
        }
        var zs: [String: Double] = [:]
        if let v = zOf(recent.map(\.restingHR), b.restingHR, sign: 1) { zs["Resting HR"] = v }
        if let v = zOf(recent.map(\.respiration), b.respiration, sign: 1) { zs["Respiration"] = v }
        if let v = zOf(recent.map(\.hrv), b.hrv, sign: -1) { zs["HRV"] = v }
        if let t = recent.compactMap(\.skinTempDev).min(), let l = recent.last?.skinTempDev { zs["Skin temp"] = min(t, l) / 0.3 }
        illness = IllnessSignalEngine.evaluate(zs: zs, baselineTrusted: b.hrv.status == .trusted, confounders: [], nights: days.count)
    }

    private func updateVitality() {
        let p = settings.profile
        let rec = days.suffix(7)
        let rhr = mean(rec.compactMap(\.restingHR))
        let pa = 5.0 + Double(rec.reduce(0) { $0 + $1.workouts }) / 2
        let male = p.male ?? true
        fitnessAge = rec.compactMap(\.restingHR).count >= 4 ? FitnessAgeEngine.fitnessAge(male: male, age: p.age, rhr: rhr, paIndex: pa) : nil
        var vo2: Double?; var exp: Double?
        if let w = p.waistCm {
            vo2 = FitnessAgeEngine.vo2max(male: male, age: p.age, paIndex: pa, waistCm: w, rhr: rhr)
            exp = FitnessAgeEngine.vo2max(male: male, age: p.age, paIndex: 5, waistCm: w, rhr: 65)
        }
        let hrs = rec.compactMap(\.asleepMin).map { $0 / 60 }
        vitality = VitalityEngine.compute(age: p.age, rhr: rec.isEmpty ? nil : rhr, vo2: vo2, expectedVO2: exp,
                                          sleepHours: hrs.isEmpty ? nil : mean(hrs), regularity: 0.7,
                                          rmssd: mean(rec.compactMap(\.hrv)), steps: mean(rec.compactMap { $0.steps.map(Double.init) }))
    }

    private func updateCircadian() {
        guard let raw else { return }
        var by: [Int: [Double]] = [:]
        let cal = Calendar.current
        for s in raw.hr { by[cal.component(.hour, from: Date(timeIntervalSince1970: s.t)), default: []].append(s.bpm) }
        let bins = by.map { (hour: Double($0.key) + 0.5, value: mean($0.value)) }.sorted { $0.hour < $1.hour }
        circadian = CircadianEngine.estimate(bins: bins, days: days.count, habitualWakeHour: Double(settings.alarm.wakeMinute) / 60)
    }

    private func updateInsights() {
        func last7(_ kp: KeyPath<DailyMetric, Double?>, _ off: Int) -> [Double] {
            let end = days.count - off, start = max(0, end - 7)
            return end > start ? days[start..<end].compactMap { $0[keyPath: kp] } : []
        }
        var tw: [String: [Double]] = [:], lw: [String: [Double]] = [:]
        for (name, kp) in [("Charge", \DailyMetric.charge), ("Effort", \.effort), ("Rest", \.rest), ("Resting HR", \.restingHR), ("HRV", \.hrv)] as [(String, KeyPath<DailyMetric, Double?>)] {
            tw[name] = last7(kp, 0); lw[name] = last7(kp, 7)
        }
        digest = WeeklyDigest.build(thisWeek: tw, lastWeek: lw)
    }

    // MARK: live data
    func startWorkout(_ kind: WorkoutKind) {
        live?.cancel()
        live = LiveWorkout(kind: kind, profile: settings.profile, restingHR: today?.restingHR ?? 60, ble: ble)
    }
    func finishWorkout(save: Bool) {
        guard let l = live else { return }
        if save, let w = l.finish() { addWorkout(w) } else { l.cancel() }
        live = nil
    }

    func ingestLive(bpm: Int, rr: [Double]) {
        live?.ingest(bpm: bpm)
        let now = Date().timeIntervalSince1970
        snapshot.liveHR.append(HRSample(t: now, bpm: Double(bpm)))
        if snapshot.liveHR.count > 20_000 { snapshot.liveHR.removeFirst(2_000) }
    }

    // MARK: actions
    func logHydration(_ ml: Int) {
        snapshot.hydration.append(HydrationLog(time: Date().timeIntervalSince1970, ml: ml)); save()
    }
    var hydrationToday: Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return snapshot.hydration.filter { $0.time >= start }.reduce(0) { $0 + $1.ml }
    }
    var hydrationGoal: Int { HydrationGoal.goalML(male: settings.profile.male, effort: today?.effort) }

    /// "I didn't work out": remember this window so it isn't suggested again.
    func dismissSuggestion() {
        guard let s = autoSuggestion else { return }
        snapshot.dismissedSuggestions = (snapshot.dismissedSuggestions ?? []) + [s.start]
        autoSuggestion = nil
        save()
    }

    func addWorkout(_ w: SavedWorkout) { snapshot.workouts.append(w); snapshot.workouts.sort { $0.start > $1.start }; recompute() }

    func exportBackup() -> URL? {
        guard let d = try? JSONEncoder().encode(snapshot) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = TimeZone(identifier: "UTC")
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("personalwhoop-backup-\(f.string(from: Date())).json")
        try? d.write(to: u)
        return u
    }
    func restore(from url: URL) throws {
        let d = try Data(contentsOf: url)
        var s = try JSONDecoder().decode(Snapshot.self, from: d)
        s.liveHR = []
        snapshot = s; recompute()
    }
}
