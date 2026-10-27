import Foundation

public struct SmcFanInfo: Equatable, Sendable {
    public var index: Int
    public var minRpm: Double
    public var maxRpm: Double
    public var targetType: String
    public var targetSize: Int
    public var modeKey: String?
    public var canStop: Bool { minRpm <= 0 }
}

public enum SmcFanError: Error, Equatable, CustomStringConvertible, Sendable {
    case noFans
    case unsupported(String)
    case badIndex(Int)
    case stopNotSupported(Int)
    case writeFailed(String)
    case verifyFailed(String)

    public var description: String {
        switch self {
        case .noFans: return "no fans on this Mac"
        case .unsupported(let m): return "unsupported: \(m)"
        case .badIndex(let i): return "no fan with index \(i)"
        case .stopNotSupported(let m): return "fan cannot stop: its minimum is \(m) rpm"
        case .writeFailed(let m): return "SMC write failed: \(m)"
        case .verifyFailed(let m): return "SMC readback differs: \(m)"
        }
    }
}

public final class SmcFanService {
    public static let maskKey = "FS! "
    public static let testKey = "Ftst"
    public static let maxFans = 10
    public static let targetTolerance = 10.0

    private let smc: SmcWriting
    private let sleeper: (TimeInterval) -> Void
    private let unlockAttempts: Int
    private let retryDelay: TimeInterval

    public init(smc: SmcWriting, sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                unlockAttempts: Int = 50, retryDelay: TimeInterval = 0.1) {
        self.smc = smc
        self.sleeper = sleeper
        self.unlockAttempts = max(1, unlockAttempts)
        self.retryDelay = retryDelay
    }

    public func discover() throws -> [SmcFanInfo] { try SmcFanDiscovery.discover(smc) }

    public func isManual(_ fan: SmcFanInfo) -> Bool? { SmcFanDiscovery.isManual(fan, smc) }

    public func setAuto(_ selector: FanSelector) throws {
        let fans = try discover()
        var targets = fans
        if case .index(let i) = selector {
            guard let f = fans.first(where: { $0.index == i }) else { throw SmcFanError.badIndex(i) }
            targets = [f]
        }
        var failures: [String] = []
        for fan in targets {
            do { try clearManual(fan) } catch { failures.append("fan \(fan.index): \(error)") }
        }
        releaseTest(force: selector == .all, fans: fans)
        if !failures.isEmpty { throw SmcFanError.writeFailed(failures.joined(separator: "; ")) }
    }

    public func setManual(index: Int) throws {
        let fan = try fan(index)
        do {
            try enterManual(fan)
            let ac = smc.readValue(SmcKeyName.fan(index, "Ac")) ?? fan.minRpm
            try writeTarget(fan, Self.clamp(ac, fan))
        } catch {
            try? setAuto(.index(index))
            throw error
        }
    }

    @discardableResult
    public func setRpm(index: Int, rpm: Int) throws -> Int {
        let fan = try fan(index)
        let applied: Double
        if rpm == 0 {
            guard fan.canStop else { throw SmcFanError.stopNotSupported(Int(fan.minRpm.rounded())) }
            applied = 0
        } else {
            applied = Self.clamp(Double(rpm), fan)
        }
        do {
            try enterManual(fan)
            try writeTarget(fan, applied)
        } catch {
            try? setAuto(.index(index))
            throw error
        }
        return Int(applied.rounded())
    }

    public static func clamp(_ rpm: Double, _ fan: SmcFanInfo) -> Double {
        min(max(rpm, fan.minRpm), fan.maxRpm)
    }

    private func fan(_ index: Int) throws -> SmcFanInfo {
        guard let f = try discover().first(where: { $0.index == index }) else { throw SmcFanError.badIndex(index) }
        return f
    }

