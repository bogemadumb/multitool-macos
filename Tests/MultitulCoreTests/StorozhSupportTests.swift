import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

@Suite struct StorozhSupportTests {
    // MARK: pause and icon

    @Test func pausePresets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 30))!
        #expect(pauseUntil(.off, now: now, calendar: cal) == 0)
        #expect(pauseUntil(.hour, now: now, calendar: cal) == now.timeIntervalSince1970 + 3600)
        let morning = Date(timeIntervalSince1970: pauseUntil(.morning, now: now, calendar: cal))
        let c = cal.dateComponents([.day, .hour, .minute], from: morning)
        #expect(c.day == 23 && c.hour == 9 && c.minute == 0)
        let early = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 6, minute: 0))!
        #expect(cal.component(.day, from: Date(timeIntervalSince1970: pauseUntil(.morning, now: early, calendar: cal))) == 22)
    }

    @Test func iconStateYellowRedAndPausedBell() {
        #expect(StorozhIconState.compute(openCount: 0, pressure: 1, pausedUntil: 0, now: 100) == StorozhIconState(level: .normal, paused: false))
        #expect(StorozhIconState.compute(openCount: 2, pressure: 1, pausedUntil: 0, now: 100).level == .warn)
        #expect(StorozhIconState.compute(openCount: 0, pressure: 2, pausedUntil: 0, now: 100).level == .normal)
        #expect(StorozhIconState.compute(openCount: 0, pressure: 4, pausedUntil: 0, now: 100).level == .crit)
        #expect(StorozhIconState.compute(openCount: 3, pressure: 4, pausedUntil: 0, now: 100).level == .crit)
        #expect(StorozhIconState.compute(openCount: 1, pressure: nil, pausedUntil: 200, now: 100) == StorozhIconState(level: .warn, paused: true))
        #expect(StorozhIconState.compute(openCount: 0, pressure: nil, pausedUntil: 100, now: 100).paused == false)
    }

    // MARK: watchdog

    final class FakeRunner: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var status: Int32 = 0
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
            calls.append((executable, arguments))
            return ProcessOutput(status: status)
        }
    }

    func health(_ s: AgentHealth.Status) -> AgentHealth { AgentHealth(status: s, lastBeat: nil, pid: nil, age: s == .silent ? 500 : 5) }

    @Test func kickstartArgumentsGoThroughRunner() {
        let r = FakeRunner()
        let k = AgentKicker(runner: r, uid: 501)
        #expect(k.kickstart())
        #expect(r.calls.count == 1)
        #expect(r.calls[0].0 == "/bin/launchctl")
        #expect(r.calls[0].1 == ["kickstart", "-k", "gui/501/dev.multitool.app.agent"])
        r.status = 113
        #expect(!k.kickstart())
    }

    @Test func watchdogKicksSilentCollectorWithBackoffAndGivesUp() {
        var w = CollectorWatchdog(maxAttempts: 2, retryInterval: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func kick(_ s: AgentHealth.Status, _ dt: TimeInterval) -> Bool { w.shouldKick(health: health(s), now: t0.addingTimeInterval(dt)) }
        let r = [kick(.alive, 0), kick(.never, 0), kick(.silent, 0), kick(.silent, 60), kick(.silent, 301), kick(.silent, 1000), kick(.alive, 1100), kick(.silent, 1200)]
        #expect(r == [false, false, true, false, true, false, false, true])
    }

    // MARK: snapshot

    @Test func snapshotWritesMarkdownAndKeepsLastN() throws {
        let store = try stzStore()
        let repo = StorozhRepository(store: store)
        let row = try repo.record(ts: stzNow - 60, AnomalyCandidate(kind: "swap", pid: 0, name: "system", detail: ["swap_mb": 9000]))
        let dir = NSTemporaryDirectory() + "stz-snap-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var tools = SnapshotTools()
        tools.topCpu = "Processes: 1\nPID COMMAND\n1 launchd"
        tools.swap = "vm.swapusage: total = 1.00G"
        var paths: [String] = []
        for i in 0..<5 {
            paths.append(try #require(SnapshotWriter.write(repo: repo, kind: i == 0 ? "swap" : "manual", anomaly: i == 0 ? row : nil, tools: tools, keep: 3, dir: dir, now: stzNow + Int64(i))))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".md") }
        #expect(files.count == 3)
        let last = try String(contentsOfFile: paths[4], encoding: .utf8)
        #expect(last.contains("Снимок по запросу"))
        #expect(last.contains("## top по CPU (25)"))
        #expect(last.contains("1 launchd"))
        #expect(last.contains("swap"))
        #expect(!FileManager.default.fileExists(atPath: paths[0]))
        #expect(SnapshotWriter.latestPath(kind: "manual", dir: dir) == paths[4])
        let same = try #require(SnapshotWriter.write(repo: repo, kind: "manual", anomaly: nil, tools: tools, keep: 50, dir: dir, now: stzNow + 4))
        #expect(same != paths[4])
        #expect(SnapshotWriter.claudePrompt(snapshotPath: "/a/b.md").contains("/a/b.md"))
    }

    // MARK: Claude sessions

    @Test func claudeSessionsAreTreeRootsOnly() {
        let procs: [Int32: RawProc] = [
            10: RawProc(ppid: 1, name: "claude", cpuTime: 0, rssBytes: 1),
            11: RawProc(ppid: 10, name: "claude", cpuTime: 0, rssBytes: 1),
            12: RawProc(ppid: 10, name: "node", cpuTime: 0, rssBytes: 1),
            20: RawProc(ppid: 1, name: "2.1.281", cpuTime: 0, rssBytes: 1),
            30: RawProc(ppid: 1, name: "codex", cpuTime: 0, rssBytes: 1),
            40: RawProc(ppid: 1, name: "Safari", cpuTime: 0, rssBytes: 1),
        ]
        let paths: [Int32: String] = [20: "/Users/x/.local/share/claude/versions/2.1.281", 40: "/Applications/Safari.app/Contents/MacOS/Safari"]
        #expect(ClaudeSessions.roots(procs: procs, pathOf: { paths[$0] }) == [10, 20, 30])
    }

    // MARK: ports and catalog

    static let lsofTcp = """
    COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    node      12345 user   23u  IPv4 0x1a2b3c4d5e6f      0t0  TCP *:3000 (LISTEN)
    node      12345 user   24u  IPv6 0x1a2b3c4d5e70      0t0  TCP *:3000 (LISTEN)
    ControlCe   450 user    8u  IPv4 0x1a2b3c4d5e71      0t0  TCP *:7000 (LISTEN)
    ControlCe   450 user    9u  IPv6 0x1a2b3c4d5e72      0t0  TCP [::1]:7000 (LISTEN)
    Google\\x20Chrome   901 user   30u  IPv4 0x1a2b3c4d5e73      0t0  TCP 127.0.0.1:9222 (LISTEN)
    postgres  777 postgres    7u  IPv6 0x1a2b3c4d5e74      0t0  TCP [fe80::1%lo0]:5432 (LISTEN)
    curl      800 user    5u  IPv4 0x1a2b3c4d5e75      0t0  TCP 10.0.0.2:51000->1.2.3.4:443 (ESTABLISHED)
    """

    static let lsofUdp = """
    COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    mDNSRespo   300 _mdnsresponder    7u  IPv4 0x1a2b3c4d5e80      0t0  UDP *:5353
    mDNSRespo   300 _mdnsresponder    8u  IPv6 0x1a2b3c4d5e81      0t0  UDP *:5353
    Google\\x20Chrome   901 user   31u  IPv4 0x1a2b3c4d5e82      0t0  UDP 192.168.1.5:50123->1.2.3.4:443
    rapportd  480 user    4u  IPv4 0x1a2b3c4d5e83      0t0  UDP 127.0.0.1:55555
    """

    @Test func lsofTcpListenParsing() {
        let p = LsofParser.parse(Self.lsofTcp, proto: .tcp)
        #expect(p.map(\.port) == [3000, 5432, 7000, 9222])
        let node = p[0]
        #expect(node.command == "node" && node.pid == 12345 && node.user == "user" && node.proto == .tcp)
        #expect(node.addresses == ["*"])
        #expect(!node.isLocalOnly)
        let cc = p[2]
        #expect(cc.addresses == ["*", "::1"])
        #expect(p[3].command == "Google Chrome")
        #expect(p[3].isLocalOnly)
        #expect(p[1].addresses == ["fe80::1%lo0"])
        #expect(!p.contains { $0.port == 443 || $0.port == 51000 })
    }

    @Test func lsofUdpParsingSkipsConnected() {
        let p = LsofParser.parse(Self.lsofUdp, proto: .udp)
        #expect(p.map(\.port) == [5353, 55555])
        #expect(p[0].command == "mDNSRespo" && p[0].addresses == ["*"])
        #expect(p[1].isLocalOnly)
        #expect(LsofParser.parse("", proto: .tcp).isEmpty)
        #expect(LsofParser.parse("garbage line", proto: .tcp).isEmpty)
    }

    @Test func portScannerUsesExpectedLsofArgumentsAndMergesProtocols() {
        var calls: [[String]] = []
        let all = PortScanner.scan(run: { exe, args in
            #expect(exe == "/usr/sbin/lsof")
            calls.append(args)
            return args.contains("-iTCP") ? Self.lsofTcp : Self.lsofUdp
        })
        #expect(calls == [["-nP", "-iTCP", "-sTCP:LISTEN"], ["-nP", "-iUDP"]])
        #expect(all.count == 4 + 2)
        #expect(all.map(\.port) == all.map(\.port).sorted())
        #expect(Set(all.map(\.id)).count == all.count)
    }

    static let psCatalog = """
      501     1   501   0.0  250000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      600   501   501  12.5  100000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper
      601   501   501   1.0   90000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)
      700     1     0   0.1    5000 /usr/libexec/cfprefsd
      701     1   501   0.0    3000 /Users/x/bin/node
      702     1   501   9.0    4000 /Users/x/bin/node
    """

    @Test func catalogParsesAndGroupsByOuterApp() throws {
        let procs = ProcessCatalog.parse(Self.psCatalog)
        #expect(procs.count == 6)
        #expect(procs[0].name == "Google Chrome" && procs[0].rssBytes == 250_000 * 1024)
        #expect(procs[3].isRoot)
        let groups = ProcessCatalog.group(procs)
        let chrome = try #require(groups.first { $0.title == "Google Chrome" })
        #expect(chrome.processes.map(\.pid) == [501, 600, 601])
        #expect(chrome.bundlePath == "/Applications/Google Chrome.app")
        #expect(groups.first { $0.title == "node" }?.processes.count == 2)
        #expect(groups.first?.title == "Google Chrome")
        #expect(ProcessCatalog.search(groups, query: "gpu").first?.processes.map(\.pid) == [601])
        #expect(ProcessCatalog.search(groups, query: "700").first?.title == "cfprefsd")
        #expect(ProcessCatalog.search(groups, query: "zzz").isEmpty)
        #expect(ProcessCatalog.search(groups, query: " ").count == groups.count)
    }

    @Test func killServiceGuardAndGroupQuit() {
        let ops = MockOps()
        let procs = ProcessCatalog.parse(Self.psCatalog)
        for p in procs { ops.procs[p.pid] = ProcInfo(pid: p.pid, ppid: p.ppid, name: p.name, path: p.path, uid: p.uid) }
        ops.children[501] = procs.filter { $0.ppid == 501 }.map { ProcInfo(pid: $0.pid, ppid: 501, name: $0.name, path: $0.path) }
        let svc = KillProcessService(ops: ops)
        let chrome = ProcessCatalog.group(procs).first { $0.title == "Google Chrome" }!
        let out = svc.quitGroup(chrome)
        #expect(out.count == 1 && out[0].status == "done")
        #expect(ops.sent.map(\.pid) == [600, 601, 501] || ops.sent.map(\.pid) == [601, 600, 501])
        #expect(ops.sent.last?.pid == 501)

        let cfprefsd = procs.first { $0.pid == 700 }!
        #expect(!svc.canTouch(ProcessCatalog.parse("  150     1   0   0.0  1000 /usr/sbin/whatever").first!))
        #expect(!svc.canTouch(cfprefsd))
        let sb = CatalogProcess(pid: 4000, ppid: 1, uid: 0, cpu: 0, rssBytes: 0, name: "sing-box", path: "/opt/homebrew/bin/sing-box")
        ops.procs[4000] = ProcInfo(pid: 4000, ppid: 1, name: "sing-box", path: sb.path, uid: 0)
        #expect(!svc.canTouch(sb))
        let before = ops.sent.count
        #expect(svc.forceQuit(sb).status == "failed")
        #expect(svc.killTree(sb).status == "failed")
        #expect(svc.restart(sb).status == "failed")
        #expect(ops.sent.count == before)
    }

    @Test func privilegedFallbackUsedOnlyOnEperm() {
        var asked: [(Int32, Int32)] = []
        var direct: [(Int32, Int32)] = []
        let ops = SystemProcOps(privilegedKill: { pid, sig in asked.append((pid, sig)); return true },
                                killer: { pid, sig in direct.append((pid, sig)); return pid == 1 ? EPERM : (pid == 2 ? ESRCH : 0) })
        #expect(ops.send(SIGTERM, to: 1))
        #expect(asked.count == 1 && asked[0].0 == 1 && asked[0].1 == SIGTERM)
        #expect(ops.send(SIGTERM, to: 3))
        #expect(!ops.send(SIGTERM, to: 2))
        #expect(asked.count == 1)
        #expect(direct.count == 3)
        let plain = SystemProcOps(killer: { _, _ in EPERM })
        #expect(!plain.send(SIGTERM, to: 1))
    }
}
