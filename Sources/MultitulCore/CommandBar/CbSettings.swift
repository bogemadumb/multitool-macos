import Foundation

public struct CbUserEntry: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var aliases: [String]
    public var target: LauncherTarget
    public var slot: Int?

    public init(id: String = UUID().uuidString, title: String, aliases: [String] = [], target: LauncherTarget, slot: Int? = nil) {
        self.id = id
        self.title = title.isEmpty ? target.defaultTitle : title
        self.aliases = aliases
        self.target = target
        self.slot = slot
    }
}

public struct CbQuicklink: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var keyword: String
    public var template: String
    public var symbol: String

    public init(id: String = UUID().uuidString, name: String, keyword: String, template: String, symbol: String = "link") {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.template = template
        self.symbol = symbol
    }

    public var takesQuery: Bool { template.contains("{query}") }

    static let allowedQuery: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&=+#?/;:@,$")
        return s
    }()

    public func url(for query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = q.addingPercentEncoding(withAllowedCharacters: Self.allowedQuery) ?? q
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
        switch LauncherResolver.normalizeURL(filled) {
        case .success(let u): return u
        case .failure: return nil
        }
    }

    public static let defaults: [CbQuicklink] = [
        CbQuicklink(id: "google", name: "Google", keyword: "g", template: "https://www.google.com/search?q={query}", symbol: "magnifyingglass"),
        CbQuicklink(id: "yandex", name: "Яндекс", keyword: "ya", template: "https://yandex.ru/search/?text={query}", symbol: "magnifyingglass"),
        CbQuicklink(id: "ddg", name: "DuckDuckGo", keyword: "ddg", template: "https://duckduckgo.com/?q={query}", symbol: "magnifyingglass"),
        CbQuicklink(id: "youtube", name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query={query}", symbol: "play.rectangle"),
        CbQuicklink(id: "maps", name: "Карты", keyword: "maps", template: "https://yandex.ru/maps/?text={query}", symbol: "map"),
        CbQuicklink(id: "wiki", name: "Википедия", keyword: "wiki", template: "https://ru.wikipedia.org/w/index.php?search={query}", symbol: "book"),
        CbQuicklink(id: "github", name: "GitHub", keyword: "gh", template: "https://github.com/search?q={query}", symbol: "chevron.left.forwardslash.chevron.right")
    ]
}

public struct CommandBarSettings: Equatable, Sendable {
    public static let maxResultsRange = 5...20
    public static let fileLimitRange = 1...20
    public static let maxEntries = 60
    public static let maxQuicklinks = 40
    public static let slotCount = 9

    public var disabledProviders: Set<CbProviderID> = []
    public var excludedFromGlobal: Set<CbProviderID> = []
    public var maxResults = 9
    public var fileFolders = ["~/Documents", "~/Desktop", "~/Downloads"]
    public var fileLimit = 6
    public var scriptsFolder = ""
    public var userEntries: [CbUserEntry] = []
    public var quicklinks = CbQuicklink.defaults
    public var webFallback = true
    public var webEngineID = "google"
    public var calcAngle = CalcAngle.radians
    public var decimalComma = true
    public var grouping = true
    public var currencyOnline = true
    public var useFrecency = true
    public var closeAfterRun = true
    public var showNumbers = true
    public var pasteResults = true
    public var clipboardLimit = 5
    public var menuLimit = 8
    public var includeLauncherItems = true

    public init() {}

    public func isEnabled(_ p: CbProviderID) -> Bool { !disabledProviders.contains(p) }

    public func inGlobal(_ p: CbProviderID) -> Bool { isEnabled(p) && p.globalByDefault && !excludedFromGlobal.contains(p) }

    public static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst(1)) : (path == "~" ? NSHomeDirectory() : path)
    }

    public var resolvedFileFolders: [String] { fileFolders.map(Self.expand).filter { $0.hasPrefix("/") } }

    public var resolvedScriptsFolder: String {
        let t = scriptsFolder.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? MultitulPaths.home + "/scripts" : Self.expand(t)
    }

    public var webEngine: CbQuicklink? { quicklinks.first { $0.id == webEngineID && $0.takesQuery } ?? quicklinks.first { $0.takesQuery } }

    public func entry(slot: Int) -> CbUserEntry? { userEntries.first { $0.slot == slot } }

    public var sanitized: CommandBarSettings {
        var s = self
        s.maxResults = ToolsClamp.int(maxResults, Self.maxResultsRange)
        s.fileLimit = ToolsClamp.int(fileLimit, Self.fileLimitRange)
        s.clipboardLimit = ToolsClamp.int(clipboardLimit, 1...20)
        s.menuLimit = ToolsClamp.int(menuLimit, 1...20)
        var seen = Set<String>()
        var slots = Set<Int>()
        s.userEntries = userEntries.filter { seen.insert($0.id).inserted }.prefix(Self.maxEntries).map { e in
            var e = e
            if let sl = e.slot { if (1...Self.slotCount).contains(sl), slots.insert(sl).inserted {} else { e.slot = nil } }
            e.aliases = e.aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return e
        }
        var ids = Set<String>()
        var words = Set<String>()
        s.quicklinks = quicklinks.filter { q in
            let kw = q.keyword.trimmingCharacters(in: .whitespaces).lowercased()
            return !q.name.isEmpty && !kw.isEmpty && !kw.contains(" ") && ids.insert(q.id).inserted && words.insert(kw).inserted
        }.prefix(Self.maxQuicklinks).map { var q = $0; q.keyword = q.keyword.trimmingCharacters(in: .whitespaces).lowercased(); return q }
        s.fileFolders = fileFolders.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return s
    }
}

