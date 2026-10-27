import Foundation

public enum VpnEventKind {
    public static let drops: Set<String> = ["core", "net", "server"]

    public static func title(_ kind: String) -> String {
        switch kind {
        case "core": "Ядро"
        case "net": "Сеть"
        case "server": "Сервер"
        case "watchdog": "Сторож"
        case "leak": "Утечка"
        case "speed": "Тест скорости"
        default: kind
        }
    }

    public static func isDrop(_ kind: String) -> Bool { drops.contains(kind) }
}

public struct VpnEventRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let start: Date
    public let end: Date?
    public let kind: String
    public let detail: String
    public var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }
    public var isOpen: Bool { end == nil && VpnEventKind.isDrop(kind) }

    public init(id: Int64, start: Date, end: Date?, kind: String, detail: String) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.detail = detail
    }
}

public struct VpnBucket: Equatable, Sendable {
    public let ts: Double
    public let down: Double
    public let up: Double
    public let delay: Double?
    public let drop: Bool

    public init(ts: Double, down: Double, up: Double, delay: Double?, drop: Bool) {
        self.ts = ts
        self.down = down
        self.up = up
        self.delay = delay
        self.drop = drop
    }
}

public struct VpnAppRow: Identifiable, Equatable, Sendable {
    public var id: String { process }
    public let process: String
    public let vps: Double
    public let direct: Double
    public var total: Double { vps + direct }

    public init(process: String, vps: Double, direct: Double) {
        self.process = process
        self.vps = vps
        self.direct = direct
    }
}

public struct VpnTrafficDelta: Equatable, Sendable {
    public let process: String
    public let via: String
    public let down: Double
    public let up: Double

    public init(process: String, via: String, down: Double, up: Double) {
        self.process = process
        self.via = via
        self.down = down
        self.up = up
    }
}

public struct VpnConnSnap: Sendable {
    public let id: String
    public let process: String
    public let via: String
    public let down: Double
    public let up: Double

    public init(id: String, process: String, via: String, down: Double, up: Double) {
        self.id = id
        self.process = process
        self.via = via
        self.down = down
        self.up = up
    }
}

public struct VpnTrafficTracker {
    private var seen: [String: (down: Double, up: Double)] = [:]
    private var primed = false

    public init() {}

    public mutating func update(_ conns: [VpnConnSnap]) -> [VpnTrafficDelta] {
        var acc: [String: (process: String, via: String, down: Double, up: Double)] = [:]
        var next: [String: (down: Double, up: Double)] = [:]
        for c in conns {
            next[c.id] = (c.down, c.up)
            var dd = 0.0, du = 0.0
            if let p = seen[c.id] {
                dd = max(0, c.down - p.down)
                du = max(0, c.up - p.up)
            } else if primed {
                dd = c.down
                du = c.up
            }
            guard dd > 0 || du > 0 else { continue }
            let key = c.process + "\u{1}" + c.via
            var a = acc[key] ?? (c.process, c.via, 0, 0)
            a.down += dd
            a.up += du
            acc[key] = a
        }
        seen = next
        primed = true
        return acc.values.map { VpnTrafficDelta(process: $0.process, via: $0.via, down: $0.down, up: $0.up) }
            .sorted { ($0.process, $0.via) < ($1.process, $1.via) }
    }
}

public enum VpnChartRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, month
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour: "Час"
        case .day: "Сутки"
        case .month: "30 дней"
        }
    }

    public var heading: String {
        switch self {
        case .hour: "Скорость за час"
        case .day: "Скорость за сутки"
        case .month: "Скорость за 30 дней"
        }
    }

    public var step: Int {
        switch self {
        case .hour: 60
        case .day: 900
        case .month: 21600
        }
    }

    public var count: Int {
        switch self {
        case .hour: 60
        case .day: 96
        case .month: 120
        }
    }

    public func start(now: Date) -> Int {
        let n = Int(now.timeIntervalSince1970)
        return (n / step) * step - (count - 1) * step
    }
}

public enum VpnDay {
    public static func start(of date: Date, calendar: Calendar = .current) -> Int64 {
        Int64(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    public static func parseKey(_ key: String, calendar: Calendar = .current) -> Int64? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]
        guard let d = calendar.date(from: c) else { return nil }
        return Int64(calendar.startOfDay(for: d).timeIntervalSince1970)
    }
}

