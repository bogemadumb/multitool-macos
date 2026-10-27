import Foundation
import CoreGraphics

public struct SwitchWindow: Equatable, Hashable, Sendable, Identifiable {
    public var key: Int
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var displayID: UInt32?
    public var isMinimized: Bool
    public var isAppHidden: Bool
    public var isFullscreen: Bool
    public var isOnCurrentSpace: Bool
    public var zIndex: Int

    public var id: Int { key }

    public init(key: Int, windowID: UInt32 = 0, pid: Int32, bundleID: String? = nil, appName: String = "", title: String = "", frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                displayID: UInt32? = nil, isMinimized: Bool = false, isAppHidden: Bool = false, isFullscreen: Bool = false, isOnCurrentSpace: Bool = true, zIndex: Int = Int.max) {
        self.key = key
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.displayID = displayID
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.isFullscreen = isFullscreen
        self.isOnCurrentSpace = isOnCurrentSpace
        self.zIndex = zIndex
    }
}

public struct SwitchApp: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var isRegular: Bool
    public var isHidden: Bool

    public init(pid: Int32, bundleID: String? = nil, name: String = "", isRegular: Bool = true, isHidden: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
    }
}

public enum SwitchEntryID: Hashable, Sendable {
    case window(Int)
    case app(Int32)
}

public enum SwitchEntryKind: Equatable, Sendable {
    case window
    case group
    case appOnly
}

public struct SwitchEntry: Equatable, Sendable, Identifiable {
    public var id: SwitchEntryID
    public var kind: SwitchEntryKind
    public var window: SwitchWindow?
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var windowCount: Int
    public var isMinimized: Bool
    public var isAppHidden: Bool
    public var previewAllowed: Bool

    public var windowID: UInt32? { window.flatMap { $0.windowID == 0 ? nil : $0.windowID } }

    public var displayTitle: String {
        switch kind {
        case .appOnly: appName
        case .group: windowCount > 1 ? "\(appName) (\(windowCount))" : appName
        case .window: title.isEmpty ? appName : title
        }
    }

    public init(window w: SwitchWindow, kind: SwitchEntryKind = .window, count: Int = 1, previewAllowed: Bool = true) {
        id = .window(w.key)
        self.kind = kind
        window = w
        pid = w.pid
        bundleID = w.bundleID
        appName = w.appName
        title = w.title
        windowCount = count
        isMinimized = w.isMinimized
        isAppHidden = w.isAppHidden
        self.previewAllowed = previewAllowed
    }

    public init(app a: SwitchApp) {
        id = .app(a.pid)
        kind = .appOnly
        window = nil
        pid = a.pid
        bundleID = a.bundleID
        appName = a.name
        title = ""
        windowCount = 0
        isMinimized = false
        isAppHidden = a.isHidden
        previewAllowed = false
    }
}

public enum SwitcherScope: Equatable, Sendable {
    case allApps
    case sameApp(Int32)
}

public struct SwitcherContext: Equatable, Sendable {
    public var scope = SwitcherScope.allApps
    public var focusedKey: Int?
    public var frontPID: Int32?
    public var activeDisplayID: UInt32?

    public init(scope: SwitcherScope = .allApps, focusedKey: Int? = nil, frontPID: Int32? = nil, activeDisplayID: UInt32? = nil) {
        self.scope = scope
        self.focusedKey = focusedKey
        self.frontPID = frontPID
        self.activeDisplayID = activeDisplayID
    }
}

public struct SwitcherSnapshot: Sendable {
    public var windows: [SwitchWindow]
    public var apps: [SwitchApp]
    public var focusedKey: Int?
    public var frontPID: Int32?
    public var displays: [WndDisplay]
    public var primaryDisplayID: UInt32?
    public var pointer: CGPoint
    public var focusedFrame: CGRect?

    public init(windows: [SwitchWindow] = [], apps: [SwitchApp] = [], focusedKey: Int? = nil, frontPID: Int32? = nil, displays: [WndDisplay] = [], primaryDisplayID: UInt32? = nil,
                pointer: CGPoint = .zero, focusedFrame: CGRect? = nil) {
        self.windows = windows
        self.apps = apps
        self.focusedKey = focusedKey
        self.frontPID = frontPID
        self.displays = displays
        self.primaryDisplayID = primaryDisplayID
        self.pointer = pointer
        self.focusedFrame = focusedFrame
    }
}

public enum SwitcherDisplayChoice {
    public static func display(for placement: SwitcherScreenPlacement, in s: SwitcherSnapshot) -> WndDisplay? {
        guard !s.displays.isEmpty else { return nil }
        func at(_ p: CGPoint) -> WndDisplay? { s.displays.first { $0.frame.contains(p) } }
        switch placement {
        case .pointer: return at(s.pointer) ?? s.displays.first
        case .menuBar: return s.displays.first { $0.id == s.primaryDisplayID } ?? s.displays.first
        case .activeWindow:
            if let f = s.focusedFrame, let d = DisplayAssignment.display(for: f, in: s.displays) { return d }
            return at(s.pointer) ?? s.displays.first
        }
    }
}

public enum DisplayAssignment {
    public static func display(for frame: CGRect, in displays: [WndDisplay]) -> WndDisplay? {
        var best: (WndDisplay, CGFloat)?
        for d in displays {
            let i = d.frame.intersection(frame)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let best { return best.0 }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y) }
    }
}
