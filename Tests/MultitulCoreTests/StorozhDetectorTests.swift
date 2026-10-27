import Testing
import Foundation
@testable import MultitulCore

@Suite struct StorozhDetectorTests {
    // MARK: one test per detector

    @Test func detectorCpuHog() {
        let r = stzRun(stzInput(procs: stzHogSeries(), sys: stzIdleSys(idle: 300)))
        #expect(r.map(\.kind) == ["cpu_hog"])
        #expect(r.first?.name == "yes")
        #expect(r.first?.detail["window_s"] as? Int == 300)
    }

    @Test func detectorMemPressure() {
        var sys = stzIdleSys(idle: 0)
        sys[sys.count - 1].pressure = 2
        #expect(stzRun(stzInput(sys: sys)).isEmpty)
        sys[sys.count - 2].pressure = 4
        let r = stzRun(stzInput(sys: sys))
        #expect(r.first?.kind == "mem_pressure")
        #expect(r.first?.detail["level"] as? Int == 4)
        #expect(r.first?.detail["level_name"] as? String == "critical")
    }

    @Test func detectorSwap() {
        var sys = stzIdleSys(idle: 0)
        sys[sys.count - 1].swapMb = 5000
        #expect(stzRun(stzInput(sys: sys)).first?.kind == "swap")
        sys[sys.count - 1].swapMb = 4000
        #expect(stzRun(stzInput(sys: sys)).isEmpty)
    }

    @Test func detectorMemLeak() {
        let r = stzRun(stzInput(procs: leakSeries(noisy: false)))
        #expect(r.map(\.kind) == ["mem_leak"])
        #expect((r.first?.detail["growth_mb"] as? Int ?? 0) > 2048)
    }

    @Test func detectorBatteryDrain() {
        let power = [PowerRow(pid: 9, name: "small", power: 3), PowerRow(pid: 10, name: "Telegram", power: 40)]
        let r = stzRun(stzInput(sys: batterySys(startPct: 80, endPct: 77), power: power))
        #expect(r.first?.kind == "battery_drain")
        #expect(r.first?.name == "Telegram")
    }

    @Test func detectorDiskLow() {
        let r = stzRun(stzInput(sys: diskSys(6.5)))
        #expect(r.map(\.kind) == ["disk_low"])
        #expect(r.first?.name == "system")
        #expect(stzRun(stzInput(sys: diskSys(10.0))).isEmpty)
        #expect(stzRun(stzInput(sys: diskSys(nil))).isEmpty)
        var s = StorozhSettings()
        s.thresholds.diskLowGb = 50
        #expect(stzRun(stzInput(sys: diskSys(20)), settings: s).map(\.kind) == ["disk_low"])
    }

    @Test func detectorThermal() {
        #expect(stzRun(stzInput(sys: thermalSys(count: 6, level: 2))).map(\.kind) == ["thermal"])
        let crit = stzRun(stzInput(sys: thermalSys(count: 6, level: 3)))
        #expect(crit.first?.detail["level_name"] as? String == "critical")
        #expect(stzRun(stzInput(sys: thermalSys(count: 3, level: 2))).isEmpty)
        #expect(stzRun(stzInput(sys: thermalSys(count: 6, level: 1))).isEmpty)
        var dip = thermalSys(count: 6, level: 2)
        dip[3].thermal = 1
        #expect(stzRun(stzInput(sys: dip)).isEmpty)
        var early = thermalSys(count: 6, level: 2)
        early[0].thermal = 1
        #expect(stzRun(stzInput(sys: early)).map(\.kind) == ["thermal"])
    }

    // MARK: cpu_hog edge cases (ported)

