import Foundation

public struct ScratchNote: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var title: String
    public var text: String
    public var created: Date
    public var updated: Date

    public init(id: Int64, title: String = "", text: String = "", created: Date, updated: Date) {
        self.id = id
        self.title = title
        self.text = text
        self.created = created
        self.updated = updated
    }

    public func displayTitle(index: Int) -> String {
        let custom = title.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return String(custom.prefix(24)) }
        if let line = text.split(separator: "\n", omittingEmptySubsequences: true).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#>-*+ "))
            if !t.isEmpty { return t.count > 22 ? String(t.prefix(21)) + "…" : t }
        }
        return "Заметка \(index + 1)"
    }
}

public enum AutoClearPeriod: Int, CaseIterable, Sendable {
    case off = 0, quarterHour = 15, hour = 60, fourHours = 240, day = 1440, week = 10080

    public var title: String {
        switch self {
        case .off: "Не очищать"
        case .quarterHour: "15 минут без правок"
        case .hour: "1 час без правок"
        case .fourHours: "4 часа без правок"
        case .day: "Сутки без правок"
        case .week: "Неделя без правок"
        }
    }
}

public struct ScratchpadSettings: Equatable, Sendable {
    public static let fontRange = 11...28
    public static let delayRange = 0.2...5.0
    public static let tabsRange = 1...30
    public var autoClear = AutoClearPeriod.off
    public var closeOnOutsideClick = false
    public var autosaveDelay = 1.0
    public var fontSize = 14
    public var maxTabs = 12
    public var startInPreview = false

    public init() {}

    public var sanitized: ScratchpadSettings {
        var s = self
        s.fontSize = ToolsClamp.int(s.fontSize, Self.fontRange)
        s.autosaveDelay = ToolsClamp.double(s.autosaveDelay, Self.delayRange)
        s.maxTabs = ToolsClamp.int(s.maxTabs, Self.tabsRange)
        return s
    }
}

public final class ScratchpadSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> ScratchpadSettings {
        var s = ScratchpadSettings()
        let p = "scratchpad."
        if let m = AutoClearPeriod(rawValue: a.int(p + "autoClear", 0)) { s.autoClear = m }
        s.closeOnOutsideClick = a.bool(p + "closeOnOutsideClick", s.closeOnOutsideClick)
        s.autosaveDelay = a.double(p + "autosaveDelay", s.autosaveDelay)
        s.fontSize = a.int(p + "fontSize", s.fontSize)
        s.maxTabs = a.int(p + "maxTabs", s.maxTabs)
        s.startInPreview = a.bool(p + "startInPreview", s.startInPreview)
        return s.sanitized
    }

    public func save(_ settings: ScratchpadSettings) {
        let s = settings.sanitized
        let b = ScratchpadSettings()
        let p = "scratchpad."
        a.put(p + "autoClear", s.autoClear.rawValue, b.autoClear.rawValue)
        a.put(p + "closeOnOutsideClick", s.closeOnOutsideClick, b.closeOnOutsideClick)
        a.put(p + "autosaveDelay", s.autosaveDelay, b.autosaveDelay)
        a.put(p + "fontSize", s.fontSize, b.fontSize)
        a.put(p + "maxTabs", s.maxTabs, b.maxTabs)
        a.put(p + "startInPreview", s.startInPreview, b.startInPreview)
    }
}

public protocol ScratchNoteStoring: AnyObject {
    func loadAll() throws -> [ScratchNote]
    func insert(title: String, text: String, at: Date) throws -> ScratchNote
    func save(_ note: ScratchNote) throws
    func delete(id: Int64) throws
    func savePositions(_ ids: [Int64]) throws
}

public protocol ScratchScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void)
    func cancel()
}

public final class DispatchScratchScheduler: ScratchScheduling {
    private var work: DispatchWorkItem?

    public init() {}

    public func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: action)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    public func cancel() {
        work?.cancel()
        work = nil
    }
}

public struct ScratchStats: Equatable, Sendable {
    public var characters: Int
    public var words: Int
    public var lines: Int

    public static func of(_ text: String) -> ScratchStats {
        ScratchStats(characters: text.count, words: text.split(whereSeparator: { $0.isWhitespace }).count,
                     lines: text.isEmpty ? 0 : text.components(separatedBy: "\n").count)
    }
}

public enum ScratchExport {
    public static func fileName(for note: ScratchNote, index: Int, ext: String = "md") -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var base = note.displayTitle(index: index).components(separatedBy: bad).joined(separator: " ")
        base = base.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if base.isEmpty { base = "Заметка" }
        return base + "." + ext
    }

    public static func combined(_ notes: [ScratchNote]) -> String {
        notes.enumerated().map { i, n in "# \(n.displayTitle(index: i))\n\n\(n.text)" }.joined(separator: "\n\n---\n\n")
    }
}

public final class ScratchpadModel {
    public private(set) var notes: [ScratchNote] = []
    public private(set) var activeIndex = 0
    public private(set) var lastError: String?
    public var settings: ScratchpadSettings
    private let store: ScratchNoteStoring
    private let clock: ToolsClock
    private let scheduler: ScratchScheduling
    private var dirty = Set<Int64>()

    public init(store: ScratchNoteStoring, settings: ScratchpadSettings = ScratchpadSettings(), clock: ToolsClock = SystemToolsClock(), scheduler: ScratchScheduling = DispatchScratchScheduler()) {
        self.store = store
        self.settings = settings.sanitized
        self.clock = clock
        self.scheduler = scheduler
    }

    public var active: ScratchNote? { notes.indices.contains(activeIndex) ? notes[activeIndex] : nil }
    public var hasUnsaved: Bool { !dirty.isEmpty }

