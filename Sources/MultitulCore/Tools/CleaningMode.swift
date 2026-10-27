import Foundation
import CoreGraphics

public extension InputPriority {
    static let cleaning = 1000
}

public enum CleaningScreenMode: String, CaseIterable, Sendable {
    case blackout, indicator

    public var title: String { self == .blackout ? "Чёрный экран" : "Индикатор в углу" }
}

public struct CleaningSettings: Equatable, Sendable {
    public static let pressRange = 3...10
    public static let windowRange = 1.0...15.0
    public static let autoEndRange = 0...120
    public var screenMode = CleaningScreenMode.blackout
    public var exitPresses = 5
    public var pressWindow = 4.0
    public var blockMouse = false
    public var autoEndMinutes = 0

    public init() {}

    public var sanitized: CleaningSettings {
        var s = self
        s.exitPresses = ToolsClamp.int(s.exitPresses, Self.pressRange)
        s.pressWindow = ToolsClamp.double(s.pressWindow, Self.windowRange)
        s.autoEndMinutes = ToolsClamp.int(s.autoEndMinutes, Self.autoEndRange)
        return s
    }
}

public final class CleaningSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> CleaningSettings {
        var s = CleaningSettings()
        let p = "cleaningMode."
        if let v = a.string(p + "screenMode"), let m = CleaningScreenMode(rawValue: v) { s.screenMode = m }
        s.exitPresses = a.int(p + "exitPresses", s.exitPresses)
        s.pressWindow = a.double(p + "pressWindow", s.pressWindow)
        s.blockMouse = a.bool(p + "blockMouse", s.blockMouse)
        s.autoEndMinutes = a.int(p + "autoEndMinutes", s.autoEndMinutes)
        return s.sanitized
    }

    public func save(_ settings: CleaningSettings) {
        let s = settings.sanitized
        let b = CleaningSettings()
        let p = "cleaningMode."
        a.put(p + "screenMode", s.screenMode.rawValue, b.screenMode.rawValue)
        a.put(p + "exitPresses", s.exitPresses, b.exitPresses)
        a.put(p + "pressWindow", s.pressWindow, b.pressWindow)
        a.put(p + "blockMouse", s.blockMouse, b.blockMouse)
        a.put(p + "autoEndMinutes", s.autoEndMinutes, b.autoEndMinutes)
    }
}

public struct CleaningExitCounter {
    public let needed: Int
    public let window: TimeInterval
    public private(set) var times: [TimeInterval] = []

    public init(needed: Int, window: TimeInterval) {
        self.needed = needed
        self.window = window
    }

    public var count: Int { times.count }

    public mutating func press(at t: TimeInterval) -> Bool {
        times = times.filter { t - $0 <= window }
        times.append(t)
        if times.count >= needed {
            times = []
            return true
        }
        return false
    }

    public mutating func reset() { times = [] }

    public func visibleCount(at t: TimeInterval) -> Int { times.filter { t - $0 <= window }.count }
}

public protocol CleaningOverlayShowing: AnyObject {
    func show(mode: CleaningScreenMode, needed: Int)
    func update(presses: Int, needed: Int)
    func hide()
}

public enum CleaningStart: Equatable, Sendable {
    case started, alreadyRunning, noTap
}

public final class CleaningSession {
    public static let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]
    public static let pointerTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                                    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]

    public private(set) var settings: CleaningSettings
    public private(set) var isActive = false
    public private(set) var swallowed = 0
    public var onFinish: ((FinishReason) -> Void)?
    private let hub: EventTapHub
    private let overlay: CleaningOverlayShowing
    private let clock: () -> TimeInterval
    private let later: (@escaping () -> Void) -> Void
    private var token: EventTapHub.Token?
    private var counter: CleaningExitCounter
    private var startedAt: TimeInterval = 0

    public enum FinishReason: Equatable, Sendable { case exitKeys, timeout, stopped }

    public init(hub: EventTapHub, overlay: CleaningOverlayShowing, settings: CleaningSettings, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                deferred: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.later = deferred
        self.hub = hub
        self.overlay = overlay
        self.settings = settings.sanitized
        self.clock = clock
        counter = CleaningExitCounter(needed: self.settings.exitPresses, window: self.settings.pressWindow)
    }

    public var presses: Int { counter.count }

    @discardableResult
    public func start() -> CleaningStart {
        guard !isActive else { return .alreadyRunning }
        counter = CleaningExitCounter(needed: settings.exitPresses, window: settings.pressWindow)
        swallowed = 0
        let types = Self.keyboardTypes + (settings.blockMouse ? Self.pointerTypes : [])
        let t = hub.subscribe(types: types, priority: InputPriority.cleaning, seesDropped: true) { [weak self] type, e in
            self?.handle(type, e) ?? .drop
        }
        guard hub.isRunning else {
            hub.unsubscribe(t)
            return .noTap
        }
        token = t
        isActive = true
        startedAt = clock()
        overlay.show(mode: settings.screenMode, needed: settings.exitPresses)
        return .started
    }

    public func stop() { finish(.stopped) }

    public func updateSettings(_ s: CleaningSettings) {
        guard !isActive else { return }
        settings = s.sanitized
    }

    public func tick() {
        guard isActive, settings.autoEndMinutes > 0 else { return }
        if clock() - startedAt >= Double(settings.autoEndMinutes) * 60 { finish(.timeout) }
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        guard isActive else { return .pass }
        swallowed += 1
        if type == .keyDown,
           e.getIntegerValueField(.keyboardEventKeycode) == Int64(Keys.escape),
           e.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            if counter.press(at: clock()) {
                later { [weak self] in self?.finish(.exitKeys) }
            } else {
                overlay.update(presses: counter.count, needed: settings.exitPresses)
            }
        }
        return .drop
    }

    private func finish(_ reason: FinishReason) {
        guard isActive else { return }
        isActive = false
        if let t = token { hub.unsubscribe(t) }
        token = nil
        overlay.hide()
        onFinish?(reason)
    }
}
