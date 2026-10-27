import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

private func orphan(_ pid: Int32, _ name: String = "node", path: String? = nil, ppid: Int32 = 1, tty: Bool = false, args: String = "") -> ProcInfo {
    pinfo(pid, name, path: path, ppid: ppid, tty: tty, args: args)
}

private func pick(_ procs: [ProcInfo], launchd: Set<Int32> = [], lists: StorozhLists = StorozhLists()) -> [Int32] {
    RamClean.orphanCandidates(procs, launchd: launchd, lists: lists, selfPid: 1).map(\.pid)
}

@Suite struct RamCleanTests {
    @Test func orphanDevServerSelection() {
        #expect(pick([orphan(4001)]) == [4001])
        #expect(pick([orphan(4002, "npm"), orphan(4003, "vite"), orphan(4004, "uvx")]) == [4002, 4003, 4004])
        #expect(pick([orphan(4010, "python3", args: "python3 -m http.server 8000")]) == [4010])
        #expect(pick([orphan(4011, "python3", args: "python3 script.py")]).isEmpty)
        #expect(pick([orphan(4020, tty: true)]).isEmpty)
        #expect(pick([orphan(4021, ppid: 777)]).isEmpty)
        #expect(pick([orphan(4030)], launchd: [4030]).isEmpty)
        #expect(pick([orphan(4030), orphan(4031)], launchd: [4030]) == [4031])
    }

    @Test func untouchablesAndServicesAreNeverCandidates() {
        #expect(pick([orphan(4040, path: "/Users/x/Library/dev.multitool.thing/node")]).isEmpty)
        #expect(pick([orphan(4041, args: "node /Users/x/Library/LaunchAgents/dev.multitool.foo/run.js")]).isEmpty)
        var lists = StorozhLists()
        lists.untouchable += ["node"]
        #expect(pick([orphan(4050)], lists: lists).isEmpty)
        #expect(pick([orphan(4051, path: "/Users/x/.local/share/claude/versions/node")]).isEmpty)
        #expect(pick([orphan(4052, "sing-box"), orphan(4053, "xray"), orphan(4054, "claude"), orphan(4055, "Multitul")]).isEmpty)
        #expect(pick([orphan(150)]).isEmpty)
        #expect(RamClean.orphanCandidates([orphan(4060)], launchd: [], lists: StorozhLists(), selfPid: 4060).isEmpty)
    }

    @Test func orphansWithUntouchableDescendantsAreDropped() {
        let ops = MockOps()
        ops.children[4070] = [pinfo(4071, "sing-box", ppid: 4070)]
        let procs = [orphan(4070), orphan(4072)]
        let found = RamClean.orphans(procs: procs, rss: [4070: 100, 4072: 300], launchd: [], lists: StorozhLists(), ops: ops)
        #expect(found.map(\.id) == [4072])
    }

    @Test func idleSampleNeedsEnoughQuietSamples() {
        #expect(RamClean.isIdleSample(Array(repeating: 0.2, count: 120)))
        #expect(!RamClean.isIdleSample(Array(repeating: 0.2, count: 99)))
        #expect(!RamClean.isIdleSample(Array(repeating: 1.5, count: 120)))
        #expect(!RamClean.isIdleSample(Array(repeating: 0.2, count: 119) + [5.0]))
    }

    @Test func idleSessionsReadFromSysProcHistory() throws {
        let store = try stzStore()
        let now = stzNow
        for i in 0..<120 {
            let ts = now - Int64(i) * 30
            try stzInsertProc(store, ts: ts, pid: 900, name: "claude", cpu: 0.1)
            try stzInsertProc(store, ts: ts, pid: 901, name: "claude", cpu: i == 5 ? 40 : 0.1)
            try stzInsertProc(store, ts: ts, pid: 903, name: "claude", cpu: 0.1)
        }
        for i in 0..<20 { try stzInsertProc(store, ts: now - Int64(i) * 30, pid: 902, name: "claude", cpu: 0.1) }
        func s(_ pid: Int32, up: TimeInterval) -> ClaudeSession { ClaudeSession(pid: pid, name: "claude", cpu: 0, rssMb: 300, uptime: up, cwd: "/x/\(pid)") }
        let out = RamClean.idleSessions(sessions: [s(900, up: 9000), s(901, up: 9000), s(902, up: 9000), s(903, up: 100)], store: store, now: now)
        #expect(out.map(\.pid) == [900])
        #expect(out[0].cwd == "/x/900" && out[0].idleMinutes == 120)
        #expect(RamClean.idleSessions(sessions: [s(900, up: 9000)], store: nil, now: now).isEmpty)
    }

