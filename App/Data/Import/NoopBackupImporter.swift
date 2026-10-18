import Foundation
import CryptoKit
import StrandAnalytics

struct BackupProfile {
    var age: Double?, heightCm: Double?, weightKg: Double?, hrMax: Double?
    var isEmpty: Bool { age == nil && heightCm == nil && weightKg == nil && hrMax == nil }
}

struct NoopImportResult {
    var days: [DailyMetric] = []           // computed from the strap (WHOOP / NOOP) — these win
    var nights: [SleepSession] = []
    var workouts: [SavedWorkout] = []
    var healthDays: [HealthDay] = []       // Apple Health history carried in the backup — fills gaps only
    var profile: BackupProfile?
    var strapDevices: [String] = []

    var summaryLines: [String] {
        var l: [String] = []
        l.append("\(days.count) days of strap scores")
        if !nights.isEmpty { l.append("\(nights.count) nights with sleep stages") }
        if !workouts.isEmpty { l.append("\(workouts.count) workouts") }
        if !healthDays.isEmpty { l.append("\(healthDays.count) days of Apple Health history") }
        return l
    }
}

enum NoopImportError: LocalizedError {
    case notABackup
    var errorDescription: String? { "This doesn't look like a NOOP backup (.noopbak)." }
}

/// Reads a `.noopbak` (ZIP with `noop-backup.sqlite`, `settings.json`, `manifest.json`) into plain values.
enum NoopBackupImporter {
    static let historyDays = 365

