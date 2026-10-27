import Foundation

public final class CbContext {
    public var settings: () -> CommandBarSettings
    public var isModuleEnabled: (ModuleID) -> Bool
    public var rates: () -> CurrencyRateTable?
    public var now: () -> Date

    public init(settings: @escaping () -> CommandBarSettings = { CommandBarSettings() }, isModuleEnabled: @escaping (ModuleID) -> Bool = { _ in true },
                rates: @escaping () -> CurrencyRateTable? = { nil }, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.isModuleEnabled = isModuleEnabled
        self.rates = rates
        self.now = now
    }
}

public enum CbText {
    public static func oneLine(_ s: String, limit: Int = 90) -> String {
        let t = s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    public static func abbreviatedPath(_ p: String, home: String = NSHomeDirectory()) -> String {
        p == home ? "~" : (p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p)
    }

    public static func age(_ date: Date, now: Date) -> String {
        let s = max(now.timeIntervalSince(date), 0)
        switch s {
        case ..<60: return "только что"
        case ..<3600: return "\(Int(s / 60)) мин назад"
        case ..<86400: return "\(Int(s / 3600)) ч назад"
        default: return "\(Int(s / 86400)) дн. назад"
        }
    }
}

// MARK: calculator and units

public final class CbCalculatorProvider: CbProvider {
    public let id = CbProviderID.calculator
    private let ctx: CbContext

    public init(ctx: CbContext) { self.ctx = ctx }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let text = q.text
        guard !text.isEmpty else { return [] }
        let s = ctx.settings()
        if q.forced == nil, !CalcEngine.looksLikeCalculation(text) { return [] }
        switch CalcEngine.evaluate(text, angle: s.calcAngle) {
        case .success(let v):
            let display = CalcFormat.format(v, CalcFormatOptions(decimalComma: s.decimalComma, grouping: s.grouping))
            let copy = CalcFormat.format(v, CalcFormatOptions(decimalComma: s.decimalComma, grouping: false))
            let plain = CalcFormat.format(v, CalcFormatOptions(decimalComma: false, grouping: false, significantDigits: 15))
            let r = CbResult(id: "calc:result", provider: id, title: display, subtitle: "\(text) =", symbol: "equal.circle", action: .copyText(copy),
                             secondary: [CbSecondary(title: "Вставить", symbol: "arrow.down.doc", action: .pasteText(copy)),
                                         CbSecondary(title: "Копировать с точкой", symbol: "doc.on.doc", action: .copyText(plain))])
            return [CbCandidate(r, fixedScore: 1000)]
        case .failure(let e):
            guard q.forced == .calculator else { return [] }
            return [CbCandidate(CbResult(id: "calc:error", provider: id, title: e.message, subtitle: text, symbol: "exclamationmark.triangle", action: .noop), fixedScore: 1000)]
        }
    }
}

public final class CbUnitsProvider: CbProvider {
    public let id = CbProviderID.units
    private let ctx: CbContext