    @Test func heavyBackgroundAppsSumTreeAndSkipFrontFinderAndUntouchable() {
        let procs = [pinfo(1100, "Slack", ppid: 1), pinfo(1101, "Slack Helper", ppid: 1100), pinfo(1200, "Small", ppid: 1), pinfo(1300, "Front", ppid: 1),
                     pinfo(1400, "sing-box", ppid: 1), pinfo(1500, "Finder", ppid: 1), pinfo(1600, "Mine", ppid: 1)]
        let rss: [Int32: Int64] = [1100: 600 * 1024, 1101: 700 * 1024, 1200: 100 * 1024, 1300: 3000 * 1024, 1400: 4000 * 1024, 1500: 4000 * 1024, 1600: 5000 * 1024]
        let apps: [(pid: Int32, name: String)] = [(1100, "Slack"), (1200, "Small"), (1300, "Front"), (1400, "sing-box"), (1500, "Finder"), (1600, "Mine")]
        let h = RamClean.heavyBackgroundApps(procs: procs, rss: rss, frontPids: [1300], lists: StorozhLists(), apps: apps, selfPid: 1600)
        #expect(h.map(\.name) == ["Slack"])
        #expect(h[0].rssMb == 1300)
    }

    @Test func vmStatAndProcessListParsing() {
        let vm = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               1000.\nPages active:                  5000.\nPages speculative:                         500.\n"
        #expect(RamClean.parseFreeMemoryMb(vmStat: vm) == 1500 * 16384 / 1_048_576)
        let parsed = RamClean.parseProcessList(argsText: " 10 node server.js\n 11 /bin/zsh -l\n", statText: "  10     1 ??       Ss      2048 /usr/local/bin/node\n  11    10 ttys001  S       512 /bin/zsh\n",
                                               pathOf: { _ in "/usr/local/bin/node" })
        #expect(parsed.procs.count == 2)
        #expect(parsed.procs[0].name == "node" && !parsed.procs[0].hasTTY && parsed.procs[0].args == "node server.js" && parsed.procs[0].ppid == 1)
        #expect(parsed.procs[1].hasTTY && parsed.rssKb[10] == 2048)
    }

    // MARK: perform

    private func service(_ ops: MockOps) -> KillProcessService { KillProcessService(ops: ops, lists: StorozhLists()) }

    @Test func performStopsOrphansThroughTheGuardAndPurges() {
        let ops = MockOps()
        ops.procs[4001] = orphan(4001)
        ops.procs[4002] = orphan(4002, "vite")
        let purged = LockedBox(0)
        let free = LockedBox([1000, 1600])
        let plan = RamPlan(orphans: [OrphanServer(info: orphan(4001), rssKb: 1), OrphanServer(info: orphan(4002, "vite"), rssKb: 1)], purge: true)
        let r = RamClean.perform(plan, service: service(ops), freeMb: { free.value.isEmpty ? 0 : { var v = 0; free.mutate { v = $0.removeFirst() }; return v }() },
                                 purge: { purged.mutate { $0 += 1 } }, settle: 0)
        #expect(r.killed == 2 && r.failed.isEmpty)
        #expect(r.purge == "выполнен" && purged.value == 1)
        #expect(r.freedMb == 600)
        #expect(Set(ops.sent.map(\.pid)) == [4001, 4002])
        #expect(r.line.contains("dev-серверов: 2") && r.line.contains("purge: выполнен"))
    }

