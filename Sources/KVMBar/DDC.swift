import Foundation
import IOKit
import os

/// DDC/CI over I2C on Apple Silicon, ported from the MIT-licensed m1ddc
/// project: find the external DCPAVServiceProxy in the IORegistry, create an
/// IOAVService for it, and talk DDC at chip address 0x37 / data address 0x51.
/// All private symbols are resolved at runtime via dlopen/dlsym.
final class DDC {
    static let shared = DDC()

    private let log = Logger(subsystem: kSubsystem, category: "ddc")

    private typealias CreateWithServiceF = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias I2CWriteF = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeRawPointer?, UInt32) -> IOReturn
    private typealias I2CReadF = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    private var createWithService: CreateWithServiceF?
    private var i2cWrite: I2CWriteF?
    private var i2cRead: I2CReadF?

    private(set) var symbolsAvailable = false
    private(set) var unavailableReason: String?

    private let chipAddress: UInt32 = 0x37
    private let dataAddress: UInt32 = 0x51

    struct VCPReply {
        let current: UInt16
        let max: UInt16

        /// Decoded input code for VCP 0x60. The Dell U2725QE packs the
        /// *active* input into the high byte (the low byte carries the other
        /// connected input); spec-following monitors use the low byte only.
        var inputCode: Int {
            let high = Int(current >> 8)
            return high != 0 ? high : Int(current & 0xFF)
        }
    }

    private init() {
        resolveSymbols()
    }

    // Verified on macOS 26.5: IOAVService* is exported by CoreDisplay (and
    // re-exported by SkyLight). Multiple candidates + RTLD_DEFAULT fallback so
    // a future relocation degrades to "unavailable", not a crash.
    private static let candidateImages = [
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
    ]

    private func resolveSymbols() {
        var handles = Self.candidateImages.compactMap { dlopen($0, RTLD_LAZY) }
        if let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) {
            handles.append(rtldDefault)
        }
        for handle in handles {
            guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
                  let write = dlsym(handle, "IOAVServiceWriteI2C"),
                  let read = dlsym(handle, "IOAVServiceReadI2C") else { continue }
            createWithService = unsafeBitCast(create, to: CreateWithServiceF.self)
            i2cWrite = unsafeBitCast(write, to: I2CWriteF.self)
            i2cRead = unsafeBitCast(read, to: I2CReadF.self)
            symbolsAvailable = true
            log.debug("IOAVService symbols resolved")
            return
        }
        unavailableReason = "IOAVService symbols not found (private API may have moved in this macOS version)"
        log.error("DDC unavailable: \(self.unavailableReason ?? "", privacy: .public)")
    }

    /// Finds the DCPAVServiceProxy for the external display. Caller must
    /// IOObjectRelease the returned entry.
    private func findExternalService() -> io_service_t? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else {
            log.error("IOServiceGetMatchingServices failed for DCPAVServiceProxy")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External" {
                return entry
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    /// True if an external DCPAVServiceProxy currently exists in the registry.
    func externalServicePresent() -> Bool {
        guard let entry = findExternalService() else { return false }
        IOObjectRelease(entry)
        return true
    }

    /// Creates a fresh IOAVService per operation — the underlying service dies
    /// when the display link drops, so caching a stale ref would fail anyway.
    private func withAVService<T>(_ body: (UnsafeMutableRawPointer) -> T?) -> T? {
        guard symbolsAvailable, let create = createWithService else {
            log.error("DDC operation skipped: symbols unavailable")
            return nil
        }
        guard let entry = findExternalService() else {
            log.info("DDC: no external DCPAVServiceProxy (display link down or no monitor)")
            return nil
        }
        defer { IOObjectRelease(entry) }
        guard let service = create(kCFAllocatorDefault, entry) else {
            log.error("IOAVServiceCreateWithService returned nil")
            return nil
        }
        defer { Unmanaged<AnyObject>.fromOpaque(service).release() }
        return body(service)
    }

    /// DDC/CI "Set VCP Feature" write. Packet layout and checksum per the
    /// DDC/CI spec, identical to m1ddc: 0x6E 0x51 [0x84 0x03 vcp hi lo chk].
    @discardableResult
    func writeVCP(_ code: UInt8, value: UInt16) -> Bool {
        let result: Bool? = withAVService { service in
            var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
            var checksum: UInt8 = 0x6E ^ 0x51
            for byte in packet.dropLast() { checksum ^= byte }
            packet[packet.count - 1] = checksum

            for attempt in 1...3 {
                let ret = packet.withUnsafeBytes {
                    self.i2cWrite!(service, self.chipAddress, self.dataAddress,
                                   $0.baseAddress, UInt32($0.count))
                }
                if ret == KERN_SUCCESS {
                    self.log.notice("VCP 0x\(String(code, radix: 16), privacy: .public) := \(value) (attempt \(attempt))")
                    return true
                }
                self.log.info("VCP write attempt \(attempt) failed: IOReturn \(ret)")
                usleep(20_000)
            }
            self.log.error("VCP 0x\(String(code, radix: 16), privacy: .public) := \(value) failed after 3 attempts")
            return false
        }
        return result ?? false
    }

    /// DDC/CI "Get VCP Feature" read. Returns nil when the monitor is
    /// unreachable (link down / showing another input on some scalers).
    func readVCP(_ code: UInt8) -> VCPReply? {
        let result: VCPReply?? = withAVService { service -> VCPReply? in
            var request: [UInt8] = [0x82, 0x01, code, 0]
            var checksum: UInt8 = 0x6E ^ 0x51
            for byte in request.dropLast() { checksum ^= byte }
            request[request.count - 1] = checksum

            let writeRet = request.withUnsafeBytes {
                self.i2cWrite!(service, self.chipAddress, self.dataAddress,
                               $0.baseAddress, UInt32($0.count))
            }
            guard writeRet == KERN_SUCCESS else {
                self.log.info("VCP read request failed: IOReturn \(writeRet)")
                return nil
            }
            usleep(50_000)

            var reply = [UInt8](repeating: 0, count: 11)
            let readRet = reply.withUnsafeMutableBytes {
                self.i2cRead!(service, self.chipAddress, self.dataAddress,
                              $0.baseAddress, UInt32($0.count))
            }
            guard readRet == KERN_SUCCESS else {
                self.log.info("VCP read reply failed: IOReturn \(readRet)")
                return nil
            }
            // Reply: 0x6E 0x88 0x02 result vcp type maxHi maxLo curHi curLo chk
            guard reply[2] == 0x02, reply[4] == code else {
                self.log.info("VCP read: unexpected reply header \(reply.map { String($0, radix: 16) }.joined(separator: " "), privacy: .public)")
                return nil
            }
            var replyChecksum: UInt8 = 0x50
            for byte in reply.dropLast() { replyChecksum ^= byte }
            if replyChecksum != reply[10] {
                self.log.info("VCP read: checksum mismatch (got \(reply[10]), expected \(replyChecksum)) — accepting anyway")
            }
            return VCPReply(current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                            max: UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return result ?? nil
    }
}
