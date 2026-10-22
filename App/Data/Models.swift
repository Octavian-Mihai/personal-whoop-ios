import Foundation
import StrandAnalytics

struct DailyMetric: Codable, Identifiable, Equatable {
    var id: String { day }
    var day: String                 // yyyy-MM-dd
    var hrv: Double?
    var restingHR: Double?
    var respiration: Double?
    var skinTempDev: Double?
    var asleepMin: Double?
    var inBedMin: Double?
    var deepMin: Double?
    var remMin: Double?
    var lightMin: Double?
    var awakeMin: Double?
    var rest: Double?
    var charge: Double?
    var effort: Double?
    var stress: Double?
    var steps: Int?
    var kcal: Double?
    var spo2: Double?
    var workouts: Int = 0

    var date: Date { DayFormat.parse(day) ?? .distantPast }
}

enum DayFormat {
    static let f: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = Calendar(identifier: .gregorian); return f
    }()
    static func string(_ d: Date) -> String { f.string(from: d) }
    static func parse(_ s: String) -> Date? { f.date(from: s) }
}

struct HydrationLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var ml: Int
}

struct AlarmSettings: Codable, Equatable {
    var enabled = false
    var wakeMinute = 7 * 60
    var weekdays: Set<Int> = []          // empty = every day
    var dayMinutes: [Int: Int]? = nil    // weekday (1=Sun…7) → wake minute, overriding wakeMinute
    var snooze = true
    var snoozeMinutes = 4
    var windDown = false
    var sleepNeedMinutes = 480
}

struct NotificationSettings: Codable, Equatable {
    var batteryAlerts = true
    var strainTarget = false
    var illness = false
    var buzzExplain = false
}

struct AppSettings: Codable, Equatable {
    var profile = Profile()
    var alarm = AlarmSettings()
    var notifications = NotificationSettings()
    var effortOn21Scale = false
    var illnessWatch = true
    var zoneCoach = false
    var sedentaryReminder = false
    var stressNudge = false
    var cycleAwareness = false
    var useDemoData = true
}

struct Lap: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var avgHR: Double
    var peakHR: Double
    var restHR: Double?        // HR ~60 s after a strength set
}

struct SavedWorkout: Codable, Identifiable, Equatable {
    var laps: [Lap]? = nil
    var zoneSeconds: [Int: Double]? = nil
    var hrSeries: [Double]? = nil      // one reading per 5 s
    var id = UUID()
    var sport: String
    var start: Double
    var end: Double
    var avgHR: Double?
    var peakHR: Double?
    var kcal: Double?
    var effort: Double?
    var distanceM: Double?
    var source: String            // "detected", "manual", "live"
    var typeGuess: String?
}

/// "Going to bed" / "I woke up" taps, used to anchor sleep detection.
struct SleepMark: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case bed, wake }
    var id = UUID()
    var kind: Kind
    var time: Double
}

struct Snapshot: Codable {
    var settings = AppSettings()
    var days: [DailyMetric] = []
    var ui: UISettings?
    var dismissedSuggestions: [Double]?
    var sleepMarks: [SleepMark]?
    /// nil on a fresh install: the first-run screen asks whether to use demo data or a real strap.
    var onboarded: Bool?
    var healthPrefs: HealthPrefs?
    var healthDays: [String: HealthDay]?
    var importedNights: [SleepSession]?
    var hydration: [HydrationLog] = []
    var workouts: [SavedWorkout] = []
    var liveHR: [HRSample] = []
    var periodStarts: [String] = []
}

enum TodayCard: String, CaseIterable, Codable, Identifiable {
    case workoutSuggestion, scores, drivers, live, forecast, stress, hydration, readiness, illness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workoutSuggestion: return "Workout suggestion"
        case .scores: return "Charge · Effort · Rest"
        case .drivers: return "Charge drivers"
        case .live: return "Live heart rate"
        case .forecast: return "Tomorrow's Charge"
        case .stress: return "Stress today"
        case .hydration: return "Hydration"
        case .readiness: return "Readiness signals"
        case .illness: return "Illness heads-up"
        }
    }
}

enum AppTab: String, CaseIterable, Codable, Identifiable {
    case sleep, trends, workouts
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum DriverDisplay: String, CaseIterable, Codable, Identifiable {
    case both = "Value + change", value = "Real value", change = "Change only"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case system = "Automatic", light = "Light", dark = "Dark", schedule = "By time of day"
    var id: String { rawValue }
}

/// Personalisation. Stored as an optional on Snapshot so older saves still decode.
struct UISettings: Codable, Equatable {
    var appearance: AppearanceMode? = nil          // nil = Automatic (follow iPhone)
    var lightFromMinute: Int? = nil                // "By time of day": light from this minute…
    var lightToMinute: Int? = nil                  // …until this one, dark otherwise (defaults 07:00–20:00)
    var hiddenCards: Set<String> = []
    var hiddenTabs: Set<String> = []
    var hiddenMore: Set<String> = []
    var driverDisplay: DriverDisplay = .both
}