    @Test func performRefusesUntouchableEvenIfAskedAndKeepsGoing() {
        let ops = MockOps()
        ops.procs[3001] = pinfo(3001, "sing-box", ppid: 1)
        ops.procs[3002] = orphan(3002)
        let plan = RamPlan(orphans: [OrphanServer(info: pinfo(3001, "sing-box", ppid: 1), rssKb: 1), OrphanServer(info: orphan(3002), rssKb: 1)])
        let r = RamClean.perform(plan, service: service(ops), freeMb: { 0 }, purge: {}, settle: 0)
        #expect(r.killed == 1)
        #expect(r.failed.count == 1 && r.failed[0].contains("untouchable"))
        #expect(ops.sent.allSatisfy { $0.pid == 3002 })
    }

    @Test func claudeSessionsClosedOnlyWhenChosenAndOtherUntouchablesStayRefused() {
        let ops = MockOps()
        ops.procs[7000] = pinfo(7000, "claude", path: "/Users/x/.local/share/claude/versions/2.1/claude", ppid: 1)
        ops.procs[7001] = pinfo(7001, "sing-box", ppid: 1)
        let plan = RamPlan(sessions: [IdleSession(pid: 7000, name: "claude", cwd: nil, rssMb: 300, idleMinutes: 120),
                                      IdleSession(pid: 7001, name: "sing-box", cwd: nil, rssMb: 300, idleMinutes: 120)])
        let r = RamClean.perform(plan, service: service(ops), freeMb: { 0 }, purge: {}, settle: 0)
        #expect(r.sessionsClosed == 1)
        #expect(r.failed.count == 1)
        #expect(ops.sent.map(\.pid) == [7000])
        let ops2 = MockOps()
        ops2.procs[7000] = pinfo(7000, "claude", path: "/Users/x/.local/share/claude/versions/2.1/claude", ppid: 1)
        let none = RamClean.perform(RamPlan(), service: service(ops2), freeMb: { 0 }, purge: {}, settle: 0)
        #expect(none.sessionsClosed == 0 && ops2.sent.isEmpty)
    }

    @Test func purgeFailureIsReportedNotThrown() {
        struct Boom: Error {}
        let r = RamClean.perform(RamPlan(purge: true), service: service(MockOps()), freeMb: { 0 }, purge: { throw Boom() }, settle: 0)
        #expect(r.purge?.hasPrefix("пропущен") == true)
        let r2 = RamClean.perform(RamPlan(purge: false), service: service(MockOps()), freeMb: { 0 }, purge: { throw Boom() }, settle: 0)
        #expect(r2.purge == nil)
    }

    @Test func appsAreQuitThroughTheInjectedQuitter() {
        let asked = LockedBox<[Int32]>([])
        let plan = RamPlan(apps: [HeavyApp(pid: 10, name: "A", rssMb: 2000), HeavyApp(pid: 11, name: "B", rssMb: 2000)])
        let r = RamClean.perform(plan, service: service(MockOps()), freeMb: { 0 }, quitApp: { pid in asked.mutate { $0.append(pid) }; return pid == 10 }, purge: {}, settle: 0)
        #expect(asked.value == [10, 11])
        #expect(r.appsQuit == 1 && r.failed.count == 1)
    }

    @Test func purgeGoesThroughPrivilegedCtlAsSudoNMemPurge() throws {
        let r = FakeRunner()
        let ctl = PrivilegedCtl(runner: r, stagingDir: NSTemporaryDirectory() + "multitul-stg-\(UUID().uuidString)", binaryExists: { _ in true })
        let res = RamClean.perform(RamPlan(purge: true), service: service(MockOps()), freeMb: { 0 }, purge: { try ctl.purgeMemory() }, settle: 0)
        #expect(res.purge == "выполнен")
        #expect(r.calls.count == 1 && r.calls[0].0 == "/usr/bin/sudo")
        #expect(r.calls[0].1 == ["-n", "/usr/local/libexec/multitul-ctl", "mem", "purge"])
        let missing = PrivilegedCtl(runner: FakeRunner(), stagingDir: NSTemporaryDirectory(), binaryExists: { _ in false })
        let res2 = RamClean.perform(RamPlan(purge: true), service: service(MockOps()), freeMb: { 0 }, purge: { try missing.purgeMemory() }, settle: 0)
        #expect(res2.purge?.hasPrefix("пропущен") == true)
    }
}

