import Testing
import Foundation
@testable import MultitulCore

@Suite struct StorozhCollectorTests {
    final class Clock { var t: Int64 = stzNow }

    func make(_ ops: MockOps = MockOps(), clock: Clock = Clock(), enabled: Bool = true,
              snapshot: ((StorozhRepository, String, AnomalyRow, StorozhThresholds) -> String?)? = nil) throws -> (StorozhCollector, Store, StorozhRepository) {
        let c = StorozhCollector(ops: ops, pathOf: { _ in "/Users/x/bin/tool" }, launchdPids: { [] },
                                 now: { Date(timeIntervalSince1970: TimeInterval(clock.t)) }, isEnabled: { enabled }, snapshot: snapshot)
        let store = try stzStore()
        return (c, store, StorozhRepository(store: store))
    }

    func fillHog(_ store: Store, name: String = "yes", pid: Int32 = 500, idle: Double = 300) throws {
        for i in 0..<11 {
            let ts = stzNow - Int64(10 - i) * 30
            try stzInsertState(store, ts: ts, idle: idle)
            try stzInsertProc(store, ts: ts, pid: pid, name: name, cpu: 99)
        }
    }

    @Test func registeredWithMigrationsAndRetention() throws {
        let (c, store, _) = try make()
        try store.migrate(c.migrations)
        #expect(try store.appliedMigrations().contains { $0.scope == "storozh" && $0.version == 1 })
        #expect(c.id == "storozh")
        #expect(c.interval == 30)
        #expect(c.retention.map(\.table).sorted() == ["storozh_anomalies", "storozh_outbox"])
        let r = CollectorRegistry.standard()
        #expect(r.collectors.map(\.id).contains("storozh"))
        #expect(r.collectors.firstIndex { $0.id == "storozh" }! > r.collectors.firstIndex { $0.id == "system" }!)
    }

