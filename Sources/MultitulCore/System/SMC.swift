import Foundation
import IOKit

public enum SMCValueCodec {
    public static func decode(_ b: [UInt8], type: String) -> Double? {
        let t = type.trimmingCharacters(in: .whitespaces)
        switch t {
        case "flt":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8", "flag":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        case "si8":
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "ui64":
            guard b.count >= 8 else { return nil }
            return Double(b.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            return fixedPoint(b, type: t)
        }
    }

    static func fixedPoint(_ b: [UInt8], type t: String) -> Double? {
        guard t.count == 4, b.count >= 2 else { return nil }
        let chars = Array(t)
        let signed: Bool
        switch String(chars[0..<2]) {
        case "fp": signed = false
        case "sp": signed = true
        default: return nil
        }
        guard let frac = chars[3].hexDigitValue, chars[2].hexDigitValue != nil else { return nil }
        let raw = UInt16(b[0]) << 8 | UInt16(b[1])
        let value = signed ? Double(Int16(bitPattern: raw)) : Double(raw)
        return value / Double(1 << frac)
    }
}

public struct TemperatureSensors: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var battery: Double?
}

public enum TemperatureSelector {
    public static func isCPUKey(_ name: String) -> Bool {
        if name.hasPrefix("Tp") || name.hasPrefix("Te") { return name.count == 4 }
        if name.hasPrefix("TC") && name.count == 4 { return true }
        return false
    }

    public static func isGPUKey(_ name: String) -> Bool {
        (name.hasPrefix("Tg") || name.hasPrefix("TG")) && name.count == 4
    }

    public static func isBatteryKey(_ name: String) -> Bool {
        guard name.count == 4, name.hasPrefix("TB"), name.hasSuffix("T") else { return false }
        return name[name.index(name.startIndex, offsetBy: 2)].isNumber
    }

    public static func isInteresting(_ name: String) -> Bool {
        isCPUKey(name) || isGPUKey(name) || isBatteryKey(name)
    }

    public static func plausible(_ v: Double) -> Bool { v > 1 && v < 125 }

    public static func hottest(_ values: [Double]) -> Double? {
        values.filter(plausible).max()
    }

    public static func isDieKey(_ name: String) -> Bool {
        name.count == 4 && (name.hasPrefix("Tp") || name.hasPrefix("Te"))
    }

    public static func displayPlausible(_ v: Double) -> Bool { v > 5 && v < 110 }

    public static func cpuDisplay(_ readings: [(name: String, value: Double)]) -> Double? {
        let cpu = readings.filter { isCPUKey($0.name) }
        let die = cpu.filter { isDieKey($0.name) }
        let v = (die.isEmpty ? cpu : die).map(\.value).filter(displayPlausible)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    public static func classify(_ readings: [(name: String, value: Double)]) -> TemperatureSensors {
        TemperatureSensors(
            cpu: cpuDisplay(readings),
            gpu: hottest(readings.filter { isGPUKey($0.name) }.map(\.value)),
            battery: hottest(readings.filter { isBatteryKey($0.name) }.map(\.value)))
    }
}

struct SMCKeyData {
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

public struct SMCKey: Sendable {
    public let code: UInt32
    public let name: String
    public let size: UInt32
    public let type: String
}

public enum SMCCodes {
    public static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    public static func string(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }
}

public final class SMCClient {
    private var connection: io_connect_t = 0
    private static let selector: UInt32 = 2
    private static let cmdRead: UInt8 = 5
    private static let cmdKeyAt: UInt8 = 8
    private static let cmdInfo: UInt8 = 9

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(connection, Self.selector, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        return kr == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func keyCount() -> Int {
        var input = SMCKeyData()
        input.key = SMCCodes.fourCC("#KEY")
        input.infoSize = 4
        input.data8 = Self.cmdRead
        guard let out = call(&input) else { return 0 }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(4)) }
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    public func keys(where filter: (String) -> Bool) -> [SMCKey] {
        var result: [SMCKey] = []
        for index in 0..<keyCount() {
            var probe = SMCKeyData()
            probe.data8 = Self.cmdKeyAt
            probe.data32 = UInt32(index)
            guard let out = call(&probe) else { continue }
            let name = SMCCodes.string(out.key)
            guard filter(name) else { continue }
            var info = SMCKeyData()
            info.key = out.key
            info.data8 = Self.cmdInfo
            guard let i = call(&info) else { continue }
            result.append(SMCKey(code: out.key, name: name, size: i.infoSize, type: SMCCodes.string(i.infoType)))
        }
        return result
    }

    public func read(_ key: SMCKey) -> Double? {
        guard key.size > 0, key.size <= 32 else { return nil }
        var input = SMCKeyData()
        input.key = key.code
        input.infoSize = key.size
        input.data8 = Self.cmdRead
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(key.size))) }
        return SMCValueCodec.decode(bytes, type: key.type)
    }
}