    static func read(url: URL, progress: @escaping @Sendable (String) -> Void) throws -> NoopImportResult {
        let zip = try ZipArchive(url: url)
        guard zip.entries["noop-backup.sqlite"] != nil else { throw NoopImportError.notABackup }

        var result = NoopImportResult()
        if let d = try? zip.data(for: "settings.json"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let p = BackupProfile(age: (j["profile.age"] as? NSNumber)?.doubleValue, heightCm: (j["profile.heightCm"] as? NSNumber)?.doubleValue,
                                  weightKg: (j["profile.weightKg"] as? NSNumber)?.doubleValue, hrMax: (j["profile.hrMax"] as? NSNumber)?.doubleValue)
            if !p.isEmpty { result.profile = p }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("noopimport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("noop-backup.sqlite")
        var lastPct = -1
        try zip.extract("noop-backup.sqlite", to: dbURL) { p in
            let pct = Int(p * 100); if pct != lastPct { lastPct = pct; progress("Unpacking backup… \(pct)%") }
        }

        progress("Reading…")
        let db = try SQLiteDB(path: dbURL.path)
        guard try db.tableExists("dailyMetric") else { throw NoopImportError.notABackup }

        // --- strap-derived days ---
        var days: [String: DailyMetric] = [:]
        var devices = Set<String>()
        try db.query("""
            select day, totalSleepMin, efficiency, deepMin, remMin, lightMin, restingHr, avgHrv, recovery, strain, respRateBpm,
                   skinTempDevC, spo2Pct, steps, activeKcalEst, exerciseCount, deviceId
            from dailyMetric where deviceId != 'apple-health' order by day, deviceId
            """) { r in
            guard let day = r.text(0) else { return }
            devices.insert(r.text(16) ?? "")
            var m = days[day] ?? DailyMetric(day: day)
            if let v = r.double(1) { m.asleepMin = v }
            if let v = r.double(3) { m.deepMin = v }
            if let v = r.double(4) { m.remMin = v }
            if let v = r.double(5) { m.lightMin = v }
            if let eff = r.double(2), eff > 0, let a = m.asleepMin { m.inBedMin = a / eff; m.awakeMin = max(0, a / eff - a) }
            if let v = r.double(6) { m.restingHR = v }
            if let v = r.double(7) { m.hrv = v }
            if let v = r.double(8) { m.charge = v }
            if let v = r.double(9) { m.effort = v }
            if let v = r.double(10) { m.respiration = v }
            if let v = r.double(11) { m.skinTempDev = v }
            if let v = r.double(12) { m.spo2 = v }
            if let v = r.int(13) { m.steps = v }
            if let v = r.double(14) { m.kcal = v }
            if let v = r.int(15) { m.workouts = v }
            days[day] = m
        }
        try db.query("select day, key, value from metricSeries where deviceId != 'apple-health' and key in ('sleep_performance','steps_est')") { r in
            guard let day = r.text(0), let key = r.text(1), let v = r.double(2), var m = days[day] else { return }
            if key == "sleep_performance" { m.rest = v } else if key == "steps_est", m.steps == nil { m.steps = Int(v) }
            days[day] = m
        }
        result.days = days.values.filter { $0.hrv != nil || $0.restingHR != nil || $0.asleepMin != nil || $0.charge != nil || $0.effort != nil }
            .map { m in
                var m = m
                if m.rest == nil, let a = m.asleepMin, let b = m.inBedMin {
                    m.rest = RestScorer.score(asleepMin: a, inBedMin: b, deepMin: m.deepMin ?? 0, remMin: m.remMin ?? 0, needMin: 480)
                }
                return m
            }.sorted { $0.day < $1.day }
        result.strapDevices = devices.sorted()

        // --- sleep nights ---
        if try db.tableExists("sleepSession") {
            try db.query("select startTs, endTs, restingHr, avgHrv, stagesJSON from sleepSession where deviceId != 'apple-health' order by startTs") { r in
                guard let s = r.int(0), let e = r.int(1), e > s, let json = r.text(4), let data = json.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
                let segs: [SleepSegment] = arr.compactMap { o in
                    guard let st = (o["start"] as? NSNumber)?.doubleValue, let en = (o["end"] as? NSNumber)?.doubleValue, let name = o["stage"] as? String else { return nil }
                    let stage: SleepStage? = { switch name { case "wake", "awake": return .awake; case "light", "core": return .light; case "rem": return .rem; case "deep": return .deep; default: return nil } }()
                    return stage.map { SleepSegment(start: st, end: en, stage: $0) }
                }
                guard !segs.isEmpty else { return }
                result.nights.append(SleepSession(start: Double(s), end: Double(e), segments: segs, restingHR: r.double(2), hrv: r.double(3)))
            }
        }

        // --- workouts (last year) ---
        let cutoffTs = Int(Date().addingTimeInterval(-Double(historyDays) * 86400).timeIntervalSince1970)
        if try db.tableExists("workout") {
            try db.query("select deviceId, startTs, endTs, sport, durationS, energyKcal, avgHr, maxHr, strain, distanceM from workout where startTs >= \(cutoffTs) order by startTs desc") { r in
                guard let dev = r.text(0), let s = r.int(1), let e = r.int(2), let sport = r.text(3) else { return }
                var w = SavedWorkout(sport: sportName(sport), start: Double(s), end: Double(e), avgHR: r.double(6), peakHR: r.double(7), kcal: r.double(5),
                                     effort: r.double(8), distanceM: r.double(9), source: dev == "apple-health" ? "Apple Health (backup)" : "NOOP backup")
                w.id = stableID("\(dev)|\(s)|\(sport)")
                result.workouts.append(w)
            }
        }

        // --- Apple Health history in the backup (gap filler) ---
        let cutoffDay = DayFormat.string(Date().addingTimeInterval(-Double(historyDays) * 86400))
        var health: [String: HealthDay] = [:]
        func hd(_ day: String) -> HealthDay { health[day] ?? HealthDay(day: day) }
        if try db.tableExists("metricSeries") {
            try db.query("select day, key, value from metricSeries where deviceId = 'apple-health' and day >= ? and key in ('steps','resting_hr','resp_rate','active_kcal','asleep_min','deep_min','rem_min','core_min','awake_min')", [cutoffDay]) { r in
                guard let day = r.text(0), let key = r.text(1), let v = r.double(2) else { return }
                var h = hd(day)
                switch key {
                case "steps": h.steps = Int(v); case "resting_hr": h.restingHR = v; case "resp_rate": h.respiration = v; case "active_kcal": h.activeKcal = v
                case "asleep_min": h.asleepMin = v; case "deep_min": h.deepMin = v; case "rem_min": h.remMin = v; case "core_min": h.coreMin = v; case "awake_min": h.awakeMin = v
                default: break
                }
                health[day] = h
            }
        }
        result.healthDays = health.values.sorted { $0.day < $1.day }
        return result
    }

    static func stableID(_ s: String) -> UUID {
        let h = SHA256.hash(data: Data(s.utf8)); let b = Array(h.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// "TraditionalStrengthTraining" → Strength, unknown CamelCase → "Camel Case".
    static func sportName(_ raw: String) -> String {
        switch raw {
        case "Running": return "Run"
        case "Walking", "Hiking": return "Walk"
        case "Cycling": return "Cycle"
        case "TraditionalStrengthTraining", "FunctionalStrengthTraining": return "Strength"
        case "HighIntensityIntervalTraining": return "HIIT"
        case "Swimming": return "Swim"
        case "Yoga": return "Yoga"
        default:
            var out = ""
            for ch in raw { if ch.isUppercase, !out.isEmpty { out.append(" ") }; out.append(ch) }
            return out
        }
    }
}
