import Foundation

/// UserDefaults-backed configuration, shared between the menu bar app and CLI
/// invocations via an explicit suite (the bare binary has no bundle identifier).
final class Settings {
    static let shared = Settings()
    static let suiteName = "dev.valerii.kvmbar.shared"

    let defaults: UserDefaults

    private enum Key {
        static let myInputName = "myInputName"
        static let myInputCode = "myInputCode"
        static let otherInputName = "otherInputName"
        static let otherInputCode = "otherInputCode"
        static let giveAwayDelayMs = "giveAwayDelayMs"
        static let cycleDelayMs = "cycleDelayMs"
        static let settleDelayMs = "settleDelayMs"
        static let debounceMs = "debounceMs"
        static let probeIntervalSec = "probeIntervalSec"
        static let autoMode = "autoMode"
        static let notificationsEnabled = "notificationsEnabled"
        static let forceRefreshOnAutoReturn = "forceRefreshOnAutoReturn"
        static let phantomWatch = "phantomWatch"
        static let blindProbeEnabled = "blindProbeEnabled"
        static let blindProbeIntervalSec = "blindProbeIntervalSec"
        static let dellKVMHandoff = "dellKVMHandoff"
        static let usbKVMDetection = "usbKVMDetection"
        static let kvmUSBVendorID = "kvmUSBVendorID"
        static let kvmUSBProductID = "kvmUSBProductID"
        static let parkMirrorEnabled = "parkMirrorEnabled"
        static let parkDelayMs = "parkDelayMs"
        static let ddcInputProbe = "ddcInputProbe"
        static let lastDisplayID = "lastDisplayID"
        static let lastDisplayName = "lastDisplayName"
        static let stateRaw = "stateRaw"
    }

    private init() {
        defaults = UserDefaults(suiteName: Settings.suiteName) ?? .standard
        defaults.register(defaults: [
            Key.myInputName: "Thunderbolt",
            Key.myInputCode: 25,
            Key.otherInputName: "HDMI",
            Key.otherInputCode: 17,
            Key.giveAwayDelayMs: 1000,
            Key.cycleDelayMs: 1000,
            Key.settleDelayMs: 1200,
            Key.debounceMs: 500,
            Key.probeIntervalSec: 2.0,
            Key.autoMode: true,
            Key.notificationsEnabled: true,
            Key.forceRefreshOnAutoReturn: true,
            Key.phantomWatch: false,
            Key.blindProbeEnabled: false,
            Key.blindProbeIntervalSec: 15.0,
            Key.dellKVMHandoff: true,
            Key.usbKVMDetection: true,
            Key.kvmUSBVendorID: 0x25A7,   // Nordic 2.4G wireless receiver (user's KVM anchor)
            Key.kvmUSBProductID: 0xFA11,
            Key.parkMirrorEnabled: true,
            Key.parkDelayMs: 8000,
            Key.ddcInputProbe: false,     // U2725QE reports a static per-port value — probe is misleading there
        ])
    }