@Suite struct ThresholdTests {
    @Test func everyDefaultSitsInsideItsRange() {
        let d = StorozhThresholds()
        for f in ThresholdField.allCases {
            #expect(f.range.contains(f.value(in: d)), "\(f.rawValue)")
            #expect(f.clamp(f.value(in: d)) == f.value(in: d), "\(f.rawValue) default must survive clamp")
            #expect(f.step > 0 && f.step <= f.range.upperBound - f.range.lowerBound)
        }
        #expect(ThresholdField.allCases.count == 15)
        #expect(ThresholdField.allCases.allSatisfy { $0.rawValue.allSatisfy(\.isASCII) })
    }

    @Test func setClampsAndRoundsAndTouchesOnlyItsField() {
        var t = StorozhThresholds()
        ThresholdField.swapMb.set(100_000, in: &t)
        #expect(t.swapMb == 65536)
        ThresholdField.swapMb.set(1, in: &t)
        #expect(t.swapMb == 512)
        ThresholdField.cpuHogPercent.set(55.6, in: &t)
        #expect(t.cpuHogPercent == 55.6)
        ThresholdField.repeatCount.set(4.4, in: &t)
        #expect(t.repeatCount == 4)
        ThresholdField.memLeakUpShare.set(0.8765, in: &t)
        #expect(t.memLeakUpShare == 0.88)
        var other = StorozhThresholds()
        other.swapMb = 512; other.cpuHogPercent = 55.6; other.repeatCount = 4; other.memLeakUpShare = 0.88
        #expect(t == other)
    }

    @Test func settingsRoundTripThroughTheDatabase() throws {
        let store = try stzStore()
        let repo = StorozhRepository(store: store)
        #expect(try repo.settings().thresholds == StorozhThresholds())
        try repo.updateThreshold(.swapMb, to: 8192)
        try repo.updateThreshold(.cpuHogPercent, to: 90)
        try repo.updateThreshold(.cooldownMin, to: 45)
        var t = try repo.settings().thresholds
        #expect(t.swapMb == 8192 && t.cpuHogPercent == 90 && t.cooldownMin == 45)
        #expect(t.diskLowGb == 10 && t.thermalSec == 120)
        let reopened = StorozhRepository(store: try Store(path: store.path, migrations: StorozhSchema.allMigrations, retention: StorozhSchema.allRetention))
        t = try reopened.settings().thresholds
        #expect(t.swapMb == 8192 && t.cpuHogPercent == 90 && t.cooldownMin == 45)
        try repo.updateThreshold(.swapMb, to: 99)
        #expect(try repo.settings().thresholds.swapMb == 512)
        try repo.resetThresholds()
        #expect(try repo.settings().thresholds == StorozhThresholds())
    }

    @Test func editedThresholdChangesWhatTheDetectorSees() throws {
        let store = try stzStore()
        let repo = StorozhRepository(store: store)
        for i in 0..<3 { try stzInsertState(store, ts: stzNow - Int64(2 - i) * 30, swap: 5000) }
        func swapFound() throws -> Bool {
            let s = try repo.settings()
            let input = try StorozhDetectors.loadInput(store: store, now: stzNow, settings: s)
            return StorozhDetectors.detect(input, lists: StorozhLists(), settings: s, pathOf: { _ in nil }).contains { $0.kind == "swap" }
        }
        #expect(try swapFound())
        try repo.updateThreshold(.swapMb, to: 6144)
        #expect(try !swapFound())
        try repo.setKind("swap", enabled: false)
        try repo.updateThreshold(.swapMb, to: 512)
        #expect(try !swapFound())
    }