public enum VpnHistorySchema {
    public static let scope = "vpn"
    public static let sampleRetentionDays = 30
    public static let trafficRetentionDays = 90
    public static let eventRetentionDays = 365

    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "vpn history", sql: """
            CREATE TABLE IF NOT EXISTS vpn_samples(
                ts INTEGER PRIMARY KEY, down_bps REAL, up_bps REAL, delay_ms INTEGER, state TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS vpn_app_traffic(
                day_ts INTEGER NOT NULL, process TEXT NOT NULL, via TEXT NOT NULL,
                bytes_down INTEGER NOT NULL DEFAULT 0, bytes_up INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(day_ts, process, via));
            CREATE TABLE IF NOT EXISTS vpn_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts_start INTEGER NOT NULL, ts_end INTEGER,
                kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS vpn_events_ts ON vpn_events(ts_start);
            CREATE UNIQUE INDEX IF NOT EXISTS vpn_events_uniq ON vpn_events(ts_start, kind, detail);
            """)
    ]

    public static let retention: [Retention] = [
        Retention(table: "vpn_samples", column: "ts", keepSeconds: Double(sampleRetentionDays) * 86400),
        Retention(table: "vpn_app_traffic", column: "day_ts", keepSeconds: Double(trafficRetentionDays) * 86400),
        Retention(table: "vpn_events", column: "ts_start", keepSeconds: Double(eventRetentionDays) * 86400)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: Store.coreMigrations + migrations, retention: Store.coreRetention + retention)
    }
}

public final class VpnHistoryStore: @unchecked Sendable {
    public let store: Store
    private let calendar: Calendar

    public init(store: Store, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    public static func open(path: String = MultitulPaths.dbPath) -> VpnHistoryStore? {
        guard let s = try? VpnHistorySchema.openStore(path: path) else { return nil }
        return VpnHistoryStore(store: s)
    }

    public func insertSample(ts: Date, down: Double, up: Double, delay: Int?, state: String) throws {
        try store.run("INSERT OR REPLACE INTO vpn_samples(ts, down_bps, up_bps, delay_ms, state) VALUES(?,?,?,?,?)",
                      [.int(Int64(ts.timeIntervalSince1970)), .real(down), .real(up),
                       delay.map { .int(Int64($0)) } ?? .null, .text(state)])
    }

    public func addTraffic(at date: Date, _ deltas: [VpnTrafficDelta]) throws {
        guard !deltas.isEmpty else { return }
        let day = VpnDay.start(of: date, calendar: calendar)
        try store.transaction {
            for d in deltas {
                try store.run("""
                    INSERT INTO vpn_app_traffic(day_ts, process, via, bytes_down, bytes_up) VALUES(?,?,?,?,?)
                    ON CONFLICT(day_ts, process, via) DO UPDATE SET bytes_down = bytes_down + excluded.bytes_down,
                      bytes_up = bytes_up + excluded.bytes_up
                    """, [.int(day), .text(d.process), .text(d.via), .int(Int64(d.down)), .int(Int64(d.up))])
            }
        }
    }

    @discardableResult
    public func insertEvent(start: Date, end: Date?, kind: String, detail: String) -> Int64 {
        let changed = (try? store.run("INSERT OR IGNORE INTO vpn_events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)",
                                      [.int(Int64(start.timeIntervalSince1970)),
                                       end.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null, .text(kind), .text(detail)])) ?? 0
        return changed > 0 ? store.lastInsertRowId : 0
    }

    public func closeEvent(id: Int64, end: Date) {
        _ = try? store.run("UPDATE vpn_events SET ts_end = ? WHERE id = ?", [.int(Int64(end.timeIntervalSince1970)), .int(id)])
    }

    public func closeStaleDrops(at now: Date) {
        _ = try? store.run("""
            UPDATE vpn_events SET ts_end = ?, detail = detail || ' (приложение перезапущено)'
            WHERE ts_end IS NULL AND kind IN ('net','core','server')
            """, [.int(Int64(now.timeIntervalSince1970))])
    }

    public func events(limit: Int, since: Date? = nil, excluding: [String] = []) -> [VpnEventRow] {
        var where_: [String] = []
        var args: [SQLValue] = []
        if let since {
            where_.append("ts_start >= ?")
            args.append(.int(Int64(since.timeIntervalSince1970)))
        }
        if !excluding.isEmpty {
            where_.append("kind NOT IN (\(excluding.map { _ in "?" }.joined(separator: ",")))")
            args += excluding.map { .text($0) }
        }
        let clause = where_.isEmpty ? "" : "WHERE " + where_.joined(separator: " AND ")
        args.append(.int(Int64(limit)))
        let rows = (try? store.query("SELECT id, ts_start, ts_end, kind, detail FROM vpn_events \(clause) ORDER BY ts_start DESC, id DESC LIMIT ?", args)) ?? []
        return rows.map {
            VpnEventRow(id: $0.int(0) ?? 0,
                        start: Date(timeIntervalSince1970: Double($0.int(1) ?? 0)),
                        end: $0.int(2).map { Date(timeIntervalSince1970: Double($0)) },
                        kind: $0.string(3) ?? "", detail: $0.string(4) ?? "")
        }
    }

    public func series(_ range: VpnChartRange, now: Date) -> [VpnBucket?] {
        let start = range.start(now: now)
        let step = range.step
        let rows = (try? store.query("""
            SELECT (ts / ?1) * ?1 AS b, AVG(down_bps), AVG(up_bps), AVG(delay_ms),
                   MAX(CASE WHEN state = 'down' THEN 1 ELSE 0 END)
            FROM vpn_samples WHERE ts >= ?2 GROUP BY b ORDER BY b
            """, [.int(Int64(step)), .int(Int64(start))])) ?? []
        var out = [VpnBucket?](repeating: nil, count: range.count)
        for r in rows {
            guard let ts = r.int(0) else { continue }
            let i = (Int(ts) - start) / step
            guard i >= 0 && i < range.count else { continue }
            out[i] = VpnBucket(ts: Double(ts), down: r.double(1) ?? 0, up: r.double(2) ?? 0, delay: r.double(3), drop: (r.int(4) ?? 0) == 1)
        }
        return out
    }

    public func averageDelay(since: Date) -> Double? {
        let r = try? store.query("SELECT AVG(delay_ms) FROM vpn_samples WHERE ts >= ? AND delay_ms IS NOT NULL",
                                 [.int(Int64(since.timeIntervalSince1970))])
        return r?.first?.double(0)
    }

    public func sampleCount() -> Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM vpn_samples")) ?? 0) }
    public func trafficRowCount() -> Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM vpn_app_traffic")) ?? 0) }
    public func eventCount() -> Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM vpn_events")) ?? 0) }

    public func trafficRows(day: Date, limit: Int) -> [VpnAppRow] {
        let d = VpnDay.start(of: day, calendar: calendar)
        let rows = (try? store.query("""
            SELECT process,
              SUM(CASE WHEN via = 'vps' THEN bytes_down + bytes_up ELSE 0 END),
              SUM(CASE WHEN via = 'direct' THEN bytes_down + bytes_up ELSE 0 END)
            FROM vpn_app_traffic WHERE day_ts = ? AND via IN ('vps', 'direct')
            GROUP BY process ORDER BY SUM(bytes_down + bytes_up) DESC, process LIMIT ?
            """, [.int(d), .int(Int64(limit))])) ?? []
        return rows.map { VpnAppRow(process: $0.string(0) ?? "", vps: $0.double(1) ?? 0, direct: $0.double(2) ?? 0) }
    }

    public func trafficTotals(day: Date) -> (vps: Double, direct: Double) {
        let d = VpnDay.start(of: day, calendar: calendar)
        let r = try? store.query("""
            SELECT SUM(CASE WHEN via = 'vps' THEN bytes_down + bytes_up ELSE 0 END),
                   SUM(CASE WHEN via = 'direct' THEN bytes_down + bytes_up ELSE 0 END)
            FROM vpn_app_traffic WHERE day_ts = ?
            """, [.int(d)])
        return (r?.first?.double(0) ?? 0, r?.first?.double(1) ?? 0)
    }
}

public struct VpnEventGroup: Identifiable, Equatable, Sendable {
    public let latest: VpnEventRow
    public let count: Int
    public let earliest: Date
    public var id: Int64 { latest.id }
    public var start: Date { latest.start }
    public var kind: String { latest.kind }
    public var detail: String { latest.detail }

