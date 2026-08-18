import Foundation
import UserNotifications
import os

/// Optional macOS notifications for auto-mode actions. UNUserNotificationCenter
/// crashes in a bare (non-bundled) executable, so everything is guarded.
enum UserNotifier {
    private static let log = Logger(subsystem: kSubsystem, category: "notify")

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard available, Settings.shared.notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                log.error("notification authorization error: \(error.localizedDescription, privacy: .public)")
            } else {
                log.debug("notification authorization granted: \(granted)")
            }
        }
    }

    static func post(_ title: String, _ body: String) {
        guard available, Settings.shared.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
