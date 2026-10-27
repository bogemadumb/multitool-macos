import Foundation

public struct CbAppInfo: Equatable, Sendable {
    public var name: String
    public var path: String
    public var bundleID: String
    public var isRunning: Bool
    public var pid: Int32
    public var extraNames: [String]

    public init(name: String, path: String, bundleID: String = "", isRunning: Bool = false, pid: Int32 = 0, extraNames: [String] = []) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.isRunning = isRunning
        self.pid = pid
        self.extraNames = extraNames
    }

    public var fileName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    public var stableID: String { bundleID.isEmpty ? path : bundleID }
}

public protocol CbAppSource: AnyObject {
    func apps() -> [CbAppInfo]
}

public protocol CbWindowSource: AnyObject {
    func windows() -> [SwitchEntry]
}

public protocol CbClipSource: AnyObject {
    func recent(limit: Int) -> [ClipItem]
    func search(_ text: String, limit: Int) -> [ClipItem]
}

public final class ClipStoreCbSource: CbClipSource {
    private let store: ClipStore

    public init(store: ClipStore) { self.store = store }

    public func recent(limit: Int) -> [ClipItem] { (try? store.items(limit: limit)) ?? [] }

    public func search(_ text: String, limit: Int) -> [ClipItem] { (try? store.search(text, limit: limit)) ?? [] }
}

public protocol CbSnippetSource: AnyObject {
    func snippets() -> [Snippet]
    func markUsed(id: Int64)
}

public final class SnippetStoreCbSource: CbSnippetSource {
    private let store: SnippetStore

    public init(store: SnippetStore) { self.store = store }

    public func snippets() -> [Snippet] { (try? store.enabled()) ?? [] }

    public func markUsed(id: Int64) { try? store.markUsed(id: id) }
}

public protocol CbProcessSource: AnyObject {
    func processes() -> [CatalogProcess]
}

public protocol CbScriptSource: AnyObject {
    func scripts(in folder: String) -> [String]
}

public protocol CbLauncherSource: AnyObject {
    func items() -> [LauncherItem]
}

public struct CbFileHit: Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var lastUsed: Date?

    public init(path: String, name: String? = nil, isDirectory: Bool = false, lastUsed: Date? = nil) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.lastUsed = lastUsed
    }
}

public protocol CbFileSearching: AnyObject {
    func search(_ text: String, folders: [String], limit: Int, deliver: @escaping (_ text: String, _ hits: [CbFileHit]) -> Void)
    func cancel()
}

public struct CbMenuNode: Equatable, Sendable {
    public var title: String
    public var children: [CbMenuNode]
    public var enabled: Bool
    public var cmdChar: String?
    public var cmdModifiers: Int?

    public init(title: String, children: [CbMenuNode] = [], enabled: Bool = true, cmdChar: String? = nil, cmdModifiers: Int? = nil) {
        self.title = title
        self.children = children
        self.enabled = enabled
        self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers
    }
}

public struct CbMenuEntry: Equatable, Sendable {
    public var path: [String]
    public var shortcut: String?
    public var enabled: Bool

    public init(path: [String], shortcut: String? = nil, enabled: Bool = true) {
        self.path = path
        self.shortcut = shortcut
        self.enabled = enabled
    }

    public var title: String { path.last ?? "" }
}

public struct CbMenuSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var appName: String
    public var entries: [CbMenuEntry]

    public init(pid: Int32, appName: String, entries: [CbMenuEntry]) {
        self.pid = pid
        self.appName = appName
        self.entries = entries
    }
}

public protocol CbMenuSource: AnyObject {
    func snapshot() -> CbMenuSnapshot?
}

public enum CbMenu {
    public static let maxDepth = 4
    public static let maxEntries = 1200
    static let skippedTopLevel: Set<String> = ["Apple", ""]

    // AX gives a bitmask where bit 3 means "no Command"; Command is part of the shortcut otherwise.
    public static func shortcut(char: String?, modifiers: Int?) -> String? {
        guard let c = char, !c.isEmpty, c != " " || modifiers != nil else { return nil }
        let m = modifiers ?? 0
        var s = ""
        if m & 4 != 0 { s += "⌃" }
        if m & 2 != 0 { s += "⌥" }
        if m & 1 != 0 { s += "⇧" }
        if m & 8 == 0 { s += "⌘" }
        return s + c.uppercased()
    }

    public static func flatten(_ menus: [CbMenuNode], maxDepth: Int = CbMenu.maxDepth, limit: Int = CbMenu.maxEntries) -> [CbMenuEntry] {
        var out: [CbMenuEntry] = []
        func visit(_ n: CbMenuNode, _ path: [String], _ enabledSoFar: Bool) {
            guard out.count < limit else { return }
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { return }
            let p = path + [title]
            let on = enabledSoFar && n.enabled
            if n.children.isEmpty {
                if p.count >= 2 { out.append(CbMenuEntry(path: p, shortcut: shortcut(char: n.cmdChar, modifiers: n.cmdModifiers), enabled: on)) }
                return
            }
            guard p.count < maxDepth else { return }
            for c in n.children { visit(c, p, on) }
        }
        for top in menus where !skippedTopLevel.contains(top.title) {
            for c in top.children { visit(c, [top.title], top.enabled) }
        }
        return out
    }
}