    public init(ctx: CbContext) { self.ctx = ctx }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let text = q.text
        guard !text.isEmpty, q.forced == nil else { return [] }
        let s = ctx.settings()
        let rates = ctx.rates()
        guard let outcome = UnitConverter.parse(text, rates: rates, decimalComma: s.decimalComma) else { return [] }
        let stamp = rates?.date.map { " · курс на \($0)" } ?? ""
        func line(_ l: ConversionLine, _ n: Int, score: Double) -> CbCandidate {
            let note = l.to.category == .currency ? stamp : ""
            let r = CbResult(id: "unit:\(l.from.id):\(l.to.id)", provider: id, title: l.display, subtitle: l.from.category.title + ": " + l.expression + note,
                             symbol: "arrow.left.arrow.right", action: .copyText(l.copyText),
                             secondary: [CbSecondary(title: "Вставить", symbol: "arrow.down.doc", action: .pasteText(l.copyText)),
                                         CbSecondary(title: "Копировать с единицей", symbol: "doc.on.doc", action: .copyText(l.display))])
            return CbCandidate(r, fixedScore: score - Double(n))
        }
        switch outcome {
        case .converted(let l): return [line(l, 0, score: 990)]
        case .suggestions(_, let lines): return lines.enumerated().map { line($0.element, $0.offset, score: 900) }
        case .incompatible(let a, let b):
            return [CbCandidate(CbResult(id: "unit:incompatible", provider: id, title: "Нельзя перевести «\(a.symbol)» в «\(b.symbol)»",
                                         subtitle: "\(a.category.title) и \(b.category.title) — разные величины", symbol: "exclamationmark.triangle", action: .noop), fixedScore: 500)]
        case .ratesUnavailable:
            let sub = s.currencyOnline ? "Нажми Return, чтобы загрузить курсы" : "Загрузка курсов выключена в настройках"
            return [CbCandidate(CbResult(id: "unit:rates", provider: id, title: "Курсы валют не загружены", subtitle: sub, symbol: "arrow.triangle.2.circlepath",
                                         action: s.currencyOnline ? .refreshRates : .noop), fixedScore: 600)]
        case .ratesMissing(let code):
            return [CbCandidate(CbResult(id: "unit:missing", provider: id, title: "Нет курса для \(code)", subtitle: "Такой валюты нет в таблице курсов", symbol: "exclamationmark.triangle", action: .noop), fixedScore: 500)]
        }
    }
}

// MARK: apps, windows, commands

public enum CbAppAliases {
    public static let byBundle: [String: [String]] = [
        "org.telegram.desktop": ["тг", "телеграм", "телега"], "ru.keepcoder.Telegram": ["тг", "телеграм", "телега"], "com.tdesktop.Telegram": ["тг", "телеграм", "телега"],
        "com.apple.Safari": ["сафари"], "com.google.Chrome": ["хром", "гугл хром"], "com.apple.finder": ["файндер", "файлы"],
        "com.apple.Terminal": ["терминал", "консоль"], "com.microsoft.VSCode": ["vs code", "vscode", "код"], "com.apple.systempreferences": ["настройки", "system settings"],
        "com.apple.Notes": ["заметки"], "com.apple.mail": ["почта"], "com.apple.iCal": ["календарь"], "com.apple.Music": ["музыка"], "com.apple.Photos": ["фото"],
        "net.whatsapp.WhatsApp": ["вацап", "ватсап"], "com.spotify.client": ["спотифай"], "com.figma.Desktop": ["фигма"], "notion.id": ["ношен", "ноушн"],
        "com.hnc.Discord": ["дискорд"], "us.zoom.xos": ["зум"], "com.apple.ActivityMonitor": ["мониторинг системы", "монитор"], "com.apple.calculator": ["калькулятор"],
        "com.apple.Preview": ["просмотр"], "ru.yandex.desktop.yandex-browser": ["яндекс браузер", "яндекс"], "org.mozilla.firefox": ["файрфокс", "лиса"],
        "com.microsoft.Word": ["ворд"], "com.microsoft.Excel": ["эксель"], "com.microsoft.Powerpoint": ["пауэрпоинт", "повер поинт"]
    ]
}

public final class CbAppsProvider: CbProvider {
    public let id = CbProviderID.apps
    private let source: CbAppSource
    private let ctx: CbContext
    private var keyCache: [String: [FuzzyKey]] = [:]

