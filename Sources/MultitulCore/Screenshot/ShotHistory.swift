import Foundation

public struct ShotRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var created: Date
    public var mode: ShotMode
    public var title: String
    public var app: String
    public var path: String?
    public var owned: Bool
    public var width: Int
    public var height: Int
    public var bytes: Int
    public var format: String
    public var ocr: String
    public var pinned: Bool
    public var link: String?
    public var linkExpires: Date?

    public init(id: Int64 = 0, created: Date, mode: ShotMode, title: String, app: String = "", path: String? = nil, owned: Bool = false,
                width: Int = 0, height: Int = 0, bytes: Int = 0, format: String = "png", ocr: String = "", pinned: Bool = false,
                link: String? = nil, linkExpires: Date? = nil) {
        self.id = id
        self.created = created
        self.mode = mode
        self.title = title
        self.app = app
        self.path = path
        self.owned = owned
        self.width = width
        self.height = height
        self.bytes = bytes
        self.format = format
        self.ocr = ocr
        self.pinned = pinned
        self.link = link
        self.linkExpires = linkExpires
    }

    public func linkIsAlive(now: Date) -> Bool {
        guard link != nil, let e = linkExpires else { return false }
        return e > now
    }
}

public enum ShotSearchText {
    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    public static func build(title: String, app: String, ocr: String, mode: ShotMode) -> String {
        normalize([title, app, mode.title, ocr].filter { !$0.isEmpty }.joined(separator: " "))
    }

    public static func words(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    public static func likePattern(_ word: String) -> String {
        var out = ""
        for ch in word {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return "%" + out + "%"
    }
}

public struct ShotPrunePolicy: Equatable, Sendable {
    public var maxCount: Int
    public var maxAgeDays: Int

    public init(maxCount: Int, maxAgeDays: Int) {
        self.maxCount = maxCount
        self.maxAgeDays = maxAgeDays
    }
}

public protocol ShotHistoryStoring: AnyObject {
    func insert(_ r: ShotRecord, thumbnail: Data?) throws -> Int64
    func setOcr(id: Int64, text: String) throws
}

public enum ShotHistorySchema {
    public static let scope = "shots"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "shot_items", sql: """
            CREATE TABLE shot_items(
                id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL, mode TEXT NOT NULL, title TEXT NOT NULL, app TEXT NOT NULL DEFAULT '',
                path TEXT, owned INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0, format TEXT NOT NULL DEFAULT 'png', ocr TEXT NOT NULL DEFAULT '', search TEXT NOT NULL DEFAULT '',
                pinned INTEGER NOT NULL DEFAULT 0, link TEXT, link_expires INTEGER, thumb BLOB, doc BLOB);
            CREATE INDEX idx_shot_items_created ON shot_items(created);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

public final class ShotHistoryStore: ShotHistoryStoring {
    public let store: Store

    public init(store: Store) { self.store = store }

    public static func open(path: String = MultitulPaths.dbPath) throws -> ShotHistoryStore {
        ShotHistoryStore(store: try ShotHistorySchema.openStore(path: path))
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
    private static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

    private static let columns = "id, created, mode, title, app, path, owned, width, height, bytes, format, ocr, pinned, link, link_expires"

    private static func record(_ r: Row) -> ShotRecord? {
        guard let id = r.int("id"), let created = r.int("created"), let mode = r.string("mode").flatMap(ShotMode.init(rawValue:)) else { return nil }
        return ShotRecord(id: id, created: date(created), mode: mode, title: r.string("title") ?? "", app: r.string("app") ?? "", path: r.string("path"),
                          owned: (r.int("owned") ?? 0) != 0, width: Int(r.int("width") ?? 0), height: Int(r.int("height") ?? 0),
                          bytes: Int(r.int("bytes") ?? 0), format: r.string("format") ?? "png", ocr: r.string("ocr") ?? "",
                          pinned: (r.int("pinned") ?? 0) != 0, link: r.string("link"), linkExpires: r.int("link_expires").map(date))
    }

    @discardableResult
    public func insert(_ r: ShotRecord, thumbnail: Data? = nil) throws -> Int64 {
        let search = ShotSearchText.build(title: r.title, app: r.app, ocr: r.ocr, mode: r.mode)
        try store.run("""
            INSERT INTO shot_items(created, mode, title, app, path, owned, width, height, bytes, format, ocr, search, pinned, link, link_expires, thumb)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
                      [.int(Self.ms(r.created)), .text(r.mode.rawValue), .text(r.title), .text(r.app), Self.opt(r.path), .int(r.owned ? 1 : 0),
                       .int(Int64(r.width)), .int(Int64(r.height)), .int(Int64(r.bytes)), .text(r.format), .text(r.ocr), .text(search),
                       .int(r.pinned ? 1 : 0), Self.opt(r.link), r.linkExpires.map { .int(Self.ms($0)) } ?? .null,
                       thumbnail.map { .blob($0) } ?? .null])
        return store.lastInsertRowId
    }

    public func record(id: Int64) throws -> ShotRecord? {
        try store.query("SELECT \(Self.columns) FROM shot_items WHERE id=?", [.int(id)]).compactMap(Self.record).first
    }