    @Test func cpuHogSilentWhenUserActive() {
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: stzIdleSys(idle: 5))).isEmpty)
    }

    @Test func cpuHogSilentWhenOneSampleDips() {
        var s = stzHogSeries()
        s[4].cpu = 40
        #expect(stzRun(stzInput(procs: s, sys: stzIdleSys(idle: 300))).isEmpty)
    }

    @Test func cpuHogSilentWithTooFewSamples() {
        #expect(stzRun(stzInput(procs: stzHogSeries(count: 5), sys: stzIdleSys(idle: 300))).isEmpty)
    }

    @Test func cpuHogToleratesMissingSamples() {
        var s = stzHogSeries()
        s.remove(at: 3)
        s.remove(at: 5)
        #expect(stzRun(stzInput(procs: s, sys: stzIdleSys(idle: 300))).count == 1)
    }

    @Test func repeatSuppressionThirtyMinutes() {
        let sys = stzIdleSys(idle: 300)
        let recent = [stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 600)]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys, anomalies: recent)).isEmpty)
        let old = [stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 31 * 60)]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys, anomalies: old)).count == 1)
        let other = [stzAnomaly(kind: "cpu_hog", name: "other", agoSec: 600)]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys, anomalies: other)).count == 1)
    }

    @Test func systemKindsAlsoSuppressedByCooldown() {
        var sys = stzIdleSys(idle: 0)
        sys[sys.count - 1].swapMb = 9000
        #expect(stzRun(stzInput(sys: sys), settings: StorozhSettings()).count == 1)
        #expect(stzRun(stzInput(sys: sys, anomalies: [stzAnomaly(kind: "swap", name: "system", agoSec: 100)])).isEmpty)
    }

    @Test func sameNameDifferentPidsOneAnomaly() {
        let s = stzHogSeries(pid: 500) + stzHogSeries(pid: 501)
        #expect(stzRun(stzInput(procs: s, sys: stzIdleSys(idle: 300))).count == 1)
    }

    @Test func repeatOffenderFlag() {
        let sys = stzIdleSys(idle: 300)
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys)).first?.detail["repeat"] as? Bool == false)
        let two = [stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 40 * 60), stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 80 * 60)]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys, anomalies: two)).first?.detail["repeat"] as? Bool == true)
        let stale = [stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 130 * 60), stzAnomaly(kind: "cpu_hog", name: "yes", agoSec: 150 * 60)]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys, anomalies: stale)).first?.detail["repeat"] as? Bool == false)
    }

    // MARK: leak / battery edge cases (ported)

    @Test func memLeakNoisySilent() {
        var s = StorozhSettings()
        s.thresholds.memLeakMb = 100
        for _ in 0..<5 { #expect(stzRun(stzInput(procs: leakSeries(noisy: true)), settings: s).isEmpty) }
    }

    @Test func memLeakSmallGrowthSilent() {
        let flat = (0..<121).map { i in
            ProcPoint(ts: stzNow - Int64(120 - i) * 30, pid: 700, name: "flat", cpu: 1, rss: 1_000_000_000 + Int64(i) * 1_000_000)
        }
        #expect(stzRun(stzInput(procs: flat)).isEmpty)
    }

    @Test func batteryDrainSilentCases() {
        #expect(stzRun(stzInput(sys: batterySys(startPct: 80, endPct: 79))).isEmpty)
        #expect(stzRun(stzInput(sys: batterySys(startPct: 80, endPct: 70, onAC: true))).isEmpty)
        #expect(stzRun(stzInput(sys: batterySys(startPct: 80, endPct: 70, idle: 60))).isEmpty)
    }

    // MARK: lists and per-detector switch

    @Test func untouchableNamesPidsAndPathsSkipped() {
        let sys = stzIdleSys(idle: 300)
        for n in ["sing-box", "xray", "claude", "Multitul", "VPNMonitor"] {
            #expect(stzRun(stzInput(procs: stzHogSeries(name: n), sys: sys)).isEmpty, "\(n)")
        }
        #expect(stzRun(stzInput(procs: stzHogSeries(pid: 150, name: "randomd"), sys: sys)).isEmpty)
        #expect(stzRun(stzInput(procs: stzHogSeries(pid: 200, name: "randomd"), sys: sys)).count == 1)
        let i = stzInput(procs: stzHogSeries(name: "mdworker"), sys: sys)
        #expect(stzRun(i, path: "/System/Library/Foo/mdworker").isEmpty)
        #expect(stzRun(i, path: "/usr/libexec/mdworker").isEmpty)
        #expect(stzRun(i, path: "/Applications/Foo.app/mdworker").count == 1)
        #expect(stzRun(stzInput(procs: stzHogSeries(name: "node"), sys: sys), path: "/Users/x/.cache/ms-playwright/chromium/node").isEmpty)
    }

    @Test func ignoreListSkipsPerProcessOnly() {
        let lists = StorozhLists(ignore: ["yes", "Code Helper*"])
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: stzIdleSys(idle: 300)), lists: lists).isEmpty)
        #expect(stzRun(stzInput(procs: stzHogSeries(name: "Code Helper (Renderer)"), sys: stzIdleSys(idle: 300)), lists: lists).isEmpty)
        var sys = stzIdleSys(idle: 0)
        sys[sys.count - 1].swapMb = 9000
        #expect(stzRun(stzInput(sys: sys), lists: StorozhLists(ignore: ["system"])).count == 1)
    }

    @Test func disabledDetectorProducesNothing() {
        var s = StorozhSettings()
        s.disabledKinds = ["cpu_hog", "swap"]
        var sys = stzIdleSys(idle: 300)
        sys[sys.count - 1].swapMb = 9000
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys), settings: s).isEmpty)
        s.disabledKinds = ["cpu_hog"]
        #expect(stzRun(stzInput(procs: stzHogSeries(), sys: sys), settings: s).map(\.kind) == ["swap"])
    }

    @Test func thresholdsDecodeOldConfigWithDefaults() throws {
        let old = Data(#"{"swapMb":2000,"cooldownMin":10}"#.utf8)
        let t = try JSONDecoder().decode(StorozhThresholds.self, from: old)
        #expect(t.swapMb == 2000)
        #expect(t.cooldownMin == 10)
        #expect(t.diskLowGb == 10)
        #expect(t.thermalSec == 120)
        #expect(t.cpuHogWindowSec == 300)
    }

    // MARK: fixtures

    func leakSeries(noisy: Bool, name: String = "leaky") -> [ProcPoint] {
        var rng = SystemRandomNumberGenerator()
        return (0..<121).map { i in
            var rss = Int64(1_000_000_000) + Int64(i) * 30_000_000
            if noisy { rss = Int64(1_000_000_000) + Int64(i) * 30_000_000 / 100 + Int64.random(in: 0...2_500_000_000, using: &rng) }
            return ProcPoint(ts: stzNow - Int64(120 - i) * 30, pid: 700, name: name, cpu: 1, rss: rss)
        }
    }

    func batterySys(startPct: Int, endPct: Int, idle: Double = 900, onAC: Bool = false) -> [SysPoint] {
        let n = 21
        return (0..<n).map { i in
            SysPoint(ts: stzNow - Int64(n - 1 - i) * 30, pressure: 1, swapMb: 100, idleS: idle,
                     battPct: startPct - (startPct - endPct) * i / (n - 1), onAC: onAC)
        }
    }

    func diskSys(_ gb: Double?) -> [SysPoint] {
        (0..<3).map { i in SysPoint(ts: stzNow - Int64(2 - i) * 30, pressure: 1, swapMb: 100, idleS: 0, battPct: 80, onAC: true, thermal: 0, diskFreeGb: gb) }
    }

    func thermalSys(count: Int, level: Int) -> [SysPoint] {
        (0..<count).map { i in
            SysPoint(ts: stzNow - Int64(count - 1 - i) * 30, pressure: 1, swapMb: 100, idleS: 0, battPct: 80, onAC: true, thermal: level)
        }
    }
}
