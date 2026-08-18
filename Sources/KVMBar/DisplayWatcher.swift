import AppKit
import CoreGraphics
import Foundation
import IOKit
import os

/// Watches display reconfiguration events (with NSScreen notifications as a
/// backup signal), IORegistry lifecycle of the external DCPAVServiceProxy
/// (fires when the physical link (re)trains even while the display is
/// soft-disabled at the WindowServer level), and runs the auto-mode DDC
/// probe timer.
///
/// Threading: CG callback and NSScreen observer fire on the main run loop;
/// event sets and debouncing live on main. IOKit notifications, probe timer
/// state and all DisplayManager calls live on the manager's serial ops queue.
final class DisplayWatcher {
    static let shared = DisplayWatcher()

    private let log = Logger(subsystem: kSubsystem, category: "watcher")

    // Main-thread state
    private var debounceItem: DispatchWorkItem?
    private var addedIDs = Set<CGDirectDisplayID>()
    private var removedIDs = Set<CGDirectDisplayID>()

    // Ops-queue state
    private var probeTimer: DispatchSourceTimer?
    private var phantomHits = 0
    private var blindTickCounter = 0
    private var notifyPort: IONotificationPortRef?
    private var appearedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var usbAppearedIterator: io_iterator_t = 0
    private var usbTerminatedIterator: io_iterator_t = 0

    private init() {}

