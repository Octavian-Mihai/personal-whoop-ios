import Foundation
import Observation
import SwiftUI
import StrandAnalytics
import UserNotifications
import WidgetKit

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
    /// Snooze chain: how many times the alarm has been re-armed this morning, and when it rings next.
    var snoozeCount = 0
    private var lastWidgetSync = Date.distantPast
    // automations
    private var zoneWindow: [Double] = []
    private var lastZone = 0
    private var rrBuffer: [Double] = []
    private var stressDetector = StressOnsetDetector()
    private var sedentary = SedentaryDetector()
    private var batteryState: BatteryAlertState = {
        (UserDefaults.standard.data(forKey: "batteryAlertState").flatMap { try? JSONDecoder().decode(BatteryAlertState.self, from: $0) }) ?? BatteryAlertState()
    }()
    var snoozeUntil: Date?

    let ble = BLEManager()
    let health = HealthBridge()
    let history = HistorySync()
    private var historyRaw: RawDay?
    #if DEBUG
    private var simulatedStrap: SimulatedStrap?
    #endif
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personalwhoop.json")
    }()

    var ui: UISettings { get { snapshot.ui ?? UISettings() } set { snapshot.ui = newValue; save() } }
    var settings: AppSettings { get { snapshot.settings } set { snapshot.settings = newValue; save() } }
    var days: [DailyMetric] { snapshot.days }
    var today: DailyMetric? { snapshot.days.last }

    init() {
        load()
        UNUserNotificationCenter.current().delegate = Notifier.Delegate.shared
        ble.onHR = { [weak self] bpm, rr in self?.ingestLive(bpm: bpm, rr: rr) }
        ble.onBattery = { [weak self] pct in self?.batteryUpdated(pct) }
        history.ble = ble
        history.isConnected = { [weak self] in self?.ble.state == .connected }
        ble.onHistoryFrame = { [weak self] f in self?.history.handle(f) }
        ble.onReady = { [weak self] in self?.history.start(manual: false) }
        history.onFinished = { [weak self] in await self?.historyFinished() }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-simulateHistory") {
            let hours = (i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) : nil) ?? 36
            if settings.useDemoData || needsOnboarding { chooseDataSource(demo: false) }
            simulatedStrap = SimulatedStrap.install(on: history, hours: hours)
            Task { try? await Task.sleep(for: .seconds(12)); history.start(manual: true) }   // give the fake strap time to build its frames
        }
        #endif
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.ble.state == .connected { self?.history.start(manual: false) } }   // the policy enforces the 15-minute floor
        }
        Task { [weak self] in
            await self?.history.loadStore()
            if self?.settings.useDemoData == false { await self?.historyFinished() }
        }
        recompute()
        loadRawAsync()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .strapAlarmFired, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.alarmDidFire() } }
        nc.addObserver(forName: .strapDoubleTap, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopSnooze() } }
        ble.connect()   // reconnect automatically so battery and live HR are there when the app opens
    }

    // MARK: persistence
    func load() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            snapshot = s
            // anyone who already had data before the first-run screen existed counts as onboarded
            if snapshot.onboarded == nil, !s.days.isEmpty { snapshot.onboarded = true }
        }
        // a fresh install stays empty until the first-run choice
    }

    /// Rest score of the day the last night ended on (the hero on Sleep), not necessarily today's row.
    var lastNightRest: Double? {
        guard let n = lastNight else { return today?.rest }
        let key = DayFormat.string(Date(timeIntervalSince1970: n.end))
        return days.first { $0.day == key }?.rest ?? today?.rest
    }

    /// nil = follow the iPhone. "By time of day" switches to light between the chosen times and dark outside them.
    func colorScheme(at date: Date = Date()) -> ColorScheme? {
        switch ui.appearance ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        case .schedule:
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let now = (c.hour ?? 12) * 60 + (c.minute ?? 0)
            let from = ui.lightFromMinute ?? 7 * 60, to = ui.lightToMinute ?? 20 * 60
            let light = from <= to ? (now >= from && now < to) : (now >= from || now < to)
            return light ? .light : .dark
        }
    }

    var needsOnboarding: Bool { snapshot.onboarded != true }

    /// First-run / Settings choice. Demo = synthetic 60 days + a raw day; real = empty history, live data from the strap.
    func chooseDataSource(demo: Bool) {
        var s = settings; s.useDemoData = demo; snapshot.settings = s
        snapshot.onboarded = true
        if demo {
            snapshot.days = DemoData.history()
            raw = nil
            recompute()
            loadRawAsync()
        } else {
            snapshot.days = []
            raw = nil
            snapshot.liveHR = []
            recompute()
            ble.connect()
        }
        save()
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
        if !settings.useDemoData { raw = realRaw() }
        var hrvB = Baseline(metric: .hrv), rhrB = Baseline(metric: .restingHR), respB = Baseline(metric: .respiration)
        var effortHist: [Double] = []
        var updated = snapshot.days
        // real strap, no history yet: keep a row for today so live heart rate can fill Effort, calories and stress
        if !settings.useDemoData, snapshot.onboarded == true, updated.last?.day != DayFormat.string(Date()) { updated.append(DailyMetric(day: DayFormat.string(Date()))) }
        if raw?.sleep == nil, !settings.useDemoData { lastNight = snapshot.importedNights?.last }
        // fold today's raw-derived night (anchored by the user's bed/wake marks when present) into the last row
        if let raw, let night = effectiveNight(raw), !updated.isEmpty {
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
            m.charge = res?.score ?? m.charge
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
        checkIllnessNotification()
        checkStrainTarget()
        updateVitality()
        updateCircadian()
        updateInsights()
        let qualifying = Set(updated.filter { $0.charge != nil }.map(\.day))
        streak = StreakCalculator.streaks(days: qualifying, today: DayFormat.string(Date()))
        save()
        syncWidgets()
        writeNightToHealth()
    }

    /// Re-derives nights, daily rows and today's raw streams from everything stored from the strap. Strap-derived values win.
    func historyFinished() async {
        guard !settings.useDemoData else { return }
        let records = await history.store.window(from: Date().addingTimeInterval(-96 * 3600))
        let profile = settings.profile
        let analysis = await Task.detached(priority: .userInitiated) { HistoryAnalyzer.analyze(records, profile: profile) }.value
        historyRaw = analysis.raw
        var map = Dictionary(snapshot.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for d in analysis.days {
            var m = map[d.day] ?? DailyMetric(day: d.day)
            if let v = d.asleepMin { m.asleepMin = v; m.inBedMin = d.inBedMin; m.deepMin = d.deepMin; m.remMin = d.remMin; m.lightMin = d.lightMin; m.awakeMin = d.awakeMin; m.rest = d.rest }
            if let v = d.restingHR { m.restingHR = v }
            if let v = d.hrv { m.hrv = v }
            if let v = d.effort { m.effort = v }
            if let v = d.kcal { m.kcal = v }
            map[d.day] = m
        }
        snapshot.days = map.values.sorted { $0.day < $1.day }
        var nights = snapshot.importedNights ?? []
        let known = Set(nights.map { $0.start })
        nights.append(contentsOf: analysis.nights.filter { !known.contains($0.start) })
        snapshot.importedNights = nights.sorted { $0.start < $1.start }
        snapshot.onboarded = true
        recompute()
    }

    /// Today's live heart-rate readings as a raw day (no gravity or beat intervals over the standard HR profile).
    private func realRaw() -> RawDay? {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let live = snapshot.liveHR.filter { $0.t >= start }
        if var h = historyRaw {                                  // stored strap history, topped up with live readings
            let lastT = h.hr.last?.t ?? 0
            h.hr.append(contentsOf: snapshot.liveHR.filter { $0.t > lastT })
            return h
        }
        guard live.count > 1 else { return nil }
        return RawDay(hr: live, gravity: [], rr: [], sleep: nil, workouts: [])
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
        if Date().timeIntervalSince(lastWidgetSync) > 300 { syncWidgets() }   // keep widgets' live HR reasonably fresh without burning reload budget
        guard live == nil else { return }          // a tracked workout has its own coach
        runAutomations(bpm: Double(bpm), rr: rr, now: now)
    }

    /// Opt-in strap buzzes: zone coaching, stress check-in, inactivity reminder. Each can explain itself with a silent notification.
    private func runAutomations(bpm: Double, rr: [Double], now: Double) {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date(timeIntervalSince1970: now))
        let rhr = today?.restingHR ?? 60

        // HR-zone coach: median of ~10 readings, buzz on entering zone 5 / dropping to zone ≤ 1
        zoneWindow.append(bpm); if zoneWindow.count > 10 { zoneWindow.removeFirst() }
        if settings.zoneCoach, zoneWindow.count >= 5 {
            let z = HRZones(age: settings.profile.age, override: settings.profile.hrMaxOverride).zone(for: median(zoneWindow))
            if let cue = ZoneCoach.cue(previous: lastZone, current: z) {
                ble.buzz(loops: UInt8(cue.loops))
                explainBuzz("zone", cue.cue == .enteredTop ? "You entered your top heart-rate zone. Ease off." : "Your heart rate settled back down.")
            }
            lastZone = z
        } else if zoneWindow.count >= 5 { lastZone = HRZones(age: settings.profile.age, override: settings.profile.hrMaxOverride).zone(for: median(zoneWindow)) }

        // Stress check-in: fast RMSSD dip that holds for 60 s while resting
        if settings.stressNudge, !rr.isEmpty {
            rrBuffer.append(contentsOf: rr); if rrBuffer.count > 60 { rrBuffer.removeFirst(rrBuffer.count - 60) }
            let quiet = hour >= 22 || hour < 7
            if rrBuffer.count >= 30, stressDetector.ingest(now: now, rr60: rrBuffer, hr: bpm, still: (55...100).contains(bpm), quietHours: quiet) {
                ble.buzz(loops: 2)
                explainBuzz("stress", "Your heart-rate variability dipped for a minute. Take a slow breath?")
                Notifier.post(id: "stress-nudge", title: "Stress check-in", body: "Your HRV dipped while you were resting. A minute of slow breathing can help.")
            }
        }

        // Inactivity: heart-rate-only proxy until the strap's motion stream is decoded (approximate)
        if settings.sedentaryReminder {
            let pseudoMotion = bpm > rhr + 12 ? 0.3 : 0.05
            if sedentary.ingest(t: now, smoothedMotion: pseudoMotion, hour: hour) {
                ble.buzz(loops: 2)
                explainBuzz("inactivity", "You've been still for a while. Time to move.")
                Notifier.post(id: "inactivity", title: "Time to move", body: "You've been sitting for a while.")
            }
        }
    }

    /// "Why did my strap buzz?" — a silent, passive notification naming the automation. Explains, never triggers.
    func explainBuzz(_ cause: String, _ text: String) {
        guard settings.notifications.buzzExplain else { return }
        Notifier.post(id: "buzz-cause-\(cause)", title: "Strap buzzed", body: text, silent: true)
    }

    // MARK: backup import
    /// Reads a NOOP backup off the main thread, then merges it. Strap-derived days win; Apple Health history only fills gaps.
    func importNoopBackup(from url: URL, progress: @escaping @Sendable (String) -> Void) async throws -> NoopImportResult {
        let r = try await Task.detached(priority: .userInitiated) { try NoopBackupImporter.read(url: url, progress: progress) }.value
        if settings.useDemoData { chooseDataSource(demo: false) }   // demo and real history must never mix
        applyNoopImport(r)
        return r
    }

    private func applyNoopImport(_ r: NoopImportResult) {
        var map = Dictionary(snapshot.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for d in r.days {
            var m = map[d.day] ?? DailyMetric(day: d.day)
            func take<T>(_ v: T?, _ set: (inout DailyMetric, T) -> Void) { if let v { set(&m, v) } }
            take(d.hrv) { $0.hrv = $1 }; take(d.restingHR) { $0.restingHR = $1 }; take(d.respiration) { $0.respiration = $1 }
            take(d.skinTempDev) { $0.skinTempDev = $1 }; take(d.spo2) { $0.spo2 = $1 }
            take(d.asleepMin) { $0.asleepMin = $1 }; take(d.inBedMin) { $0.inBedMin = $1 }; take(d.deepMin) { $0.deepMin = $1 }
            take(d.remMin) { $0.remMin = $1 }; take(d.lightMin) { $0.lightMin = $1 }; take(d.awakeMin) { $0.awakeMin = $1 }
            take(d.rest) { $0.rest = $1 }; take(d.effort) { $0.effort = $1 }; take(d.steps) { $0.steps = $1 }; take(d.kcal) { $0.kcal = $1 }
            m.workouts = max(m.workouts, d.workouts)
            m.charge = d.charge ?? m.charge     // recomputed below, but keep imported when the strap provided it
            map[d.day] = m
        }
        snapshot.days = map.values.sorted { $0.day < $1.day }
        var nights = snapshot.importedNights ?? []
        let known = Set(nights.map { $0.start })
        nights.append(contentsOf: r.nights.filter { !known.contains($0.start) })
        snapshot.importedNights = nights.sorted { $0.start < $1.start }
        let have = Set(snapshot.workouts.map(\.id))
        snapshot.workouts.append(contentsOf: r.workouts.filter { !have.contains($0.id) })
        snapshot.workouts.sort { $0.start > $1.start }
        snapshot.onboarded = true
        applyHealth(r.healthDays, workouts: [])     // gap filler (also recomputes and saves)
    }

    func useBackupProfile(_ p: BackupProfile) {
        var s = settings
        if let v = p.age { s.profile.age = v }
        if let v = p.heightCm { s.profile.heightCm = v }
        if let v = p.weightKg { s.profile.weightKg = v }
        if let v = p.hrMax { s.profile.hrMaxOverride = v }
        settings = s
        recompute()
    }

    // MARK: Apple Health
    var healthPrefs: HealthPrefs { get { snapshot.healthPrefs ?? HealthPrefs() } set { snapshot.healthPrefs = newValue; save() } }
    /// True once the user has gone through the Health permission sheet.
    var healthConnected: Bool { healthPrefs.readEnabled }

    func connectHealth() async {
        guard await health.requestAuthorization() else { return }
        var p = healthPrefs; p.readEnabled = true; healthPrefs = p
        await importHealth()
    }

    func disconnectHealth() { var p = healthPrefs; p.readEnabled = false; healthPrefs = p }

    /// Pulls the last 30 days from Apple Health. It fills gaps and feeds the comparison screen; it never replaces strap-derived numbers,
    /// except steps, which Health *counts* while the strap only estimates.
    func importHealth() async {
        guard healthConnected else { return }
        let r = await health.importDays(30)
        applyHealth(r.days, workouts: r.workouts)
        var p = healthPrefs; p.lastImport = Date(); healthPrefs = p
    }

    private func applyHealth(_ days: [HealthDay], workouts: [SavedWorkout]) {
        var map = Dictionary(snapshot.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var hd = snapshot.healthDays ?? [:]
        let need = sleepNeedMin
        for h in days {
            hd[h.day] = h
            var m = map[h.day] ?? DailyMetric(day: h.day)
            if let s = h.steps { m.steps = s }
            if m.restingHR == nil { m.restingHR = h.restingHR }
            if m.respiration == nil { m.respiration = h.respiration }
            if m.asleepMin == nil, let a = h.asleepMin, a > 0 {
                m.asleepMin = a; m.deepMin = h.deepMin; m.remMin = h.remMin; m.lightMin = h.coreMin; m.awakeMin = h.awakeMin
                m.inBedMin = a + (h.awakeMin ?? 0)
                m.rest = RestScorer.score(asleepMin: a, inBedMin: m.inBedMin ?? a, deepMin: h.deepMin ?? 0, remMin: h.remMin ?? 0, needMin: need)
            }
            map[h.day] = m
        }
        snapshot.days = map.values.sorted { $0.day < $1.day }
        snapshot.healthDays = hd
        let known = Set(snapshot.workouts.map(\.id))
        snapshot.workouts.append(contentsOf: workouts.filter { !known.contains($0.id) })
        snapshot.workouts.sort { $0.start > $1.start }
        recompute()
    }

    private func writeNightToHealth() {
        guard healthConnected, healthPrefs.writeSleep, let n = lastNight else { return }
        let key = "healthSleepWritten"
        guard UserDefaults.standard.double(forKey: key) != n.start else { return }
        UserDefaults.standard.set(n.start, forKey: key)
        Task { await health.save(night: n) }
    }

    // MARK: widgets
    /// Shares today's numbers with the home/lock-screen widgets and asks them to refresh.
    func syncWidgets() {
        let t = today
        let last7 = Array(days.suffix(7))
        let n = lastNight
        WidgetSnapshot(
            charge: t?.charge, effort: t?.effort, rest: t?.rest, forecast: forecast?.value, streak: streak.current,
            hrv: t?.hrv, restingHR: t?.restingHR, respiration: t?.respiration, stress: t?.stress,
            steps: t?.steps, kcal: t?.kcal,
            chargeSeries: last7.map(\.charge), effortSeries: last7.map(\.effort),
            asleepMin: n?.asleepMinutes ?? t?.asleepMin, deepMin: n?.minutes(.deep) ?? t?.deepMin, remMin: n?.minutes(.rem) ?? t?.remMin,
            lightMin: n?.minutes(.light) ?? t?.lightMin, awakeMin: n?.minutes(.awake) ?? t?.awakeMin,
            sleepNeedMin: sleepNeedMin, sleepDebtMin: sleepDebtMin,
            sleepStart: n.map { Date(timeIntervalSince1970: $0.start) }, sleepEnd: n.map { Date(timeIntervalSince1970: $0.end) },
            hydrationML: hydrationToday, hydrationGoalML: hydrationGoal,
            batteryPercent: ble.batteryPercent ?? ble.lastBattery?.percent, batteryAt: ble.lastBattery?.at,
            liveHR: ble.heartRate, liveHRAt: ble.heartRate == nil ? nil : Date(), nextAlarm: nextAlarm,
            updated: Date(), isDemo: settings.useDemoData).save()
        lastWidgetSync = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: notifications
    private func batteryUpdated(_ pct: Double) {
        syncWidgets()
        guard settings.notifications.batteryAlerts else { return }
        let alerts = BatteryNotifier.evaluate(soc: pct, charging: nil, runtimeHours: nil, state: &batteryState)
        if let d = try? JSONEncoder().encode(batteryState) { UserDefaults.standard.set(d, forKey: "batteryAlertState") }
        for a in alerts {
            switch a {
            case .critical: Notifier.post(id: "battery-critical", title: "Strap battery critical", body: String(format: "%.0f%% — charge it now, it stops recording near 10%%.", pct))
            case .low: Notifier.post(id: "battery-low", title: "Strap battery low", body: String(format: "%.0f%% left.", pct))
            case .full: Notifier.post(id: "battery-full", title: "Strap fully charged", body: "You can take it off the charger.")
            case .runtime, .bedtime: break
            }
        }
    }

    private func notifyOncePerDay(_ key: String, _ send: () -> Void) {
        let today = DayFormat.string(Date())
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)   // marked up front so it can't repeat even if delivery is declined
        send()
    }

    private func checkStrainTarget() {
        guard settings.notifications.strainTarget, let t = today, let e = t.effort,
              StrainTarget.reached(effort100: e, charge: t.charge) else { return }
        notifyOncePerDay("strainNotifiedDay") {
            Notifier.post(id: "strain-target", title: "Optimal strain reached", body: "You've reached the effort that suits today's Charge.")
        }
    }

    private func checkIllnessNotification() {
        guard settings.notifications.illness, illness?.level == .raised else { return }
        notifyOncePerDay("illnessNotifiedDay") {
            Notifier.post(id: "illness", title: "A heads-up to rest", body: "On-device estimate (approximate), not a diagnosis.")
        }
    }


    // MARK: sleep marks
    var sleepMarks: [SleepMark] { (snapshot.sleepMarks ?? []).sorted { $0.time < $1.time } }

    /// The latest bed mark and the wake mark that closed it. A wake with no bed before it is returned alone.
    var markedNight: (bed: Double?, wake: Double?) {
        let m = sleepMarks
        guard let bed = m.last(where: { $0.kind == .bed }) else { return (nil, m.last(where: { $0.kind == .wake })?.time) }
        let wake = m.first { $0.kind == .wake && $0.time > bed.time }
        return (bed.time, wake?.time)
    }
    var isMarkedAsleep: Bool { let n = markedNight; return n.bed != nil && n.wake == nil }

    func markBed(at date: Date = Date()) {
        snapshot.sleepMarks = (snapshot.sleepMarks ?? []) + [SleepMark(kind: .bed, time: date.timeIntervalSince1970)]
        save()
    }
    func markWake(at date: Date = Date()) {
        snapshot.sleepMarks = (snapshot.sleepMarks ?? []) + [SleepMark(kind: .wake, time: date.timeIntervalSince1970)]
        recompute()
    }
    func undoLastMark() {
        guard var m = snapshot.sleepMarks, !m.isEmpty else { return }
        m.removeLast(); snapshot.sleepMarks = m
        recompute()
    }

    /// Detected night, snapped to what the user told us. Re-stages inside the corrected window.
    private func effectiveNight(_ raw: RawDay) -> SleepSession? {
        let m = markedNight
        guard m.bed != nil || m.wake != nil, let first = raw.hr.first?.t, let last = raw.hr.last?.t else { return raw.sleep }
        let detected = raw.sleep.map { [(start: $0.start, end: $0.end)] } ?? []
        guard let w = SleepDetector.refine(detected: detected, bed: m.bed, wake: m.wake, dataRange: first...last).first else { return raw.sleep }
        if let s = raw.sleep, s.start == w.start, s.end == w.end { return s }
        let segs = SleepStager.stage(start: w.start, end: w.end, hr: raw.hr, gravity: raw.gravity)
        guard !segs.isEmpty else { return raw.sleep }
        let beats = raw.rr.filter { $0.t >= w.start && $0.t <= w.end }
        return SleepSession(start: w.start, end: w.end, segments: segs,
                            restingHR: SleepStager.restingHR(hr: raw.hr, start: w.start, end: w.end),
                            hrv: HRVAnalyzer.nightlyRMSSD(beats))
    }

    // MARK: alarm
    /// The next time the alarm will ring: the pending snooze if there is one, else the next scheduled wake.
    var nextAlarm: Date? {
        if let s = snoozeUntil { return s }
        let a = settings.alarm
        return a.enabled ? SmartAlarm.next(after: Date(), wakeMinute: a.wakeMinute, weekdays: a.weekdays) : nil
    }

    /// Arms the strap + phone backup for the next wake time and schedules the wind-down nudge.
    func applyAlarm() {
        defer { syncWidgets() }
        let a = settings.alarm
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-backup", "wind-down"])
        guard a.enabled || a.windDown else { ble.disarmAlarm(); return }
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            Task { @MainActor in
                if a.enabled, let d = SmartAlarm.next(after: Date(), wakeMinute: a.wakeMinute, weekdays: a.weekdays) {
                    self.scheduleAlarmNotification(id: "alarm-backup", at: d, title: "Wake up", body: "Your alarm")
                    self.ble.armAlarm(at: d)
                }
                if a.windDown {
                    let w = WindDownNudge.minuteOfDay(wakeMinute: a.wakeMinute, needMinutes: a.sleepNeedMinutes)
                    let c = UNMutableNotificationContent(); c.title = "Time to wind down"; c.body = "Dim the lights — bedtime is near."
                    var dc = DateComponents(); dc.hour = w.minute / 60; dc.minute = w.minute % 60
                    center.add(UNNotificationRequest(identifier: "wind-down", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
                }
            }
        }
    }

    private func scheduleAlarmNotification(id: String, at d: Date, title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// The strap reported the alarm went off. With snooze on, ring again `snoozeMinutes` later (up to 3 more times).
    func alarmDidFire() {
        let a = settings.alarm
        guard a.enabled, a.snooze,
              let d = SmartAlarm.snoozeInstant(firedAt: Date(), delayMinutes: a.snoozeMinutes, count: snoozeCount) else { stopSnooze(); return }
        snoozeCount += 1
        snoozeUntil = d
        scheduleAlarmNotification(id: "alarm-snooze", at: d, title: "Wake up", body: "Alarm ringing again")
        ble.armAlarm(at: d)
    }

    /// Ends the snooze chain (double-tap on the strap, opening the app, or the Stop button) and re-arms the regular alarm.
    func stopSnooze() {
        guard snoozeUntil != nil || snoozeCount > 0 else { return }
        snoozeCount = 0; snoozeUntil = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["alarm-snooze"])
        applyAlarm()
    }

    // MARK: actions
    func logHydration(_ ml: Int) {
        let log = HydrationLog(time: Date().timeIntervalSince1970, ml: ml)
        snapshot.hydration.append(log); save()
        if healthConnected, healthPrefs.writeWater { Task { await health.save(water: ml, at: Date(), id: log.id) } }
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

    func addWorkout(_ w: SavedWorkout) {
        snapshot.workouts.append(w); snapshot.workouts.sort { $0.start > $1.start }; recompute()
        if healthConnected, healthPrefs.writeWorkouts { Task { await health.save(workout: w) } }
    }

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