    public init(source: CbAppSource, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    func keys(for a: CbAppInfo) -> [FuzzyKey] {
        let cacheKey = a.path + "|" + a.name + "|" + a.extraNames.joined(separator: ",")
        if let k = keyCache[cacheKey] { return k }
        var names = [a.name]
        if a.fileName != a.name { names.append(a.fileName) }
        names += a.extraNames
        names += CbAppAliases.byBundle[a.bundleID] ?? []
        if let last = a.bundleID.split(separator: ".").last, last.count > 2 { names.append(String(last)) }
        let keys = names.map { FuzzyKey($0) }
        keyCache[cacheKey] = keys
        return keys
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        let canUninstall = ctx.isModuleEnabled(.uninstaller)
        return source.apps().map { a in
            var sec: [CbSecondary] = []
            if a.isRunning && a.pid > 0 { sec.append(CbSecondary(title: "Завершить", symbol: "power", action: .quitApp(pid: a.pid))) }
            sec.append(CbSecondary(title: "Показать в Finder", symbol: "folder", action: .revealFile(a.path)))
            if canUninstall, InstalledApp(path: a.path, bundleId: a.bundleID, name: a.name).protection == nil {
                sec.append(CbSecondary(title: "Удалить…", symbol: "trash", action: .uninstallApp(a.path)))
            }
            sec.append(CbSecondary(title: "Скопировать путь", symbol: "doc.on.doc", action: .copyText(a.path)))
            var extra: [String] = []
            for e in s.userEntries where e.target == .app(a.path) || e.target == .app(a.bundleID) { extra += e.aliases }
            let r = CbResult(id: "app:" + a.stableID, provider: id, title: a.name, subtitle: a.isRunning ? "Запущено" : CbText.abbreviatedPath((a.path as NSString).deletingLastPathComponent),
                             symbol: "app", iconPath: a.path, trailing: a.isRunning ? "●" : "", action: .openApp(a.path), secondary: sec, frecencyKey: "app:" + a.stableID)
            return CbCandidate(r, keys: keys(for: a) + extra.map { FuzzyKey($0) })
        }
    }
}

public final class CbWindowsProvider: CbProvider {
    public let id = CbProviderID.windows
    private let source: CbWindowSource

    public init(source: CbWindowSource) { self.source = source }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        source.windows().compactMap { e in
            guard e.kind == .window, let w = e.window else { return nil }
            let title = e.displayTitle
            let r = CbResult(id: "win:\(e.pid):\(w.key)", provider: id, title: title, subtitle: e.appName + (e.isMinimized ? " · свёрнуто" : ""), symbol: "macwindow",
                             trailing: e.isMinimized ? "▾" : "", action: .focusWindow(key: w.key, pid: e.pid),
                             secondary: [CbSecondary(title: "Завершить приложение", symbol: "power", action: .quitApp(pid: e.pid))])
            return CbCandidate(r, names: [title, e.appName])
        }
    }
}

public final class CbCommandsProvider: CbProvider {
    public let id = CbProviderID.commands
    private let ctx: CbContext

    public init(ctx: CbContext) { self.ctx = ctx }

    static let toolKeywords: [LauncherTool: [String]] = [
        .colorPicker: ["color picker", "eyedropper", "пипетка", "цвет"],
        .screenOcr: ["ocr", "text from screen", "распознать текст", "текст с экрана"],
        .scratchpad: ["scratchpad", "notes", "блокнот", "заметки"],
        .cameraPreview: ["camera", "mirror", "камера", "зеркало"],
        .cleaningMode: ["cleaning mode", "wipe keyboard", "уборка", "протереть клавиатуру"],
        .shelf: ["shelf", "полка"],
        .clipboard: ["clipboard history", "история буфера", "буфер обмена"]
    ]

    static let toggleKeywords: [QuickToggleID: [String]] = [
        .darkMode: ["dark mode", "appearance", "тёмная тема", "ночная тема", "тема"],
        .desktopIcons: ["desktop icons", "hide desktop", "иконки рабочего стола", "значки стола"],
        .ejectDisks: ["eject", "unmount", "извлечь диски", "флешка"],
        .emptyTrash: ["empty trash", "очистить корзину"],
        .restartFinder: ["restart finder", "relaunch finder", "перезапустить finder"],
        .lockScreen: ["lock screen", "lock", "заблокировать экран", "блокировка"],
        .displaySleep: ["display off", "sleep display", "выключить экран", "погасить экран"],
        .screenSaver: ["screen saver", "screensaver", "заставка"]
    ]

