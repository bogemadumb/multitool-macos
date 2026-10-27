import Testing
import Foundation
@testable import MultitulCore

enum SysFixtures {
    static let ps = """
        1     0  12345   0:12.34 /sbin/launchd
      523     1  98765  1:02:03.45 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      524   523  45000   12:34.56 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
    this is not a process line
      700     1    abc   0:01.00 /bin/broken
    """

    static let vmStat = """
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                               10000.
    Pages active:                            200000.
    Pages inactive:                          190000.
    Pages speculative:                         5000.
    Pages throttled:                              0.
    Pages wired down:                         80000.
    Pages purgeable:                           3000.
    "Translation faults":                 123456789.
    Pages copy-on-write:                    1234567.
    Pages occupied by compressor:             60000.
    Anonymous pages:                         150000.
    File-backed pages:                       120000.
    Swapouts:                                     0.
    """

    static let pmsetBattery = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=4653155)\t87%; discharging; 5:23 remaining present: true
    """
    static let pmsetCharging = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=4653155)\t64%; charging; 1:12 remaining present: true
    """
    static let pmsetCharged = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=4653155)\t100%; charged; 0:00 remaining present: true
    """
    static let pmsetNoEstimate = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=4653155)\t55%; discharging; (no estimate) present: true
    """
    static let pmsetDesktop = "Now drawing from 'AC Power'\n"

    static let topPower = """
    Processes: 400 total, 3 running
    PID    COMMAND          POWER
    123    Google Chrome    12.5
    456    WindowServer     8.1
    Processes: 401 total, 2 running
    PID    COMMAND          POWER
    123    Google Chrome H  15.0
    456    WindowServer     9.25
    789    Code Helper (R)  3.0
    """

    static let nettopTimeless = """
    ,bytes_in,bytes_out,
    launchd.1,0,0,
    Google Chrome H.524,12345,2345,
    kernel_task.0,5,6,
    """
    static let nettopTime = """
    time,,bytes_in,bytes_out,
    10:11:12.123456,Safari.801,1000,2000,
    10:11:12.123456,mDNSResponder.250,40,50,
    """
}

@Suite struct SystemParsersTests {
    @Test func cpuTimeFormats() {
        let a: Double = 12.34
        let b: Double = 754.56
        let c: Double = 3723.45
        let d: Double = 183845
        #expect(abs(SystemParsers.cpuTime("0:12.34") - a) < 1e-9)
        #expect(abs(SystemParsers.cpuTime("12:34.56") - b) < 1e-9)
        #expect(abs(SystemParsers.cpuTime("1:02:03.45") - c) < 1e-9)
        #expect(abs(SystemParsers.cpuTime("2-03:04:05") - d) < 1e-9)
    }

    @Test func psParsesAndSkipsGarbage() {
        let r = SystemParsers.ps(SysFixtures.ps)
        #expect(r.count == 3)
        #expect(r[1]?.name == "launchd")
        #expect(r[523]?.name == "Google Chrome")
        let expectedRss: Int64 = 101_135_360
        #expect(r[523]?.rssBytes == expectedRss)
        #expect(r[524]?.ppid == 523)
        #expect(r[524]?.name == "Google Chrome Helper (Renderer)")
        #expect(r[700] == nil)
    }

    @Test func vmStatParsesPagesAndComposes() throws {
        let p = try #require(SystemParsers.vmStat(SysFixtures.vmStat))
        #expect(p.pageSize == 16384)
        #expect(p.free == 10000)
        #expect(p.wired == 80000)
        #expect(p.compressor == 60000)
        #expect(p.anonymous == 150000)
        #expect(p.fileBacked == 120000)
        let c = MemoryMath.compose(p, totalBytes: 16 * 1024 * 1024 * 1024)
        #expect(c.appBytes == (150000 - 3000) * 16384)
        #expect(c.cachedBytes == (120000 + 3000) * 16384)
        #expect(c.usedBytes == c.appBytes + c.wiredBytes + c.compressedBytes)
        #expect(c.usedFraction > 0 && c.usedFraction < 1)
    }

    @Test func vmStatRejectsEmpty() {
        #expect(SystemParsers.vmStat("") == nil)
        #expect(SystemParsers.vmStat("garbage\nlines") == nil)
    }

    @Test func composeClampsWhenPurgeableExceedsAnonymous() {
        var p = VMPages(pageSize: 4096)
        p.anonymous = 10
        p.purgeable = 50
        #expect(MemoryMath.compose(p, totalBytes: 1 << 30).appBytes == 0)
    }

