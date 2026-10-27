import Foundation
import CoreGraphics

public struct DisplayIdentity: Equatable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var isBuiltin: Bool

    public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool = false) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
    }

    public var baseID: String {
        isBuiltin ? "builtin" : String(format: "%04x-%04x-%08x", vendor, model, serial)
    }
}

public enum BrightnessIDs {
    // Identical monitors without serials share a base id; the 2nd, 3rd... get -2, -3 in input order.
    public static func assign(_ identities: [DisplayIdentity]) -> [String] {
        var seen: [String: Int] = [:]
        return identities.map { identity in
            let base = identity.baseID
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)-\(n)"
        }
    }
}

public enum BrightnessMethod: String, Equatable, Sendable {
    case builtin, ddc, software, unavailable

    public var title: String {
        switch self {
        case .builtin: "встроенный"
        case .ddc: "DDC"
        case .software: "программно"
        case .unavailable: "недоступно"
        }
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public var cgID: UInt32
    public var identity: DisplayIdentity
    public var isMain: Bool
    public var frame: CGRect
    public var name: String

    public init(cgID: UInt32, identity: DisplayIdentity, isMain: Bool = false, frame: CGRect = .zero, name: String = "") {
        self.cgID = cgID
        self.identity = identity
        self.isMain = isMain
        self.frame = frame
        self.name = name
    }

    public var isBuiltin: Bool { identity.isBuiltin }
}

public struct AvServiceInfo: Equatable, Sendable {
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32

    public init(vendor: UInt32, product: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }
}

public enum EdidVendor {
    // Three EDID PNP letters pack into 15 bits; CGDisplayVendorNumber reports the same value.
    public static func code(_ letters: String) -> UInt32? {
        let scalars = Array(letters.uppercased().unicodeScalars)
        guard scalars.count == 3, scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 5) | ($1.value - 64) }
    }
}

public enum AvServiceMatcher {
    public static func score(display: DisplayIdentity, service: AvServiceInfo) -> Int {
        var s = 0
        if display.vendor != 0, display.vendor == service.vendor { s += 4 }
        if display.model != 0, display.model == service.product { s += 4 }
        if display.serial != 0, display.serial == service.serial { s += 8 }
        return s
    }

    // Returns display index -> service index. Highest scores first; a lone display with a lone service pairs even without a score.
    public static func assign(displays: [DisplayIdentity], services: [AvServiceInfo]) -> [Int: Int] {
        var pairs: [(d: Int, s: Int, score: Int)] = []
        for (di, d) in displays.enumerated() {
            for (si, s) in services.enumerated() {
                let sc = score(display: d, service: s)
                if sc >= 8 { pairs.append((di, si, sc)) }
            }
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.d, $0.s) < ($1.d, $1.s) }
        var out: [Int: Int] = [:]
        var usedServices = Set<Int>()
        for p in pairs where out[p.d] == nil && !usedServices.contains(p.s) {
            out[p.d] = p.s
            usedServices.insert(p.s)
        }
        let freeDisplays = displays.indices.filter { out[$0] == nil }
        let freeServices = services.indices.filter { !usedServices.contains($0) }
        if freeDisplays.count == 1, freeServices.count == 1 { out[freeDisplays[0]] = freeServices[0] }
        return out
    }
}
