import Foundation
import CoreGraphics

public protocol SecureInputChecking: AnyObject {
    func isSecureInputActive() -> Bool
}

public protocol SecureFocusInspecting: AnyObject {
    func focusIsSecure(pid: Int32) -> Bool
}

public enum SnippetOutcome: Equatable, Sendable {
    case expanded, secureInput, secureField, excludedApp
}

public final class SnippetExpander {
    public var settings: SnippetSettings {
        didSet { settings = settings.sanitized }
    }
    public var settleDelay: TimeInterval = 0.05
    public var restoreDelay: TimeInterval = 0.45
    public var cursorDelay: TimeInterval = 0.15
    public var onExpanded: ((Snippet) -> Void)?
    private let pasteboard: PasteboardDriving
    private let keys: KeyPosting
    private let scheduler: Scheduling
    private let secure: SecureInputChecking
    private let focus: SecureFocusInspecting
    private let frontmost: FrontmostAppProviding
    private let acknowledge: () -> Void
    private let now: () -> Date

    public init(pasteboard: PasteboardDriving, keys: KeyPosting, scheduler: Scheduling, secure: SecureInputChecking, focus: SecureFocusInspecting, frontmost: FrontmostAppProviding,
                settings: SnippetSettings = SnippetSettings(), acknowledge: @escaping () -> Void = {}, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.scheduler = scheduler
        self.secure = secure
        self.focus = focus
        self.frontmost = frontmost
        self.settings = settings.sanitized
        self.acknowledge = acknowledge
        self.now = now
    }

    public func preflight() -> SnippetOutcome {
        if secure.isSecureInputActive() { return .secureInput }
        let app = frontmost.frontmost()
        if settings.exceptions.contains(app?.bundleID) { return .excludedApp }
        if let pid = app?.pid, pid > 0, focus.focusIsSecure(pid: pid) { return .secureField }
        return .expanded
    }

    @discardableResult
    public func expand(_ snippet: Snippet, deleting count: Int, terminator: SnippetTerminator?) -> SnippetOutcome {
        let gate = preflight()
        guard gate == .expanded else { return gate }
        let clip = pasteboard.readItems(types: [PBType.utf8]).first?.string
        let ctx = SnippetContext(now: now(), timeZone: settings.timeZone, locale: settings.locale, clipboard: clip)
        var rendered = SnippetTemplate.render(snippet.body, context: ctx)
        if terminator == .space, settings.appendSpace, rendered.cursorFromEnd == nil { rendered.text += " " }
        for _ in 0..<max(0, count) { keys.post(keyCode: Keys.backspace, flags: []) }
        let text = rendered.text
        let typed = shouldType(text)
        if typed {
            if !text.isEmpty { keys.type(text) }
            moveCursor(rendered.cursorFromEnd, after: 0)
        } else {
            paste(text, cursorFromEnd: rendered.cursorFromEnd)
        }
        onExpanded?(snippet)
        return .expanded
    }

    func shouldType(_ text: String) -> Bool {
        switch settings.method {
        case .type: return true
        case .paste: return false
        case .auto: return text.count <= settings.typeLimit && !text.contains(where: { $0.isNewline || $0 == "\t" })
        }
    }

    private func paste(_ text: String, cursorFromEnd: Int?) {
        let saved = settings.restoreClipboard ? pasteboard.readItems(types: nil) : []
        let written = pasteboard.write([PasteboardItemData(reps: [PBType.utf8: Data(text.utf8), PBType.transient: Data()])])
        acknowledge()
        scheduler.after(settleDelay) { [weak self] in
            self?.keys.post(keyCode: Keys.v, flags: .maskCommand)
        }
        moveCursor(cursorFromEnd, after: settleDelay + cursorDelay)
        guard settings.restoreClipboard else { return }
        scheduler.after(settleDelay + restoreDelay) { [weak self] in
            guard let self, pasteboard.changeCount == written else { return }
            if saved.isEmpty { pasteboard.clear() } else { pasteboard.write(saved) }
            acknowledge()
        }
    }