    @Test func pmsetBattery() {
        let r = SystemParsers.pmsetBatt(SysFixtures.pmsetBattery)
        #expect(r.hasBattery && !r.onAC && r.percent == 87 && r.state == "discharging")
        #expect(r.timeRemainingMin == 5 * 60 + 23)
        #expect(!r.isCharging)
    }

    @Test func pmsetChargingAndCharged() {
        let c = SystemParsers.pmsetBatt(SysFixtures.pmsetCharging)
        #expect(c.onAC && c.isCharging && c.percent == 64 && c.timeRemainingMin == 72)
        let f = SystemParsers.pmsetBatt(SysFixtures.pmsetCharged)
        #expect(f.isCharged && f.timeRemainingMin == nil && f.percent == 100)
    }

    @Test func pmsetNoEstimateAndDesktop() {
        let n = SystemParsers.pmsetBatt(SysFixtures.pmsetNoEstimate)
        #expect(n.percent == 55 && n.timeRemainingMin == nil)
        let d = SystemParsers.pmsetBatt(SysFixtures.pmsetDesktop)
        #expect(!d.hasBattery && d.onAC && d.percent == nil)
    }

    @Test func topPowerUsesLastBlock() {
        let rows = SystemParsers.topPower(SysFixtures.topPower)
        #expect(rows.count == 3)
        #expect(rows[0] == PowerRow(pid: 123, name: "Google Chrome H", power: 15.0))
        #expect(rows[2].name == "Code Helper (R)")
        #expect(SystemParsers.topPower("nothing").isEmpty)
    }

    @Test func nettopWithoutTimeColumn() {
        let r = SystemParsers.nettop(SysFixtures.nettopTimeless)
        #expect(r.count == 3)
        #expect(r[1] == NetCounter(name: "Google Chrome H", pid: 524, bytesIn: 12345, bytesOut: 2345))
        #expect(r[2].pid == 0 && r[2].name == "kernel_task")
    }

    @Test func nettopWithTimeColumn() {
        let r = SystemParsers.nettop(SysFixtures.nettopTime)
        #expect(r.count == 2)
        #expect(r[0] == NetCounter(name: "Safari", pid: 801, bytesIn: 1000, bytesOut: 2000))
        #expect(SystemParsers.nettop("").isEmpty)
        #expect(SystemParsers.nettop("garbage,1,2").isEmpty)
    }

    @Test func smartStatusPlist() throws {
        func plist(_ v: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["SMARTStatus": v], format: .xml, options: 0)
        }
        #expect(SystemParsers.smartStatus(plist: try plist("Verified")) == .verified)
        #expect(SystemParsers.smartStatus(plist: try plist("Failing")) == .failing)
        #expect(SystemParsers.smartStatus(plist: try plist("Not Supported")) == .unsupported)
        #expect(SystemParsers.smartStatus(plist: Data("junk".utf8)) == .unknown)
    }

    @Test func procArgs() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/bin/ls".utf8) + [0, 0, 0]
        bytes += Array("ls".utf8) + [0] + Array("-l".utf8) + [0]
        let r = SystemParsers.procArgs(bytes)
        #expect(r?.execPath == "/bin/ls")
        #expect(r?.args == ["ls", "-l"])
        #expect(SystemParsers.procArgs([1, 2]) == nil)
    }

    @Test func bundlePathAndGrouping() {
        #expect(SystemParsers.bundlePath(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(SystemParsers.bundlePath(forExecutable: "/usr/bin/ssh") == nil)
        let rows = [ProcRow(pid: 1, ppid: 0, name: "a", cpu: 1, rssBytes: 10), ProcRow(pid: 2, ppid: 0, name: "a", cpu: 2, rssBytes: 20),
                    ProcRow(pid: 3, ppid: 0, name: "b", cpu: 5, rssBytes: 1)]
        let g = SystemParsers.groupProcesses(rows).sorted { $0.name < $1.name }
        #expect(g.count == 2)
        #expect(g[0].pids == [1, 2] && g[0].cpu == 3 && g[0].rssBytes == 30)
    }
}

@Suite struct SystemMathTests {
    @Test func cpuDeltaMath() {
        let p = CPUTicks(user: 100, system: 50, idle: 850)
        let c = CPUTicks(user: 200, system: 100, idle: 1700)
        let l = CPUMath.load(prev: p, cur: c)
        #expect(abs(l.total - 0.15) < 1e-9)
        #expect(abs(l.user - 0.10) < 1e-9)
        #expect(abs(l.system - 0.05) < 1e-9)
    }

