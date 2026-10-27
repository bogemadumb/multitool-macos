import Foundation

public struct RecRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var created: Date
    public var mode: RecMode
    public var title: String
    public var app: String
    public var path: String?
    public var width: Int
    public var height: Int
    public var duration: Double
    public var bytes: Int
    public var codec: String
    public var fps: Int
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool
    public var pinned: Bool
    public var link: String?
    public var linkExpires: Date?

    public init(id: Int64 = 0, created: Date, mode: RecMode, title: String, app: String = "", path: String? = nil, width: Int = 0, height: Int = 0,
                duration: Double = 0, bytes: Int = 0, codec: String = "h264", fps: Int = 30, hasSystemAudio: Bool = false, hasMicrophone: Bool = false,
                pinned: Bool = false, link: String? = nil, linkExpires: Date? = nil) {
        self.id = id
        self.created = created
        self.mode = mode
        self.title = title
        self.app = app
        self.path = path
        self.width = width
        self.height = height
        self.duration = duration
        self.bytes = bytes
        self.codec = codec
        self.fps = fps
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.pinned = pinned
        self.link = link
        self.linkExpires = linkExpires
    }

    public var sourceInfo: RecSourceInfo { RecSourceInfo(width: width, height: height, duration: duration, fps: fps, hasSystemAudio: hasSystemAudio, hasMicrophone: hasMicrophone) }

    public func linkIsAlive(now: Date) -> Bool {
        guard link != nil, let e = linkExpires else { return false }
        return e > now
    }
}