    private var cached: [CbCandidate] = []
    private var cachedSignature = ""

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let signature = LauncherTool.allCases.map { ctx.isModuleEnabled($0.module) ? "1" : "0" }.joined() + (ctx.isModuleEnabled(.quickToggles) ? "1" : "0")
        if signature == cachedSignature, !cached.isEmpty { return cached }
        cached = build()
        cachedSignature = signature
        return cached
    }

    private func build() -> [CbCandidate] {
        var out: [CbCandidate] = []
        for t in LauncherTool.allCases where t != .commandBar && ctx.isModuleEnabled(t.module) {
            let r = CbResult(id: "cmd:tool:\(t.rawValue)", provider: id, title: t.title, subtitle: "Инструмент Мультитула", symbol: t.symbol, action: .launcher(.tool(t)), frecencyKey: "cmd:tool:\(t.rawValue)")
            out.append(CbCandidate(r, names: [t.title] + (Self.toolKeywords[t] ?? [])))
        }
        if ctx.isModuleEnabled(.quickToggles) {
            for t in QuickToggleID.allCases {
                let r = CbResult(id: "cmd:toggle:\(t.rawValue)", provider: id, title: t.title, subtitle: "Переключатель", symbol: t.symbol, action: .launcher(.toggle(t)), frecencyKey: "cmd:toggle:\(t.rawValue)")
                out.append(CbCandidate(r, names: [t.title] + (Self.toggleKeywords[t] ?? [])))
            }
        }
        for c in CbSystemCommand.allCases {
            let r = CbResult(id: "cmd:sys:\(c.rawValue)", provider: id, title: c.title, subtitle: c.needsConfirmation ? "Системная команда · с подтверждением" : "Системная команда",
                             symbol: c.symbol, action: .system(c), frecencyKey: "cmd:sys:\(c.rawValue)")
            out.append(CbCandidate(r, names: [c.title] + c.keywords))
        }
        for g in ModuleGroup.allCases {
            let r = CbResult(id: "cmd:section:\(g.rawValue)", provider: id, title: "Раздел «\(g.title)»", subtitle: "Открыть окно Мультитула", symbol: g.symbol, action: .openSection(g.rawValue), frecencyKey: "cmd:section:\(g.rawValue)")
            out.append(CbCandidate(r, names: [g.title, "открыть " + g.title, "multitul " + g.title]))
        }
        let modules = CbResult(id: "cmd:section:modules", provider: id, title: "Модули и права", subtitle: "Открыть окно Мультитула", symbol: "gearshape", action: .openSection("modules"), frecencyKey: "cmd:section:modules")
        out.append(CbCandidate(modules, names: ["Модули и права", "modules", "permissions", "права", "настройки мультитула"]))
        return out
    }
}

// MARK: user entries, scripts, links

public final class CbEntriesProvider: CbProvider {
    public let id = CbProviderID.entries
    private let ctx: CbContext
    private let launcher: CbLauncherSource?

    public init(ctx: CbContext, launcher: CbLauncherSource? = nil) {
        self.ctx = ctx
        self.launcher = launcher
    }

    public static func detail(_ t: LauncherTarget) -> String {
        switch t {
        case .app(let a), .url(let a), .script(let a): return t.kindTitle + " · " + CbText.abbreviatedPath(a)
        default: return t.kindTitle
        }
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        var seen = Set<String>()
        var out: [CbCandidate] = []
        func add(title: String, aliases: [String], target: LauncherTarget, slot: Int?) {
            guard seen.insert(target.stored).inserted else { return }
            var sec: [CbSecondary] = []
            if case .app(let p) = target, p.hasPrefix("/") { sec.append(CbSecondary(title: "Показать в Finder", symbol: "folder", action: .revealFile(p))) }
            let r = CbResult(id: "entry:" + target.stored, provider: id, title: title, subtitle: Self.detail(target), symbol: target.defaultSymbol,
                             iconPath: { if case .app(let p) = target, p.hasPrefix("/") { return p } else { return nil } }(),
                             trailing: slot.map { "#\($0)" } ?? "", action: .launcher(target), secondary: sec, frecencyKey: "entry:" + target.stored)
            out.append(CbCandidate(r, names: [title] + aliases))
        }
        for e in s.userEntries { add(title: e.title, aliases: e.aliases, target: e.target, slot: e.slot) }
        if s.includeLauncherItems, let launcher {
            for it in launcher.items() { add(title: it.title, aliases: [], target: it.target, slot: nil) }
        }
        return out
    }
}

