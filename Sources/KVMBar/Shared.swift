import Foundation

let kSubsystem = "dev.valerii.kvmbar"
let kBundleID = "dev.valerii.kvmbar"
let kCommandNotification = "dev.valerii.kvmbar.command"
let kSettingsChangedNotification = Notification.Name("dev.valerii.kvmbar.settingsChanged")

/// VCP feature code for input select (DDC/CI).
let kVCPInputSelect: UInt8 = 0x60

/// Dell vendor VCP code: KVM USB handoff. On the U2725QE, writing the target
/// input's code (e.g. 0x11 for HDMI) hands the USB hub/peripherals to that
/// input's computer. One-way: firmware accepts it only from the current USB
/// owner. Verified live on U2725QE (standard 0x60 is ACKed but ignored there).
let kVCPDellKVMUSB: UInt8 = 0xE8

/// MCCS "Ambient light sensor" — the monitor's own auto brightness. Low
/// nibble per spec: 0x01 = off, 0x02 = on. The U2725QE honors this one
/// (unlike input select) but keeps vendor flags in the high nibble: it reads
/// 0x91 with auto brightness off and 0x92 with it on, and clearing bit 0x80
/// makes the auto level go much darker — so writes preserve the high nibble.
let kVCPAmbientLightSensor: UInt8 = 0x66

var isBundledApp: Bool {
    Bundle.main.bundleIdentifier == kBundleID && Bundle.main.bundlePath.hasSuffix(".app")
}

// MARK: - About

let kAppVersion = "1.0"
let kAuthorName = "Valerii Bakalenko"
let kAuthorEmail = "valeriy.bakalenko@gmail.com"
let kAuthorLinkedInURLString = "https://www.linkedin.com/in/valerii-bakalenko/"
/// The About window shows a GitHub link automatically when this is non-nil.
let kProjectURLString: String? = "https://github.com/wishval/KVMBar"
