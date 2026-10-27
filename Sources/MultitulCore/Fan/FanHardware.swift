import Foundation
import MultitulCtlCore

public protocol FanHardware: AnyObject {
    func detect() -> FanDetection
    func readFans() -> [FanReading]?
    func readThermal() -> FanThermal?
}

public protocol FanApplying: AnyObject {
    func setAuto(index: Int?) throws
    func setRpm(index: Int, rpm: Int) throws
}

public protocol FanClock: AnyObject {
    var now: TimeInterval { get }
}

public final class FanSystemClock: FanClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// Unprivileged reads over any SmcReading; the live one is SmcIOKitDevice(readOnly: true).
public final class FanSmcHardware: FanHardware {
    private let smc: SmcReading
    private var smcFans: [SmcFanInfo] = []
    private var cpuKeys: [String]?
    private var gpuKeys: [String] = []

    public init(smc: SmcReading) { self.smc = smc }

    public func detect() -> FanDetection {
        do {
            smcFans = try SmcFanDiscovery.discover(smc)
            return .fans(smcFans.map { FanInfo(index: $0.index, minRpm: $0.minRpm, maxRpm: $0.maxRpm) })
        } catch SmcFanError.noFans {
            smcFans = []
            return .noFans
        } catch {
            smcFans = []
            return .unsupported("\(error)")
        }
    }

    public func readFans() -> [FanReading]? {
        guard !smcFans.isEmpty else { return nil }
        var out: [FanReading] = []
        for f in smcFans {
            guard let ac = smc.readValue(SmcKeyName.fan(f.index, "Ac")), let tg = smc.readValue(SmcKeyName.fan(f.index, "Tg")),
                  ac.isFinite, tg.isFinite, ac >= 0, tg >= 0, ac <= 20000, tg <= 20000,
                  let manual = SmcFanDiscovery.isManual(f, smc) else { return nil }
            out.append(FanReading(index: f.index, actual: ac, target: tg, manual: manual))
        }
        return out
    }

    public func readThermal() -> FanThermal? {
        if cpuKeys == nil {
            let names = smc.allKeyNames()
            cpuKeys = names.filter(TemperatureSelector.isCPUKey)
            gpuKeys = names.filter(TemperatureSelector.isGPUKey)
        }
        guard let cpuKeys, !(cpuKeys.isEmpty && gpuKeys.isEmpty) else { return nil }
        return FanThermal(cpu: cpuKeys.compactMap { smc.readValue($0) }, gpu: gpuKeys.compactMap { smc.readValue($0) })
    }
}

public final class FanUnavailableHardware: FanHardware {
    public init() {}
    public func detect() -> FanDetection { .unsupported("AppleSMC недоступен") }
    public func readFans() -> [FanReading]? { nil }
    public func readThermal() -> FanThermal? { nil }
}

public final class FanCtlApplier: FanApplying {
    private let ctl: PrivilegedCtl
    private let timeout: TimeInterval

    public init(ctl: PrivilegedCtl = PrivilegedCtl(), timeout: TimeInterval = 15) {
        self.ctl = ctl
        self.timeout = timeout
    }

    public func setAuto(index: Int?) throws {
        try ctl.fanAuto(index.map { .index($0) } ?? .all, timeout: timeout)
    }

    public func setRpm(index: Int, rpm: Int) throws {
        try ctl.fanSet(index: index, rpm: rpm, timeout: timeout)
    }
}

public extension FanEngine {
    // The only place that opens AppleSMC for fans; the app calls it, tests never do.
    static func live(notify: @escaping (String, String) -> Void) -> FanEngine {
        let hardware: FanHardware = SmcIOKitDevice(readOnly: true).map { FanSmcHardware(smc: $0) } ?? FanUnavailableHardware()
        return FanEngine(hardware: hardware, applier: FanCtlApplier(), store: FanSettingsStore(), notify: notify)
    }
}
