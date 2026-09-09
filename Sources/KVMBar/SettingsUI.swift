import AppKit
import SwiftUI

/// Write-through view model over Settings; posts a change notification so the
/// watcher can pick up new intervals/toggles immediately.
final class SettingsModel: ObservableObject {
    private let s = Settings.shared

    @Published var myInputName: String { didSet { s.myInputName = myInputName; changed() } }
    @Published var myInputCode: Int { didSet { s.myInputCode = myInputCode; changed() } }
    @Published var otherInputName: String { didSet { s.otherInputName = otherInputName; changed() } }
    @Published var otherInputCode: Int { didSet { s.otherInputCode = otherInputCode; changed() } }
    @Published var giveAwayDelayMs: Int { didSet { s.giveAwayDelayMs = giveAwayDelayMs; changed() } }
    @Published var cycleDelayMs: Int { didSet { s.cycleDelayMs = cycleDelayMs; changed() } }
    @Published var settleDelayMs: Int { didSet { s.settleDelayMs = settleDelayMs; changed() } }
    @Published var debounceMs: Int { didSet { s.debounceMs = debounceMs; changed() } }
    @Published var probeIntervalSec: Double { didSet { s.probeIntervalSec = probeIntervalSec; changed() } }
    @Published var notificationsEnabled: Bool { didSet { s.notificationsEnabled = notificationsEnabled; changed() } }
    @Published var forceRefreshOnAutoReturn: Bool { didSet { s.forceRefreshOnAutoReturn = forceRefreshOnAutoReturn; changed() } }
    @Published var phantomWatch: Bool { didSet { s.phantomWatch = phantomWatch; changed() } }
    @Published var blindProbeEnabled: Bool { didSet { s.blindProbeEnabled = blindProbeEnabled; changed() } }
    @Published var blindProbeIntervalSec: Double { didSet { s.blindProbeIntervalSec = blindProbeIntervalSec; changed() } }
    @Published var dellKVMHandoff: Bool { didSet { s.dellKVMHandoff = dellKVMHandoff; changed() } }
    @Published var giveAwayOnSwitchToOther: Bool { didSet { s.giveAwayOnSwitchToOther = giveAwayOnSwitchToOther; changed() } }
    @Published var reconnectOnSwitchToMine: Bool { didSet { s.reconnectOnSwitchToMine = reconnectOnSwitchToMine; changed() } }
    @Published var usbKVMDetection: Bool { didSet { s.usbKVMDetection = usbKVMDetection; changed() } }
    @Published var kvmUSBVendorID: Int { didSet { s.kvmUSBVendorID = kvmUSBVendorID; changed() } }
    @Published var kvmUSBProductID: Int { didSet { s.kvmUSBProductID = kvmUSBProductID; changed() } }
    @Published var parkMirrorEnabled: Bool { didSet { s.parkMirrorEnabled = parkMirrorEnabled; changed() } }
    @Published var parkDelayMs: Int { didSet { s.parkDelayMs = parkDelayMs; changed() } }
    @Published var ddcInputProbe: Bool { didSet { s.ddcInputProbe = ddcInputProbe; changed() } }

    init() {
        myInputName = s.myInputName
        myInputCode = s.myInputCode
        otherInputName = s.otherInputName
        otherInputCode = s.otherInputCode
        giveAwayDelayMs = s.giveAwayDelayMs
        cycleDelayMs = s.cycleDelayMs
        settleDelayMs = s.settleDelayMs
        debounceMs = s.debounceMs
        probeIntervalSec = s.probeIntervalSec
        notificationsEnabled = s.notificationsEnabled
        forceRefreshOnAutoReturn = s.forceRefreshOnAutoReturn
        phantomWatch = s.phantomWatch
        blindProbeEnabled = s.blindProbeEnabled
        blindProbeIntervalSec = s.blindProbeIntervalSec
        dellKVMHandoff = s.dellKVMHandoff
        giveAwayOnSwitchToOther = s.giveAwayOnSwitchToOther
        reconnectOnSwitchToMine = s.reconnectOnSwitchToMine
        usbKVMDetection = s.usbKVMDetection
        kvmUSBVendorID = s.kvmUSBVendorID
        kvmUSBProductID = s.kvmUSBProductID
        parkMirrorEnabled = s.parkMirrorEnabled
        parkDelayMs = s.parkDelayMs
        ddcInputProbe = s.ddcInputProbe
    }

    private func changed() {
        NotificationCenter.default.post(name: kSettingsChangedNotification, object: nil)
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("This Mac's input") {
                TextField("Name", text: $model.myInputName)
                TextField("DDC code", value: $model.myInputCode, format: .number)
            }
            Section("Other input") {
                TextField("Name", text: $model.otherInputName)
                TextField("DDC code", value: $model.otherInputCode, format: .number)
            }
            Section("Timings") {
                TextField("Give-away: switch → disconnect delay (ms)", value: $model.giveAwayDelayMs, format: .number)
                TextField("Reconnect cycle gap (ms)", value: $model.cycleDelayMs, format: .number)
                TextField("Settle delay after enable (ms)", value: $model.settleDelayMs, format: .number)
                TextField("Display event debounce (ms)", value: $model.debounceMs, format: .number)
                TextField("Auto-mode probe interval (s)", value: $model.probeIntervalSec, format: .number)
            }
            Section("KVM detection (USB)") {
                Toggle("Track KVM by USB device presence (recommended)", isOn: $model.usbKVMDetection)
                TextField("KVM device vendor ID", value: $model.kvmUSBVendorID, format: .number)
                TextField("KVM device product ID", value: $model.kvmUSBProductID, format: .number)
                Toggle("Park given-away display as mirror (instant switch-back)", isOn: $model.parkMirrorEnabled)
                TextField("Park delay after give-away (ms)", value: $model.parkDelayMs, format: .number)
            }
            Section("Behavior") {
                Toggle("“Switch to other input” gives the monitor away (handoff + disconnect)",
                       isOn: $model.giveAwayOnSwitchToOther)
                Toggle("“Switch to my input” reconnects the display afterwards (unpark / re-enable / refresh)",
                       isOn: $model.reconnectOnSwitchToMine)
                Toggle("Notify on auto-mode actions", isOn: $model.notificationsEnabled)
                Toggle("Force video refresh when display returns on its own", isOn: $model.forceRefreshOnAutoReturn)
                Toggle("Auto-disconnect when monitor switches away (experimental)", isOn: $model.phantomWatch)
                Toggle("Blind return probe when DDC is unreachable (experimental)", isOn: $model.blindProbeEnabled)
                TextField("Blind probe interval (s)", value: $model.blindProbeIntervalSec, format: .number)
                Toggle("Dell KVM USB handoff on give-away (VCP E8)", isOn: $model.dellKVMHandoff)
                Toggle("DDC input probe while away (not usable on U2725QE)", isOn: $model.ddcInputProbe)
            }
            Text("Dell U2725QE input codes (from its DDC capabilities): Thunderbolt = 25, HDMI = 17, DisplayPort = 15.\nSettings apply immediately — no Save button; number fields commit on Enter/Tab or focus change.\nChanging the KVM USB device IDs or the USB-detection toggle requires an app restart.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "KVMBar Settings"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Commit any in-progress text field edit before the window closes —
    /// otherwise a value typed without pressing Enter/Tab would be lost.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }
}