public enum RecHistorySchema {
    public static let scope = "recs"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "rec_items", sql: """
            CREATE TABLE rec_items(
                id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL, mode TEXT NOT NULL, title TEXT NOT NULL, app TEXT NOT NULL DEFAULT '',
                path TEXT, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0, codec TEXT NOT NULL DEFAULT 'h264', fps INTEGER NOT NULL DEFAULT 30,
                sys_audio INTEGER NOT NULL DEFAULT 0, mic_audio INTEGER NOT NULL DEFAULT 0, search TEXT NOT NULL DEFAULT '',
                pinned INTEGER NOT NULL DEFAULT 0, link TEXT, link_expires INTEGER, thumb BLOB, doc BLOB, events BLOB);
            CREATE INDEX idx_rec_items_created ON rec_items(created);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

public final class RecHistoryStore {
    public let store: Store

    public init(store: Store) { self.store = store }

    public static func open(path: String = MultitulPaths.dbPath) throws -> RecHistoryStore {
        RecHistoryStore(store: try RecHistorySchema.openStore(path: path))
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
    private static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

    private static let columns = "id, created, mode, title, app, path, width, height, duration, bytes, codec, fps, sys_audio, mic_audio, pinned, link, link_expires"

    private static func record(_ r: Row) -> RecRecord? {
        guard let id = r.int("id"), let created = r.int("created"), let mode = r.string("mode").flatMap(RecMode.init(rawValue:)) else { return nil }
        return RecRecord(id: id, created: date(created), mode: mode, title: r.string("title") ?? "", app: r.string("app") ?? "", path: r.string("path"),
                         width: Int(r.int("width") ?? 0), height: Int(r.int("height") ?? 0), duration: r.double("duration") ?? 0, bytes: Int(r.int("bytes") ?? 0),
                         codec: r.string("codec") ?? "h264", fps: Int(r.int("fps") ?? 30), hasSystemAudio: (r.int("sys_audio") ?? 0) != 0,
                         hasMicrophone: (r.int("mic_audio") ?? 0) != 0, pinned: (r.int("pinned") ?? 0) != 0, link: r.string("link"), linkExpires: r.int("link_expires").map(date))
    }

    public static func searchText(title: String, app: String, mode: RecMode) -> String {
        ShotSearchText.normalize([title, app, mode.title].filter { !$0.isEmpty }.joined(separator: " "))
    }

    @discardableResult
    public func insert(_ r: RecRecord, thumbnail: Data? = nil) throws -> Int64 {
        try store.run("""
            INSERT INTO rec_items(created, mode, title, app, path, width, height, duration, bytes, codec, fps, sys_audio, mic_audio, search, pinned, link, link_expires, thumb)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
                      [.int(Self.ms(r.created)), .text(r.mode.rawValue), .text(r.title), .text(r.app), Self.opt(r.path), .int(Int64(r.width)), .int(Int64(r.height)),
                       .real(r.duration), .int(Int64(r.bytes)), .text(r.codec), .int(Int64(r.fps)), .int(r.hasSystemAudio ? 1 : 0), .int(r.hasMicrophone ? 1 : 0),
                       .text(Self.searchText(title: r.title, app: r.app, mode: r.mode)), .int(r.pinned ? 1 : 0), Self.opt(r.link),
                       r.linkExpires.map { .int(Self.ms($0)) } ?? .null, thumbnail.map { .blob($0) } ?? .null])
        return store.lastInsertRowId
    }

    public func record(id: Int64) throws -> RecRecord? {
        try store.query("SELECT \(Self.columns) FROM rec_items WHERE id=?", [.int(id)]).compactMap(Self.record).first
    }

    public func recent(limit: Int = 100, offset: Int = 0) throws -> [RecRecord] {
        try store.query("SELECT \(Self.columns) FROM rec_items ORDER BY created DESC, id DESC LIMIT ? OFFSET ?", [.int(Int64(limit)), .int(Int64(offset))]).compactMap(Self.record)
    }

    public func latest() throws -> RecRecord? { try recent(limit: 1).first }

    public func search(_ query: String, limit: Int = 100) throws -> [RecRecord] {
        let words = ShotSearchText.words(query)
        guard !words.isEmpty else { return try recent(limit: limit) }
        let clause = words.map { _ in "search LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        var args: [SQLValue] = words.map { .text(ShotSearchText.likePattern($0)) }
        args.append(.int(Int64(limit)))
        return try store.query("SELECT \(Self.columns) FROM rec_items WHERE \(clause) ORDER BY created DESC, id DESC LIMIT ?", args).compactMap(Self.record)
    }

    public func thumbnail(id: Int64) throws -> Data? { try store.query("SELECT thumb FROM rec_items WHERE id=?", [.int(id)]).first?.data(0) }
    public func document(id: Int64) throws -> Data? { try store.query("SELECT doc FROM rec_items WHERE id=?", [.int(id)]).first?.data(0) }
    public func inputLog(id: Int64) throws -> Data? { try store.query("SELECT events FROM rec_items WHERE id=?", [.int(id)]).first?.data(0) }

    public func setThumbnail(id: Int64, data: Data?) throws {
        try store.run("UPDATE rec_items SET thumb=? WHERE id=?", [data.map { .blob($0) } ?? .null, .int(id)])
    }

    public func setDocument(id: Int64, json: Data?) throws {
        try store.run("UPDATE rec_items SET doc=? WHERE id=?", [json.map { .blob($0) } ?? .null, .int(id)])
    }

    public func setInputLog(id: Int64, json: Data?) throws {
        try store.run("UPDATE rec_items SET events=? WHERE id=?", [json.map { .blob($0) } ?? .null, .int(id)])
    }

    public func setLink(id: Int64, url: String?, expires: Date?) throws {
        try store.run("UPDATE rec_items SET link=?, link_expires=? WHERE id=?", [Self.opt(url), expires.map { .int(Self.ms($0)) } ?? .null, .int(id)])
    }

    public func setLocation(id: Int64, path: String?, bytes: Int, width: Int, height: Int, duration: Double) throws {
        try store.run("UPDATE rec_items SET path=?, bytes=?, width=?, height=?, duration=? WHERE id=?",
                      [Self.opt(path), .int(Int64(bytes)), .int(Int64(width)), .int(Int64(height)), .real(duration), .int(id)])
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try store.run("UPDATE rec_items SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .int(id)])
    }

    public func rename(id: Int64, title: String) throws {
        guard let r = try record(id: id) else { return }
        try store.run("UPDATE rec_items SET title=?, search=? WHERE id=?", [.text(title), .text(Self.searchText(title: title, app: r.app, mode: r.mode)), .int(id)])
    }

    public func count() throws -> Int { Int(try store.scalarInt("SELECT count(*) FROM rec_items") ?? 0) }
    public func totalBytes() throws -> Int { Int(try store.scalarInt("SELECT COALESCE(SUM(bytes),0) FROM rec_items") ?? 0) }

    @discardableResult
    public func delete(ids: [Int64]) throws -> [RecRecord] {
        var removed: [RecRecord] = []
        try store.transaction {
            for id in ids {
                if let r = try record(id: id) {
                    removed.append(r)
                    try store.run("DELETE FROM rec_items WHERE id=?", [.int(id)])
                }
            }
        }
        return removed
    }

    @discardableResult
    public func prune(_ policy: ShotPrunePolicy, now: Date = Date()) throws -> [RecRecord] {
        var doomed: [Int64] = []
        if policy.maxAgeDays > 0 {
            let cutoff = Self.ms(now.addingTimeInterval(-Double(policy.maxAgeDays) * 86400))
            doomed += try store.query("SELECT id FROM rec_items WHERE pinned=0 AND created<?", [.int(cutoff)]).compactMap { $0.int(0) }
        }
        if policy.maxCount > 0 {
            doomed += try store.query("""
                SELECT id FROM rec_items WHERE pinned=0 AND id NOT IN
                (SELECT id FROM rec_items WHERE pinned=0 ORDER BY created DESC, id DESC LIMIT ?)
                """, [.int(Int64(policy.maxCount))]).compactMap { $0.int(0) }
        }
        return try delete(ids: Array(Set(doomed)).sorted())
    }
}