public final class CbScriptsProvider: CbProvider {
    public let id = CbProviderID.scripts
    private let source: CbScriptSource
    private let ctx: CbContext

    public init(source: CbScriptSource, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    public static let extensions: Set<String> = ["sh", "zsh", "command", "py", "scpt", "applescript"]

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let folder = ctx.settings().resolvedScriptsFolder
        return source.scripts(in: folder).filter { Self.extensions.contains(($0 as NSString).pathExtension.lowercased()) }.map { path in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let r = CbResult(id: "script:" + path, provider: id, title: name, subtitle: "Скрипт · " + CbText.abbreviatedPath((path as NSString).deletingLastPathComponent), symbol: "terminal",
                             action: .launcher(.script(path)), secondary: [CbSecondary(title: "Показать в Finder", symbol: "folder", action: .revealFile(path))], frecencyKey: "script:" + path)
            return CbCandidate(r, names: [name, (path as NSString).lastPathComponent])
        }
    }
}

public final class CbQuicklinksProvider: CbProvider {
    public let id = CbProviderID.quicklinks
    private let ctx: CbContext

    public init(ctx: CbContext) { self.ctx = ctx }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        let text = q.text
        var out: [CbCandidate] = []
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let head = parts.first.map { $0.lowercased() } ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        for l in s.quicklinks {
            if !text.isEmpty, head == l.keyword, l.takesQuery, !rest.isEmpty, let u = l.url(for: rest) {
                let r = CbResult(id: "ql:\(l.id):query", provider: id, title: "Искать «\(rest)» — \(l.name)", subtitle: u.host ?? u.absoluteString, symbol: l.symbol, action: .launcher(.url(u.absoluteString)))
                out.append(CbCandidate(r, fixedScore: 800))
                continue
            }
            guard let u = l.url(for: "") else { continue }
            let r = CbResult(id: "ql:\(l.id)", provider: id, title: l.name, subtitle: l.takesQuery ? "Быстрая ссылка · \(l.keyword) …" : CbText.oneLine(l.template, limit: 60),
                             symbol: l.symbol, action: .launcher(.url(u.absoluteString)), frecencyKey: "ql:\(l.id)")
            out.append(CbCandidate(r, names: [l.name, l.keyword]))
        }
        return out
    }
}

public final class CbWebProvider: CbProvider {
    public let id = CbProviderID.web
    private let ctx: CbContext

    public init(ctx: CbContext) { self.ctx = ctx }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        let text = q.text
        guard !text.isEmpty, q.forced == .web || (q.forced == nil && s.webFallback), let engine = s.webEngine, let u = engine.url(for: text) else { return [] }
        let r = CbResult(id: "web:search", provider: id, title: "Искать «\(CbText.oneLine(text, limit: 50))» — \(engine.name)", subtitle: u.host ?? "", symbol: "magnifyingglass", action: .launcher(.url(u.absoluteString)))
        return [CbCandidate(r, fixedScore: q.forced == .web ? 1000 : 1)]
    }
}

// MARK: files, clipboard, snippets, menu, emoji, processes, uninstall

public enum CbFileFilter {
    public static func accept(_ path: String) -> Bool {
        let comps = path.split(separator: "/")
        for c in comps {
            if c.hasPrefix(".") { return false }
            if c == "node_modules" || c == "__pycache__" { return false }
        }
        if path.contains(".app/") || path.contains(".framework/") || path.contains(".photoslibrary/") { return false }
        return true
    }
}

public final class CbFilesProvider: CbProvider {
    public let id = CbProviderID.files
    private let source: CbFileSearching
    private let ctx: CbContext
    private var cache: [String: [CbFileHit]] = [:]
    private var requested: String?
    public var onUpdate: (() -> Void)?

