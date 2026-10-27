import Foundation
import IOKit

private struct SmcWire {
    var key: UInt32 = 0
    var versMajor: UInt8 = 0
    var versMinor: UInt8 = 0
    var versBuild: UInt8 = 0
    var versReserved: UInt8 = 0
    var versRelease: UInt16 = 0
    var padA: UInt16 = 0
    var limitVersion: UInt16 = 0
    var limitLength: UInt16 = 0
    var limitCPU: UInt32 = 0
    var limitGPU: UInt32 = 0
    var limitMem: UInt32 = 0
    var infoSize: UInt32 = 0
    var infoType: UInt32 = 0
    var infoAttributes: UInt8 = 0
    var padB: UInt8 = 0
    var padC: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padD: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

public enum SmcWireLayout {
    public static var size: Int { MemoryLayout<SmcWire>.size }
    public static var stride: Int { MemoryLayout<SmcWire>.stride }
    public static var infoSizeOffset: Int? { MemoryLayout<SmcWire>.offset(of: \.infoSize) }
    public static var resultOffset: Int? { MemoryLayout<SmcWire>.offset(of: \.result) }
    public static var data8Offset: Int? { MemoryLayout<SmcWire>.offset(of: \.data8) }
    public static var data32Offset: Int? { MemoryLayout<SmcWire>.offset(of: \.data32) }
    public static var bytesOffset: Int? { MemoryLayout<SmcWire>.offset(of: \.bytes) }
}

// Opens AppleSMC on init. Never constructed by tests: they use fakes of SmcReading/SmcWriting.
public final class SmcIOKitDevice: SmcWriting, @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let readOnly: Bool
    private static let selector: UInt32 = 2
    private static let cmdRead: UInt8 = 5
    private static let cmdWrite: UInt8 = 6
    private static let cmdKeyAt: UInt8 = 8
    private static let cmdInfo: UInt8 = 9

    public init?(readOnly: Bool) {
        self.readOnly = readOnly
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout SmcWire) -> SmcWire? {
        var output = SmcWire()
        var outSize = MemoryLayout<SmcWire>.stride
        let kr = IOConnectCallStructMethod(connection, Self.selector, &input, MemoryLayout<SmcWire>.stride, &output, &outSize)
        return kr == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    public func keyInfo(_ name: String) -> SmcKeyInfo? {
        guard let code = SmcKeyName.fourCC(name) else { return nil }
        var input = SmcWire()
        input.key = code
        input.data8 = Self.cmdInfo
        guard let out = call(&input), out.infoSize > 0, out.infoSize <= 32 else { return nil }
        return SmcKeyInfo(size: Int(out.infoSize), type: SmcKeyName.string(out.infoType))
    }

    public func readBytes(_ name: String) -> [UInt8]? {
        guard let code = SmcKeyName.fourCC(name), let info = keyInfo(name) else { return nil }
        var input = SmcWire()
        input.key = code
        input.infoSize = UInt32(info.size)
        input.data8 = Self.cmdRead
        guard let out = call(&input) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(info.size)) }
    }

    public func writeBytes(_ name: String, _ bytes: [UInt8]) -> Bool {
        guard !readOnly, let code = SmcKeyName.fourCC(name), let info = keyInfo(name),
              info.size == bytes.count, bytes.count <= 32 else { return false }
        var input = SmcWire()
        input.key = code
        input.infoSize = UInt32(info.size)
        input.data8 = Self.cmdWrite
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        return call(&input) != nil
    }

    public func allKeyNames() -> [String] {
        var input = SmcWire()
        input.key = SmcKeyName.fourCC("#KEY") ?? 0
        input.infoSize = 4
        input.data8 = Self.cmdRead
        guard let out = call(&input) else { return [] }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(4)) }
        let count = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        var names: [String] = []
        for index in 0..<min(count, 20000) {
            var probe = SmcWire()
            probe.data8 = Self.cmdKeyAt
            probe.data32 = UInt32(index)
            if let o = call(&probe) { names.append(SmcKeyName.string(o.key)) }
        }
        return names
    }
}
