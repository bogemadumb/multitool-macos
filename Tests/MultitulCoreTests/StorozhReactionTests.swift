import Testing
import Foundation
@testable import MultitulCore

@Suite struct StorozhReactionTests {
    func facts(_ i: ProcInfo, launchd: Set<Int32> = []) -> ProcFacts { ProcFacts(info: i, launchdPids: launchd) }

    func react(_ name: String, kind: String = "cpu_hog", pid: Int32 = 3000, rep: Bool = false, f: ProcFacts? = nil, lists: StorozhLists = StorozhLists()) -> StorozhReaction {
        StorozhReactions.decide(kind: kind, name: name, pid: pid, repeatFlag: rep, facts: f, lists: lists)
    }

    // MARK: untouchable guard

    @Test func untouchableNeverActedOnEvenIfWhitelisted() {
        var lists = StorozhLists()
        lists.whitelist += ["sing-box", "claude", "xray", "VPNMonitor", "Multitul"]
        for n in ["sing-box", "claude", "xray", "VPNMonitor", "Multitul"] {
            #expect(react(n, f: facts(pinfo(3000, n)), lists: lists) == .skip, "\(n)")
        }
    }

    @Test func claudeAndCodexBinariesCoveredByPath() {
        let lists = StorozhLists()
        let v = pinfo(3000, "2.1.281", path: "/Users/user/.local/share/claude/versions/2.1.281")
        #expect(isUntouchable(v, lists))
        #expect(react("2.1.281", f: facts(v), lists: lists) == .skip)
        #expect(isUntouchable(pinfo(3001, "claude", path: "/Users/user/.vscode/extensions/anthropic.claude-code-2.1.300-darwin-arm64/resources/native-binary/claude"), lists))
        #expect(isUntouchable(pinfo(3002, "codex", path: "/Users/user/.vscode/extensions/openai.chatgpt-26.5/bin/macos-aarch64/codex"), lists))
        #expect(isUntouchable(pinfo(3003, "Claude Helper (Renderer)", path: "/Applications/Claude.app/Contents/Frameworks/x"), lists))
    }

    @Test func multitulItselfIsUntouchableByNameAndBundlePath() {
        let lists = StorozhLists()
        #expect(isUntouchable(pinfo(3000, "Multitul", path: "/Users/user/Applications/Multitul.app/Contents/MacOS/Multitul"), lists))
        #expect(isUntouchable(pinfo(3001, "multitul-ctl", path: "/usr/local/libexec/multitul-ctl"), lists))
        #expect(isUntouchable(pinfo(3002, "Some Helper", path: "/Users/user/Applications/Multitul.app/Contents/Frameworks/Some Helper"), lists))
    }

    @Test func untouchableSurvivesEmptiedUserList() {
        var lists = StorozhLists()
        lists.untouchable = []
        #expect(react("sing-box", f: facts(pinfo(3000, "sing-box")), lists: lists) == .skip)
        #expect(react("anything", pid: 120, f: facts(pinfo(120, "anything")), lists: lists) == .skip)
    }

    @Test func playwrightDaemonIsUntouchable() {
        let args = "/usr/local/bin/node /Users/x/.local/lib/node_modules/@playwright/cli/node_modules/playwright-core/lib/entry/cliDaemon.js web --persistent"
        let daemon = pinfo(7001, "node", path: "/usr/local/bin/node", ppid: 1, args: args)
        #expect(isUntouchable(daemon, StorozhLists()))
        #expect(react("node", pid: 7001, f: facts(daemon)) == .skip)
        #expect(!isUntouchable(pinfo(7002, "node", path: "/usr/local/bin/node", ppid: 1, args: "/usr/local/bin/node server.js"), StorozhLists()))
    }

    // MARK: decide

    @Test func repeatOffenderGetsRestartUseless() {
        #expect(react("Telegram", rep: true, f: facts(pinfo(3000, "Telegram"))) == .restartUseless)
        #expect(react("Telegram", rep: false, f: facts(pinfo(3000, "Telegram"))) == .restart)
    }

    @Test func ignoreListWinsOverWhitelist() {
        var lists = StorozhLists()
        lists.ignore = ["Telegram"]
        #expect(react("Telegram", f: facts(pinfo(3000, "Telegram")), lists: lists) == .ignored)
    }

