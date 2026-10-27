import Foundation

public protocol SystemSource: AnyObject {
    func psText() -> String
    func vmPages() -> VMPages?
    func swapUsedMB() -> Double?
    func pressureLevel() -> Int?
    func idleSeconds() -> Double?
    func pmsetText() -> String
    func topPowerText() -> String
    func batteryRegistry() -> [String: Any]?
    func thermalState() -> Int
    func diskFreeGB() -> Double?
    func cpuTicks() -> CPUTicks?
    func temperatures() -> TemperatureReading
    func totalMemoryBytes() -> UInt64
}

public final class TemperatureProbe {
    private var smc: SMCClient?
    private var keys: [SMCKey] = []
    private var prepared = false

    public init() {}

    public func read() -> TemperatureReading {
        if !prepared {
            prepared = true
            smc = SMCClient()
            keys = smc?.keys(where: TemperatureSelector.isInteresting) ?? []
        }
        guard let smc, !keys.isEmpty else { return TemperatureReading() }
        let readings: [(name: String, value: Double)] = keys.compactMap { k in
            smc.read(k).map { (name: k.name, value: $0) }
        }
        let t = TemperatureSelector.classify(readings)
        return TemperatureReading(cpu: t.cpu, gpu: t.gpu, battery: t.battery)
    }
}

public final class LiveSystemSource: SystemSource {
    private let probe = TemperatureProbe()
    public init() {}

    public func psText() -> String { ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,time=,comm="]) }
    public func vmPages() -> VMPages? { MemoryReader.pages() }
    public func swapUsedMB() -> Double? { Double(MemoryReader.swap().used) / 1_048_576 }
    public func pressureLevel() -> Int? { MemoryReader.pressure().rawValue }
    public func idleSeconds() -> Double? { IdleReader.seconds() }
    public func pmsetText() -> String { ToolRunner.run("/usr/bin/pmset", ["-g", "batt"], timeout: 10) }
    public func topPowerText() -> String {
        ToolRunner.run("/usr/bin/top", ["-l", "2", "-stats", "pid,command,power", "-o", "power", "-n", "10"], timeout: 30)
    }
    public func batteryRegistry() -> [String: Any]? {
        var d: [String: Any]?
        Registry.services("AppleSmartBattery") { e in if d == nil { d = Registry.properties(e) } }
        return d
    }
    public func thermalState() -> Int { ProcessInfo.processInfo.thermalState.rawValue }
    public func diskFreeGB() -> Double? {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let cap = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Double(cap) / 1e9 * 10).rounded() / 10
    }
    public func cpuTicks() -> CPUTicks? { CPUReader.totalTicks() }
    public func temperatures() -> TemperatureReading { probe.read() }
    public func totalMemoryBytes() -> UInt64 { ProcessInfo.processInfo.physicalMemory }
}
