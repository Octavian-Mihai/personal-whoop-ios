import SwiftUI

/// What the app shares with its widgets (via the App Group). Plain values only, so the widget needs no analytics code.
struct WidgetSnapshot: Codable, Equatable {
    var charge: Double?
    var effort: Double?
    var rest: Double?
    var hrv: Double?
    var restingHR: Double?
    var batteryPercent: Double?
    var batteryAt: Date?
    var nextAlarm: Date?
    var updated: Date
    var isDemo: Bool

    static let groupID = "group.com.octa.personalwhoop"
    private static let key = "widgetSnapshot"

    static var sample: WidgetSnapshot {
        WidgetSnapshot(charge: 89, effort: 54, rest: 80, hrv: 68, restingHR: 48, batteryPercent: 62,
                       batteryAt: Date().addingTimeInterval(-600), nextAlarm: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date().addingTimeInterval(86400)),
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
    static let sage = Color(red: 0.42, green: 0.70, blue: 0.58)
    static let butter = Color(red: 0.96, green: 0.76, blue: 0.32)
    static let clay = Color(red: 0.90, green: 0.55, blue: 0.45)
    static func battery(_ p: Double?) -> Color { guard let p else { return .secondary }; return p <= 15 ? clay : (p <= 30 ? butter : sage) }
    static func batterySymbol(_ p: Double?) -> String {
        guard let p else { return "battery.0percent" }
        return p > 87 ? "battery.100percent" : (p > 62 ? "battery.75percent" : (p > 37 ? "battery.50percent" : (p > 12 ? "battery.25percent" : "battery.0percent")))
    }
}
