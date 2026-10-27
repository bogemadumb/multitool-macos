import Foundation

public struct VpnJournalCleanPlan: Equatable, Sendable {
    public var remove: [VpnEventRow]
    public var keepLeaks: [VpnEventRow]
    public var totalEvents: Int
}

public enum VpnJournalClean {
    private static let home = VpnLeakLogic.home

    // A leak row written by the pre-26.10 detector: every part names a non-home country, and the DNS part is present.
    public static func isFalseDnsLeak(kind: String, detail: String) -> Bool {
        guard kind == "leak" else { return false }
        let parts = detail.components(separatedBy: "; ")
        var hasDns = false
        for part in parts {
            guard let loc = country(part) else { return false }
            if loc == home { return false }
            if part.hasPrefix("DNS: ") { hasDns = true }
        }
        return hasDns
    }

    static func country(_ part: String) -> String? {
        if part.hasPrefix("DNS: 1.1.1.1 виден из ") {
            let c = String(part.dropFirst("DNS: 1.1.1.1 виден из ".count))
            return code(c)
        }
        for prefix in ["Гео для cloudflare.com: ", "Утечка IPv6: "] where part.hasPrefix(prefix) {
            let rest = part.dropFirst(prefix.count)
            guard let r = rest.range(of: " · ") else { return nil }
            return code(String(rest[..<r.lowerBound]))
        }
        return nil
    }

    private static func code(_ s: String) -> String? {
        s.count == 2 && s.allSatisfy { $0.isASCII && $0.isUppercase } ? s : nil
    }

    public static func plan(_ store: Store) throws -> VpnJournalCleanPlan {
        let rows = try store.query("SELECT id, ts_start, ts_end, kind, detail FROM vpn_events ORDER BY ts_start, id")
        let all = rows.map { r in
            VpnEventRow(id: r.int(0) ?? 0, start: Date(timeIntervalSince1970: Double(r.int(1) ?? 0)),
                        end: r.int(2).map { Date(timeIntervalSince1970: Double($0)) }, kind: r.string(3) ?? "", detail: r.string(4) ?? "")
        }
        let leaks = all.filter { $0.kind == "leak" }
        let remove = leaks.filter { isFalseDnsLeak(kind: $0.kind, detail: $0.detail) }
        let ids = Set(remove.map(\.id))
        return VpnJournalCleanPlan(remove: remove, keepLeaks: leaks.filter { !ids.contains($0.id) }, totalEvents: all.count)
    }

    @discardableResult
    public static func apply(_ plan: VpnJournalCleanPlan, to store: Store) throws -> Int {
        try store.transaction {
            var n = 0
            for e in plan.remove where isFalseDnsLeak(kind: e.kind, detail: e.detail) {
                n += try store.run("DELETE FROM vpn_events WHERE id = ? AND kind = 'leak' AND detail = ?", [.int(e.id), .text(e.detail)])
            }
            return n
        }
    }
}

public enum VpnJournalCleanCLI {
    public static let usage = "Использование: Multitul --vpn-journal-clean (--dry-run | --apply) [--db <multitul.db>]"

    public static func run(arguments: [String], out: (String) -> Void) -> Int32 {
        var db = MultitulPaths.dbPath
        var dry = false, apply = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--dry-run": dry = true
            case "--apply": apply = true
            case "--db":
                i += 1
                guard i < arguments.count else { out(usage); return 64 }
                db = arguments[i]
            default: out(usage); return 64
            }
            i += 1
        }
        guard dry != apply else { out(usage); return 64 }
        do {
            let store = try Store(path: db, migrations: [], retention: [], readOnly: dry)
            let plan = try VpnJournalClean.plan(store)
            out(dry ? "Пробный прогон, в базу ничего не записано." : "Чистка журнала VPN.")
            out("Всего событий: \(plan.totalEvents), из них утечек: \(plan.remove.count + plan.keepLeaks.count)")
            out("Ложные утечки DNS (\(dry ? "будут удалены" : "удаляются")): \(plan.remove.count)")
            for e in plan.remove { out("  - id \(e.id) · \(stamp(e.start)) · \(e.detail)") }
            out("Остаются утечки: \(plan.keepLeaks.count)")
            for e in plan.keepLeaks { out("  + id \(e.id) · \(stamp(e.start)) · \(e.detail)") }
            if apply {
                let n = try VpnJournalClean.apply(plan, to: store)
                out("Удалено: \(n)")
            }
            return 0
        } catch {
            out("Ошибка: \(error)")
            return 1
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}
