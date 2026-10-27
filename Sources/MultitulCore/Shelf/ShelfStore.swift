import Foundation

public enum ShelfSchema {
    public static let scope = "shelf"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "shelf_core", sql: """
            CREATE TABLE shelf_items(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, hash TEXT NOT NULL UNIQUE, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
                created INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, path TEXT, owned INTEGER NOT NULL DEFAULT 0,
                ext TEXT, source_bundle TEXT, bookmark BLOB, body TEXT, data BLOB);
            CREATE INDEX idx_shelf_items_order ON shelf_items(pinned, created);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

public struct ShelfInsertResult: Equatable, Sendable {
    public var id: Int64
    public var deduped: Bool
}

public final class ShelfStore {
    public let store: Store
    private let now: () -> Date

    public init(store: Store, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public static func open(path: String = MultitulPaths.dbPath, now: @escaping () -> Date = Date.init) throws -> ShelfStore {
        ShelfStore(store: try ShelfSchema.openStore(path: path), now: now)
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }

    private static let columns = "id, kind, hash, title, detail, created, pinned, size, path, owned, ext, source_bundle"

    private static func item(_ r: Row) -> ShelfItem? {
        guard let id = r.int("id"), let k = r.string("kind").flatMap(ShelfKind.init(rawValue:)) else { return nil }
        return ShelfItem(id: id, kind: k, hash: r.string("hash") ?? "", title: r.string("title") ?? "", detail: r.string("detail") ?? "",
                         created: date(r.int("created") ?? 0), pinned: (r.int("pinned") ?? 0) != 0, size: Int(r.int("size") ?? 0),
                         path: r.string("path"), owned: (r.int("owned") ?? 0) != 0, ext: r.string("ext"), sourceBundle: r.string("source_bundle"))
    }

    private func stamp() throws -> Int64 {
        max(Self.ms(now()), (try store.scalarInt("SELECT COALESCE(MAX(created),0) FROM shelf_items") ?? 0) + 1)
    }

    @discardableResult
    public func insert(_ c: ShelfCandidate) throws -> ShelfInsertResult {
        try store.transaction {
            let t = try stamp()
            if let existing = try store.scalarInt("SELECT id FROM shelf_items WHERE hash=?", [.text(c.hash)]) {
                try store.run("UPDATE shelf_items SET created=?, title=?, detail=?, size=?, path=?, source_bundle=?, bookmark=COALESCE(?, bookmark) WHERE id=?",
                              [.int(t), .text(c.title), .text(c.detail), .int(Int64(c.size)), Self.opt(c.path), Self.opt(c.sourceBundle),
                               c.payload.bookmark.map { .blob($0) } ?? .null, .int(existing)])
                return ShelfInsertResult(id: existing, deduped: true)
            }
            try store.run("""
                INSERT INTO shelf_items(kind, hash, title, detail, created, pinned, size, path, owned, ext, source_bundle, bookmark, body, data)
                VALUES(?,?,?,?,?,0,?,?,?,?,?,?,?,?)
                """,
                          [.text(c.kind.rawValue), .text(c.hash), .text(c.title), .text(c.detail), .int(t), .int(Int64(c.size)), Self.opt(c.path),
                           .int(c.owned ? 1 : 0), Self.opt(c.ext), Self.opt(c.sourceBundle),
                           c.payload.bookmark.map { .blob($0) } ?? .null, Self.opt(c.payload.body), c.payload.data.map { .blob($0) } ?? .null])
            return ShelfInsertResult(id: store.lastInsertRowId, deduped: false)
        }
    }

    private static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

    public func items(limit: Int = 500) throws -> [ShelfItem] {
        try store.query("SELECT \(Self.columns) FROM shelf_items ORDER BY pinned DESC, created DESC, id DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.item)
    }

    public func item(id: Int64) throws -> ShelfItem? {
        try store.query("SELECT \(Self.columns) FROM shelf_items WHERE id=?", [.int(id)]).compactMap(Self.item).first
    }

    public func payload(id: Int64) throws -> ShelfPayload? {
        try store.query("SELECT bookmark, body, data FROM shelf_items WHERE id=?", [.int(id)]).first.map {
            ShelfPayload(bookmark: $0.data("bookmark"), body: $0.string("body"), data: $0.data("data"))
        }
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try store.run("UPDATE shelf_items SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .int(id)])
    }

    public func updateLocation(id: Int64, path: String, bookmark: Data?) throws {
        try store.run("UPDATE shelf_items SET path=?, bookmark=COALESCE(?, bookmark), detail=CASE WHEN owned=1 THEN detail ELSE ? END WHERE id=?",
                      [.text(path), bookmark.map { .blob($0) } ?? .null, .text(ShelfPaths.displayDirectory(path)), .int(id)])
    }

    public func delete(ids: [Int64]) throws {
        try store.transaction {
            for id in ids { try store.run("DELETE FROM shelf_items WHERE id=?", [.int(id)]) }
        }
    }

    public func count() throws -> Int { Int(try store.scalarInt("SELECT count(*) FROM shelf_items") ?? 0) }

    public func ownedPaths() throws -> Set<String> {
        Set(try store.query("SELECT path FROM shelf_items WHERE owned=1 AND path IS NOT NULL").compactMap { $0.string(0) })
    }

    public func oldestUnpinned(beyond keep: Int) throws -> [ShelfItem] {
        try store.query("""
            SELECT \(Self.columns) FROM shelf_items WHERE pinned=0 AND id NOT IN
            (SELECT id FROM shelf_items WHERE pinned=0 ORDER BY created DESC, id DESC LIMIT ?)
            """, [.int(Int64(keep))]).compactMap(Self.item)
    }
}