    private func moveCursor(_ n: Int?, after delay: TimeInterval) {
        guard let n, n > 0 else { return }
        let move = { [weak self] in
            for _ in 0..<n { self?.keys.post(keyCode: Keys.left, flags: []) }
        }
        if delay <= 0 { move() } else { scheduler.after(delay, move) }
    }
}

public final class SnippetEngine {
    public var settings: SnippetSettings {
        didSet {
            settings = settings.sanitized
            rebuild()
        }
    }
    public private(set) var buffer = SnippetBuffer()
    public private(set) var expandedCount = 0
    private var matcher: SnippetMatcher
    private var snippets: [Snippet] = []
    private var swallowedUp = Set<UInt32>()
    private var lastBundle: String?
    private let expander: SnippetExpander
    private let secure: SecureInputChecking
    private let frontmost: FrontmostAppProviding
    private let scheduler: Scheduling

    public init(settings: SnippetSettings = SnippetSettings(), expander: SnippetExpander, secure: SecureInputChecking, frontmost: FrontmostAppProviding, scheduler: Scheduling) {
        self.settings = settings.sanitized
        self.expander = expander
        self.secure = secure
        self.frontmost = frontmost
        self.scheduler = scheduler
        matcher = SnippetMatcher(snippets: [], caseSensitive: settings.caseSensitive, layoutInsensitive: settings.layoutInsensitive)
    }

    private func rebuild() {
        matcher = SnippetMatcher(snippets: snippets, caseSensitive: settings.caseSensitive, layoutInsensitive: settings.layoutInsensitive)
        expander.settings = settings
    }

    public func load(_ list: [Snippet]) {
        snippets = list
        rebuild()
    }

    public var activeSnippetCount: Int { matcher.count }

    public func reset() {
        buffer.reset()
        swallowedUp.removeAll()
        lastBundle = nil
    }

    public func pointerDown() { buffer.reset() }

    public func keyDown(keyCode: UInt32, flags: CGEventFlags, characters: String) -> EventTapAction {
        if swallowedUp.contains(keyCode) { return .drop }
        if secure.isSecureInputActive() {
            buffer.reset()
            return .pass
        }
        let app = frontmost.frontmost()
        if app?.bundleID != lastBundle {
            buffer.reset()
            lastBundle = app?.bundleID
        }
        if settings.exceptions.contains(app?.bundleID) {
            buffer.reset()
            return .pass
        }
        switch SnippetKeyClassifier.classify(keyCode: keyCode, flags: flags, characters: characters) {
        case .text(let s):
            buffer.append(s)
        case .backspace:
            buffer.backspace()
        case .reset:
            buffer.reset()
        case .ignore:
            break
        case .terminator(let t):
            defer { buffer.reset() }
            guard settings.accepts(t), !flags.contains(.maskAlternate),
                  let m = matcher.match(in: buffer.chars), expander.preflight() == .expanded else { return .pass }
            swallowedUp.insert(keyCode)
            expandedCount += 1
            let snippet = m.snippet
            let length = m.typedLength
            scheduler.after(0) { [weak self] in
                self?.expander.expand(snippet, deleting: length, terminator: t)
            }
            return .drop
        }
        return .pass
    }

    public func keyUp(keyCode: UInt32) -> EventTapAction {
        swallowedUp.remove(keyCode) != nil ? .drop : .pass
    }
}

public final class SnippetStage {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    private let hub: EventTapHub
    private let engine: SnippetEngine
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: SnippetEngine) {
        self.hub = hub
        self.engine = engine
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.snippets, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        switch type {
        case .keyDown:
            return engine.keyDown(keyCode: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)), flags: e.flags, characters: e.typedCharacters())
        case .keyUp:
            return engine.keyUp(keyCode: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)))
        default:
            engine.pointerDown()
            return .pass
        }
    }
}
