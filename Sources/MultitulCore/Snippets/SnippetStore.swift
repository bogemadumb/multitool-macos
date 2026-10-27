import Foundation

public enum SnippetError: Error, Equatable {
    case invalid(SnippetIssue)
    case notFound
    case badFormat
}

public struct SnippetImportResult: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var skipped = 0
    public init() {}
}

public enum SnippetSchema {
    public static let scope = "snippets"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "snippets_core", sql: """
            CREATE TABLE snippets(
                id INTEGER PRIMARY KEY AUTOINCREMENT, trig TEXT NOT NULL, tkey TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1, created INTEGER NOT NULL, updated INTEGER NOT NULL, uses INTEGER NOT NULL DEFAULT 0);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

private struct SnippetFile: Codable {
    struct Item: Codable {
        var trigger: String
        var title: String?
        var body: String
        var enabled: Bool?
    }
    var version: Int
    var snippets: [Item]
}

public final class SnippetStore {
    public let store: Store
    private let now: () -> Date

    public init(store: Store, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public static func open(path: String = MultitulPaths.dbPath) throws -> SnippetStore {
        SnippetStore(store: try SnippetSchema.openStore(path: path))
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
    private static let columns = "id, trig, title, body, enabled, created, updated, uses"

    private static func snippet(_ r: Row) -> Snippet? {
        guard let id = r.int("id"), let t = r.string("trig"), let b = r.string("body") else { return nil }
        return Snippet(id: id, trigger: t, title: r.string("title") ?? "", body: b, enabled: (r.int("enabled") ?? 1) != 0,
                       created: date(r.int("created") ?? 0), updated: date(r.int("updated") ?? 0), uses: Int(r.int("uses") ?? 0))
    }

    public func all() throws -> [Snippet] {
        try store.query("SELECT \(Self.columns) FROM snippets ORDER BY tkey ASC").compactMap(Self.snippet)
    }

    public func enabled() throws -> [Snippet] { try all().filter(\.enabled) }

    public func snippet(id: Int64) throws -> Snippet? {
        try store.query("SELECT \(Self.columns) FROM snippets WHERE id=?", [.int(id)]).compactMap(Self.snippet).first
    }

    public func find(trigger: String) throws -> Snippet? {
        try store.query("SELECT \(Self.columns) FROM snippets WHERE tkey=?", [.text(SnippetRules.key(trigger))]).compactMap(Self.snippet).first
    }

    @discardableResult
    public func add(trigger: String, body: String, title: String = "", enabled: Bool = true) throws -> Snippet {
        let t = SnippetRules.normalized(trigger)
        if let issue = SnippetRules.validate(trigger: t, body: body) { throw SnippetError.invalid(issue) }
        if try find(trigger: t) != nil { throw SnippetError.invalid(.duplicate(t)) }
        let stamp = Self.ms(now())
        try store.run("INSERT INTO snippets(trig, tkey, title, body, enabled, created, updated) VALUES(?,?,?,?,?,?,?)",
                      [.text(t), .text(SnippetRules.key(t)), .text(title), .text(body), .int(enabled ? 1 : 0), .int(stamp), .int(stamp)])
        guard let s = try snippet(id: store.lastInsertRowId) else { throw SnippetError.notFound }
        return s
    }

    public func update(_ s: Snippet) throws {
        let t = SnippetRules.normalized(s.trigger)
        if let issue = SnippetRules.validate(trigger: t, body: s.body) { throw SnippetError.invalid(issue) }
        if let other = try find(trigger: t), other.id != s.id { throw SnippetError.invalid(.duplicate(t)) }
        let n = try store.run("UPDATE snippets SET trig=?, tkey=?, title=?, body=?, enabled=?, updated=? WHERE id=?",
                              [.text(t), .text(SnippetRules.key(t)), .text(s.title), .text(s.body), .int(s.enabled ? 1 : 0), .int(Self.ms(now())), .int(s.id)])
        if n == 0 { throw SnippetError.notFound }
    }

    public func setEnabled(id: Int64, _ on: Bool) throws {
        try store.run("UPDATE snippets SET enabled=? WHERE id=?", [.int(on ? 1 : 0), .int(id)])
    }

    public func delete(id: Int64) throws { try store.run("DELETE FROM snippets WHERE id=?", [.int(id)]) }

    public func markUsed(id: Int64) throws { try store.run("UPDATE snippets SET uses=uses+1 WHERE id=?", [.int(id)]) }

    public func count() throws -> Int { Int(try store.scalarInt("SELECT COUNT(*) FROM snippets") ?? 0) }

    public func exportJSON() throws -> Data {
        let file = SnippetFile(version: 1, snippets: try all().map { SnippetFile.Item(trigger: $0.trigger, title: $0.title, body: $0.body, enabled: $0.enabled) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(file)
    }

    public func importJSON(_ data: Data, overwrite: Bool) throws -> SnippetImportResult {
        guard let file = try? JSONDecoder().decode(SnippetFile.self, from: data) else { throw SnippetError.badFormat }
        var result = SnippetImportResult()
        try store.transaction {
            for item in file.snippets {
                if SnippetRules.validate(trigger: item.trigger, body: item.body) != nil { result.skipped += 1; continue }
                if var existing = try find(trigger: item.trigger) {
                    guard overwrite else { result.skipped += 1; continue }
                    existing.body = item.body
                    existing.title = item.title ?? existing.title
                    existing.enabled = item.enabled ?? existing.enabled
                    try update(existing)
                    result.updated += 1
                } else {
                    try add(trigger: item.trigger, body: item.body, title: item.title ?? "", enabled: item.enabled ?? true)
                    result.added += 1
                }
            }
        }
        return result
    }
}

public final class SnippetLibraryModel {
    public private(set) var snippets: [Snippet]
    public var query = "" { didSet { if query != oldValue { selection = 0 } } }
    public private(set) var selection = 0

    public init(snippets: [Snippet]) { self.snippets = snippets.filter(\.enabled) }

    public func reload(_ s: [Snippet]) {
        snippets = s.filter(\.enabled)
        selection = min(selection, max(filtered.count - 1, 0))
    }

    public var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snippets.sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.trigger.lowercased() < $1.trigger.lowercased() } }
        return snippets.filter {
            $0.trigger.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }.sorted { a, b in
            let ap = a.trigger.lowercased().hasPrefix(q), bp = b.trigger.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.trigger.lowercased() < b.trigger.lowercased()
        }
    }

    public var selected: Snippet? {
        let f = filtered
        return f.indices.contains(selection) ? f[selection] : nil
    }

    public func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { selection = 0; return }
        selection = min(max(selection + delta, 0), n - 1)
    }

    public func select(_ i: Int) { selection = min(max(i, 0), max(filtered.count - 1, 0)) }
}
