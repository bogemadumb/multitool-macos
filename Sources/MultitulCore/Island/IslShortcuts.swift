import Foundation

public struct IslShortcut: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var target: LauncherTarget

    public init(id: String = UUID().uuidString, title: String = "", target: LauncherTarget) {
        self.id = id
        self.title = title.isEmpty ? target.defaultTitle : title
        self.target = target
    }

    public var symbol: String { target.defaultSymbol }
}

public enum IslShortcutDefaults {
    public static let items: [IslShortcut] = [
        IslShortcut(id: "default-clipboard", target: .tool(.clipboard)),
        IslShortcut(id: "default-shelf", target: .tool(.shelf)),
        IslShortcut(id: "default-colorPicker", target: .tool(.colorPicker)),
        IslShortcut(id: "default-screenOcr", target: .tool(.screenOcr)),
        IslShortcut(id: "default-scratchpad", target: .tool(.scratchpad)),
        IslShortcut(id: "default-darkMode", target: .toggle(.darkMode)),
        IslShortcut(id: "default-lockScreen", target: .toggle(.lockScreen))
    ]
}

public struct IslShortcutList: Equatable, Sendable {
    public static let maxItems = 16

    public var items: [IslShortcut]

    public init(items: [IslShortcut] = IslShortcutDefaults.items) { self.items = items }

    public var sanitized: IslShortcutList {
        var seen = Set<String>()
        let unique = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        return IslShortcutList(items: Array(unique.prefix(Self.maxItems)))
    }

    @discardableResult
    public mutating func add(_ target: LauncherTarget, title: String = "", fs: LauncherFileChecking) -> Result<IslShortcut, LauncherIssue> {
        guard items.count < Self.maxItems else { return .failure(.emptyValue) }
        var final = target
        if case .url(let raw) = target {
            switch LauncherResolver.normalizeURL(raw) {
            case .success(let u): final = .url(u.absoluteString)
            case .failure(let e): return .failure(e)
            }
        }
        if case .failure(let e) = LauncherResolver.command(for: final, fs: fs) { return .failure(e) }
        let item = IslShortcut(title: title.trimmingCharacters(in: .whitespaces), target: final)
        items.append(item)
        return .success(item)
    }

    public mutating func remove(id: String) { items.removeAll { $0.id == id } }

    public mutating func move(_ id: String, before target: String) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }), items.contains(where: { $0.id == target }) else { return }
        let item = items.remove(at: from)
        let to = items.firstIndex { $0.id == target } ?? items.count
        items.insert(item, at: to)
    }

    public mutating func nudge(_ id: String, by delta: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + delta, 0), items.count - 1)
        guard to != from else { return }
        items.insert(items.remove(at: from), at: to)
    }

    public mutating func rename(_ id: String, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        items[i].title = t.isEmpty ? items[i].target.defaultTitle : t
    }

    public mutating func reset() { items = IslShortcutDefaults.items }
}

public final class IslShortcutStore {
    private let a: KVAccess
    static let key = "notch.shortcuts"

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslShortcutList {
        guard let raw = a.strings(Self.key) else { return IslShortcutList() }
        let items = raw.compactMap { line -> IslShortcut? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3, let t = LauncherTarget(stored: parts[2]) else { return nil }
            return IslShortcut(id: parts[0], title: parts[1], target: t)
        }
        return IslShortcutList(items: items).sanitized
    }

    public func save(_ list: IslShortcutList) {
        let l = list.sanitized
        if l == IslShortcutList() { a.kv.removeObject(forKey: Self.key); return }
        a.kv.set(l.items.map { "\($0.id)\t\($0.title.replacingOccurrences(of: "\t", with: " "))\t\($0.target.stored)" }, forKey: Self.key)
    }
}

public final class IslShortcutRunner {
    private let fs: LauncherFileChecking
    private let executor: LauncherExecuting

    public init(fs: LauncherFileChecking, executor: LauncherExecuting) {
        self.fs = fs
        self.executor = executor
    }

    public func run(_ item: IslShortcut) -> Result<Void, LauncherIssue> {
        switch LauncherResolver.command(for: item.target, fs: fs) {
        case .failure(let e): return .failure(e)
        case .success(let cmd):
            switch executor.execute(cmd) {
            case .ok: return .success(())
            case .failed(let m): return .failure(.executionFailed(m))
            }
        }
    }
}

public enum IslToolsCatalog {
    public static func tools(available: (LauncherTool) -> Bool) -> [LauncherTool] {
        LauncherTool.allCases.filter(available)
    }

    public static let toggles: [QuickToggleID] = QuickToggleID.allCases.filter { !$0.needsConfirmation }
}

public enum IslCoreSections {
    public static let descriptors: [IslSectionDescriptor] = [
        IslSectionDescriptor(id: IslSectionIDs.music, title: "Музыка", symbol: "music.note", summary: "Играющий трек, обложка, перемотка и управление плеером", defaultOrder: 10),
        IslSectionDescriptor(id: IslSectionIDs.levels, title: "Громкость и яркость", symbol: "speaker.wave.2", summary: "Громкость вывода и яркость дисплеев", defaultOrder: 20),
        IslSectionDescriptor(id: IslSectionIDs.shortcuts, title: "Ярлыки", symbol: "square.grid.2x2", summary: "Твои кнопки: инструменты, приложения, ссылки, скрипты", defaultOrder: 30),
        IslSectionDescriptor(id: IslSectionIDs.mixer, title: "Микшер", symbol: "slider.vertical.3", summary: "Громкость по приложениям", defaultOrder: 40, module: .mixer),
        IslSectionDescriptor(id: IslSectionIDs.clipboard, title: "Буфер", symbol: "doc.on.clipboard", summary: "История буфера обмена", defaultOrder: 50, module: .clipboardHistory),
        IslSectionDescriptor(id: IslSectionIDs.shots, title: "Снимки", symbol: "camera.viewfinder", summary: "Последние скриншоты и запись экрана", defaultOrder: 60, module: .screenshot),
        IslSectionDescriptor(id: IslSectionIDs.shelf, title: "Полка", symbol: "tray.and.arrow.down", summary: "Файловая полка: бросил, вытащил", defaultOrder: 70, module: .shelf),
        IslSectionDescriptor(id: IslSectionIDs.stats, title: "Система", symbol: "cpu", summary: "Процессор, память, сеть, батарея", defaultOrder: 80),
        IslSectionDescriptor(id: IslSectionIDs.tools, title: "Инструменты", symbol: "wrench.and.screwdriver", summary: "Пипетка, текст с экрана, блокнот и другие", defaultOrder: 90)
    ] + IslExtModules.descriptors
}

public enum IslActivityFactory {
    public static func music(_ np: IslNowPlaying, now: Date) -> IslActivity? {
        guard let t = np.track, np.isPlaying else { return nil }
        return IslActivity(id: "music", section: IslSectionIDs.music, priority: IslPriority.music, startedAt: np.updatedAt, peeks: true, token: t.identity,
                           title: t.title.isEmpty ? t.artist : t.title)
    }
}