    public init(latest: VpnEventRow, count: Int, earliest: Date) {
        self.latest = latest
        self.count = count
        self.earliest = earliest
    }
}

public enum VpnEventCollapse {
    public static func collapse(_ events: [VpnEventRow]) -> [VpnEventGroup] {
        var out: [VpnEventGroup] = []
        for e in events.sorted(by: { ($0.start, $0.id) > ($1.start, $1.id) }) {
            if let last = out.last, !last.latest.isOpen, !e.isOpen, last.kind == e.kind, last.detail == e.detail {
                out[out.count - 1] = VpnEventGroup(latest: last.latest, count: last.count + 1, earliest: e.start)
            } else {
                out.append(VpnEventGroup(latest: e, count: 1, earliest: e.start))
            }
        }
        return out
    }
}

public struct VpnEventDay: Identifiable, Equatable, Sendable {
    public var id: Int64 { dayStart }
    public let dayStart: Int64
    public let title: String
    public let events: [VpnEventRow]
}

public enum VpnEventGrouping {
    public static func group(_ events: [VpnEventRow], now: Date, calendar: Calendar = .current) -> [VpnEventDay] {
        var order: [Int64] = []
        var buckets: [Int64: [VpnEventRow]] = [:]
        for e in events.sorted(by: { ($0.start, $0.id) > ($1.start, $1.id) }) {
            let d = VpnDay.start(of: e.start, calendar: calendar)
            if buckets[d] == nil { order.append(d) }
            buckets[d, default: []].append(e)
        }
        return order.map { d in
            VpnEventDay(dayStart: d, title: dayTitle(Date(timeIntervalSince1970: Double(d)), now: now, calendar: calendar), events: buckets[d] ?? [])
        }
    }

    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Сегодня" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMMM"
        return f.string(from: day)
    }

    public static func timeText(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
