import AppKit
import CoreGraphics
import Foundation
import os

enum KVMState: String {
    case activeHere      // external display is active on this Mac
    case givenAway       // we DDC-switched away and soft-disconnected
    case disconnected    // manually soft-disconnected (no input switch)
    case offline         // display went away on its own (KVM switch / unplug)
    case transitioning
    case noDisplay       // nothing connected and nothing persisted
    case unknown

    var menuDescription: String {
        switch self {
        case .activeHere: return "active here"
        case .givenAway: return "on other input (given away)"
        case .disconnected: return "soft-disconnected"
        case .offline: return "offline / on other input"
        case .transitioning: return "switching…"
        case .noDisplay: return "no external display"
        case .unknown: return "unknown"
        }
    }

    var isAway: Bool {
        self == .givenAway || self == .disconnected || self == .offline
    }
}

/// Owns KVM state and all display actions. Mutating methods are synchronous
/// (they sleep between steps) and must run on `queue` in app mode; the CLI
/// calls them directly and exits.
final class DisplayManager {
    static let shared = DisplayManager()

    let queue = DispatchQueue(label: "dev.valerii.kvmbar.ops", qos: .userInitiated)

    private let log = Logger(subsystem: kSubsystem, category: "display")
    private let settings = Settings.shared

    private(set) var state: KVMState
    /// The given-away display has been re-enabled as a mirror of the built-in
    /// screen: harmless (no window/cursor drift) but keeps a live signal on
    /// our input so a joystick switch-back locks instantly.
    private(set) var isParked = false
    /// Called on the main queue whenever state changes.
    var onStateChange: ((KVMState) -> Void)?

    /// While set, the watcher must not run auto-logic: the burst of
    /// reconfiguration events was caused by our own SkyLight calls.
    private var suppressUntil = Date.distantPast
    var isSuppressed: Bool { Date() < suppressUntil }

    private init() {
        state = settings.stateRaw.flatMap(KVMState.init(rawValue:)) ?? .unknown
    }

