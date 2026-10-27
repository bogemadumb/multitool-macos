import Foundation

public struct AutoQuitSettings: Equatable, Sendable {
    public static let delayRange = 150...3000
    public static let mandatoryExceptions = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.TelephonyUtilities", "com.apple.FaceTime", "dev.multitool.app"
    ]

    public var exceptions = AppExceptionList()
    public var delayMs = 400
    public init() {}

    public var sanitized: AutoQuitSettings {
        var s = self
        s.delayMs = min(max(delayMs, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        return s
    }

    public func isExcepted(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.mandatoryExceptions.contains(bundleID) || exceptions.contains(bundleID)
    }
}

public struct AutoQuitApp: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var isRegular: Bool
    public var isHidden: Bool

    public init(pid: Int32, bundleID: String?, name: String? = nil, isRegular: Bool = true, isHidden: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
    }
}

public struct AutoQuitSnapshot: Equatable, Sendable {
    public var accessible: Bool
    public var windows: Int
    public var minimized: Int
    public var otherSpaces: Int
    public var surfaces: Int

    public init(accessible: Bool = true, windows: Int = 0, minimized: Int = 0, otherSpaces: Int = 0, surfaces: Int = 0) {
        self.accessible = accessible
        self.windows = windows
        self.minimized = minimized
        self.otherSpaces = otherSpaces
        self.surfaces = surfaces
    }

    public var holdsApp: Bool { windows + minimized + otherSpaces + surfaces > 0 }
}

public protocol AutoQuitDriving: AnyObject {
    func app(pid: Int32) -> AutoQuitApp?
    func snapshot(of app: AutoQuitApp) -> AutoQuitSnapshot
    func terminate(_ app: AutoQuitApp) -> Bool
}

public enum AutoQuitVerdict: Equatable, Sendable {
    case quit
    case keep(String)
}

public enum AutoQuitPolicy {
    public static func verdict(app: AutoQuitApp, hadWindow: Bool, snapshot: AutoQuitSnapshot, settings: AutoQuitSettings) -> AutoQuitVerdict {
        guard app.isRegular else { return .keep("приложение без Dock-значка") }
        if settings.isExcepted(app.bundleID) { return .keep("исключение") }
        guard hadWindow else { return .keep("окон ещё не было") }
        guard snapshot.accessible else { return .keep("нет доступа к окнам") }
        if app.isHidden { return .keep("приложение спрятано") }
        if snapshot.windows > 0 { return .keep("есть окна") }
        if snapshot.minimized > 0 { return .keep("есть свёрнутые окна") }
        if snapshot.otherSpaces > 0 { return .keep("есть окна на другом рабочем столе") }
        if snapshot.surfaces > 0 { return .keep("открыта панель или диалог") }
        return .quit
    }
}

public final class AutoQuitService {
    public private(set) var quitLog: [String] = []
    private let driver: AutoQuitDriving
    private let timers: TimerScheduling
    private let settingsProvider: () -> AutoQuitSettings
    private var seen = Set<Int32>()
    private var pending: [Int32: CancelHandle] = [:]

    public init(driver: AutoQuitDriving, timers: TimerScheduling, settings: @escaping () -> AutoQuitSettings) {
        self.driver = driver
        self.timers = timers
        self.settingsProvider = settings
    }

    public var watchedCount: Int { seen.count }

    public func reset() {
        for h in pending.values { h.cancel() }
        pending.removeAll()
        seen.removeAll()
    }

    public func appObserved(pid: Int32, hasWindows: Bool) {
        if hasWindows { seen.insert(pid) }
    }

    public func windowCreated(pid: Int32) {
        seen.insert(pid)
        pending.removeValue(forKey: pid)?.cancel()
    }

    public func appTerminated(pid: Int32) {
        seen.remove(pid)
        pending.removeValue(forKey: pid)?.cancel()
    }

    public func windowClosed(pid: Int32) {
        guard seen.contains(pid) else { return }
        pending.removeValue(forKey: pid)?.cancel()
        let delay = Double(settingsProvider().sanitized.delayMs) / 1000
        pending[pid] = timers.schedule(after: delay) { [weak self] in self?.check(pid: pid) }
    }

    @discardableResult
    public func check(pid: Int32) -> AutoQuitVerdict {
        pending.removeValue(forKey: pid)
        guard let app = driver.app(pid: pid) else { seen.remove(pid); return .keep("приложение закрыто") }
        let s = settingsProvider().sanitized
        let snap = driver.snapshot(of: app)
        let v = AutoQuitPolicy.verdict(app: app, hadWindow: seen.contains(pid), snapshot: snap, settings: s)
        if v == .quit, driver.terminate(app) {
            quitLog.append(app.bundleID ?? "pid\(pid)")
            seen.remove(pid)
        }
        return v
    }
}