    public init(source: CbFileSearching, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    public func reset() {
        source.cancel()
        cache = [:]
        requested = nil
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        let text = q.text
        let minLength = q.forced == .files ? 1 : id.globalMinLength
        guard text.count >= minLength else {
            if requested != nil { source.cancel(); requested = nil }
            return []
        }
        let key = text.lowercased()
        if requested != key {
            requested = key
            let folders = s.resolvedFileFolders
            guard !folders.isEmpty else { return [] }
            source.search(text, folders: folders, limit: s.fileLimit * 3) { [weak self] t, hits in
                guard let self else { return }
                self.cache[t.lowercased()] = hits.filter { CbFileFilter.accept($0.path) }
                if self.requested == t.lowercased() { self.onUpdate?() }
            }
        }
        let canShelf = ctx.isModuleEnabled(.shelf)
        return (cache[key] ?? []).map { h in
            var sec = [CbSecondary(title: "Показать в Finder", symbol: "folder", action: .revealFile(h.path)),
                       CbSecondary(title: "Скопировать путь", symbol: "doc.on.doc", action: .copyText(h.path))]
            if canShelf { sec.append(CbSecondary(title: "Положить на Полку", symbol: "tray.and.arrow.down", action: .shelfAdd(h.path))) }
            let r = CbResult(id: "file:" + h.path, provider: id, title: h.name, subtitle: CbText.abbreviatedPath((h.path as NSString).deletingLastPathComponent),
                             symbol: h.isDirectory ? "folder" : "doc", iconPath: h.path, action: .openFile(h.path), secondary: sec)
            return CbCandidate(r, names: [h.name])
        }
    }
}

public final class CbClipboardProvider: CbProvider {
    public let id = CbProviderID.clipboard
    private let source: CbClipSource
    private let ctx: CbContext

    public init(source: CbClipSource, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        let s = ctx.settings()
        let limit = q.forced == .clipboard ? s.clipboardLimit * 3 : s.clipboardLimit * 2
        let items = q.isEmpty ? (q.forced == .clipboard ? source.recent(limit: limit) : []) : source.search(q.text, limit: limit)
        let now = ctx.now()
        return items.map { it in
            let title = CbText.oneLine(it.title)
            let who = it.sourceName.map { " · " + $0 } ?? ""
            let paste = CbAction.pasteClip(it.id), copy = CbAction.copyClip(it.id)
            let r = CbResult(id: "clip:\(it.id)", provider: id, title: title.isEmpty ? it.kind.title : title, subtitle: it.kind.title + " · " + CbText.age(it.used, now: now) + who,
                             symbol: it.kind.symbol, trailing: it.pinned ? "📌" : "", action: s.pasteResults ? paste : copy,
                             secondary: [CbSecondary(title: s.pasteResults ? "Только копировать" : "Вставить", symbol: "doc.on.doc", action: s.pasteResults ? copy : paste)])
            return CbCandidate(r, names: [it.title])
        }
    }
}

public final class CbSnippetsProvider: CbProvider {
    public let id = CbProviderID.snippets
    private let source: CbSnippetSource

    public init(source: CbSnippetSource) { self.source = source }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        source.snippets().map { sn in
            let r = CbResult(id: "snip:\(sn.id)", provider: id, title: sn.displayTitle, subtitle: CbText.oneLine(sn.body, limit: 70), symbol: "text.badge.plus",
                             trailing: sn.trigger, action: .snippet(sn.id), frecencyKey: "snip:\(sn.id)")
            return CbCandidate(r, names: [sn.displayTitle, sn.trigger, String(sn.body.prefix(60))])
        }
    }
}

public final class CbMenuProvider: CbProvider {
    public let id = CbProviderID.menu
    private let source: CbMenuSource

    public init(source: CbMenuSource) { self.source = source }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        guard let snap = source.snapshot() else { return [] }
        return snap.entries.filter(\.enabled).map { e in
            let r = CbResult(id: "menu:\(snap.pid):" + e.path.joined(separator: "/"), provider: id, title: e.title,
                             subtitle: snap.appName + " · " + e.path.dropLast().joined(separator: " › "), symbol: "filemenu.and.selection", trailing: e.shortcut ?? "",
                             action: .menuItem(pid: snap.pid, path: e.path))
            return CbCandidate(r, names: [e.title, e.path.joined(separator: " ")])
        }
    }
}

