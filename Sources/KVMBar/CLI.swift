import AppKit
import Foundation
import os

/// CLI entry point (`KVMBar --give-away` etc., for Raycast script commands).
/// If the menu bar app is running, the command is forwarded to it via
/// DistributedNotificationCenter so its state/icon stay in sync; otherwise the
/// action executes directly in this process.
enum CLI {
    private static let log = Logger(subsystem: kSubsystem, category: "cli")

    static let usage = """
    KVMBar — Dell U2725QE KVM helper

    Usage:
      KVMBar                        run the menu bar app
      KVMBar --status               print current status (read-only)
      KVMBar --switch-input <v>     DDC-switch monitor input
                                    <v> = DDC code (17, 27, …), a configured
                                    input name, "mine" or "other"
                                    switching to the other input runs the full
                                    give-away (see giveAwayOnSwitchToOther)
      KVMBar --give-away            switch to the other input, then soft-disconnect
      KVMBar --disconnect           soft-disconnect the external display
      KVMBar --reconnect            re-enable the display / force a video refresh
      KVMBar --help                 show this help
    """

    static func run(arguments: [String]) -> Never {
        switch arguments.first {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--status":
            printStatus()
            exit(0)
        case "--switch-input":
            guard arguments.count >= 2, let code = resolveInputCode(arguments[1]) else {
                fputs("error: --switch-input needs a DDC code or input name\n\n\(usage)\n", stderr)
                exit(2)
            }
            dispatch(action: "switch-input", value: String(code))
        case "--give-away":
            dispatch(action: "give-away")
        case "--disconnect":
            dispatch(action: "disconnect")
        case "--reconnect":
            dispatch(action: "reconnect")
        default:
            fputs("error: unknown arguments: \(arguments.joined(separator: " "))\n\n\(usage)\n", stderr)
            exit(2)
        }
    }

    static func resolveInputCode(_ raw: String) -> UInt16? {
        if let code = UInt16(raw) { return code }
        let s = Settings.shared
        switch raw.lowercased() {
        case s.myInputName.lowercased(), "mine", "my":
            return UInt16(clamping: s.myInputCode)
        case s.otherInputName.lowercased(), "other":
            return UInt16(clamping: s.otherInputCode)
        default:
            return nil
        }
    }

    private static func dispatch(action: String, value: String? = nil) -> Never {
        if let running = runningAppInstance() {
            var userInfo: [String: String] = ["action": action]
            if let value { userInfo["value"] = value }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(kCommandNotification),
                object: nil, userInfo: userInfo, deliverImmediately: true)
            log.notice("forwarded \(action, privacy: .public) to running instance pid \(running.processIdentifier)")
            print("Sent \(action) to the running KVMBar instance.")
            Thread.sleep(forTimeInterval: 0.2)
            exit(0)
        }
        log.notice("executing \(action, privacy: .public) directly (no running instance)")
        let ok = perform(action: action, value: value)
        print(ok ? "OK: \(action)" : "FAILED: \(action) (see log: log show --predicate 'subsystem == \"\(kSubsystem)\"' --last 2m)")
        exit(ok ? 0 : 1)
    }

    private static func runningAppInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID)
            .first { $0.processIdentifier != getpid() }
    }

    /// Shared by the direct CLI path and the app's command listener.
    @discardableResult
    static func perform(action: String, value: String?) -> Bool {
        let manager = DisplayManager.shared
        switch action {
        case "switch-input":
            guard let value, let code = UInt16(value) else { return false }
            return manager.switchInput(code: code)
        case "give-away":
            return manager.giveAway()
        case "disconnect":
            return manager.softDisconnect()
        case "reconnect":
            return manager.reconnect()
        default:
            log.error("unknown command: \(action, privacy: .public)")
            return false
        }
    }

    // MARK: - Status

    static func printStatus() {
        let s = Settings.shared
        let m = DisplayManager.shared

        print("KVMBar status")
        print("  SkyLight (soft disconnect): " +
              (SkyLight.shared.available ? "available"
               : "UNAVAILABLE — \(SkyLight.shared.unavailableReason ?? "?")"))
        print("  IOAVService (DDC):          " +
              (DDC.shared.symbolsAvailable ? "symbols resolved"
               : "UNAVAILABLE — \(DDC.shared.unavailableReason ?? "?")"))
        print("  External DDC service:       " +
              (DDC.shared.externalServicePresent() ? "present" : "not found"))

        let online = m.onlineIDs()
        let active = Set(m.activeIDs())
        if online.isEmpty {
            print("  Displays: none online")
        } else {
            print("  Displays:")
            for id in online {
                let builtin = CGDisplayIsBuiltin(id) != 0
                let name = DisplayManager.name(for: id) ?? "?"
                print("    id \(id)  \(name)  \(builtin ? "built-in" : "external")  \(active.contains(id) ? "active" : "online, inactive")")
            }
        }
        print("  Persisted external display: " +
              (s.lastDisplayID != 0 ? "id \(s.lastDisplayID) (\(s.lastDisplayName ?? "?"))" : "none"))
        if s.usbKVMDetection {
            let present = DisplayWatcher.usbKVMDevicePresent()
            print("  KVM USB device (\(String(format: "0x%04X:0x%04X", s.kvmUSBVendorID, s.kvmUSBProductID))): \(present ? "present — monitor is ours" : "absent — monitor is on the other computer")")
        }
        print("  State: \(m.state.rawValue)\(m.isParked ? " (parked as mirror)" : "")   Auto mode: \(s.autoMode ? "on" : "off")")
        print("  Inputs: mine = \(s.myInputName) (\(s.myInputCode)), other = \(s.otherInputName) (\(s.otherInputCode))")

        if DDC.shared.symbolsAvailable {
            if let reply = DDC.shared.readVCP(kVCPInputSelect) {
                print("  Monitor input (VCP 0x60): current = \(reply.inputCode) (raw 0x\(String(reply.current, radix: 16)))")
            } else {
                print("  Monitor input (VCP 0x60): no reply (normal when the monitor is on another input, or DDC blocked on this connection)")
            }
        }
    }
}

/// App-side listener for CLI-forwarded commands.
enum CommandListener {
    private static let log = Logger(subsystem: kSubsystem, category: "cli")

    static func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kCommandNotification),
            object: nil, queue: nil
        ) { note in
            guard let info = note.userInfo, let action = info["action"] as? String else { return }
            let value = info["value"] as? String
            log.notice("received command: \(action, privacy: .public)")
            DisplayManager.shared.async {
                CLI.perform(action: action, value: value)
            }
        }
    }
}