public enum CommandBarHotkeys {
    public static let toggle = HotkeySpec(id: "commandBar.toggle", title: "Командная строка: открыть", defaultCombo: .none)
    public static let slots: [HotkeySpec] = (1...CommandBarSettings.slotCount).map {
        HotkeySpec(id: "commandBar.slot\($0)", title: "Командная строка: пункт \($0)", defaultCombo: .none)
    }
    public static let all = [toggle] + slots
}

public final class CommandBarSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    private struct EntryDTO: Codable {
        var id: String
        var title: String
        var aliases: [String]
        var target: String
        var slot: Int?
    }

    private struct LinkDTO: Codable {
        var id: String
        var name: String
        var keyword: String
        var template: String
        var symbol: String
    }

    private func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let s = a.string(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    private func encode<T: Encodable>(_ v: T) -> String? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func set(_ raw: [String]?) -> Set<CbProviderID> { Set((raw ?? []).compactMap(CbProviderID.init(rawValue:))) }

    public func load() -> CommandBarSettings {
        var s = CommandBarSettings()
        let p = "commandBar."
        s.disabledProviders = Self.set(a.strings(p + "disabledProviders"))
        s.excludedFromGlobal = Self.set(a.strings(p + "excludedFromGlobal"))
        s.maxResults = a.int(p + "maxResults", s.maxResults)
        if let f = a.strings(p + "fileFolders") { s.fileFolders = f }
        s.fileLimit = a.int(p + "fileLimit", s.fileLimit)
        s.scriptsFolder = a.string(p + "scriptsFolder") ?? s.scriptsFolder
        if let e = decode(p + "userEntries", [EntryDTO].self) {
            s.userEntries = e.compactMap { d in LauncherTarget(stored: d.target).map { CbUserEntry(id: d.id, title: d.title, aliases: d.aliases, target: $0, slot: d.slot) } }
        }
        if let l = decode(p + "quicklinks", [LinkDTO].self) {
            s.quicklinks = l.map { CbQuicklink(id: $0.id, name: $0.name, keyword: $0.keyword, template: $0.template, symbol: $0.symbol) }
        }
        s.webFallback = a.bool(p + "webFallback", s.webFallback)
        s.webEngineID = a.string(p + "webEngineID") ?? s.webEngineID
        if let raw = a.string(p + "calcAngle"), let v = CalcAngle(rawValue: raw) { s.calcAngle = v }
        s.decimalComma = a.bool(p + "decimalComma", s.decimalComma)
        s.grouping = a.bool(p + "grouping", s.grouping)
        s.currencyOnline = a.bool(p + "currencyOnline", s.currencyOnline)
        s.useFrecency = a.bool(p + "useFrecency", s.useFrecency)
        s.closeAfterRun = a.bool(p + "closeAfterRun", s.closeAfterRun)
        s.showNumbers = a.bool(p + "showNumbers", s.showNumbers)
        s.pasteResults = a.bool(p + "pasteResults", s.pasteResults)
        s.clipboardLimit = a.int(p + "clipboardLimit", s.clipboardLimit)
        s.menuLimit = a.int(p + "menuLimit", s.menuLimit)
        s.includeLauncherItems = a.bool(p + "includeLauncherItems", s.includeLauncherItems)
        return s.sanitized
    }

    public func save(_ settings: CommandBarSettings) {
        let s = settings.sanitized
        let b = CommandBarSettings()
        let p = "commandBar."
        func putList(_ key: String, _ v: [String], _ d: [String]) { if v == d { a.kv.removeObject(forKey: key) } else { a.kv.set(v, forKey: key) } }
        putList(p + "disabledProviders", s.disabledProviders.map(\.rawValue).sorted(), [])
        putList(p + "excludedFromGlobal", s.excludedFromGlobal.map(\.rawValue).sorted(), [])
        a.put(p + "maxResults", s.maxResults, b.maxResults)
        putList(p + "fileFolders", s.fileFolders, b.fileFolders)
        a.put(p + "fileLimit", s.fileLimit, b.fileLimit)
        a.put(p + "scriptsFolder", s.scriptsFolder, b.scriptsFolder)
        if s.userEntries.isEmpty { a.kv.removeObject(forKey: p + "userEntries") }
        else if let j = encode(s.userEntries.map { EntryDTO(id: $0.id, title: $0.title, aliases: $0.aliases, target: $0.target.stored, slot: $0.slot) }) { a.kv.set(j, forKey: p + "userEntries") }
        if s.quicklinks == b.quicklinks { a.kv.removeObject(forKey: p + "quicklinks") }
        else if let j = encode(s.quicklinks.map { LinkDTO(id: $0.id, name: $0.name, keyword: $0.keyword, template: $0.template, symbol: $0.symbol) }) { a.kv.set(j, forKey: p + "quicklinks") }
        a.put(p + "webFallback", s.webFallback, b.webFallback)
        a.put(p + "webEngineID", s.webEngineID, b.webEngineID)
        a.put(p + "calcAngle", s.calcAngle.rawValue, b.calcAngle.rawValue)
        a.put(p + "decimalComma", s.decimalComma, b.decimalComma)
        a.put(p + "grouping", s.grouping, b.grouping)
        a.put(p + "currencyOnline", s.currencyOnline, b.currencyOnline)
        a.put(p + "useFrecency", s.useFrecency, b.useFrecency)
        a.put(p + "closeAfterRun", s.closeAfterRun, b.closeAfterRun)
        a.put(p + "showNumbers", s.showNumbers, b.showNumbers)
        a.put(p + "pasteResults", s.pasteResults, b.pasteResults)
        a.put(p + "clipboardLimit", s.clipboardLimit, b.clipboardLimit)
        a.put(p + "menuLimit", s.menuLimit, b.menuLimit)
        a.put(p + "includeLauncherItems", s.includeLauncherItems, b.includeLauncherItems)
    }
}