    @Test func whitelistGlobRestarts() {
        #expect(react("Code Helper (Renderer)", f: facts(pinfo(3000, "Code Helper (Renderer)"))) == .restart)
        #expect(react("Google Chrome Helper (GPU)", f: facts(pinfo(3000, "Google Chrome Helper (GPU)"))) == .restart)
    }

    @Test func nonListedNotifies() {
        #expect(react("yes", f: facts(pinfo(3000, "yes"))) == .notify)
        #expect(react("yes", f: nil) == .notify)
    }

    @Test func systemKindsAlwaysNotify() {
        for k in ["swap", "mem_pressure", "battery_drain", "disk_low", "thermal"] {
            #expect(react("sing-box", kind: k, pid: 642) == .notify, "\(k)")
        }
    }

    @Test func devServerOnlyWhenOrphan() {
        let orphan = pinfo(3000, "node", ppid: 1)
        #expect(react("node", f: facts(orphan)) == .restart)
        #expect(react("node", f: facts(pinfo(3000, "node", ppid: 777))) == .notify)
        #expect(react("node", f: facts(pinfo(3000, "node", ppid: 1, tty: true))) == .notify)
        #expect(react("node", f: facts(orphan, launchd: [3000])) == .notify)
        #expect(react("node", f: nil) == .notify)
    }

    @Test func pythonHttpServerOrphan() {
        var lists = StorozhLists()
        lists.whitelist.append("python*")
        let srv = pinfo(3000, "python3", ppid: 1, args: "python3 -m http.server 8000")
        #expect(isOrphanDevServer(facts(srv)))
        #expect(react("python3", f: facts(srv), lists: lists) == .restart)
        #expect(react("python3", f: facts(pinfo(3000, "python3", ppid: 1, args: "python3 job.py")), lists: lists) == .notify)
    }

    // MARK: terminate

