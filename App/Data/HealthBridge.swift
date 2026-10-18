import Foundation
import HealthKit
import Observation
import StrandAnalytics

/// One day as Apple Health knows it (phone and/or Apple Watch). Used as a *measured-by-someone-else* source:
/// it never overwrites what this app computed from the strap, only fills gaps and feeds the comparison screen.
struct HealthDay: Codable, Equatable {
    var day: String
    var steps: Int?
    var restingHR: Double?
    var respiration: Double?
    var activeKcal: Double?
    var asleepMin: Double?
    var deepMin: Double?
    var remMin: Double?
    var coreMin: Double?
    var awakeMin: Double?
}

struct HealthPrefs: Codable, Equatable {
    var readEnabled = false
    var writeWorkouts = true
    var writeSleep = true
    var writeWater = true
    var lastImport: Date?
}

@Observable
@MainActor
final class HealthBridge {
    private let store = HKHealthStore()
    let isAvailable = HKHealthStore.isHealthDataAvailable()
    var lastError: String?

    private static var steps: HKQuantityType { HKQuantityType(.stepCount) }
    private static var rhr: HKQuantityType { HKQuantityType(.restingHeartRate) }
    private static var resp: HKQuantityType { HKQuantityType(.respiratoryRate) }
    private static var energy: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private static var hr: HKQuantityType { HKQuantityType(.heartRate) }
    private static var water: HKQuantityType { HKQuantityType(.dietaryWater) }
    private static var sleep: HKCategoryType { HKCategoryType(.sleepAnalysis) }