    private func readMask() -> UInt16? {
        guard let b = smc.readBytes(Self.maskKey), b.count == 2 else { return nil }
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private func writeMask(_ mask: UInt16) -> Bool {
        smc.writeBytes(Self.maskKey, [UInt8(mask >> 8), UInt8(mask & 0xff)]) && readMask() == mask
    }

    private func testValue() -> Double? { smc.keyInfo(Self.testKey) == nil ? nil : smc.readValue(Self.testKey) }

    private func enterManual(_ fan: SmcFanInfo) throws {
        if isManual(fan) == true { return }
        guard let key = fan.modeKey else {
            guard let mask = readMask() else { throw SmcFanError.writeFailed("cannot read FS!") }
            guard writeMask(mask | (1 << UInt16(fan.index))) else { throw SmcFanError.verifyFailed("FS! bit \(fan.index)") }
            return
        }
        if let t = testValue(), t != 1 {
            guard smc.writeBytes(Self.testKey, [1]) else { throw SmcFanError.writeFailed(Self.testKey) }
        }
        for attempt in 0..<unlockAttempts {
            if smc.writeBytes(key, [1]), isManual(fan) == true { return }
            if attempt + 1 < unlockAttempts { sleeper(retryDelay) }
        }
        _ = smc.writeBytes(key, [0])
        releaseTest(force: false, fans: (try? discover()) ?? [])
        throw SmcFanError.verifyFailed("\(key) did not switch to manual")
    }

    private func clearManual(_ fan: SmcFanInfo) throws {
        if let key = fan.modeKey {
            for attempt in 0..<3 {
                if smc.writeBytes(key, [0]), isManual(fan) == false { return }
                if attempt < 2 { sleeper(retryDelay) }
            }
            throw SmcFanError.verifyFailed("\(key) stays manual")
        }
        guard let mask = readMask() else { throw SmcFanError.writeFailed("cannot read FS!") }
        let cleared = mask & ~(1 << UInt16(fan.index))
        if cleared == mask { return }
        guard writeMask(cleared) else { throw SmcFanError.verifyFailed("FS! bit \(fan.index)") }
    }

    private func releaseTest(force: Bool, fans: [SmcFanInfo]) {
        guard let t = testValue(), t != 0 else { return }
        if !force, fans.contains(where: { isManual($0) != false }) { return }
        _ = smc.writeBytes(Self.testKey, [0])
    }

    private func writeTarget(_ fan: SmcFanInfo, _ rpm: Double) throws {
        let key = SmcKeyName.fan(fan.index, "Tg")
        guard let bytes = SmcCodec.encode(rpm, type: fan.targetType, size: fan.targetSize) else {
            throw SmcFanError.unsupported("cannot encode \(rpm) as \(fan.targetType)")
        }
        for attempt in 0..<3 {
            if smc.writeBytes(key, bytes), let now = smc.readValue(key), abs(now - rpm) <= Self.targetTolerance { return }
            if attempt < 2 { sleeper(retryDelay) }
        }
        throw SmcFanError.verifyFailed("\(key) != \(Int(rpm.rounded()))")
    }
}

public enum SmcFanDiscovery {
    public static func discover(_ smc: SmcReading) throws -> [SmcFanInfo] {
        guard smc.keyInfo("FNum") != nil, let n = smc.readValue("FNum") else { throw SmcFanError.noFans }
        guard n == n.rounded(), n >= 0, n <= Double(SmcFanService.maxFans) else { throw SmcFanError.unsupported("FNum = \(n)") }
        if n == 0 { throw SmcFanError.noFans }
        var fans: [SmcFanInfo] = []
        for i in 0..<Int(n) {
            guard let mn = smc.readValue(SmcKeyName.fan(i, "Mn")), let mx = smc.readValue(SmcKeyName.fan(i, "Mx")),
                  let tg = smc.keyInfo(SmcKeyName.fan(i, "Tg")) else { throw SmcFanError.unsupported("fan \(i) lacks Mn/Mx/Tg") }
            guard mn >= 0, mx > mn, mx <= 10000 else { throw SmcFanError.unsupported("fan \(i) bounds \(mn)...\(mx)") }
            guard SmcCodec.encode(mx, type: tg.type, size: tg.size) != nil else {
                throw SmcFanError.unsupported("fan \(i) target type \(tg.type)")
            }
            var modeKey: String?
            for name in [SmcKeyName.fan(i, "Md"), SmcKeyName.fan(i, "md")] where modeKey == nil {
                if let info = smc.keyInfo(name), info.size == 1, smc.readBytes(name) != nil { modeKey = name }
            }
            if modeKey == nil {
                guard let mask = smc.keyInfo(SmcFanService.maskKey), mask.size == 2, smc.readBytes(SmcFanService.maskKey) != nil else {
                    throw SmcFanError.unsupported("fan \(i) has neither F\(i)Md nor FS!")
                }
            }
            fans.append(SmcFanInfo(index: i, minRpm: mn, maxRpm: mx, targetType: tg.type, targetSize: tg.size, modeKey: modeKey))
        }
        return fans
    }

    public static func isManual(_ fan: SmcFanInfo, _ smc: SmcReading) -> Bool? {
        if let key = fan.modeKey {
            guard let b = smc.readBytes(key), b.count == 1 else { return nil }
            return b[0] != 0
        }
        guard let b = smc.readBytes(SmcFanService.maskKey), b.count == 2 else { return nil }
        let mask = UInt16(b[0]) << 8 | UInt16(b[1])
        return mask & (1 << UInt16(fan.index)) != 0
    }
}
