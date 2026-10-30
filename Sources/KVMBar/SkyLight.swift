import CoreGraphics
import Foundation
import os

/// Soft display disconnect/reconnect via the private SkyLight (WindowServer)
/// API — the same mechanism BetterDisplay and Lunar use.
///
/// Signature verified on macOS 26 (crash-report analysis, matches the old
/// CGSDisplays.h headers):
///   CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
/// The change must be staged inside a public CGBeginDisplayConfiguration
/// transaction and committed with CGCompleteDisplayConfiguration. Passing a
/// connection ID as the first argument (a widely circulated variant) crashes:
/// the function dereferences it as a CGSConfigData pointer.
///
/// The symbol is loaded with dlopen/dlsym so a missing symbol after a macOS
/// update degrades gracefully instead of failing at link time.
final class SkyLight {
    static let shared = SkyLight()

    private let log = Logger(subsystem: kSubsystem, category: "skylight")

    private typealias ConfigureDisplayEnabledF = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32

    private typealias GetDisplayListF = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32

    private var configureDisplayEnabled: ConfigureDisplayEnabledF?
    private var getDisplayList: GetDisplayListF?

    private(set) var available = false
    private(set) var unavailableReason: String?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            unavailableReason = "cannot load SkyLight: \(err)"
            log.error("SkyLight unavailable: \(self.unavailableReason ?? "", privacy: .public)")
            return
        }
        guard let cfgSym = dlsym(handle, "SLSConfigureDisplayEnabled") else {
            unavailableReason = "SLSConfigureDisplayEnabled missing (private API may have changed in this macOS version)"
            log.error("SkyLight unavailable: \(self.unavailableReason ?? "", privacy: .public)")
            return
        }
        configureDisplayEnabled = unsafeBitCast(cfgSym, to: ConfigureDisplayEnabledF.self)
        // Optional: only used to find a soft-disabled display under a new ID.
        if let listSym = dlsym(handle, "SLSGetDisplayList") {
            getDisplayList = unsafeBitCast(listSym, to: GetDisplayListF.self)
        }
        available = true
        log.debug("SkyLight symbols resolved")
    }

    /// Enable or disable a display at the WindowServer level. Works on the
    /// persisted display ID even while the display is offline.
    @discardableResult
    func setDisplay(_ displayID: UInt32, enabled: Bool) -> Bool {
        guard available, let configure = configureDisplayEnabled else {
            log.error("setDisplay(\(displayID), \(enabled)): SkyLight unavailable")
            return false
        }
        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let config else {
            log.error("CGBeginDisplayConfiguration failed: \(beginErr.rawValue)")
            return false
        }
        let err = configure(config, displayID, enabled)
        guard err == 0 else {
            log.error("SLSConfigureDisplayEnabled(\(displayID), \(enabled)) failed: CGError \(err)")
            CGCancelDisplayConfiguration(config)
            return false
        }
        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        if completeErr == .success {
            log.notice("display \(displayID) \(enabled ? "enabled" : "disabled", privacy: .public)")
            return true
        } else {
            log.error("CGCompleteDisplayConfiguration failed: \(completeErr.rawValue)")
            return false
        }
    }

    /// Every display WindowServer knows about, *including* soft-disabled ones
    /// (which CGGetOnlineDisplayList hides). Also lists empty framebuffers;
    /// those report vendor/model 0. Empty if the symbol is missing.
    func allDisplayIDs() -> [UInt32] {
        guard let getDisplayList else { return [] }
        var ids = [UInt32](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard getDisplayList(16, &ids, &count) == 0 else { return [] }
        return Array(ids.prefix(Int(min(count, 16))))
    }
}