    private var readTypes: Set<HKObjectType> { [Self.steps, Self.rhr, Self.resp, Self.energy, Self.sleep, HKObjectType.workoutType()] }
    private var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), Self.hr, Self.energy, Self.sleep, Self.water] }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { lastError = "Health data isn't available on this device."; return false }
        do { try await store.requestAuthorization(toShare: shareTypes, read: readTypes); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - import

    func importDays(_ n: Int) async -> (days: [HealthDay], workouts: [SavedWorkout]) {
        guard isAvailable else { return ([], []) }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: end))!
        async let st = dailyStats(Self.steps, unit: .count(), option: .cumulativeSum, from: start, to: end)
        async let en = dailyStats(Self.energy, unit: .kilocalorie(), option: .cumulativeSum, from: start, to: end)
        async let rh = dailyStats(Self.rhr, unit: HKUnit.count().unitDivided(by: .minute()), option: .discreteAverage, from: start, to: end)
        async let rs = dailyStats(Self.resp, unit: HKUnit.count().unitDivided(by: .minute()), option: .discreteAverage, from: start, to: end)
        async let sl = sleepByDay(from: start, to: end)
        async let wk = workouts(from: start, to: end)
        let (steps, energy, rhr, resp, sleep, workouts) = await (st, en, rh, rs, sl, wk)

        var out: [String: HealthDay] = [:]
        func day(_ k: String) -> HealthDay { out[k] ?? HealthDay(day: k) }
        for (k, v) in steps { var d = day(k); d.steps = Int(v); out[k] = d }
        for (k, v) in energy { var d = day(k); d.activeKcal = v; out[k] = d }
        for (k, v) in rhr { var d = day(k); d.restingHR = v; out[k] = d }
        for (k, v) in resp { var d = day(k); d.respiration = v; out[k] = d }
        for (k, v) in sleep { var d = day(k); d.asleepMin = v.asleep; d.deepMin = v.deep; d.remMin = v.rem; d.coreMin = v.core; d.awakeMin = v.awake; out[k] = d }
        return (out.values.sorted { $0.day < $1.day }, workouts)
    }

    private func dailyStats(_ type: HKQuantityType, unit: HKUnit, option: HKStatisticsOptions, from: Date, to: Date) async -> [String: Double] {
        await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                                options: option, anchorDate: Calendar.current.startOfDay(for: from), intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                var map: [String: Double] = [:]
                results?.enumerateStatistics(from: from, to: to) { s, _ in
                    let v = option == .cumulativeSum ? s.sumQuantity()?.doubleValue(for: unit) : s.averageQuantity()?.doubleValue(for: unit)
                    if let v, v > 0 { map[DayFormat.string(s.startDate)] = v }
                }
                cont.resume(returning: map)
            }
            store.execute(q)
        }
    }

    private struct SleepTotals { var asleep = 0.0, deep = 0.0, rem = 0.0, core = 0.0, awake = 0.0 }

    /// Sleep samples grouped by the day you woke up. Our own writes are skipped so they aren't counted twice.
    private func sleepByDay(from: Date, to: Date) async -> [String: SleepTotals] {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: Self.sleep, predicate: HKQuery.predicateForSamples(withStart: from, end: to), limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
                var map: [String: SleepTotals] = [:]
                for case let s as HKCategorySample in samples ?? [] {
                    if s.sourceRevision.source.bundleIdentifier.hasPrefix("com.octa.personalwhoop") { continue }
                    let minutes = s.endDate.timeIntervalSince(s.startDate) / 60
                    let key = DayFormat.string(s.endDate)
                    var t = map[key] ?? SleepTotals()
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .asleepDeep: t.deep += minutes; t.asleep += minutes
                    case .asleepREM: t.rem += minutes; t.asleep += minutes
                    case .asleepCore: t.core += minutes; t.asleep += minutes
                    case .asleepUnspecified: t.core += minutes; t.asleep += minutes
                    case .awake: t.awake += minutes
                    default: break
                    }
                    map[key] = t
                }
                cont.resume(returning: map)
            }
            store.execute(q)
        }
    }

    private func workouts(from: Date, to: Date) async -> [SavedWorkout] {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: HKQuery.predicateForSamples(withStart: from, end: to), limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, _ in
                let list: [SavedWorkout] = (samples as? [HKWorkout] ?? []).compactMap { w in
                    if w.sourceRevision.source.bundleIdentifier.hasPrefix("com.octa.personalwhoop") { return nil }
                    let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
                    let avg = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    let peak = w.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    var sw = SavedWorkout(sport: Self.name(for: w.workoutActivityType), start: w.startDate.timeIntervalSince1970, end: w.endDate.timeIntervalSince1970,
                                          avgHR: avg, peakHR: peak, kcal: kcal, effort: nil, distanceM: w.totalDistance?.doubleValue(for: .meter()), source: "Apple Health")
                    sw.id = w.uuid
                    return sw
                }
                cont.resume(returning: list)
            }
            store.execute(q)
        }
    }

    // MARK: - write

    func save(workout w: SavedWorkout) async {
        guard isAvailable, w.source != "Apple Health" else { return }
        let cfg = HKWorkoutConfiguration(); cfg.activityType = Self.type(for: w.sport)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: cfg, device: .local())
        let start = Date(timeIntervalSince1970: w.start), end = Date(timeIntervalSince1970: w.end)
        do {
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = []
            let bpm = HKUnit.count().unitDivided(by: .minute())
            for (i, v) in (w.hrSeries ?? []).enumerated() {
                let t = start.addingTimeInterval(Double(i) * 5)
                if t < end { samples.append(HKQuantitySample(type: Self.hr, quantity: HKQuantity(unit: bpm, doubleValue: v), start: t, end: t.addingTimeInterval(5))) }
            }
            if let k = w.kcal, k > 0 { samples.append(HKQuantitySample(type: Self.energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: k), start: start, end: end)) }
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.addMetadata([HKMetadataKeySyncIdentifier: "personalwhoop.workout.\(w.id.uuidString)", HKMetadataKeySyncVersion: 1])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch { lastError = error.localizedDescription }
    }

    func save(night: SleepSession) async {
        guard isAvailable, !night.segments.isEmpty else { return }
        let samples: [HKCategorySample] = night.segments.enumerated().map { i, s in
            let value: HKCategoryValueSleepAnalysis = { switch s.stage { case .deep: return .asleepDeep; case .rem: return .asleepREM; case .light: return .asleepCore; case .awake: return .awake } }()
            return HKCategorySample(type: Self.sleep, value: value.rawValue, start: Date(timeIntervalSince1970: s.start), end: Date(timeIntervalSince1970: s.end),
                                    metadata: [HKMetadataKeySyncIdentifier: "personalwhoop.sleep.\(Int(night.start)).\(i)", HKMetadataKeySyncVersion: 1])
        }
        do { try await store.save(samples) } catch { lastError = error.localizedDescription }
    }

    func save(water ml: Int, at date: Date, id: UUID) async {
        guard isAvailable else { return }
        let s = HKQuantitySample(type: Self.water, quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: Double(ml)), start: date, end: date,
                                 metadata: [HKMetadataKeySyncIdentifier: "personalwhoop.water.\(id.uuidString)", HKMetadataKeySyncVersion: 1])
        do { try await store.save(s) } catch { lastError = error.localizedDescription }
    }

    // MARK: - sport mapping

    static func type(for sport: String) -> HKWorkoutActivityType {
        switch sport.lowercased() {
        case "run": return .running; case "walk": return .walking; case "cycle": return .cycling
        case "strength": return .traditionalStrengthTraining; case "hiit": return .highIntensityIntervalTraining
        case "swim": return .swimming; case "yoga": return .yoga; case "ski": return .downhillSkiing
        default: return .other
        }
    }

    static func name(for t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "Run"; case .walking: return "Walk"; case .cycling: return "Cycle"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"; case .swimming: return "Swim"; case .yoga: return "Yoga"
        case .downhillSkiing: return "Ski"; case .hiking: return "Walk"
        default: return "Other"
        }
    }
}
