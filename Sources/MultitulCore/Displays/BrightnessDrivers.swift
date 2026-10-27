import Foundation
import AppKit
import CoreGraphics
import IOKit
import ObjectiveC

public enum LiveDisplayEnumerator {
    // Main thread only: names come from NSScreen.
    public static func snapshots() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        var names: [UInt32: String] = [:]
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        for s in NSScreen.screens {
            if let n = s.deviceDescription[numberKey] as? NSNumber { names[n.uint32Value] = s.localizedName }
        }
        return ids.prefix(Int(count)).map { id in
            let identity = DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), isBuiltin: CGDisplayIsBuiltin(id) != 0)
            return DisplaySnapshot(cgID: id, identity: identity, isMain: CGDisplayIsMain(id) != 0, frame: CGDisplayBounds(id), name: names[id] ?? "Дисплей \(id)")
        }
    }
}

final class DisplayServicesAPI {
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    static let shared = DisplayServicesAPI()

    let getFn: GetFn?
    let setFn: SetFn?

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = h.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = h.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    var available: Bool { getFn != nil && setFn != nil }
}

public final class DisplayServicesBackend: BrightnessBackend {
    private let cgID: UInt32
    public init(cgID: UInt32) { self.cgID = cgID }

    public var method: BrightnessMethod { .builtin }

    public func probe() -> Bool { read() != nil }

    public func read() -> Double? {
        guard let get = DisplayServicesAPI.shared.getFn else { return nil }
        var v: Float = 0
        guard get(cgID, &v) == 0, v.isFinite else { return nil }
        return BrightnessStep.clamp(Double(v))
    }

    public func write(_ value: Double) -> Bool {
        guard let set = DisplayServicesAPI.shared.setFn else { return false }
        return set(cgID, Float(BrightnessStep.clamp(value))) == 0
    }

    public func release() {}
}

public final class GammaBackend: BrightnessBackend {
    private let cgID: UInt32
    private let floor: Double
    private var original: (r: [Float], g: [Float], b: [Float])?
    private var touched = false

    public init(cgID: UInt32, floor: Double) {
        self.cgID = cgID
        self.floor = floor
        original = Self.capture(cgID)
    }

    private static func capture(_ id: UInt32) -> (r: [Float], g: [Float], b: [Float])? {
        var r = [Float](repeating: 0, count: GammaMath.tableSize)
        var g = r, b = r
        var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(GammaMath.tableSize), &r, &g, &b, &n) == .success, n > 0 else { return nil }
        return (Array(r.prefix(Int(n))), Array(g.prefix(Int(n))), Array(b.prefix(Int(n))))
    }

    public var method: BrightnessMethod { .software }
    public func probe() -> Bool { true }
    public func read() -> Double? { nil }

    public func write(_ value: Double) -> Bool {
        let factor = GammaMath.dimFactor(for: value, floor: floor)
        let base = original ?? (GammaMath.identityTable(), GammaMath.identityTable(), GammaMath.identityTable())
        let r = GammaMath.scaled(base.r, factor: factor), g = GammaMath.scaled(base.g, factor: factor), b = GammaMath.scaled(base.b, factor: factor)
        touched = true
        return CGSetDisplayTransferByTable(cgID, UInt32(r.count), r, g, b) == .success
    }

    public func release() {
        guard touched else { return }
        touched = false
        if let o = original { _ = CGSetDisplayTransferByTable(cgID, UInt32(o.r.count), o.r, o.g, o.b) } else { CGDisplayRestoreColorSyncSettings() }
    }

    public static func restoreAll() { CGDisplayRestoreColorSyncSettings() }
}

final class IOAVAPI {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> Int32
    static let shared = IOAVAPI()

    let create: CreateFn?
    let readI2C: ReadFn?
    let writeI2C: WriteFn?

    private init() {
        let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func sym(_ n: String) -> UnsafeMutableRawPointer? { h.flatMap { dlsym($0, n) } ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), n) }
        create = sym("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        readI2C = sym("IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadFn.self) }
        writeI2C = sym("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
    }

    var available: Bool { create != nil && readI2C != nil && writeI2C != nil }
}

public final class AvServiceTransport: DdcTransport {
    private let service: CFTypeRef
    init(service: CFTypeRef) { self.service = service }

    public func write(_ bytes: [UInt8]) -> Bool {
        guard let w = IOAVAPI.shared.writeI2C else { return false }
        return bytes.withUnsafeBytes { w(service, DdcPacket.chipAddress, DdcPacket.dataAddress, $0.baseAddress!, UInt32(bytes.count)) } == 0
    }

    public func read(length: Int) -> [UInt8]? {
        guard let r = IOAVAPI.shared.readI2C else { return nil }
        var buf = [UInt8](repeating: 0, count: length)
        let rc = buf.withUnsafeMutableBytes { r(service, DdcPacket.chipAddress, DdcPacket.dataAddress, $0.baseAddress!, UInt32(length)) }
        return rc == 0 ? buf : nil
    }
}

struct AvServiceEntry {
    var info: AvServiceInfo
    var service: CFTypeRef
}