    public func recent(limit: Int = 100, offset: Int = 0, mode: ShotMode? = nil) throws -> [ShotRecord] {
        if let mode {
            return try store.query("SELECT \(Self.columns) FROM shot_items WHERE mode=? ORDER BY created DESC, id DESC LIMIT ? OFFSET ?",
                                   [.text(mode.rawValue), .int(Int64(limit)), .int(Int64(offset))]).compactMap(Self.record)
        }
        return try store.query("SELECT \(Self.columns) FROM shot_items ORDER BY created DESC, id DESC LIMIT ? OFFSET ?",
                               [.int(Int64(limit)), .int(Int64(offset))]).compactMap(Self.record)
    }

    public func latest() throws -> ShotRecord? { try recent(limit: 1).first }

    public func search(_ query: String, limit: Int = 100) throws -> [ShotRecord] {
        let words = ShotSearchText.words(query)
        guard !words.isEmpty else { return try recent(limit: limit) }
        let clause = words.map { _ in "search LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        var args: [SQLValue] = words.map { .text(ShotSearchText.likePattern($0)) }
        args.append(.int(Int64(limit)))
        return try store.query("SELECT \(Self.columns) FROM shot_items WHERE \(clause) ORDER BY created DESC, id DESC LIMIT ?", args).compactMap(Self.record)
    }

    public func thumbnail(id: Int64) throws -> Data? {
        try store.query("SELECT thumb FROM shot_items WHERE id=?", [.int(id)]).first?.data(0)
    }

    public func setOcr(id: Int64, text: String) throws {
        guard let r = try record(id: id) else { return }
        try store.run("UPDATE shot_items SET ocr=?, search=? WHERE id=?",
                      [.text(text), .text(ShotSearchText.build(title: r.title, app: r.app, ocr: text, mode: r.mode)), .int(id)])
    }

    public func setLink(id: Int64, url: String?, expires: Date?) throws {
        try store.run("UPDATE shot_items SET link=?, link_expires=? WHERE id=?", [Self.opt(url), expires.map { .int(Self.ms($0)) } ?? .null, .int(id)])
    }

    public func setLocation(id: Int64, path: String?, owned: Bool, bytes: Int, width: Int, height: Int, format: String) throws {
        try store.run("UPDATE shot_items SET path=?, owned=?, bytes=?, width=?, height=?, format=? WHERE id=?",
                      [Self.opt(path), .int(owned ? 1 : 0), .int(Int64(bytes)), .int(Int64(width)), .int(Int64(height)), .text(format), .int(id)])
    }

    public func setThumbnail(id: Int64, data: Data?) throws {
        try store.run("UPDATE shot_items SET thumb=? WHERE id=?", [data.map { .blob($0) } ?? .null, .int(id)])
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try store.run("UPDATE shot_items SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .int(id)])
    }

    public func setDocument(id: Int64, json: Data?) throws {
        try store.run("UPDATE shot_items SET doc=? WHERE id=?", [json.map { .blob($0) } ?? .null, .int(id)])
    }

    public func document(id: Int64) throws -> Data? {
        try store.query("SELECT doc FROM shot_items WHERE id=?", [.int(id)]).first?.data(0)
    }

    public func count() throws -> Int { Int(try store.scalarInt("SELECT count(*) FROM shot_items") ?? 0) }

    @discardableResult
    public func delete(ids: [Int64]) throws -> [ShotRecord] {
        var removed: [ShotRecord] = []
        try store.transaction {
            for id in ids {
                if let r = try record(id: id) {
                    removed.append(r)
                    try store.run("DELETE FROM shot_items WHERE id=?", [.int(id)])
                }
            }
        }
        return removed
    }

    @discardableResult
    public func prune(_ policy: ShotPrunePolicy, now: Date = Date()) throws -> [ShotRecord] {
        var doomed: [Int64] = []
        if policy.maxAgeDays > 0 {
            let cutoff = Self.ms(now.addingTimeInterval(-Double(policy.maxAgeDays) * 86400))
            doomed += try store.query("SELECT id FROM shot_items WHERE pinned=0 AND created<?", [.int(cutoff)]).compactMap { $0.int(0) }
        }
        if policy.maxCount > 0 {
            doomed += try store.query("""
                SELECT id FROM shot_items WHERE pinned=0 AND id NOT IN
                (SELECT id FROM shot_items WHERE pinned=0 ORDER BY created DESC, id DESC LIMIT ?)
                """, [.int(Int64(policy.maxCount))]).compactMap { $0.int(0) }
        }
        let unique = Array(Set(doomed)).sorted()
        return try delete(ids: unique)
    }

    public func expiredLinks(now: Date = Date()) throws -> [ShotRecord] {
        try store.query("SELECT \(Self.columns) FROM shot_items WHERE link IS NOT NULL AND link_expires IS NOT NULL AND link_expires<=?", [.int(Self.ms(now))])
            .compactMap(Self.record)
    }

    public func totalBytes() throws -> Int { Int(try store.scalarInt("SELECT COALESCE(SUM(bytes),0) FROM shot_items") ?? 0) }
}