    var myInputName: String {
        get { defaults.string(forKey: Key.myInputName) ?? "Thunderbolt" }
        set { defaults.set(newValue, forKey: Key.myInputName) }
    }
    var myInputCode: Int {
        get { defaults.integer(forKey: Key.myInputCode) }
        set { defaults.set(newValue, forKey: Key.myInputCode) }
    }
    var otherInputName: String {
        get { defaults.string(forKey: Key.otherInputName) ?? "HDMI" }
        set { defaults.set(newValue, forKey: Key.otherInputName) }
    }
    var otherInputCode: Int {
        get { defaults.integer(forKey: Key.otherInputCode) }
        set { defaults.set(newValue, forKey: Key.otherInputCode) }
    }
    var giveAwayDelayMs: Int {
        get { defaults.integer(forKey: Key.giveAwayDelayMs) }
        set { defaults.set(newValue, forKey: Key.giveAwayDelayMs) }
    }
    var cycleDelayMs: Int {
        get { defaults.integer(forKey: Key.cycleDelayMs) }
        set { defaults.set(newValue, forKey: Key.cycleDelayMs) }
    }
    var settleDelayMs: Int {
        get { defaults.integer(forKey: Key.settleDelayMs) }
        set { defaults.set(newValue, forKey: Key.settleDelayMs) }
    }
    var debounceMs: Int {
        get { defaults.integer(forKey: Key.debounceMs) }
        set { defaults.set(newValue, forKey: Key.debounceMs) }
    }
    var probeIntervalSec: Double {
        get { defaults.double(forKey: Key.probeIntervalSec) }
        set { defaults.set(newValue, forKey: Key.probeIntervalSec) }
    }
    var autoMode: Bool {
        get { defaults.bool(forKey: Key.autoMode) }
        set { defaults.set(newValue, forKey: Key.autoMode) }
    }
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }
    var forceRefreshOnAutoReturn: Bool {
        get { defaults.bool(forKey: Key.forceRefreshOnAutoReturn) }
        set { defaults.set(newValue, forKey: Key.forceRefreshOnAutoReturn) }
    }
    var phantomWatch: Bool {
        get { defaults.bool(forKey: Key.phantomWatch) }
        set { defaults.set(newValue, forKey: Key.phantomWatch) }
    }
    var blindProbeEnabled: Bool {
        get { defaults.bool(forKey: Key.blindProbeEnabled) }
        set { defaults.set(newValue, forKey: Key.blindProbeEnabled) }
    }
    var blindProbeIntervalSec: Double {
        get { defaults.double(forKey: Key.blindProbeIntervalSec) }
        set { defaults.set(newValue, forKey: Key.blindProbeIntervalSec) }
    }
    var dellKVMHandoff: Bool {
        get { defaults.bool(forKey: Key.dellKVMHandoff) }
        set { defaults.set(newValue, forKey: Key.dellKVMHandoff) }
    }
    var usbKVMDetection: Bool {
        get { defaults.bool(forKey: Key.usbKVMDetection) }
        set { defaults.set(newValue, forKey: Key.usbKVMDetection) }
    }
    var kvmUSBVendorID: Int {
        get { defaults.integer(forKey: Key.kvmUSBVendorID) }
        set { defaults.set(newValue, forKey: Key.kvmUSBVendorID) }
    }
    var kvmUSBProductID: Int {
        get { defaults.integer(forKey: Key.kvmUSBProductID) }
        set { defaults.set(newValue, forKey: Key.kvmUSBProductID) }
    }
    var parkMirrorEnabled: Bool {
        get { defaults.bool(forKey: Key.parkMirrorEnabled) }
        set { defaults.set(newValue, forKey: Key.parkMirrorEnabled) }
    }
    var parkDelayMs: Int {
        get { defaults.integer(forKey: Key.parkDelayMs) }
        set { defaults.set(newValue, forKey: Key.parkDelayMs) }
    }
    var ddcInputProbe: Bool {
        get { defaults.bool(forKey: Key.ddcInputProbe) }
        set { defaults.set(newValue, forKey: Key.ddcInputProbe) }
    }

    /// Last known CGDirectDisplayID of the external display; lets us re-enable
    /// it while the display is offline (soft-disconnected).
    var lastDisplayID: UInt32 {
        get { UInt32(clamping: defaults.integer(forKey: Key.lastDisplayID)) }
        set { defaults.set(Int(newValue), forKey: Key.lastDisplayID) }
    }
    var lastDisplayName: String? {
        get { defaults.string(forKey: Key.lastDisplayName) }
        set { defaults.set(newValue, forKey: Key.lastDisplayName) }
    }
    var stateRaw: String? {
        get { defaults.string(forKey: Key.stateRaw) }
        set { defaults.set(newValue, forKey: Key.stateRaw) }
    }
}