enum AvServiceRegistry {
    static func discover() -> [AvServiceEntry] {
        guard let create = IOAVAPI.shared.create else { return [] }
        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var last: AvServiceInfo?
        var out: [AvServiceEntry] = []
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            let name = entryName(entry)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                last = attributes(entry)
            } else if name == "DCPAVServiceProxy", property(entry, "Location") as? String == "External",
                      let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                out.append(AvServiceEntry(info: last ?? AvServiceInfo(vendor: 0, product: 0, serial: 0), service: svc))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return out
    }

    private static func entryName(_ e: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(e, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    private static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func attributes(_ e: io_registry_entry_t) -> AvServiceInfo? {
        guard let d = property(e, "DisplayAttributes") as? [String: Any], let p = d["ProductAttributes"] as? [String: Any] else { return nil }
        let vendor = (p["ManufacturerID"] as? String).flatMap(EdidVendor.code) ?? 0
        func num(_ k: String) -> UInt32 { (p[k] as? NSNumber)?.uint32Value ?? 0 }
        return AvServiceInfo(vendor: vendor, product: num("ProductID"), serial: num("SerialNumber"))
    }
}

public final class DdcBackend: BrightnessBackend, PowerBackend, ContrastBackend {
    private let client: DdcClient
    private var brightnessMax: UInt16 = 100
    private var contrastMax: UInt16 = 100
    private var outcome: DdcChannelOutcome = .dead
    private var lastRead: Double?

    init(service: CFTypeRef, timing: DdcTiming = .standard) {
        client = DdcClient(transport: AvServiceTransport(service: service), timing: timing)
    }

    public init(client: DdcClient) { self.client = client }

    public var method: BrightnessMethod { .ddc }
    public var channel: DdcChannelOutcome { outcome }

    public func probe() -> Bool {
        let p = client.probe()
        outcome = p.outcome
        if let m = p.maximum { brightnessMax = DdcScale.sanitizedMaximum(m) }
        if let c = p.current { lastRead = DdcScale.normalized(current: c, maximum: brightnessMax) }
        return outcome != .dead
    }

    public func read() -> Double? { lastRead }

    public func write(_ value: Double) -> Bool {
        client.write(VcpCode.brightness, value: DdcScale.deviceValue(for: value, maximum: brightnessMax))
    }

    public func release() {}

    public func setPower(_ on: Bool) -> Bool {
        client.write(VcpCode.power, value: (on ? DdcPowerState.on : DdcPowerState.standby).rawValue)
    }

    public func readContrast() -> Double? {
        guard case .value(let c, let m) = client.read(VcpCode.contrast).result else { return nil }
        contrastMax = DdcScale.sanitizedMaximum(m)
        return DdcScale.normalized(current: c, maximum: contrastMax)
    }

    public func writeContrast(_ value: Double) -> Bool {
        client.write(VcpCode.contrast, value: DdcScale.deviceValue(for: value, maximum: contrastMax))
    }
}

public final class LiveBrightnessFactory: BrightnessBackendFactory {
    private var services: [UInt32: CFTypeRef] = [:]

    public init() {}

    public func prepare(_ displays: [DisplaySnapshot]) {
        services = [:]
        let externals = displays.filter { !$0.isBuiltin }
        guard !externals.isEmpty, IOAVAPI.shared.available else { return }
        let found = AvServiceRegistry.discover()
        let map = AvServiceMatcher.assign(displays: externals.map(\.identity), services: found.map(\.info))
        for (di, si) in map { services[externals[di].cgID] = found[si].service }
    }

    public func candidates(for display: DisplaySnapshot, forceSoftware: Bool, softwareFloor: Double) -> [BrightnessBackend] {
        let gamma = GammaBackend(cgID: display.cgID, floor: softwareFloor)
        if forceSoftware { return [gamma] }
        var list: [BrightnessBackend] = []
        if display.isBuiltin || display.identity.vendor == 1552 { list.append(DisplayServicesBackend(cgID: display.cgID)) }
        if !display.isBuiltin, let s = services[display.cgID] { list.append(DdcBackend(service: s)) }
        list.append(gamma)
        return list
    }
}

public final class CoreBrightnessKeyboard: KeyboardBacklighting {
    private var client: NSObject?
    private var keyboardID: UInt64 = 1
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private var getter: GetFn?
    private var setter: SetFn?

    public init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let obj = cls.init()
        let getSel = NSSelectorFromString("brightnessForKeyboard:")
        let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard obj.responds(to: getSel), obj.responds(to: setSel),
              let gi = class_getMethodImplementation(type(of: obj), getSel), let si = class_getMethodImplementation(type(of: obj), setSel) else { return }
        getter = unsafeBitCast(gi, to: GetFn.self)
        setter = unsafeBitCast(si, to: SetFn.self)
        client = obj
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if obj.responds(to: idsSel), let ids = obj.perform(idsSel)?.takeRetainedValue() as? [NSNumber], let first = ids.first { keyboardID = first.uint64Value }
    }

    public var isAvailable: Bool { client != nil && level() != nil }

    public func level() -> Double? {
        guard let client, let getter else { return nil }
        let v = getter(client, NSSelectorFromString("brightnessForKeyboard:"), keyboardID)
        guard v.isFinite, v >= 0, v <= 1 else { return nil }
        return Double(v)
    }

    public func setLevel(_ v: Double) -> Bool {
        guard let client, let setter else { return false }
        return setter(client, NSSelectorFromString("setBrightness:forKeyboard:"), Float(BrightnessStep.clamp(v)), keyboardID)
    }
}