    @Test func pidReuseRefusedNoSignals() {
        let ops = MockOps()
        ops.procs[3000] = pinfo(3000, "Safari")
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "Telegram", relaunch: true, lists: StorozhLists(), ops: ops)
        #expect(r.status == "failed")
        #expect(r.note.hasPrefix("pid reused"))
        #expect(ops.sent.isEmpty)
    }

    @Test func missingProcessRefused() {
        let ops = MockOps()
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "Telegram", relaunch: false, lists: StorozhLists(), ops: ops)
        #expect(r.status == "failed")
        #expect(ops.sent.isEmpty)
    }

    @Test func untouchableTargetRefusedNoSignals() {
        let ops = MockOps()
        ops.procs[642] = pinfo(642, "sing-box", path: "/opt/homebrew/bin/sing-box", ppid: 1)
        for relaunch in [true, false] {
            var lists = StorozhLists()
            lists.whitelist.append("sing-box")
            let r = ProcessTerminator.terminate(pid: 642, expectedName: "sing-box", relaunch: relaunch, lists: lists, ops: ops)
            #expect(r.status == "failed")
            #expect(r.note.hasPrefix("refused"))
        }
        #expect(ops.sent.isEmpty)
    }

    @Test func untouchableChildProtectsParent() {
        let ops = MockOps()
        ops.procs[3000] = pinfo(3000, "Code Helper (Plugin)")
        ops.children[3000] = [pinfo(3001, "claude", path: "/x/native-binary/claude", ppid: 3000)]
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "Code Helper (Plugin)", relaunch: true, lists: StorozhLists(), ops: ops)
        #expect(r.status == "failed")
        #expect(r.note.contains("untouchable child"))
        #expect(ops.sent.isEmpty)
    }

    @Test func termThenNothingElseWhenItDies() {
        let ops = MockOps()
        ops.procs[3000] = pinfo(3000, "yes")
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "yes", relaunch: false, lists: StorozhLists(), ops: ops)
        #expect(r.status == "done")
        #expect(ops.sent.map(\.sig) == [SIGTERM])
    }

    @Test func killEscalatesToSigkill() {
        let ops = MockOps()
        ops.diesOnTerm = false
        ops.procs[3000] = pinfo(3000, "yes")
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "yes", relaunch: false, lists: StorozhLists(), ops: ops)
        #expect(r.status == "done")
        #expect(ops.sent.map(\.sig) == [SIGTERM, SIGKILL])
    }

    @Test func mainAppRelaunchedHelperNot() {
        let ops = MockOps()
        ops.procs[3000] = pinfo(3000, "Telegram", path: "/Applications/Telegram.app/Contents/MacOS/Telegram")
        ops.bundles["/Applications/Telegram.app"] = "ru.telegram.test"
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "Telegram", relaunch: true, lists: StorozhLists(), ops: ops)
        #expect(r.status == "done")
        #expect(ops.opened == ["ru.telegram.test"])

        let h = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(mainBundlePath(ofExecutable: h) == nil)
        ops.procs[3001] = pinfo(3001, "Google Chrome Helper", path: h)
        ops.bundles["/Applications/Google Chrome.app"] = "com.google.Chrome"
        let r2 = ProcessTerminator.terminate(pid: 3001, expectedName: "Google Chrome Helper", relaunch: true, lists: StorozhLists(), ops: ops)
        #expect(r2.status == "done")
        #expect(ops.opened == ["ru.telegram.test"])
    }

    @Test func dryRunSendsNothing() {
        let ops = MockOps()
        ops.procs[3000] = pinfo(3000, "yes")
        let r = ProcessTerminator.terminate(pid: 3000, expectedName: "yes", relaunch: false, lists: StorozhLists(), ops: ops, dry: true)
        #expect(r.status == "dry_run")
        #expect(ops.sent.isEmpty)
    }

    // MARK: kill tree

    func tree() -> MockOps {
        // 3100 -> 3101 -> 3103 -> 3105 ; 3100 -> 3102 -> 3104
        let ops = MockOps()
        ops.procs[3100] = pinfo(3100, "app", ppid: 1)
        let kids = [pinfo(3101, "w1", ppid: 3100), pinfo(3102, "w2", ppid: 3100), pinfo(3103, "w3", ppid: 3101), pinfo(3104, "w4", ppid: 3102), pinfo(3105, "w5", ppid: 3103)]
        for k in kids { ops.procs[k.pid] = k }
        ops.children[3100] = kids
        return ops
    }

    @Test func killOrderIsLeavesFirstRootLast() {
        let ops = tree()
        let order = ProcessTerminator.killOrder(root: 3100, descendants: ops.children[3100] ?? [])
        #expect(order == [3105, 3103, 3101, 3104, 3102, 3100])
        for (i, pid) in order.enumerated() {
            let parent = ops.procs[pid]?.ppid ?? 0
            if let pi = order.firstIndex(of: parent) { #expect(pi > i, "parent \(parent) must come after child \(pid)") }
        }
    }

    @Test func killTreeSendsTermInOrderThenNothing() {
        let ops = tree()
        let r = ProcessTerminator.killTree(pid: 3100, expectedName: "app", lists: StorozhLists(), ops: ops)
        #expect(r.status == "done")
        #expect(ops.sent.map(\.pid) == [3105, 3103, 3101, 3104, 3102, 3100])
        #expect(ops.sent.allSatisfy { $0.sig == SIGTERM })
    }

    @Test func killTreeEscalatesOnlyStragglers() {
        let ops = tree()
        ops.diesOnTerm = false
        let r = ProcessTerminator.killTree(pid: 3100, expectedName: "app", lists: StorozhLists(), ops: ops)
        #expect(r.status == "done")
        #expect(ops.sent.prefix(6).map(\.sig) == Array(repeating: SIGTERM, count: 6))
        #expect(ops.sent.suffix(6).map(\.pid) == [3105, 3103, 3101, 3104, 3102, 3100])
        #expect(ops.sent.suffix(6).allSatisfy { $0.sig == SIGKILL })
    }

    @Test func killTreeRefusedWhenAnyMemberUntouchable() {
        let ops = tree()
        ops.children[3100]?[2] = pinfo(3103, "sing-box", ppid: 3101)
        let r = ProcessTerminator.killTree(pid: 3100, expectedName: "app", lists: StorozhLists(), ops: ops)
        #expect(r.status == "failed")
        #expect(r.note.contains("untouchable child"))
        #expect(ops.sent.isEmpty)
    }

    @Test func killTreeDryRunAndReusedPid() {
        let ops = tree()
        #expect(ProcessTerminator.killTree(pid: 3100, expectedName: "app", lists: StorozhLists(), ops: ops, dry: true).status == "dry_run")
        #expect(ProcessTerminator.killTree(pid: 3100, expectedName: "other", lists: StorozhLists(), ops: ops).note.hasPrefix("pid reused"))
        #expect(ops.sent.isEmpty)
    }

    // MARK: ps parsing

    @Test func psParsersBuildInfoAndDescendants() {
        let i = ProcParsers.info(pid: 42, psLine: " Ss       1 ??         501 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n", args: "/x/y\n", pathOf: { _ in nil })
        #expect(i?.name == "Google Chrome")
        #expect(i?.ppid == 1)
        #expect(i?.uid == 501)
        #expect(i?.hasTTY == false)
        #expect(i?.zombie == false)
        #expect(ProcParsers.info(pid: 1, psLine: "garbage", args: "") == nil)
        let z = ProcParsers.info(pid: 9, psLine: "Z 1 ttys001 501 (defunct)", args: "", pathOf: { _ in nil })
        #expect(z?.zombie == true)
        #expect(z?.hasTTY == true)
        let ps = "10 1 /bin/a\n11 10 /bin/b\n12 11 /bin/c c\n13 1 /bin/d\n"
        #expect(ProcParsers.descendants(of: 10, psText: ps, pathOf: { _ in nil }).map(\.pid).sorted() == [11, 12])
    }

    // MARK: notifications

    @Test func notificationRoutingAcceptsOnlyStorozhActions() {
        let act = NotificationEvent(requestId: "storozh-7", actionId: "kill", userInfo: ["anomalyId": "7"])
        #expect(StorozhNotifications.route(act) == .act(anomalyId: 7, action: "kill"))
        let tap = NotificationEvent(requestId: "storozh-7", actionId: NotificationEvent.defaultAction, userInfo: ["anomalyId": "7", "snapshot": "/tmp/a.md"])
        #expect(StorozhNotifications.route(tap) == .openSnapshot(path: "/tmp/a.md"))
        #expect(StorozhNotifications.route(NotificationEvent(requestId: "storozh-7", actionId: NotificationEvent.defaultAction, userInfo: [:])) == nil)
        #expect(StorozhNotifications.route(NotificationEvent(requestId: "vpn-1", actionId: "kill", userInfo: ["anomalyId": "7"])) == nil)
        #expect(StorozhNotifications.route(NotificationEvent(requestId: "storozh-7", actionId: "rm-rf", userInfo: ["anomalyId": "7"])) == nil)
        #expect(StorozhNotifications.route(NotificationEvent(requestId: "storozh-7", actionId: "kill", userInfo: [:])) == nil)
    }

    @Test func notificationCategoriesMatchReactions() {
        let cats = Dictionary(uniqueKeysWithValues: StorozhNotifications.categories.map { ($0.id, $0.actions.map(\.title)) })
        #expect(cats[StorozhNotifications.categoryProc] == ["Перезапустить", "Убить", "Игнор", "В белый список"])
        #expect(cats[StorozhNotifications.categoryUseless] == ["Убить", "Игнор"])
        #expect(cats[StorozhNotifications.categorySystem] == [])
        let swap = AnomalyRow(id: 1, ts: 0, kind: "swap", pid: 0, name: "system", detail: "{}", status: "pending_user")
        let hog = AnomalyRow(id: 2, ts: 0, kind: "cpu_hog", pid: 5, name: "yes", detail: "{}", action: "restart_useless", status: "pending_user")
        #expect(StorozhNotifications.category(for: swap) == StorozhNotifications.categorySystem)
        #expect(StorozhNotifications.category(for: hog) == StorozhNotifications.categoryUseless)
    }

    @Test func notificationTexts() {
        let row = AnomalyRow(id: 1, ts: 0, kind: "disk_low", pid: 0, name: "system", detail: "{\"free_gb\":3.2,\"limit_gb\":10}", status: "pending_user")
        #expect(StorozhReactions.notificationText(row).title.contains("3.2"))
        let hog = AnomalyRow(id: 1, ts: 0, kind: "cpu_hog", pid: 5, name: "yes", detail: "{\"avg_cpu\":99.5,\"window_s\":300,\"rss_mb\":12}", status: "pending_user")
        #expect(StorozhReactions.notificationText(hog).title == "yes грузит CPU")
    }
}