public final class CbEmojiProvider: CbProvider {
    public let id = CbProviderID.emoji
    private let ctx: CbContext
    private let entries: [EmojiEntry]

    public init(ctx: CbContext, entries: [EmojiEntry] = EmojiTable.all) {
        self.ctx = ctx
        self.entries = entries
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        guard !q.isEmpty else { return [] }
        let s = ctx.settings()
        return EmojiTable.scored(q.text, limit: 14, entries: entries).map { hit in
            let e = hit.entry
            let primary: CbAction = s.pasteResults ? .pasteText(e.emoji) : .copyText(e.emoji)
            let other: CbAction = s.pasteResults ? .copyText(e.emoji) : .pasteText(e.emoji)
            let r = CbResult(id: "emoji:" + e.emoji, provider: id, title: e.emoji + "  " + e.title, subtitle: e.en.first ?? "", symbol: "face.smiling", action: primary,
                             secondary: [CbSecondary(title: s.pasteResults ? "Только копировать" : "Вставить", symbol: "doc.on.doc", action: other)], frecencyKey: "emoji:" + e.emoji)
            return CbCandidate(r, fixedScore: hit.score, scoredByProvider: true)
        }
    }
}

public final class CbProcessesProvider: CbProvider {
    public let id = CbProviderID.processes
    private let source: CbProcessSource
    private let ctx: CbContext

    public init(source: CbProcessSource, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        guard ctx.isModuleEnabled(.killProcess), !q.isEmpty else { return [] }
        let procs = source.processes().filter { !$0.isRoot && $0.pid > 1 }
        return ProcessCatalog.group(procs).compactMap { g in
            let pids = Set(g.processes.map(\.pid))
            guard let root = g.processes.first(where: { !pids.contains($0.ppid) }) ?? g.processes.first else { return nil }
            let mb = Int(Double(g.rssBytes) / 1_048_576)
            let r = CbResult(id: "proc:" + g.key, provider: id, title: g.title, subtitle: "Процессов: \(g.processes.count) · \(mb) МБ · pid \(root.pid)", symbol: "xmark.octagon",
                             action: .killProcess(pid: root.pid, name: root.name, tree: true),
                             secondary: [CbSecondary(title: "Завершить только процесс", symbol: "xmark", action: .killProcess(pid: root.pid, name: root.name, tree: false))])
            return CbCandidate(r, names: [g.title, root.name])
        }
    }
}

public final class CbUninstallProvider: CbProvider {
    public let id = CbProviderID.uninstall
    private let source: CbAppSource
    private let ctx: CbContext

    public init(source: CbAppSource, ctx: CbContext) {
        self.source = source
        self.ctx = ctx
    }

    public func candidates(for q: CbQuery) -> [CbCandidate] {
        guard q.forced == .uninstall else { return [] }
        guard ctx.isModuleEnabled(.uninstaller) else {
            return [CbCandidate(CbResult(id: "uninstall:off", provider: id, title: "Модуль «Удаление приложений» выключен", subtitle: "Включи его в «Модули и права»", symbol: "trash", action: .noop), fixedScore: 1000)]
        }
        return source.apps().compactMap { a in
            guard !a.path.isEmpty, InstalledApp(path: a.path, bundleId: a.bundleID, name: a.name).protection == nil else { return nil }
            let r = CbResult(id: "uninstall:" + a.stableID, provider: id, title: "Удалить «\(a.name)»…", subtitle: "Откроется раздел «Очистка → Удаление», всё уйдёт в Корзину", symbol: "trash", iconPath: a.path,
                             action: .uninstallApp(a.path), frecencyKey: "uninstall:" + a.stableID)
            return CbCandidate(r, names: [a.name, a.fileName] + a.extraNames)
        }
    }
}
