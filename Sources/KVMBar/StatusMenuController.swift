import AppKit
import os

/// Menu bar icon + menu. The icon reflects state at a glance; the menu is
/// rebuilt each time it opens so labels and checkmarks are always current.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: kSubsystem, category: "menu")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        stateChanged(DisplayManager.shared.state)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func stateChanged(_ state: KVMState) {
        // Fallback chains: a missing SF Symbol name must never leave the
        // status item blank ("display.slash" e.g. does not exist).
        let candidates: [String]
        switch state {
        case .activeHere:
            candidates = ["display"]
        case .transitioning:
            candidates = ["arrow.triangle.2.circlepath", "arrow.2.circlepath", "display"]
        default:
            candidates = ["tv.slash", "rectangle.on.rectangle.slash", "xmark.rectangle", "display"]
        }
        var image: NSImage?
        for name in candidates {
            if let resolved = NSImage(systemSymbolName: name,
                                      accessibilityDescription: "KVMBar: \(state.menuDescription)") {
                image = resolved
                break
            }
        }
        if let image {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            log.error("no SF Symbol resolved for state \(state.rawValue, privacy: .public) — using text fallback")
            statusItem.button?.image = nil
            statusItem.button?.title = "KVM"
        }
        statusItem.button?.toolTip = "KVMBar — \(state.menuDescription)"
    }

    private func rebuild() {
        menu.removeAllItems()
        let settings = Settings.shared
        let state = DisplayManager.shared.state
        let displayName = settings.lastDisplayName ?? "External display"

        addInfoItem("\(displayName): \(state.menuDescription)")
        if !SkyLight.shared.available {
            addInfoItem("⚠️ Soft disconnect unavailable — \(SkyLight.shared.unavailableReason ?? "SkyLight API missing")")
        }
        if !DDC.shared.symbolsAvailable {
            addInfoItem("⚠️ DDC unavailable — \(DDC.shared.unavailableReason ?? "IOAVService API missing")")
        }
        menu.addItem(.separator())

        addActionItem("Switch to \(settings.otherInputName) input",
                      action: #selector(switchToOther), enabled: DDC.shared.symbolsAvailable)
        addActionItem("Switch to \(settings.myInputName) input",
                      action: #selector(switchToMine), enabled: DDC.shared.symbolsAvailable)
        menu.addItem(.separator())

        addActionItem("Give monitor away", action: #selector(giveAway),
                      enabled: DDC.shared.symbolsAvailable && SkyLight.shared.available)
        addActionItem("Disconnect display", action: #selector(disconnect),
                      enabled: SkyLight.shared.available)
        addActionItem("Reconnect display", action: #selector(reconnect),
                      enabled: SkyLight.shared.available)
        menu.addItem(.separator())

        addActionItem("Auto mode", action: #selector(toggleAutoMode), checked: settings.autoMode)
        menu.addItem(.separator())

        addActionItem("Settings…", action: #selector(openSettings))
        if LoginItem.isSupported {
            addActionItem("Launch at Login", action: #selector(toggleLoginItem), checked: LoginItem.isEnabled)
        }
        menu.addItem(.separator())
        addActionItem("About KVMBar", action: #selector(showAbout))
        addActionItem("Quit KVMBar", action: #selector(quit))
    }

    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addActionItem(_ title: String, action: Selector,
                               enabled: Bool = true, checked: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        if let checked {
            item.state = checked ? .on : .off
        }
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func switchToOther() {
        DisplayManager.shared.async {
            DisplayManager.shared.switchInput(code: UInt16(clamping: Settings.shared.otherInputCode))
        }
    }

    @objc private func switchToMine() {
        DisplayManager.shared.async {
            DisplayManager.shared.switchInput(code: UInt16(clamping: Settings.shared.myInputCode))
        }
    }

    @objc private func giveAway() {
        DisplayManager.shared.async { DisplayManager.shared.giveAway() }
    }

    @objc private func disconnect() {
        DisplayManager.shared.async { DisplayManager.shared.softDisconnect() }
    }

    @objc private func reconnect() {
        DisplayManager.shared.async { DisplayManager.shared.reconnect() }
    }

    @objc private func toggleAutoMode() {
        Settings.shared.autoMode.toggle()
        log.notice("auto mode: \(Settings.shared.autoMode)")
        DisplayWatcher.shared.scheduleProbeTimerUpdate()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.toggle()
        } catch {
            log.error("launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
