import SwiftUI

/// What the app shares with its widgets (via the App Group). Plain values only, so the widget needs no analytics code.
/// Every field is optional or defaulted so an older saved snapshot still decodes after an update.
struct WidgetSnapshot: Codable, Equatable {
    // scores
    var charge: Double?
    var effort: Double?
    var rest: Double?
    var forecast: Double?
    var streak: Int?
    // vitals
    var hrv: Double?
    var restingHR: Double?
    var respiration: Double?
    var stress: Double?          // 0–3
    var steps: Int?
    var kcal: Double?
    // last 7 days, oldest first
    var chargeSeries: [Double?]?
    var effortSeries: [Double?]?
    // sleep
    var asleepMin: Double?
    var deepMin: Double?
    var remMin: Double?
    var lightMin: Double?
    var awakeMin: Double?
    var sleepNeedMin: Double?
    var sleepDebtMin: Double?
    var sleepStart: Date?
    var sleepEnd: Date?
    // water
    var hydrationML: Int?
    var hydrationGoalML: Int?
    // strap
    var batteryPercent: Double?
    var batteryAt: Date?
    var liveHR: Int?
    var liveHRAt: Date?
    var nextAlarm: Date?
    // meta
    var updated: Date
    var isDemo: Bool

    static let groupID = "group.com.octa.personalwhoop"
    private static let key = "widgetSnapshot"

    static var empty: WidgetSnapshot { WidgetSnapshot(updated: Date(), isDemo: false) }

    static var sample: WidgetSnapshot {
        WidgetSnapshot(charge: 89, effort: 54, rest: 80, forecast: 56, streak: 56,
                       hrv: 68, restingHR: 48, respiration: 14.7, stress: 1.4, steps: 8420, kcal: 2310,
                       chargeSeries: [62, 48, 71, 55, 83, 67, 89], effortSeries: [40, 66, 35, 72, 28, 55, 54],
                       asleepMin: 459, deepMin: 74, remMin: 122, lightMin: 263, awakeMin: 18, sleepNeedMin: 480, sleepDebtMin: 48,
                       sleepStart: Calendar.current.date(bySettingHour: 22, minute: 55, second: 0, of: Date().addingTimeInterval(-86400)),
                       sleepEnd: Calendar.current.date(bySettingHour: 6, minute: 44, second: 0, of: Date()),
                       hydrationML: 1650, hydrationGoalML: 3600,
                       batteryPercent: 62, batteryAt: Date().addingTimeInterval(-600), liveHR: 71, liveHRAt: Date().addingTimeInterval(-30),
                       nextAlarm: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date().addingTimeInterval(86400)),
                       updated: Date(), isDemo: true)
    }

    static func load() -> WidgetSnapshot? {
        guard let d = UserDefaults(suiteName: groupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.groupID)?.set(d, forKey: Self.key)
    }
}

/// Colours used by the widgets (same soft palette as the app).
enum WTheme {
    static let ink = Color(red: 0.17, green: 0.20, blue: 0.30)
    static let mint = [Color(red: 0.38, green: 0.78, blue: 0.60), Color(red: 0.20, green: 0.60, blue: 0.46)]
    static let sky = [Color(red: 0.45, green: 0.66, blue: 0.96), Color(red: 0.25, green: 0.45, blue: 0.86)]
    static let lavender = [Color(red: 0.66, green: 0.54, blue: 0.94), Color(red: 0.46, green: 0.32, blue: 0.82)]
    static let indigo = [Color(red: 0.10, green: 0.13, blue: 0.32), Color(red: 0.30, green: 0.22, blue: 0.58)]
    static let sage = Color(red: 0.42, green: 0.70, blue: 0.58)
    static let butter = Color(red: 0.96, green: 0.76, blue: 0.32)
    static let clay = Color(red: 0.90, green: 0.55, blue: 0.45)
    static let teal = Color(red: 0.12, green: 0.58, blue: 0.62)
    static let rose = Color(red: 0.84, green: 0.30, blue: 0.42)
    static let blue = Color(red: 0.25, green: 0.45, blue: 0.88)
    // sleep stages
    static let awake = Color(red: 0.98, green: 0.66, blue: 0.48)
    static let rem = Color(red: 0.80, green: 0.60, blue: 0.98)
    static let light = Color(red: 0.45, green: 0.72, blue: 0.98)
    static let deep = Color(red: 0.42, green: 0.45, blue: 0.92)

    static func battery(_ p: Double?) -> Color { guard let p else { return .secondary }; return p <= 15 ? clay : (p <= 30 ? butter : sage) }
    static func batterySymbol(_ p: Double?) -> String {
        guard let p else { return "battery.0percent" }
        return p > 87 ? "battery.100percent" : (p > 62 ? "battery.75percent" : (p > 37 ? "battery.50percent" : (p > 12 ? "battery.25percent" : "battery.0percent")))
    }
    static func band(_ c: Double?) -> String { guard let c else { return "Calibrating" }; return c >= 67 ? "Primed" : (c >= 34 ? "Steady" : "Take it easy") }
}
