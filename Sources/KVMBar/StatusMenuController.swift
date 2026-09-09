import AppKit
import os

/// Menu bar icon + menu. The icon reflects state at a glance; the menu is
/// rebuilt each time it opens so labels and checkmarks are always current.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: kSubsystem, category: "menu")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var autoBrightnessItem: NSMenuItem?
    /// Last state read from the monitor — shown while the fresh read is in flight.
    private var autoBrightnessOn = false

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

        // With the give-away chaining on (the default), switching away *is*
        // the give-away, so the separate item would be a duplicate.
        let chained = settings.giveAwayOnSwitchToOther
        addActionItem("Switch to \(settings.otherInputName) input",
                      action: #selector(switchToOther),
                      enabled: DDC.shared.symbolsAvailable && (!chained || SkyLight.shared.available),
                      toolTip: chained
                        ? "Hands the monitor and USB peripherals to \(settings.otherInputName), then soft-disconnects the phantom display (same as “Give monitor away”)."
                        : nil)
        // Switching back is chained with a reconnect (the default): the
        // parked mirror otherwise comes back as a duplicate screen.
        let reconnectChained = settings.reconnectOnSwitchToMine && SkyLight.shared.available
        addActionItem("Switch to \(settings.myInputName) input",
                      action: #selector(switchToMine), enabled: DDC.shared.symbolsAvailable,
                      toolTip: reconnectChained
                        ? "Switches the monitor to \(settings.myInputName), then reconnects the display: unparks the mirror, re-enables it or refreshes the video (same as “Reconnect display”)."
                        : nil)
        menu.addItem(.separator())

        if !chained {
            addActionItem("Give monitor away", action: #selector(giveAway),
                          enabled: DDC.shared.symbolsAvailable && SkyLight.shared.available)
        }
        addActionItem("Disconnect display", action: #selector(disconnect),
                      enabled: SkyLight.shared.available)
        addActionItem("Reconnect display", action: #selector(reconnect),
                      enabled: SkyLight.shared.available)
        menu.addItem(.separator())

        // The monitor's own ambient-light auto brightness, toggled over DDC.
        // Its state is read on the ops queue after the menu opens: a DDC read
        // must neither stall the main thread nor race another DDC operation.
        autoBrightnessItem = addActionItem("Monitor auto brightness",
                                           action: #selector(toggleAutoBrightness),
                                           enabled: DDC.shared.symbolsAvailable,
                                           checked: autoBrightnessOn,
                                           toolTip: "The monitor's ambient-light sensor drives its brightness (OSD → Auto Brightness). Switched over DDC, VCP 0x66.")
        refreshAutoBrightnessItem()
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

    @discardableResult
    private func addActionItem(_ title: String, action: Selector,
                               enabled: Bool = true, checked: Bool? = nil,
                               toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.toolTip = toolTip
        if let checked {
            item.state = checked ? .on : .off
        }
        menu.addItem(item)
        return item
    }

    /// Updates the auto brightness item in place once the monitor answers;
    /// greys it out when the monitor is unreachable over DDC.
    private func refreshAutoBrightnessItem() {
        guard DDC.shared.symbolsAvailable, let item = autoBrightnessItem else { return }
        DisplayManager.shared.async { [weak self] in
            let result = DisplayManager.shared.readAutoBrightness()
            DispatchQueue.main.async {
                guard let self, self.autoBrightnessItem === item else { return } // menu rebuilt meanwhile
                if let result {
                    self.autoBrightnessOn = result.on
                    item.state = result.on ? .on : .off
                    item.isEnabled = true
                } else {
                    item.isEnabled = false
                    item.toolTip = "Monitor not reachable over DDC (link down or no external display)."
                }
            }
        }
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

    @objc private func toggleAutoBrightness() {
        DisplayManager.shared.async { [weak self] in
            guard let on = DisplayManager.shared.toggleAutoBrightness() else { return }
            DispatchQueue.main.async { self?.autoBrightnessOn = on }
        }
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
