import Foundation
import ServiceManagement
import os

/// Launch-at-login via SMAppService (macOS 13+). Only meaningful when running
/// from the .app bundle.
enum LoginItem {
    private static let log = Logger(subsystem: kSubsystem, category: "login")

    static var isSupported: Bool { isBundledApp }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func toggle() throws {
        guard isSupported else { return }
        if isEnabled {
            try SMAppService.mainApp.unregister()
            log.notice("launch at login disabled")
        } else {
            try SMAppService.mainApp.register()
            log.notice("launch at login enabled")
        }
    }
}