    @Test func fieldsAreGroupedUnderTheirDetectors() {
        for kind in DetectorKind.allCases where kind != .memPressure { #expect(ThresholdField.allCases.contains { $0.detector == kind }, "\(kind)") }
        #expect(ThresholdField.allCases.filter { $0.detector == nil }.map(\.rawValue).sorted() == ["cooldownMin", "repeatCount", "repeatWindowMin", "snapshotKeep"])
    }
}

@Suite struct SnapshotOffTickTests {
    func make(_ ops: MockOps, queue: DispatchQueue?, snapshot: @escaping (StorozhRepository, String, AnomalyRow, StorozhThresholds) -> String?) throws -> (StorozhCollector, Store, StorozhRepository) {
        let c = StorozhCollector(ops: ops, pathOf: { _ in "/Users/x/bin/tool" }, launchdPids: { [] },
                                 now: { Date(timeIntervalSince1970: TimeInterval(stzNow)) }, isEnabled: { true }, snapshot: snapshot, snapshotQueue: queue)
        let store = try stzStore()
        return (c, store, StorozhRepository(store: store))
    }

    func fillHog(_ store: Store, name: String = "yes") throws {
        for i in 0..<11 {
            let ts = stzNow - Int64(10 - i) * 30
            try stzInsertState(store, ts: ts, idle: 300)
            try stzInsertProc(store, ts: ts, pid: 500, name: name, cpu: 99)
        }
    }

    @Test func tickReturnsWhileTheSnapshotIsStillRunning() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.snapshot")
        let (c, store, repo) = try make(ops, queue: queue) { _, _, _, _ in gate.wait(); return "/tmp/fake-snapshot.md" }
        try fillHog(store)
        try c.collect(store: store)
        let a = try #require(try repo.anomalies(since: 0).first)
        #expect(a.action == "notify" && a.status == "pending_user")
        #expect(try repo.pendingNotifications(since: 0).isEmpty)
        gate.signal()
        queue.sync {}
        let pending = try repo.pendingNotifications(since: 0)
        #expect(pending.count == 1)
        #expect(pending.first?.snapshot == "/tmp/fake-snapshot.md")
        #expect(pending.first?.anomaly.id == a.id)
    }

    @Test func silentRestartStillWritesTheSnapshotButNeverNotifies() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "Telegram", path: "/Applications/Telegram.app/Contents/MacOS/Telegram")
        ops.bundles["/Applications/Telegram.app"] = "ru.telegram.test"
        let wrote = LockedBox(0)
        let queue = DispatchQueue(label: "test.snapshot2")
        let (c, store, repo) = try make(ops, queue: queue) { _, _, _, _ in wrote.mutate { $0 += 1 }; return "/tmp/s.md" }
        try fillHog(store, name: "Telegram")
        try c.collect(store: store)
        queue.sync {}
        #expect(wrote.value == 1)
        #expect(ops.opened == ["ru.telegram.test"])
        #expect(try repo.pendingNotifications(since: 0).isEmpty)
    }

    @Test func withoutAQueueTheOldSynchronousOrderIsKept() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let (c, store, repo) = try make(ops, queue: nil) { _, _, _, _ in "/tmp/sync.md" }
        try fillHog(store)
        try c.collect(store: store)
        #expect(try repo.pendingNotifications(since: 0).first?.snapshot == "/tmp/sync.md")
    }

    @Test func joinFiresExactlyOnceInEitherOrder() {
        let fired = LockedBox<[(String?, Bool)]>([])
        let j1 = SnapshotJoin { f, n in fired.mutate { $0.append((f, n)) } }
        j1.setFile("a"); j1.setNotify(true); j1.setNotify(true); j1.setFile("b")
        let j2 = SnapshotJoin { f, n in fired.mutate { $0.append((f, n)) } }
        j2.setNotify(false); j2.setFile(nil)
        #expect(fired.value.count == 2)
        #expect(fired.value[0].0 == "a" && fired.value[0].1)
        #expect(fired.value[1].0 == nil && !fired.value[1].1)
    }
}