    func start() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, selfPtr)
        if err != .success {
            log.error("CGDisplayRegisterReconfigurationCallback failed: \(err.rawValue)")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.log.debug("NSScreen parameters changed")
            self?.scheduleBurstProcessing()
        }
        NotificationCenter.default.addObserver(
            forName: kSettingsChangedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleProbeTimerUpdate()
        }
        startRegistryWatcher()
        scheduleProbeTimerUpdate()
        log.notice("watcher started")
    }

    // MARK: - IORegistry AV service lifecycle

    /// The U2725QE (over TB/DP-alt) does not answer DDC reads, so the probe
    /// can't detect the return on that path. The DCPAVServiceProxy appearing
    /// in the IORegistry is a hardware-level "link came back" signal that
    /// works even while the display is soft-disabled.
    private func startRegistryWatcher() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log.error("IONotificationPortCreate failed — AV service watcher disabled")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DisplayManager.shared.queue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var kr = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, IOServiceMatching("DCPAVServiceProxy"),
            avServiceAppearedCallback, selfPtr, &appearedIterator)
        if kr == KERN_SUCCESS {
            _ = Self.drainExternalEntries(appearedIterator) // arm; ignore preexisting
        } else {
            log.error("AV service matched notification failed: \(kr)")
        }

        kr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching("DCPAVServiceProxy"),
            avServiceTerminatedCallback, selfPtr, &terminatedIterator)
        if kr == KERN_SUCCESS {
            _ = Self.drainExternalEntries(terminatedIterator)
        } else {
            log.error("AV service terminated notification failed: \(kr)")
        }

        registerUSBKVMWatch(on: port)
    }

    // MARK: - USB KVM device watch (the monitor's KVM moves the user's
    // wireless receiver between computers together with the video — its
    // presence is the most reliable "who owns the monitor" signal)

    private func usbKVMMatchingDict() -> CFMutableDictionary? {
        let settings = Settings.shared
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let dict = matching as NSMutableDictionary
        dict["idVendor"] = settings.kvmUSBVendorID
        dict["idProduct"] = settings.kvmUSBProductID
        return (dict as! CFMutableDictionary)
    }

    /// True if the configured KVM USB device is currently attached.
    static func usbKVMDevicePresent() -> Bool {
        let settings = Settings.shared
        guard settings.kvmUSBVendorID != 0 else { return false }
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return false }
        let dict = matching as NSMutableDictionary
        dict["idVendor"] = settings.kvmUSBVendorID
        dict["idProduct"] = settings.kvmUSBProductID
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, (dict as! CFMutableDictionary),
                                           &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        if entry != 0 {
            IOObjectRelease(entry)
            var rest = IOIteratorNext(iterator)
            while rest != 0 { IOObjectRelease(rest); rest = IOIteratorNext(iterator) }
            return true
        }
        return false
    }

    private func registerUSBKVMWatch(on port: IONotificationPortRef) {
        let settings = Settings.shared
        guard settings.usbKVMDetection, settings.kvmUSBVendorID != 0 else {
            log.info("USB KVM watch disabled")
            return
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let matchDict = usbKVMMatchingDict(), let termDict = usbKVMMatchingDict() else { return }
        var kr = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, matchDict,
            usbKVMAppearedCallback, selfPtr, &usbAppearedIterator)
        var presentAtStart = false
        if kr == KERN_SUCCESS {
            presentAtStart = Self.drainAll(usbAppearedIterator)
        } else {
            log.error("USB KVM matched notification failed: \(kr)")
        }
        kr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, termDict,
            usbKVMTerminatedCallback, selfPtr, &usbTerminatedIterator)
        if kr == KERN_SUCCESS {
            _ = Self.drainAll(usbTerminatedIterator)
        } else {
            log.error("USB KVM terminated notification failed: \(kr)")
        }
        log.notice("USB KVM watch armed (device \(presentAtStart ? "present" : "absent", privacy: .public) at start)")

        // Reconcile at launch: if the device is absent but we think the
        // monitor is ours, the monitor is actually away — clean up.
        if !presentAtStart {
            DisplayManager.shared.async {
                DisplayManager.shared.kvmUSBDisappeared()
            }
        }
    }

    fileprivate static func drainAll(_ iterator: io_iterator_t) -> Bool {
        var any = false
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            any = true
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return any
    }

    fileprivate func handleUSBKVMAppeared(_ iterator: io_iterator_t) {
        guard Self.drainAll(iterator) else { return }
        log.notice("USB KVM device appeared")
        DisplayManager.shared.kvmUSBAppeared()
        updateProbeTimerOnQueue()
    }

    fileprivate func handleUSBKVMTerminated(_ iterator: io_iterator_t) {
        guard Self.drainAll(iterator) else { return }
        log.notice("USB KVM device disappeared")
        DisplayManager.shared.kvmUSBDisappeared()
        updateProbeTimerOnQueue()
    }

    /// Drains the iterator (required to re-arm the notification) and reports
    /// whether any drained entry was the external display's service.
    fileprivate static func drainExternalEntries(_ iterator: io_iterator_t) -> Bool {
        var sawExternal = false
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External" { sawExternal = true }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return sawExternal
    }

    fileprivate func handleAVServiceAppeared(_ iterator: io_iterator_t) {
        guard Self.drainExternalEntries(iterator) else { return }
        let manager = DisplayManager.shared
        log.notice("external DCP AV service appeared — display link (re)established")
        guard Settings.shared.autoMode, manager.state.isAway, !manager.isSuppressed else { return }
        Thread.sleep(forTimeInterval: 1.0) // let the link settle before enabling
        manager.autoReturn(trigger: "AV service appeared")
        updateProbeTimerOnQueue()
    }

    fileprivate func handleAVServiceTerminated(_ iterator: io_iterator_t) {
        guard Self.drainExternalEntries(iterator) else { return }
        // No action needed — CG remove events reconcile state. Logged because
        // it tells us whether soft-disconnect tears the link down on this
        // hardware (key diagnostic for auto-return behavior).
        log.notice("external DCP AV service terminated — display link went down")
    }

    // MARK: - Reconfiguration events (main thread)

    func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }
        let isBuiltin = CGDisplayIsBuiltin(display) != 0
        log.debug("reconfig: display \(display) flags \(flags.rawValue) builtin \(isBuiltin)")
        guard !isBuiltin else { return }
        if flags.contains(.addFlag) || flags.contains(.enabledFlag) {
            addedIDs.insert(display)
        }
        if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
            removedIDs.insert(display)
        }
        scheduleBurstProcessing()
    }

    /// Reconfiguration fires in bursts — debounce before acting.
    private func scheduleBurstProcessing() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.processBurst() }
        debounceItem = item
        let delay = Double(Settings.shared.debounceMs) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func processBurst() {
        let added = addedIDs
        let removed = removedIDs
        addedIDs.removeAll()
        removedIDs.removeAll()
        log.info("reconfig burst: added \(Array(added)) removed \(Array(removed))")

        DisplayManager.shared.async { [weak self] in
            guard let self else { return }
            let manager = DisplayManager.shared
            if manager.isSuppressed {
                // Our own operation caused this burst; it reconciles state itself.
                self.log.debug("burst ignored (own operation in progress)")
            } else if !added.isEmpty && manager.state.isAway {
                manager.autoReturn(trigger: "display added")
            } else {
                manager.refreshState()
            }
            self.updateProbeTimerOnQueue()
        }
    }

    // MARK: - Probe timer (ops queue)

    func scheduleProbeTimerUpdate() {
        DisplayManager.shared.async { [weak self] in self?.updateProbeTimerOnQueue() }
    }

    private func updateProbeTimerOnQueue() {
        let settings = Settings.shared
        let state = DisplayManager.shared.state

        let needed: Bool
        if !settings.autoMode || !DDC.shared.symbolsAvailable {
            needed = false
        } else if state.isAway && (settings.ddcInputProbe || settings.blindProbeEnabled) {
            needed = true
        } else if state == .activeHere && settings.phantomWatch {
            needed = true
        } else {
            needed = false
        }

        probeTimer?.cancel()
        probeTimer = nil
        guard needed else { return }

        let interval = max(settings.probeIntervalSec, 0.5)
        let timer = DispatchSource.makeTimerSource(queue: DisplayManager.shared.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.probeTick() }
        timer.resume()
        probeTimer = timer
        log.debug("probe timer running every \(interval)s for state \(state.rawValue, privacy: .public)")
    }

    private func probeTick() {
        let manager = DisplayManager.shared
        let settings = Settings.shared
        guard settings.autoMode, !manager.isSuppressed else { return }

        switch manager.state {
        case .givenAway, .disconnected, .offline:
            if settings.ddcInputProbe, let reply = DDC.shared.readVCP(kVCPInputSelect) {
                blindTickCounter = 0
                let current = reply.inputCode
                log.debug("probe (away): monitor input = \(current)")
                if current == settings.myInputCode {
                    manager.probeDetectedReturn()
                    updateProbeTimerOnQueue()
                }
            } else if settings.blindProbeEnabled {
                blindTickCounter += 1
                let interval = max(settings.probeIntervalSec, 0.5)
                let everyN = max(1, Int((settings.blindProbeIntervalSec / interval).rounded()))
                if blindTickCounter >= everyN {
                    blindTickCounter = 0
                    manager.blindReturnAttempt()
                    updateProbeTimerOnQueue()
                }
            }
        case .activeHere:
            guard settings.phantomWatch else { return }
            if let reply = DDC.shared.readVCP(kVCPInputSelect) {
                let current = reply.inputCode
                if current == settings.otherInputCode {
                    phantomHits += 1
                    log.info("phantom watch: monitor reports other input (\(self.phantomHits)/2)")
                    if phantomHits >= 2 {
                        phantomHits = 0
                        manager.autoPhantomDisconnect()
                        updateProbeTimerOnQueue()
                    }
                } else {
                    phantomHits = 0
                }
            } else {
                phantomHits = 0
            }
        default:
            break
        }
    }
}

private func displayReconfigurationCallback(display: CGDirectDisplayID,
                                            flags: CGDisplayChangeSummaryFlags,
                                            userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let watcher = Unmanaged<DisplayWatcher>.fromOpaque(userInfo).takeUnretainedValue()
    watcher.handleReconfiguration(display: display, flags: flags)
}

private func avServiceAppearedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue()
        .handleAVServiceAppeared(iterator)
}

private func avServiceTerminatedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue()
        .handleAVServiceTerminated(iterator)
}

private func usbKVMAppearedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue()
        .handleUSBKVMAppeared(iterator)
}

private func usbKVMTerminatedCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue()
        .handleUSBKVMTerminated(iterator)
}
