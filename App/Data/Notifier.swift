import Foundation
import UserNotifications

/// Local notifications. Each alert type asks for permission when its toggle is turned on and only *checks*
/// status when it fires, so a declined permission never blocks the app.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String, silent: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body
            if !silent { c.sound = .default }
            // a stable id means a repeat replaces the previous notification instead of stacking
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }

    /// Shows banners while the app is open too.
    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
    }
}