    @Test func cpuDeltaHandlesWrapAndZero() {
        let p = CPUTicks(user: 10, system: 0, idle: UInt32.max - 4)
        let c = CPUTicks(user: 10, system: 0, idle: 5)
        #expect(CPUMath.load(prev: p, cur: c).total == 0)
        #expect(CPUMath.load(prev: c, cur: c) == .zero)
    }

    @Test func perCoreAndAverage() {
        let prev = [CPUTicks(user: 0, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 0)]
        let cur = [CPUTicks(user: 100, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 100)]
        let l = CPUMath.loads(prev: prev, cur: cur)
        #expect(l.map(\.total) == [1, 0])
        #expect(CPUMath.average(l).total == 0.5)
        #expect(CPUMath.loads(prev: prev, cur: [cur[0]]).isEmpty)
        #expect(CPUMath.average([]) == .zero)
    }

    @Test func rateMath() {
        #expect(RateMath.rate(prev: 1000, cur: 3000, dt: 2) == 1000)
        #expect(RateMath.rate(prev: 3000, cur: 10, dt: 2) == 0)
        #expect(RateMath.rate(prev: 0, cur: 100, dt: 0) == 0)
        #expect(RateMath.delta32(prev: UInt32.max - 1, cur: 3) == 5)
    }

    @Test func counterRateSkipsFirstAndNewKeys() {
        var r = CounterRate()
        let r0 = r.update(["a": 100], at: 10).isEmpty
        #expect(r0)
        let x = r.update(["a": 300, "b": 999], at: 12)
        #expect(x["a"] == 100)
        #expect(x["b"] == 0)
        let y = r.update(["a": 10, "b": 1999], at: 14)
        #expect(y["a"] == 0)
        #expect(y["b"] == 500)
    }

    @Test func processTrackerCpuPercent() {
        var t = ProcessCPUTracker()
        let a: [Int32: RawProc] = [1: RawProc(ppid: 0, name: "x", cpuTime: 10, rssBytes: 100)]
        let r1 = t.update(a, at: 100) == nil
        #expect(r1)
        let b: [Int32: RawProc] = [1: RawProc(ppid: 0, name: "x", cpuTime: 13, rssBytes: 100),
                                   2: RawProc(ppid: 0, name: "y", cpuTime: 50, rssBytes: 200)]
        let rows = t.update(b, at: 130)!.sorted { $0.pid < $1.pid }
        #expect(rows[0].cpu == 10)
        #expect(rows[1].cpu == 0)
    }

    @Test func topSelectionMergesCpuAndRss() {
        let rows = (1...10).map { ProcRow(pid: Int32($0), ppid: 0, name: "p\($0)", cpu: Double($0), rssBytes: Int64(100 - $0)) }
        let top = ProcessCPUTracker.topSelection(rows, top: 2)
        #expect(Set(top.map(\.pid)) == [10, 9, 1, 2])
    }

    @Test func historyRingAndBuckets() {
        var h = MetricHistory(capacity: 3)
        for v in 1...5 { h.append(Double(v)) }
        #expect(h.values == [3, 4, 5])
        #expect(Downsample.bucketRanges(count: 10, maxPoints: 5).count == 5)
        #expect(Downsample.bucketRanges(count: 3, maxPoints: 5).count == 3)
        #expect(Downsample.bucketRanges(count: 0, maxPoints: 5).isEmpty)
    }

    @Test func drainRate() {
        let pts: [(ts: Int64, pct: Int, onAC: Bool)] = [(0, 90, true), (100, 80, false), (1900, 70, false), (3700, 60, false)]
        #expect(Downsample.drainRate(pts) == 20.0)
        #expect(Downsample.drainRate([(0, 50, false), (60, 49, false)]) == nil)
    }

    @Test func formats() {
        #expect(SysFormat.bytes(1536) == "1,50 КБ")
        #expect(SysFormat.rate(0) == "0 Б/с")
        #expect(SysFormat.rateShort(2048) == "2,0К")
        #expect(SysFormat.percent(0.456) == "46")
        #expect(SysFormat.duration(3700) == "1 ч 1 мин")
        #expect(SysFormat.minutes(75) == "1 ч 15 мин")
    }
}