    func async(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    private func beginOwnOperation(_ seconds: TimeInterval = 5) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    private func setState(_ newState: KVMState) {
        guard newState != state else { return }
        log.notice("state: \(self.state.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public)")
        state = newState
        settings.stateRaw = newState.rawValue
        DispatchQueue.main.async { self.onStateChange?(newState) }
    }

    // MARK: - Display discovery

    private func displayList(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard fetch(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func activeIDs() -> [CGDirectDisplayID] { displayList(CGGetActiveDisplayList) }
    func onlineIDs() -> [CGDirectDisplayID] { displayList(CGGetOnlineDisplayList) }
    func activeExternalIDs() -> [CGDirectDisplayID] { activeIDs().filter { CGDisplayIsBuiltin($0) == 0 } }
    func onlineExternalIDs() -> [CGDirectDisplayID] { onlineIDs().filter { CGDisplayIsBuiltin($0) == 0 } }

    /// Currently visible external display, if any. Persists the ID so
    /// reconnect keeps working after the display goes offline.
    func currentExternalID() -> CGDirectDisplayID? {
        let active = activeExternalIDs()
        if active.count > 1 {
            log.warning("multiple external displays (\(active)), using the first")
        }
        if let id = active.first ?? onlineExternalIDs().first {
            remember(id)
            return id
        }
        return nil
    }

    /// Target for SkyLight operations: the live display or the persisted ID.
    func targetID() -> CGDirectDisplayID? {
        if let id = currentExternalID() { return id }
        let persisted = settings.lastDisplayID
        return persisted != 0 ? persisted : nil
    }

    private func remember(_ id: CGDirectDisplayID) {
        settings.lastDisplayID = id
        let capture = { [settings] in
            if let name = DisplayManager.name(for: id) { settings.lastDisplayName = name }
        }
        if Thread.isMainThread { capture() } else { DispatchQueue.main.async(execute: capture) }
    }

    static func name(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber, number.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }

    // MARK: - State reconciliation

    /// Reconcile in-memory state with what the system reports.
    func refreshState() {
        if let id = activeExternalIDs().first {
            _ = currentExternalID()
            if state.isAway && (isParked || CGDisplayIsInMirrorSet(id) != 0) {
                return // parked mirror while away — not a real return
            }
            setState(.activeHere)
        } else {
            switch state {
            case .givenAway, .disconnected:
                break // intentional away-state, keep it
            default:
                setState(awayStateFallback())
            }
        }
    }

    /// When the display vanishes, prefer an away-state persisted by another
    /// process (CLI invocation) over the generic "offline".
    private func awayStateFallback() -> KVMState {
        if let raw = settings.stateRaw, let persisted = KVMState(rawValue: raw),
           persisted == .givenAway || persisted == .disconnected {
            return persisted
        }
        return settings.lastDisplayID != 0 ? .offline : .noDisplay
    }

    // MARK: - Actions

    /// DDC input switch. Switching *away* runs the full give-away sequence
    /// (handoff → soft-disconnect → park) unless that is turned off: a bare
    /// input write leaves the phantom display behind — and on the U2725QE it
    /// is ACKed but ignored outright — so it always had to be followed by
    /// "Give monitor away" by hand. Switching *back* to our own input from an
    /// away state re-enables the soft-disconnected display.
    @discardableResult
    func switchInput(code: UInt16) -> Bool {
        if settings.giveAwayOnSwitchToOther,
           code == UInt16(clamping: settings.otherInputCode),
           DDC.shared.symbolsAvailable, SkyLight.shared.available {
            log.notice("switch to other input -> full give-away")
            return giveAway()
        }
        beginOwnOperation(10)
        let wasAway = state.isAway
        log.notice("switch input -> \(code)")
        guard DDC.shared.writeVCP(kVCPInputSelect, value: code) else {
            log.error("input switch to \(code) failed")
            return false
        }
        if wasAway && code == UInt16(clamping: settings.myInputCode) {
            Thread.sleep(forTimeInterval: Double(settings.settleDelayMs) / 1000)
            if let id = targetID(), !activeExternalIDs().contains(id) {
                log.notice("switched back to our input — re-enabling display \(id)")
                SkyLight.shared.setDisplay(id, enabled: true)
                Thread.sleep(forTimeInterval: 0.5)
            }
            refreshState()
        }
        return true
    }

    /// The combo: hand the monitor to the other input, wait, then soft-
    /// disconnect the phantom display. DDC must go first — the I2C channel
    /// dies once the display is disconnected.
    ///
    /// U2725QE specifics (verified live): the standard input select (VCP 0x60)
    /// is ACKed but ignored, so video is handed over indirectly — the Dell
    /// vendor code 0xE8 moves the USB/KVM to the other computer, and the soft
    /// disconnect kills our video signal so the monitor's Auto Select switches
    /// to the other input on its own.
    @discardableResult
    func giveAway() -> Bool {
        beginOwnOperation(10)
        guard DDC.shared.symbolsAvailable else {
            log.error("give away: DDC unavailable, aborting")
            return false
        }
        setState(.transitioning)
        let otherCode = UInt16(clamping: settings.otherInputCode)
        log.notice("give away: handing monitor to input \(otherCode) (\(self.settings.otherInputName, privacy: .public))")
        var handoffOK = false
        if DDC.shared.writeVCP(kVCPInputSelect, value: otherCode) {
            handoffOK = true // spec-following monitors switch video here
        }
        if settings.dellKVMHandoff {
            if DDC.shared.writeVCP(kVCPDellKVMUSB, value: otherCode) {
                handoffOK = true // Dell KVM: USB/peripherals move to the other computer
            } else {
                log.info("give away: Dell KVM USB handoff (E8) write failed")
            }
        }
        guard handoffOK else {
            log.error("give away: no handoff write succeeded — aborting before disconnect")
            refreshState()
            return false
        }
        Thread.sleep(forTimeInterval: Double(settings.giveAwayDelayMs) / 1000)

        guard SkyLight.shared.available else {
            log.error("give away: input switched but SkyLight unavailable — phantom display may remain")
            refreshState()
            return false
        }
        guard let id = targetID() else {
            log.info("give away: display already dropped off on its own")
            setState(.givenAway)
            return true
        }
        let allActive = activeIDs()
        if allActive.contains(id) {
            if allActive.count == 1 {
                log.error("give away: refusing to disable the only active display (clamshell?)")
                refreshState()
                return false
            }
            let ok = SkyLight.shared.setDisplay(id, enabled: false)
            Thread.sleep(forTimeInterval: 0.3)
            if ok {
                setState(.givenAway)
                schedulePark()
            } else {
                refreshState()
            }
            return ok
        } else {
            log.info("give away: display already inactive")
            setState(.givenAway)
            schedulePark()
            return true
        }
    }

    // MARK: - Park / unpark (mirror trick)

    /// After giving away, wait for the monitor to settle on the other input,
    /// then re-enable our display as a mirror of the built-in screen. This
    /// keeps a live signal on our input (instant joystick switch-back, the
    /// monitor's Auto Select won't bounce) while being a harmless phantom —
    /// windows and the cursor cannot drift onto a mirror.
    private func schedulePark() {
        guard settings.parkMirrorEnabled else { return }
        let delay = max(2.0, Double(settings.parkDelayMs) / 1000)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.parkAsMirror()
        }
    }

    func parkAsMirror() {
        guard state.isAway, !isParked, settings.parkMirrorEnabled else { return }
        guard SkyLight.shared.available, let id = targetID() else { return }
        guard let builtin = activeIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            log.info("park: no built-in display to mirror — skipping")
            return
        }
        beginOwnOperation(8)
        log.notice("park: re-enabling display \(id) as mirror of built-in \(builtin)")
        if !activeIDs().contains(id) {
            guard SkyLight.shared.setDisplay(id, enabled: true) else { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.error("park: CGBeginDisplayConfiguration failed")
            return
        }
        let err = CGConfigureDisplayMirrorOfDisplay(config, id, builtin)
        guard err == .success else {
            log.error("park: mirror configuration failed: \(err.rawValue)")
            CGCancelDisplayConfiguration(config)
            return
        }
        if CGCompleteDisplayConfiguration(config, .forSession) == .success {
            isParked = true
            log.notice("park: display \(id) parked as mirror")
        } else {
            log.error("park: CGCompleteDisplayConfiguration failed")
        }
    }

    /// Restore the extended desktop (used when the monitor comes back).
    func unparkAndExtend(trigger: String) {
        guard let id = targetID() else { return }
        beginOwnOperation(8)
        log.notice("unpark (\(trigger, privacy: .public)): restoring extended desktop on \(id)")
        if !activeIDs().contains(id) {
            SkyLight.shared.setDisplay(id, enabled: true)
            Thread.sleep(forTimeInterval: 1.0)
        }
        if CGDisplayIsInMirrorSet(id) != 0 {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                if CGConfigureDisplayMirrorOfDisplay(config, id, CGDirectDisplayID(0)) == .success {
                    CGCompleteDisplayConfiguration(config, .forSession)
                } else {
                    CGCancelDisplayConfiguration(config)
                }
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        isParked = false
        refreshState()
        if state == .activeHere {
            UserNotifier.post("Monitor is back", "Extended desktop restored.")
        }
    }

    // MARK: - USB KVM signals (the reliable ones — the KVM moves the user's
    // wireless receiver between computers together with the video)

    /// The KVM device left our USB tree: the monitor switched away (joystick,
    /// or the other computer pulled it). Clean up the phantom and park.
    func kvmUSBDisappeared() {
        guard settings.autoMode, settings.usbKVMDetection else { return }
        guard !isSuppressed else { return } // our own give-away already handles it
        guard state == .activeHere else { return }
        log.notice("USB KVM device left — monitor switched away externally")
        if softDisconnect(markAs: .givenAway) {
            UserNotifier.post("Monitor given away",
                              "KVM moved to the other computer; phantom display cleaned up.")
            schedulePark()
        }
    }

    /// The KVM device appeared in our USB tree: the monitor is back on us.
    func kvmUSBAppeared() {
        guard settings.autoMode, settings.usbKVMDetection else { return }
        if state.isAway || isParked {
            log.notice("USB KVM device appeared — monitor is back")
            unparkAndExtend(trigger: "USB KVM returned")
        } else {
            refreshState()
        }
    }

    /// Soft-disconnect only (no input switch).
    @discardableResult
    func softDisconnect(markAs: KVMState = .disconnected) -> Bool {
        beginOwnOperation()
        guard SkyLight.shared.available else {
            log.error("disconnect: SkyLight unavailable")
            return false
        }
        guard let id = targetID() else {
            log.error("disconnect: no external display known")
            setState(.noDisplay)
            return false
        }
        let allActive = activeIDs()
        if allActive == [id] {
            log.error("disconnect: refusing to disable the only active display (clamshell?)")
            return false
        }
        setState(.transitioning)
        let ok = SkyLight.shared.setDisplay(id, enabled: false)
        Thread.sleep(forTimeInterval: 0.3)
        isParked = false
        if ok { setState(markAs) } else { refreshState() }
        return ok
    }

    /// Manual fix-it button: if the display is offline/disabled, enable it;
    /// if it is "active" but black, power-cycle the video stream
    /// (disable → wait → enable) to force macOS to re-issue it.
    @discardableResult
    func reconnect() -> Bool {
        beginOwnOperation(10)
        guard SkyLight.shared.available else {
            log.error("reconnect: SkyLight unavailable")
            return false
        }
        guard let id = targetID() else {
            log.error("reconnect: no external display known (no persisted ID)")
            setState(.noDisplay)
            return false
        }
        if isParked || CGDisplayIsInMirrorSet(id) != 0 {
            unparkAndExtend(trigger: "manual reconnect")
            return state == .activeHere
        }
        setState(.transitioning)
        var ok: Bool
        if activeExternalIDs().contains(id) {
            log.notice("reconnect: display \(id) active — forcing video refresh cycle")
            ok = SkyLight.shared.setDisplay(id, enabled: false)
            Thread.sleep(forTimeInterval: Double(settings.cycleDelayMs) / 1000)
            ok = SkyLight.shared.setDisplay(id, enabled: true) && ok
        } else {
            log.notice("reconnect: re-enabling display \(id)")
            ok = SkyLight.shared.setDisplay(id, enabled: true)
        }
        Thread.sleep(forTimeInterval: Double(settings.settleDelayMs) / 1000)
        refreshState()
        return ok
    }

    // MARK: - Auto mode entry points (called by DisplayWatcher on `queue`)

    /// A display-added event arrived while we were in an away state.
    func autoReturn(trigger: String) {
        guard settings.autoMode, state.isAway else {
            refreshState()
            return
        }
        if isParked {
            unparkAndExtend(trigger: trigger)
            return
        }
        beginOwnOperation()
        log.notice("auto-return (\(trigger, privacy: .public)) from \(self.state.rawValue, privacy: .public)")
        guard let id = targetID() else {
            refreshState()
            return
        }
        if !activeExternalIDs().contains(id) {
            SkyLight.shared.setDisplay(id, enabled: true)
            Thread.sleep(forTimeInterval: 0.8)
        } else if settings.forceRefreshOnAutoReturn {
            // The system re-added the display on its own; this is exactly the
            // black-screen-on-return case, so force a fresh video stream.
            log.notice("auto-return: display already active — forcing video refresh cycle")
            cycle(id)
            Thread.sleep(forTimeInterval: 0.5)
        }
        refreshState()
        if state == .activeHere {
            UserNotifier.post("Monitor is back", "Display re-enabled automatically.")
        }
    }

    /// The DDC probe read our own input code while away: the monitor switched
    /// back to us but the display is still soft-disabled.
    func probeDetectedReturn() {
        guard state.isAway else { return }
        beginOwnOperation()
        log.notice("probe: monitor is back on our input — re-enabling display")
        guard let id = targetID() else { return }
        if !activeExternalIDs().contains(id) {
            guard SkyLight.shared.setDisplay(id, enabled: true) else { return }
            Thread.sleep(forTimeInterval: Double(settings.settleDelayMs) / 1000)
        }
        refreshState()
        if state != .activeHere {
            log.notice("probe: enable didn't stick — trying refresh cycle")
            cycle(id)
            Thread.sleep(forTimeInterval: 0.5)
            refreshState()
        }
        if state == .activeHere {
            UserNotifier.post("Monitor is back", "Display re-enabled after the input returned.")
        }
    }

    /// Phantom watch: the monitor reports the other input as active while
    /// macOS still thinks the display is here.
    func autoPhantomDisconnect() {
        guard state == .activeHere else { return }
        log.notice("phantom watch: monitor is on the other input — soft-disconnecting")
        if softDisconnect(markAs: .givenAway) {
            UserNotifier.post("Phantom display disconnected",
                              "Monitor switched to the other input; windows moved back to the built-in screen.")
        }
    }

    /// Blind probe (opt-in): DDC is unreachable while away, so briefly enable
    /// the display and check whether the monitor answers on our input.
    func blindReturnAttempt() {
        guard state.isAway, SkyLight.shared.available, let id = targetID() else { return }
        beginOwnOperation(8)
        log.notice("blind probe: temporarily enabling display \(id) to check for the monitor")
        guard SkyLight.shared.setDisplay(id, enabled: true) else { return }
        Thread.sleep(forTimeInterval: 1.2)
        if let reply = DDC.shared.readVCP(kVCPInputSelect),
           reply.inputCode == settings.myInputCode {
            log.notice("blind probe: monitor is back — keeping display enabled")
            refreshState()
            if state == .activeHere {
                UserNotifier.post("Monitor is back", "Display re-enabled (blind probe).")
            }
        } else {
            log.info("blind probe: monitor still away — disabling again")
            SkyLight.shared.setDisplay(id, enabled: false)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func cycle(_ id: CGDirectDisplayID) {
        SkyLight.shared.setDisplay(id, enabled: false)
        Thread.sleep(forTimeInterval: Double(settings.cycleDelayMs) / 1000)
        SkyLight.shared.setDisplay(id, enabled: true)
    }
}
