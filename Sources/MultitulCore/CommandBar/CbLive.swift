import Foundation
import AppKit
import ApplicationServices

public final class SwitcherCbWindowSource: CbWindowSource {
    private let source: SwitcherSource
    private let ownPID: Int32

    public init(source: SwitcherSource, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.source = source
        self.ownPID = ownPID
    }

    public func windows() -> [SwitchEntry] {
        let snap = source.snapshot()
        var filter = SwitchFilter()
        filter.ownPID = ownPID
        filter.windowless = .off
        let ctx = SwitcherContext(scope: .allApps, focusedKey: snap.focusedKey, frontPID: snap.frontPID)
        return SwitcherListBuilder.build(windows: snap.windows, apps: snap.apps, filter: filter, context: ctx)
    }
}

public final class SystemCbAppSource: CbAppSource {
    private var cache: [CbAppInfo] = []
    private var loadedAt: Date = .distantPast
    private let ttl: TimeInterval
    private let catalog: SystemAppCatalog

    public init(ttl: TimeInterval = 90) {
        self.ttl = ttl
        catalog = SystemAppCatalog(extraFolders: { ["/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices/Applications"] })
    }

    public func invalidate() { loadedAt = .distantPast }

    public func apps() -> [CbAppInfo] {
        if Date().timeIntervalSince(loadedAt) > ttl || cache.isEmpty {
            cache = catalog.installedApps().map { a in
                let shown = FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: "")
                return CbAppInfo(name: a.name, path: a.path, bundleID: a.bundleId, extraNames: shown != a.name ? [shown] : [])
            }
            loadedAt = Date()
        }
        var running: [String: Int32] = [:]
        for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular {
            if let b = r.bundleIdentifier { running[b] = r.processIdentifier }
        }
        return cache.map { var a = $0; if let pid = running[a.bundleID] { a.isRunning = true; a.pid = pid }; return a }
    }
}

public final class SpotlightFileSearcher: CbFileSearching {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 0.12) { self.debounce = debounce }

    public func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
        stopQuery()
    }

    private func stopQuery() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        query?.stop()
        query = nil
    }

    static func predicate(for text: String) -> NSPredicate? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let parts = tokens.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    public func search(_ text: String, folders: [String], limit: Int, deliver: @escaping (String, [CbFileHit]) -> Void) {
        cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, let pred = Self.predicate(for: text) else { return }
            let q = NSMetadataQuery()
            q.predicate = pred
            q.searchScopes = folders
            q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
            self.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
                guard let self, gen == self.generation else { return }
                q.disableUpdates()
                var hits: [CbFileHit] = []
                for i in 0..<min(q.resultCount, limit) {
                    guard let item = q.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                    hits.append(CbFileHit(path: path, isDirectory: type == "public.folder", lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date))
                }
                self.stopQuery()
                deliver(text, hits)
            }
            self.query = q
            q.start()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

public final class AXMenuReader: CbMenuSource {
    private let lock = NSLock()
    private var latest: CbMenuSnapshot?
    private let queue = DispatchQueue(label: "multitul.commandbar.menu", qos: .userInitiated)

    public init() { _ = AXTimeouts.configured }

    public func snapshot() -> CbMenuSnapshot? { lock.withLock { latest } }

    public func clear() { lock.withLock { latest = nil } }

    public func capture(pid: Int32, appName: String, completion: (() -> Void)? = nil) {
        guard AXIsProcessTrusted() else { clear(); return }
        queue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var count = 0
            let deadline = Date().addingTimeInterval(1.5)
            func node(_ e: AXUIElement, depth: Int) -> CbMenuNode? {
                guard count < CbMenu.maxEntries * 2, Date() < deadline else { return nil }
                count += 1
                let title = AXRead.string(e, kAXTitleAttribute) ?? ""
                var kids: [CbMenuNode] = []
                if depth < CbMenu.maxDepth {
                    for menu in AXRead.elements(e, kAXChildrenAttribute) {
                        for item in AXRead.elements(menu, kAXChildrenAttribute) { if let n = node(item, depth: depth + 1) { kids.append(n) } }
                    }
                }
                var raw: CFTypeRef?
                var mods: Int?
                if AXUIElementCopyAttributeValue(e, kAXMenuItemCmdModifiersAttribute as CFString, &raw) == .success { mods = (raw as? NSNumber)?.intValue }
                let ch = AXRead.string(e, kAXMenuItemCmdCharAttribute)
                return CbMenuNode(title: title, children: kids, enabled: AXRead.bool(e, kAXEnabledAttribute) ?? true, cmdChar: ch, cmdModifiers: mods)
            }
            var tops: [CbMenuNode] = []
            if let bar = AXRead.element(app, kAXMenuBarAttribute) {
                for item in AXRead.elements(bar, kAXChildrenAttribute) { if let n = node(item, depth: 1) { tops.append(n) } }
            }
            let entries = CbMenu.flatten(tops)
            self?.lock.withLock { self?.latest = CbMenuSnapshot(pid: pid, appName: appName, entries: entries) }
            completion?()
        }
    }

    public static func press(pid: Int32, path: [String]) -> Bool {
        guard AXIsProcessTrusted(), !path.isEmpty else { return false }
        _ = AXTimeouts.configured
        let app = AXUIElementCreateApplication(pid)
        guard let bar = AXRead.element(app, kAXMenuBarAttribute) else { return false }
        var level = AXRead.elements(bar, kAXChildrenAttribute)
        var current: AXUIElement?
        for title in path {
            guard let hit = level.first(where: { (AXRead.string($0, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == title }) else { return false }
            current = hit
            level = AXRead.elements(hit, kAXChildrenAttribute).flatMap { AXRead.elements($0, kAXChildrenAttribute) }
        }
        guard let target = current else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }
}

public final class SystemCbProcessSource: CbProcessSource {
    private var cache: [CatalogProcess] = []
    private var loadedAt: Date = .distantPast
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 4) { self.ttl = ttl }

    public func processes() -> [CatalogProcess] {
        if Date().timeIntervalSince(loadedAt) > ttl { cache = ProcessCatalog.live(); loadedAt = Date() }
        return cache
    }

    public func invalidate() { loadedAt = .distantPast }
}

public final class FolderCbScriptSource: CbScriptSource {
    public init() {}

    public func scripts(in folder: String) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.map { folder + "/" + $0 }
    }
}

public final class QuickLauncherCbSource: CbLauncherSource {
    private let store: QuickLauncherSettingsStore

    public init(store: QuickLauncherSettingsStore = QuickLauncherSettingsStore()) { self.store = store }

    public func items() -> [LauncherItem] { store.load().items }
}