    @Test func notWhitelistedHogRecordsAnomalyAndNotifies() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let (c, store, repo) = try make(ops)
        try fillHog(store)
        try c.collect(store: store)
        let a = try #require(try repo.anomalies(since: 0).first)
        #expect(a.kind == "cpu_hog")
        #expect(a.name == "yes")
        #expect(a.action == "notify")
        #expect(a.status == "pending_user")
        #expect(ops.sent.isEmpty)
        let pending = try repo.pendingNotifications(since: 0)
        #expect(pending.count == 1)
        #expect(pending.first?.anomaly.id == a.id)
        #expect(try repo.openAnomalies(since: 0).count == 1)
    }

    @Test func whitelistedHogIsRestartedSilently() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "Telegram", path: "/Applications/Telegram.app/Contents/MacOS/Telegram")
        ops.bundles["/Applications/Telegram.app"] = "ru.telegram.test"
        let (c, store, repo) = try make(ops)
        try fillHog(store, name: "Telegram")
        try c.collect(store: store)
        #expect(ops.sent.map(\.sig) == [SIGTERM])
        #expect(ops.opened == ["ru.telegram.test"])
        let a = try #require(try repo.anomalies(since: 0).first)
        #expect(a.action == "restart")
        #expect(a.status == "done")
        #expect(try repo.pendingNotifications(since: 0).isEmpty)
    }

    @Test func untouchableHogIsNeverRecorded() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "sing-box")
        let (c, store, repo) = try make(ops)
        try fillHog(store, name: "sing-box")
        try c.collect(store: store)
        #expect(try repo.anomalies(since: 0).isEmpty)
        #expect(ops.sent.isEmpty)
    }

    @Test func secondTickWithinThirtyMinutesDoesNotRepeat() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let clock = Clock()
        let (c, store, repo) = try make(ops, clock: clock)
        try fillHog(store)
        try c.collect(store: store)
        clock.t += 30
        try stzInsertState(store, ts: stzNow + 30, idle: 300)
        try stzInsertProc(store, ts: stzNow + 30, pid: 500, name: "yes", cpu: 99)
        try c.collect(store: store)
        #expect(try repo.anomalies(since: 0).count == 1)
    }

    @Test func disabledKindAndDisabledModuleDoNothing() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let (c, store, repo) = try make(ops)
        try fillHog(store)
        try repo.seedIfNeeded()
        try repo.setKind("cpu_hog", enabled: false)
        try c.collect(store: store)
        #expect(try repo.anomalies(since: 0).isEmpty)

        let (off, store2, repo2) = try make(ops, enabled: false)
        try fillHog(store2)
        try off.collect(store: store2)
        #expect(try repo2.anomalies(since: 0).isEmpty)
        #expect(try repo2.isSeeded() == false)
    }

    @Test func staleSystemDataIsNotJudged() throws {
        let clock = Clock()
        clock.t = stzNow + 600
        let (c, store, repo) = try make(MockOps(), clock: clock)
        try fillHog(store)
        try c.collect(store: store)
        #expect(try repo.anomalies(since: 0).isEmpty)
    }

    @Test func systemDetectorsNotifyAndSnapshotPathTravelsWithOutbox() throws {
        var snaps: [String] = []
        let (c, store, repo) = try make(MockOps(), snapshot: { _, kind, _, _ in snaps.append(kind); return "/tmp/snap-\(kind).md" })
        for i in 0..<3 { try stzInsertState(store, ts: stzNow - Int64(2 - i) * 30, swap: 9000) }
        try c.collect(store: store)
        #expect(snaps == ["swap"])
        let p = try #require(try repo.pendingNotifications(since: 0).first)
        #expect(p.anomaly.kind == "swap")
        #expect(p.snapshot == "/tmp/snap-swap.md")
        try repo.markDelivered(p.outboxId)
        #expect(try repo.pendingNotifications(since: 0).isEmpty)
    }

    @Test func eachSystemDetectorFiresFromRowsInStore() throws {
        let (c, store, repo) = try make()
        for i in 0..<11 {
            let ts = stzNow - Int64(10 - i) * 30
            try stzInsertState(store, ts: ts, pressure: 4, swap: 9000, idle: 900, batt: 80 - i * 1, ac: false, thermal: 2, disk: 3)
        }
        try c.collect(store: store)
        let kinds = Set(try repo.anomalies(since: 0).map(\.kind))
        #expect(kinds.isSuperset(of: ["mem_pressure", "swap", "disk_low", "thermal"]))
        #expect(!kinds.contains("battery_drain"))
    }

    @Test func seedingIsOneTimeAndListsAreEditable() throws {
        let (_, store, repo) = try make()
        try repo.seedIfNeeded()
        var l = try repo.lists()
        #expect(l.whitelist == StorozhLists.defaultWhitelist)
        try repo.addEntry("Slack*", to: .whitelist)
        try repo.removeEntry("node", from: .whitelist)
        try repo.seedIfNeeded()
        l = try repo.lists()
        #expect(l.whitelist.contains("Slack*"))
        #expect(!l.whitelist.contains("node"))
        #expect(try repo.removeEntry("sing-box", from: .untouchable) == false)
        #expect(try repo.addEntry("my-daemon", to: .untouchable))
        #expect(try repo.lists().effectiveUntouchable.contains("my-daemon"))
        #expect(try repo.lists().effectiveUntouchable.contains("pathhas:playwright"))
        try repo.moveEntry("Slack*", to: .ignore)
        l = try repo.lists()
        #expect(l.ignore == ["Slack*"])
        #expect(!l.whitelist.contains("Slack*"))
        _ = store
    }

    @Test func userActionsFromNotificationButtons() throws {
        let ops = MockOps()
        ops.procs[500] = pinfo(500, "yes")
        let (c, store, repo) = try make(ops)
        try fillHog(store)
        try c.collect(store: store)
        let id = try #require(try repo.anomalies(since: 0).first?.id)

        let ig = StorozhReactions.handleAction(repo: repo, id: id, action: "ignore", ops: ops)
        #expect(ig.status == "done")
        #expect(try repo.lists().ignore == ["yes"])

        let wl = StorozhReactions.handleAction(repo: repo, id: id, action: "whitelist", ops: ops)
        #expect(wl.status == "done")
        let l = try repo.lists()
        #expect(l.whitelist.contains("yes"))
        #expect(!l.ignore.contains("yes"))

        let k = StorozhReactions.handleAction(repo: repo, id: id, action: "kill", ops: ops)
        #expect(k.status == "done")
        #expect(ops.sent.map(\.sig) == [SIGTERM])
        #expect(try repo.anomaly(id: id)?.action == "kill")

        #expect(StorozhReactions.handleAction(repo: repo, id: id, action: "format-disk", ops: ops).status == "failed")
        #expect(StorozhReactions.handleAction(repo: repo, id: 999, action: "kill", ops: ops).status == "failed")
    }

    @Test func systemAnomalyHasNoProcessActionButCanBeDismissed() throws {
        let (c, store, repo) = try make()
        for i in 0..<3 { try stzInsertState(store, ts: stzNow - Int64(2 - i) * 30, swap: 9000) }
        try c.collect(store: store)
        let id = try #require(try repo.anomalies(since: 0).first?.id)
        #expect(StorozhReactions.handleAction(repo: repo, id: id, action: "kill", ops: MockOps()).status == "failed")
        #expect(StorozhReactions.handleAction(repo: repo, id: id, action: "dismiss", ops: MockOps()).status == "done")
        #expect(try repo.openAnomalies(since: 0).isEmpty)
    }

    @Test func settingsPersistThresholdsDisabledAndPause() throws {
        let (_, _, repo) = try make()
        var s = try repo.settings()
        #expect(s == StorozhSettings())
        var th = StorozhThresholds()
        th.swapMb = 2048
        try repo.setThresholds(th)
        try repo.setKind("thermal", enabled: false)
        try repo.setPausedUntil(1234.5)
        s = try repo.settings()
        #expect(s.thresholds.swapMb == 2048)
        #expect(s.disabledKinds == ["thermal"])
        #expect(s.pausedUntil == 1234.5)
        #expect(s.isPaused(at: 1000))
        #expect(!s.isPaused(at: 1234.5))
        try repo.setKind("thermal", enabled: true)
        #expect(try repo.settings().disabledKinds.isEmpty)
    }

    @Test func weeklyOffendersGroupByName() throws {
        let (_, _, repo) = try make()
        let now = Date(timeIntervalSince1970: TimeInterval(stzNow))
        for (ts, kind, name) in [(stzNow - 100, "cpu_hog", "yes"), (stzNow - 4000, "mem_leak", "yes"), (stzNow - 200, "swap", "system"), (stzNow - 9 * 86400, "cpu_hog", "old")] {
            try repo.record(ts: ts, AnomalyCandidate(kind: kind, pid: 1, name: name, detail: [:]))
        }
        let o = try repo.weeklyOffenders(now: now)
        #expect(o == [Offender(name: "yes", count: 2, kinds: ["cpu_hog", "mem_leak"])])
    }
}
