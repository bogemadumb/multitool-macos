import Testing
import Foundation
@testable import MultitulCore

@Suite struct VpnJournalCleanTests {
    static let falseDns = "DNS: 1.1.1.1 виден из SE; Гео для cloudflare.com: SE · 198.51.100.131"

    @Test func classifiesFalseAndRealLeaks() {
        #expect(VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: Self.falseDns))
        #expect(VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "DNS: 1.1.1.1 виден из LT"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "DNS: 1.1.1.1 виден из RU"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "DNS: 1.1.1.1 виден из NL; Гео для cloudflare.com: RU · 1.2.3.4"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "Гео для cloudflare.com: SE · 198.51.100.131"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "Утечка IPv6: RU · 2a00::1"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "leak", detail: "DNS: 1.1.1.1 виден из SE; что-то новое"))
        #expect(!VpnJournalClean.isFalseDnsLeak(kind: "net", detail: Self.falseDns))
    }

    private func seeded() throws -> Store {
        let s = try VpnHistorySchema.openStore(path: tempDBPath())
        let rows: [(Int64, String, String)] = [
            (100, "leak", Self.falseDns), (200, "leak", Self.falseDns), (300, "leak", "DNS: 1.1.1.1 виден из RU"),
            (400, "net", "Wi-Fi"), (500, "leak", "Утечка IPv6: RU · 2a00::1"), (600, "server", Self.falseDns)]
        for r in rows { _ = try s.run("INSERT INTO vpn_events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)", [.int(r.0), .int(r.0), .text(r.1), .text(r.2)]) }
        return s
    }

    @Test func planSeparatesRemovalFromKept() throws {
        let plan = try VpnJournalClean.plan(try seeded())
        #expect(plan.totalEvents == 6 && plan.remove.map(\.ts) == [100, 200])
        #expect(plan.keepLeaks.map(\.ts) == [300, 500])
    }

    @Test func dryRunLeavesDatabaseUntouchedAndApplyDeletes() throws {
        let path = tempDBPath()
        do {
            let s = try VpnHistorySchema.openStore(path: path)
            for t in [100, 200] { _ = try s.run("INSERT INTO vpn_events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)", [.int(Int64(t)), .int(Int64(t)), .text("leak"), .text(Self.falseDns)]) }
            _ = try s.run("INSERT INTO vpn_events(ts_start, ts_end, kind, detail) VALUES(300,300,'leak','DNS: 1.1.1.1 виден из RU')")
        }
        var lines: [String] = []
        #expect(VpnJournalCleanCLI.run(arguments: ["--dry-run", "--db", path]) { lines.append($0) } == 0)
        #expect(lines.contains { $0.contains("будут удалены") && $0.hasSuffix(": 2") })
        let after = try Store(path: path, migrations: [], retention: [], readOnly: true)
        #expect(try after.scalarInt("SELECT count(*) FROM vpn_events") == 3)
        #expect(VpnJournalCleanCLI.run(arguments: ["--db", path]) { _ in } == 64)
        #expect(VpnJournalCleanCLI.run(arguments: ["--dry-run", "--apply", "--db", path]) { _ in } == 64)
        #expect(VpnJournalCleanCLI.run(arguments: ["--apply", "--db", path]) { _ in } == 0)
        let done = try Store(path: path, migrations: [], retention: [], readOnly: true)
        #expect(try done.scalarInt("SELECT count(*) FROM vpn_events") == 1)
    }

    @Test func collapseMergesConsecutiveIdenticalEvents() {
        func ev(_ id: Int64, _ t: Double, _ kind: String, _ detail: String, open: Bool = false) -> VpnEventRow {
            VpnEventRow(id: id, start: Date(timeIntervalSince1970: t), end: open ? nil : Date(timeIntervalSince1970: t), kind: kind, detail: detail)
        }
        let events = [ev(1, 10, "leak", "a"), ev(2, 20, "leak", "a"), ev(3, 30, "leak", "a"), ev(4, 40, "net", "x"), ev(5, 50, "leak", "a"),
                      ev(6, 60, "net", "o", open: true), ev(7, 70, "net", "o", open: true)]
        let g = VpnEventCollapse.collapse(events)
        #expect(g.map(\.count) == [1, 1, 1, 1, 3])
        #expect(g.last?.latest.id == 3 && g.last?.earliest == Date(timeIntervalSince1970: 10))
        #expect(VpnEventCollapse.collapse([]).isEmpty)
    }
}

private extension VpnEventRow { var ts: Int { Int(start.timeIntervalSince1970) } }
