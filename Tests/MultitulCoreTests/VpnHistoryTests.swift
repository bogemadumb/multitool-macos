import Testing
import Foundation
@testable import MultitulCore

func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

func makeHistory(calendar: Calendar = utcCalendar()) throws -> VpnHistoryStore {
    VpnHistoryStore(store: try VpnHistorySchema.openStore(path: tempDBPath()), calendar: calendar)
}

@Suite struct VpnHistoryTests {
    @Test func migrationScopeVpnApplied() throws {
        let s = try VpnHistorySchema.openStore(path: tempDBPath())
        let applied = try s.appliedMigrations()
        #expect(applied.contains { $0.scope == "vpn" && $0.version == 1 })
        #expect(applied.contains { $0.scope == "core" })
        #expect(try s.scalarInt("SELECT count(*) FROM vpn_samples") == 0)
        #expect(try s.scalarInt("SELECT count(*) FROM vpn_app_traffic") == 0)
        #expect(try s.scalarInt("SELECT count(*) FROM vpn_events") == 0)
    }

    @Test func secondOpenIsNoOp() throws {
        let path = tempDBPath()
        _ = try VpnHistorySchema.openStore(path: path)
        let s = try VpnHistorySchema.openStore(path: path)
        #expect(try s.appliedMigrations().filter { $0.scope == "vpn" }.count == 1)
    }

    @Test func retentionRulesMatchSpec() {
        let r = Dictionary(uniqueKeysWithValues: VpnHistorySchema.retention.map { ($0.table, $0.keepSeconds) })
        let day = 86400.0
        #expect(r["vpn_samples"] == 30 * day)
        #expect(r["vpn_app_traffic"] == 90 * day)
        #expect(r["vpn_events"] == 365 * day)
    }

    @Test func cleanupDropsOldRowsOnly() throws {
        let h = try makeHistory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day = 86400.0
        try h.insertSample(ts: now.addingTimeInterval(-31 * day), down: 1, up: 1, delay: 10, state: "ok")
        try h.insertSample(ts: now.addingTimeInterval(-29 * day), down: 1, up: 1, delay: 10, state: "ok")
        try h.addTraffic(at: now.addingTimeInterval(-91 * day), [VpnTrafficDelta(process: "a", via: "vps", down: 5, up: 5)])
        try h.addTraffic(at: now.addingTimeInterval(-89 * day), [VpnTrafficDelta(process: "a", via: "vps", down: 5, up: 5)])
        h.insertEvent(start: now.addingTimeInterval(-366 * day), end: nil, kind: "net", detail: "old")
        h.insertEvent(start: now.addingTimeInterval(-364 * day), end: nil, kind: "net", detail: "fresh")
        let del = try h.store.cleanup(now: now)
        #expect(del["vpn_samples"] == 1)
        #expect(del["vpn_app_traffic"] == 1)
        #expect(del["vpn_events"] == 1)
        #expect(h.sampleCount() == 1 && h.trafficRowCount() == 1 && h.eventCount() == 1)
    }

    @Test func seriesAveragesIntoBucketsAndMarksDrops() throws {
        let h = try makeHistory()
        let base = (2_000_000_000 / 3600) * 3600
        let now = Date(timeIntervalSince1970: Double(base + 1500))
        for i in 0..<30 {
            try h.insertSample(ts: Date(timeIntervalSince1970: Double(base - 1800 + i * 10)), down: 1000, up: 100, delay: 50 + i, state: "ok")
        }
        for i in 0..<6 {
            try h.insertSample(ts: Date(timeIntervalSince1970: Double(base - 600 + i * 10)), down: 0, up: 0, delay: nil, state: "down")
        }
        let s = h.series(.hour, now: now)
        #expect(s.count == VpnChartRange.hour.count)
        let withData = s.compactMap { $0 }
        #expect(withData.count == 6)
        #expect(withData.contains { $0.drop } && withData.contains { !$0.drop })
        let first = withData.first!
        #expect(first.down == 1000 && first.up == 100)
        #expect(first.delay != nil)
        #expect(withData.first { $0.drop }!.delay == nil)
        #expect(s.last! == nil)
        let avg = h.averageDelay(since: Date(timeIntervalSince1970: Double(base - 3600)))
        #expect(avg != nil && avg! > 50 && avg! < 80)
    }