    public func load() {
        do {
            notes = try store.loadAll()
            if notes.isEmpty { notes = [try store.insert(title: "", text: "", at: clock.now)] }
            lastError = nil
        } catch {
            lastError = "\(error)"
            if notes.isEmpty { notes = [ScratchNote(id: -1, created: clock.now, updated: clock.now)] }
        }
        activeIndex = min(activeIndex, notes.count - 1)
        applyAutoClear()
    }

    public func applyAutoClear() {
        guard settings.autoClear != .off else { return }
        let limit = Double(settings.autoClear.rawValue) * 60
        let now = clock.now
        var keep: [ScratchNote] = []
        var cleared = false
        for var n in notes {
            guard now.timeIntervalSince(n.updated) >= limit, !(n.text.isEmpty && n.title.isEmpty) else { keep.append(n); continue }
            n.text = ""
            n.title = ""
            n.updated = now
            persist(n)
            cleared = true
            keep.append(n)
        }
        notes = keep
        if cleared {
            dirty = []
            while notes.count > 1, let last = notes.last, last.text.isEmpty, last.title.isEmpty {
                try? store.delete(id: last.id)
                notes.removeLast()
            }
            activeIndex = min(activeIndex, notes.count - 1)
        }
    }

    public func select(_ index: Int) {
        guard notes.indices.contains(index), index != activeIndex else { return }
        flush()
        activeIndex = index
    }

    @discardableResult
    public func addNote(text: String = "") -> Bool {
        guard notes.count < settings.maxTabs else { return false }
        flush()
        do {
            notes.append(try store.insert(title: "", text: text, at: clock.now))
            activeIndex = notes.count - 1
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    public func closeNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        flush()
        let id = notes[index].id
        if notes.count == 1 {
            notes[0].text = ""
            notes[0].title = ""
            notes[0].updated = clock.now
            persist(notes[0])
            return
        }
        try? store.delete(id: id)
        dirty.remove(id)
        notes.remove(at: index)
        var a = activeIndex
        if index < a { a -= 1 }
        activeIndex = max(0, min(a, notes.count - 1))
    }

    public func rename(at index: Int, to title: String) {
        guard notes.indices.contains(index) else { return }
        notes[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].updated = clock.now
        markDirty(notes[index].id)
    }

    public func moveNote(from: Int, to: Int) {
        guard notes.indices.contains(from), notes.indices.contains(to), from != to else { return }
        let activeID = active?.id
        notes.insert(notes.remove(at: from), at: to)
        activeIndex = notes.firstIndex { $0.id == activeID } ?? 0
        try? store.savePositions(notes.map(\.id))
    }

    public func edit(_ text: String) {
        guard notes.indices.contains(activeIndex), notes[activeIndex].text != text else { return }
        notes[activeIndex].text = text
        notes[activeIndex].updated = clock.now
        markDirty(notes[activeIndex].id)
    }

    private func markDirty(_ id: Int64) {
        dirty.insert(id)
        scheduler.schedule(after: settings.autosaveDelay) { [weak self] in self?.flush() }
    }

    public func flush() {
        scheduler.cancel()
        guard !dirty.isEmpty else { return }
        for n in notes where dirty.contains(n.id) { persist(n) }
        dirty = []
    }

    private func persist(_ note: ScratchNote) {
        do {
            try store.save(note)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    public func clearActive() {
        edit("")
        flush()
    }
}

public enum ScratchpadHotkeys {
    public static let toggle = HotkeySpec(id: "scratchpad.toggle", title: "Блокнот: показать или скрыть", defaultCombo: .none)
}

public enum ScratchSchema {
    public static let scope = "scratchpad"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "scratch_notes", sql: """
            CREATE TABLE scratch_notes(
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
                pos INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, updated INTEGER NOT NULL);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

public final class SQLiteScratchStore: ScratchNoteStoring {
    public let store: Store

    public init(store: Store) { self.store = store }

    public static func open(path: String = MultitulPaths.dbPath) throws -> SQLiteScratchStore {
        SQLiteScratchStore(store: try ScratchSchema.openStore(path: path))
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }

    private static func note(_ r: Row) -> ScratchNote? {
        guard let id = r.int("id") else { return nil }
        return ScratchNote(id: id, title: r.string("title") ?? "", text: r.string("body") ?? "",
                           created: date(r.int("created") ?? 0), updated: date(r.int("updated") ?? 0))
    }

    public func loadAll() throws -> [ScratchNote] {
        try store.query("SELECT id, title, body, created, updated FROM scratch_notes ORDER BY pos ASC, id ASC").compactMap(Self.note)
    }

    public func insert(title: String, text: String, at: Date) throws -> ScratchNote {
        let pos = (try store.scalarInt("SELECT COALESCE(MAX(pos), -1) + 1 FROM scratch_notes")) ?? 0
        let stamp = Self.ms(at)
        try store.run("INSERT INTO scratch_notes(title, body, pos, created, updated) VALUES(?,?,?,?,?)",
                      [.text(title), .text(text), .int(pos), .int(stamp), .int(stamp)])
        return ScratchNote(id: store.lastInsertRowId, title: title, text: text, created: Self.date(stamp), updated: Self.date(stamp))
    }

    public func save(_ note: ScratchNote) throws {
        try store.run("UPDATE scratch_notes SET title=?, body=?, updated=? WHERE id=?",
                      [.text(note.title), .text(note.text), .int(Self.ms(note.updated)), .int(note.id)])
    }

    public func delete(id: Int64) throws { try store.run("DELETE FROM scratch_notes WHERE id=?", [.int(id)]) }

    public func savePositions(_ ids: [Int64]) throws {
        try store.transaction {
            for (i, id) in ids.enumerated() { try store.run("UPDATE scratch_notes SET pos=? WHERE id=?", [.int(Int64(i)), .int(id)]) }
        }
    }
}
