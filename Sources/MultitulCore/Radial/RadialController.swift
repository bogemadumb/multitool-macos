import Foundation
import CoreGraphics

public enum RadialInput: Equatable, Sendable {
    case keyDown(code: UInt32, mods: UInt32, repeating: Bool)
    case keyUp(code: UInt32)
    case modsChanged(UInt32)
    case buttonDown(Int, CGPoint)
    case buttonUp(Int, CGPoint)
    case leftDown(CGPoint)
    case leftUp(CGPoint)
    case moved(CGPoint)
    case fourFingerTap
}

public struct RadialViewState: Equatable, Sendable {
    public var center: CGPoint
    public var items: [RadialItem]
    public var hovered: Int?
    public var mode: RadialMode
    public var depth: Int
    public var title: String
    public var geometry: RadialGeometry
    public var showTitles: Bool

    public init(center: CGPoint, items: [RadialItem], hovered: Int?, mode: RadialMode, depth: Int, title: String, geometry: RadialGeometry, showTitles: Bool) {
        self.center = center
        self.items = items
        self.hovered = hovered
        self.mode = mode
        self.depth = depth
        self.title = title
        self.geometry = geometry
        self.showTitles = showTitles
    }
}

public protocol RadialPresenting: AnyObject {
    func show(_ state: RadialViewState)
    func update(_ state: RadialViewState)
    func hide()
}

public protocol RadialRunning: AnyObject {
    func run(_ item: RadialItem)
}

public final class RadialController {
    public static let digitKeys: [UInt32: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]

    private enum Trigger: Equatable {
        case hotkey
        case button(Int)
        case tap
    }

    private let settings: () -> RadialSettings
    private let presenter: RadialPresenting
    private let runner: RadialRunning
    private let clock: () -> TimeInterval
    private let frontBundleID: () -> String?
    private let screenFrame: (CGPoint) -> CGRect
    private let trusted: () -> Bool
    private var session: RadialSession?
    private var trigger: Trigger?
    private var pointer = CGPoint.zero
    private var swallowLeftUp = false
    public private(set) var openCount = 0

    public init(settings: @escaping () -> RadialSettings, presenter: RadialPresenting, runner: RadialRunning,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                frontBundleID: @escaping () -> String? = { nil },
                screenFrame: @escaping (CGPoint) -> CGRect = { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                trusted: @escaping () -> Bool = { true }) {
        self.settings = settings
        self.presenter = presenter
        self.runner = runner
        self.clock = clock
        self.frontBundleID = frontBundleID
        self.screenFrame = screenFrame
        self.trusted = trusted
    }

    public var isActive: Bool { session != nil }

    public var state: RadialViewState? { session.map(makeState) }

    private func makeState(_ s: RadialSession) -> RadialViewState {
        let cfg = settings()
        return RadialViewState(center: s.center, items: s.items, hovered: s.hovered, mode: s.mode, depth: s.depth, title: s.title, geometry: s.geometry, showTitles: cfg.showTitles)
    }

    public func cancel() {
        guard session != nil else { return }
        end()
    }

    private func end() {
        session = nil
        trigger = nil
        presenter.hide()
    }

    private func open(mode: RadialMode, trigger t: Trigger) {
        let cfg = settings()
        let profile = cfg.profile(forBundleID: frontBundleID())
        guard !profile.items.isEmpty else { return }
        let g = cfg.geometry
        let center = RadialPlacement.center(pointer: pointer, radius: cfg.ringRadius + 20, in: screenFrame(pointer))
        let s = RadialSession(items: profile.items, center: center, anchor: pointer, geometry: g, mode: mode, stickyMs: cfg.stickyMs, clock: clock)
        session = s
        trigger = t
        openCount += 1
        presenter.show(makeState(s))
    }

    private func apply(_ o: RadialOutcome) {
        guard let s = session else { return }
        switch o {
        case .run(let item):
            end()
            runner.run(item)
        case .cancelled:
            end()
        case .none, .enteredSubmenu, .leftSubmenu, .becameSticky:
            presenter.update(makeState(s))
        }
    }

    public func handle(_ input: RadialInput) -> EventTapAction {
        let cfg = settings()
        if case .moved(let p) = input { pointer = p }
        if case .leftDown(let p) = input { pointer = p }
        if case .buttonDown(_, let p) = input { pointer = p }
        guard let s = session else { return idle(input, cfg) }
        switch input {
        case .moved(let p):
            s.move(to: p)
            presenter.update(makeState(s))
            return .pass
        case .keyDown(let code, let mods, let repeating):
            if code == Keys.escape { apply(s.cancel()); return .drop }
            if code == cfg.trigger.hotkey.keyCode {
                if s.mode == .sticky, !repeating, mods == cfg.trigger.hotkey.modifiers { apply(s.cancel()) }
                return .drop
            }
            if repeating { return .drop }
            if let n = Self.digitKeys[code] { apply(s.pick(number: n)); return .drop }
            if code == Keys.backspace { apply(s.back()); return .drop }
            return .drop
        case .keyUp(let code):
            if trigger == .hotkey, code == cfg.trigger.hotkey.keyCode {
                apply(s.release(at: pointer))
                return .drop
            }
            return .pass
        case .modsChanged(let mods):
            if trigger == .hotkey, s.mode == .hold, mods & cfg.trigger.hotkey.modifiers != cfg.trigger.hotkey.modifiers { apply(s.release(at: pointer)) }
            return .pass
        case .buttonDown(let b, let p):
            if case .button(let t) = trigger, t == b { return .drop }
            apply(s.mode == .sticky ? s.click(at: p) : s.cancel())
            return .drop
        case .buttonUp(let b, let p):
            if case .button(let t) = trigger, t == b {
                apply(s.release(at: p))
                return .drop
            }
            return .pass
        case .leftDown(let p):
            swallowLeftUp = true
            apply(s.click(at: p))
            return .drop
        case .leftUp:
            if swallowLeftUp { swallowLeftUp = false; return .drop }
            return .pass
        case .fourFingerTap:
            if trigger == .tap { apply(s.cancel()) }
            return .pass
        }
    }

    private func idle(_ input: RadialInput, _ cfg: RadialSettings) -> EventTapAction {
        switch input {
        case .keyDown(let code, let mods, let repeating):
            guard cfg.trigger.hotkeyEnabled, code == cfg.trigger.hotkey.keyCode, mods == cfg.trigger.hotkey.modifiers, trusted() else { return .pass }
            if repeating { return .pass }
            open(mode: .hold, trigger: .hotkey)
            return session != nil ? .drop : .pass
        case .buttonDown(let b, _):
            guard let want = cfg.trigger.mouseButton, want == b, trusted() else { return .pass }
            open(mode: .hold, trigger: .button(b))
            return session != nil ? .drop : .pass
        case .leftUp:
            if swallowLeftUp { swallowLeftUp = false; return .drop }
            return .pass
        case .fourFingerTap:
            guard cfg.trigger.fourFingerTap, trusted() else { return .pass }
            open(mode: .sticky, trigger: .tap)
            return .pass
        default:
            return .pass
        }
    }
}