    @Test func rangeGeometry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for r in VpnChartRange.allCases {
            let start = r.start(now: now)
            #expect(start % r.step == 0)
            #expect(Int(now.timeIntervalSince1970) - start < r.step * r.count)
        }
        #expect(VpnChartRange.month.step * VpnChartRange.month.count == 30 * 86400)
    }

    @Test func trafficTrackerCountsDeltasAndNewConnections() {
        var t = VpnTrafficTracker()
        func c(_ id: String, _ p: String, _ via: String, _ d: Double, _ u: Double) -> VpnConnSnap { VpnConnSnap(id: id, process: p, via: via, down: d, up: u) }
        #expect(t.update([c("1", "safari", "vps", 1000, 100)]).isEmpty)
        let a = t.update([c("1", "safari", "vps", 1500, 150), c("2", "safari", "vps", 300, 30), c("3", "curl", "direct", 40, 0)])
        #expect(a == [VpnTrafficDelta(process: "curl", via: "direct", down: 40, up: 0),
                      VpnTrafficDelta(process: "safari", via: "vps", down: 800, up: 80)])
        #expect(t.update([c("1", "safari", "vps", 1500, 150)]).isEmpty)
        #expect(t.update([c("1", "safari", "vps", 1400, 100)]).isEmpty)
    }

    @Test func trafficAccumulatesPerDayAndTotals() throws {
        let h = try makeHistory()
        let d1 = Date(timeIntervalSince1970: 2_000_000_000)
        try h.addTraffic(at: d1, [VpnTrafficDelta(process: "safari", via: "vps", down: 100, up: 10),
                                  VpnTrafficDelta(process: "safari", via: "direct", down: 50, up: 0),
                                  VpnTrafficDelta(process: "claude", via: "vps", down: 500, up: 5),
                                  VpnTrafficDelta(process: "mdns", via: "local", down: 999, up: 999)])
        try h.addTraffic(at: d1.addingTimeInterval(60), [VpnTrafficDelta(process: "safari", via: "vps", down: 100, up: 10)])
        try h.addTraffic(at: d1.addingTimeInterval(86400), [VpnTrafficDelta(process: "safari", via: "vps", down: 7, up: 0)])
        let rows = h.trafficRows(day: d1, limit: 8)
        #expect(rows.map(\.process) == ["claude", "safari"])
        #expect(rows[1].vps == 220 && rows[1].direct == 50)
        let t = h.trafficTotals(day: d1)
        #expect(t.vps == 725 && t.direct == 50)
        #expect(h.trafficRows(day: d1.addingTimeInterval(86400), limit: 8).count == 1)
        #expect(h.trafficRows(day: d1, limit: 1).count == 1)
    }

    @Test func eventsLifecycleAndStaleDrops() throws {
        let h = try makeHistory()
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let id = h.insertEvent(start: t0, end: nil, kind: "server", detail: "сервер недоступен")
        #expect(id > 0)
        #expect(h.events(limit: 10).first!.isOpen)
        h.closeEvent(id: id, end: t0.addingTimeInterval(95))
        let e = h.events(limit: 10).first!
        #expect(!e.isOpen && e.duration == 95)
        let open = h.insertEvent(start: t0.addingTimeInterval(500), end: nil, kind: "net", detail: "смена сети")
        h.insertEvent(start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(600), kind: "watchdog", detail: "перезапуск")
        h.closeStaleDrops(at: t0.addingTimeInterval(900))
        let all = h.events(limit: 10)
        #expect(all.count == 3)
        #expect(all.first { $0.id == open }!.detail.hasSuffix("(приложение перезапущено)"))
        #expect(all.first { $0.kind == "watchdog" }!.detail == "перезапуск")
        #expect(h.events(limit: 10, excluding: ["watchdog"]).count == 2)
        #expect(h.events(limit: 10, since: t0.addingTimeInterval(550)).count == 1)
    }

    @Test func duplicateEventIsIgnored() throws {
        let h = try makeHistory()
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(h.insertEvent(start: t, end: t, kind: "speed", detail: "10 МБ/с") > 0)
        #expect(h.insertEvent(start: t, end: t, kind: "speed", detail: "10 МБ/с") == 0)
        #expect(h.eventCount() == 1)
    }

    @Test func groupsEventsByDayNewestFirst() {
        let cal = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = cal.startOfDay(for: now)
        func ev(_ id: Int64, _ offset: TimeInterval, _ kind: String) -> VpnEventRow {
            VpnEventRow(id: id, start: day.addingTimeInterval(offset), end: nil, kind: kind, detail: "x")
        }
        let events = [ev(1, -86400 * 2 + 100, "net"), ev(2, 3600, "leak"), ev(3, -3600, "core"), ev(4, 7200, "speed"), ev(5, -86400 * 2 + 5000, "net")]
        let g = VpnEventGrouping.group(events, now: now, calendar: cal)
        #expect(g.count == 3)
        #expect(g[0].title == "Сегодня" && g[0].events.map(\.id) == [4, 2])
        #expect(g[1].title == "Вчера" && g[1].events.map(\.id) == [3])
        #expect(g[2].events.map(\.id) == [5, 1])
        #expect(g[2].title.hasSuffix("октября") || g[2].title.hasSuffix("сентября") || g[2].title.contains(" "))
        #expect(VpnEventGrouping.group([], now: now, calendar: cal).isEmpty)
    }

    @Test func dayKeyParsing() {
        let cal = utcCalendar()
        #expect(VpnDay.parseKey("2026-10-22", calendar: cal) == 1_792_627_200)
        #expect(VpnDay.parseKey("garbage", calendar: cal) == nil)
        #expect(VpnDay.start(of: Date(timeIntervalSince1970: 1_792_627_200 + 3600), calendar: cal) == 1_792_627_200)
    }

    @Test func eventKindTitles() {
        #expect(VpnEventKind.title("watchdog") == "Сторож" && VpnEventKind.title("leak") == "Утечка" && VpnEventKind.title("speed") == "Тест скорости")
        #expect(VpnEventKind.isDrop("net") && VpnEventKind.isDrop("core") && VpnEventKind.isDrop("server") && !VpnEventKind.isDrop("leak"))
    }
}
