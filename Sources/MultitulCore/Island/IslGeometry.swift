import Foundation
import CoreGraphics

public enum IslState: String, CaseIterable, Sendable {
    case closed, peek, open
}

public struct IslScreenInfo: Equatable, Sendable {
    public var id: UInt32
    public var key: String
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxLeftWidth: CGFloat?
    public var auxRightWidth: CGFloat?
    public var scale: CGFloat
    public var isBuiltin: Bool
    public var isMain: Bool

    public init(id: UInt32, key: String = "", name: String = "", frame: CGRect, visibleFrame: CGRect? = nil, safeAreaTop: CGFloat = 0,
                auxLeftWidth: CGFloat? = nil, auxRightWidth: CGFloat? = nil, scale: CGFloat = 2, isBuiltin: Bool = false, isMain: Bool = false) {
        self.id = id
        self.key = key.isEmpty ? String(id) : key
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame ?? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(frame.height - 24, 0))
        self.safeAreaTop = safeAreaTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
        self.scale = scale
        self.isBuiltin = isBuiltin
        self.isMain = isMain
    }
}

public struct IslNotch: Equatable, Sendable {
    public var rect: CGRect
    public var isHardware: Bool

    public init(rect: CGRect, isHardware: Bool) {
        self.rect = rect
        self.isHardware = isHardware
    }
}

public enum IslNotchDetector {
    public static let pillWidth: CGFloat = 132
    public static let pillHeightRange: ClosedRange<CGFloat> = 18...26
    public static let minHardwareWidth: CGFloat = 80
    public static let defaultMenuBarHeight: CGFloat = 24

    public static func menuBarHeight(_ s: IslScreenInfo) -> CGFloat {
        if s.safeAreaTop > 0 { return s.safeAreaTop }
        let gap = s.frame.maxY - s.visibleFrame.maxY
        return gap >= 10 && gap <= 60 ? gap : defaultMenuBarHeight
    }

    public static func hardwareNotchRect(_ s: IslScreenInfo) -> CGRect? {
        guard s.safeAreaTop > 0, let l = s.auxLeftWidth, let r = s.auxRightWidth, l > 0, r > 0 else { return nil }
        let w = s.frame.width - l - r
        guard w >= minHardwareWidth, w < s.frame.width / 2 else { return nil }
        return CGRect(x: s.frame.minX + l, y: s.frame.maxY - s.safeAreaTop, width: w, height: s.safeAreaTop)
    }

    public static func hasHardwareNotch(_ s: IslScreenInfo) -> Bool { hardwareNotchRect(s) != nil }

    public static func notch(for s: IslScreenInfo) -> IslNotch {
        if let r = hardwareNotchRect(s) { return IslNotch(rect: r, isHardware: true) }
        let h = min(max(menuBarHeight(s), pillHeightRange.lowerBound), pillHeightRange.upperBound)
        return IslNotch(rect: CGRect(x: s.frame.midX - pillWidth / 2, y: s.frame.maxY - h, width: pillWidth, height: h), isHardware: false)
    }
}

public enum IslSizePreset: String, CaseIterable, Sendable {
    case compact, standard, spacious

    public var title: String {
        switch self {
        case .compact: "Компактный"
        case .standard: "Обычный"
        case .spacious: "Просторный"
        }
    }

    public var openSize: CGSize {
        switch self {
        case .compact: CGSize(width: 460, height: 190)
        case .standard: CGSize(width: 580, height: 230)
        case .spacious: CGSize(width: 700, height: 280)
        }
    }
}

public struct IslWings: Equatable, Sendable {
    public var left: CGFloat
    public var right: CGFloat

    public init(left: CGFloat = 0, right: CGFloat = 0) {
        self.left = left
        self.right = right
    }

    public static let zero = IslWings()
    public var isEmpty: Bool { left <= 0 && right <= 0 }
}

public struct IslFrames: Equatable, Sendable {
    public var notch: CGRect
    public var closed: CGRect
    public var peek: CGRect
    public var open: CGRect

    public func frame(for state: IslState) -> CGRect {
        switch state {
        case .closed: closed
        case .peek: peek
        case .open: open
        }
    }
}

public enum IslLayoutMath {
    public static let desiredWing: CGFloat = 54
    public static let minUsefulWing: CGFloat = 34
    public static let wingPadding: CGFloat = 8
    public static let peekExtraHeight: CGFloat = 46
    public static let peekMinWidth: CGFloat = 340
    public static let edgeMargin: CGFloat = 8

    public static func frames(screen: IslScreenInfo, notch: IslNotch, preset: IslSizePreset, wings: IslWings = .zero) -> IslFrames {
        let n = notch.rect
        let f = screen.frame
        let maxWidth = max(f.width - edgeMargin * 2, n.width)
        let openW = min(max(preset.openSize.width, n.width + 120), maxWidth)
        let openH = min(max(preset.openSize.height, n.height + 80), max(f.height - 40, n.height))
        let peekW = min(max(n.width + 200, peekMinWidth), openW)
        let peekH = n.height + peekExtraHeight

        func centered(_ w: CGFloat, _ h: CGFloat) -> CGRect {
            var x = n.midX - w / 2
            x = min(max(x, f.minX + edgeMargin), f.maxX - edgeMargin - w)
            return CGRect(x: x, y: f.maxY - h, width: w, height: h)
        }

        let lw = max(wings.left, 0), rw = max(wings.right, 0)
        var closed = CGRect(x: n.minX - lw, y: f.maxY - n.height, width: n.width + lw + rw, height: n.height)
        closed.origin.x = min(max(closed.origin.x, f.minX), f.maxX - closed.width)
        return IslFrames(notch: n, closed: closed, peek: centered(peekW, peekH), open: centered(openW, openH))
    }
}

public struct IslMenuClearance: Equatable, Sendable {
    public var appMenuMaxX: CGFloat?
    public var statusItemsMinX: CGFloat?

    public init(appMenuMaxX: CGFloat? = nil, statusItemsMinX: CGFloat? = nil) {
        self.appMenuMaxX = appMenuMaxX
        self.statusItemsMinX = statusItemsMinX
    }

    public static let unknown = IslMenuClearance()

    public func localized(to frame: CGRect) -> IslMenuClearance {
        func inside(_ x: CGFloat?) -> CGFloat? { x.flatMap { frame.minX...frame.maxX ~= $0 ? $0 : nil } }
        return IslMenuClearance(appMenuMaxX: inside(appMenuMaxX), statusItemsMinX: inside(statusItemsMinX))
    }

    public func wings(notch: CGRect, enabled: Bool = true,
                      desired: CGFloat = IslLayoutMath.desiredWing, minUseful: CGFloat = IslLayoutMath.minUsefulWing, padding: CGFloat = IslLayoutMath.wingPadding) -> IslWings {
        guard enabled else { return IslWings(left: desired, right: desired) }
        func fit(_ available: CGFloat) -> CGFloat {
            let w = min(desired, available)
            return w >= minUseful ? w : 0
        }
        let left = appMenuMaxX.map { fit(notch.minX - ($0 + padding)) } ?? desired
        let right = statusItemsMinX.map { fit(($0 - padding) - notch.maxX) } ?? desired
        return IslWings(left: max(left, 0), right: max(right, 0))
    }
}

public enum IslHoverZone {
    public static let triggerSlop: CGFloat = 3
    public static let topEdgeSlop: CGFloat = 3
    public static let leaveSlop: CGFloat = 8

    public static func trigger(closedFrame: CGRect) -> CGRect {
        CGRect(x: closedFrame.minX - triggerSlop, y: closedFrame.minY - triggerSlop, width: closedFrame.width + triggerSlop * 2, height: closedFrame.height + triggerSlop + topEdgeSlop)
    }

    public static func contains(_ p: CGPoint, state: IslState, frames: IslFrames) -> Bool {
        switch state {
        case .closed: trigger(closedFrame: frames.closed).contains(p)
        case .peek: frames.peek.insetBy(dx: -leaveSlop, dy: -leaveSlop).contains(p) || trigger(closedFrame: frames.closed).contains(p)
        case .open: frames.open.insetBy(dx: -leaveSlop, dy: -leaveSlop).contains(p) || trigger(closedFrame: frames.closed).contains(p)
        }
    }
}

public enum IslDisplayMode: String, CaseIterable, Sendable {
    case all, builtin, main, selected

    public var title: String {
        switch self {
        case .all: "Все дисплеи"
        case .builtin: "Только встроенный"
        case .main: "Только основной"
        case .selected: "Выбранные"
        }
    }
}

public enum IslDisplaySelector {
    public static func select(_ screens: [IslScreenInfo], mode: IslDisplayMode, selected: Set<String>, virtualPill: Bool) -> [IslScreenInfo] {
        screens.filter { s in
            guard IslNotchDetector.hasHardwareNotch(s) || virtualPill else { return false }
            switch mode {
            case .all: return true
            case .builtin: return s.isBuiltin
            case .main: return s.isMain
            case .selected: return selected.contains(s.key)
            }
        }
    }
}

public enum IslConflictApp: String, CaseIterable, Sendable {
    case atoll, boringNotch, notchNook, custom

    public var title: String {
        switch self {
        case .atoll: "Atoll"
        case .boringNotch: "Boring Notch"
        case .notchNook: "NotchNook"
        case .custom: "Другое приложение"
        }
    }

    var needles: [String] {
        switch self {
        case .atoll: ["atoll"]
        case .boringNotch: ["boringnotch", "boring.notch", "boring notch"]
        case .notchNook: ["notchnook"]
        case .custom: []
        }
    }
}

public struct IslConflict: Equatable, Sendable {
    public var app: IslConflictApp
    public var bundleID: String
    public var pid: Int32

    public init(app: IslConflictApp, bundleID: String, pid: Int32) {
        self.app = app
        self.bundleID = bundleID
        self.pid = pid
    }
}

public enum IslConflictDetector {
    public static let extraDefaultsKey = "islandConflicts.extraBundleIDs"

    public static func find(running: [(bundleID: String, name: String, pid: Int32)], ownBundleID: String = "dev.multitool.app",
                            extraBundleIDs: [String] = UserDefaults.standard.stringArray(forKey: IslConflictDetector.extraDefaultsKey) ?? []) -> [IslConflict] {
        var out: [IslConflict] = []
        for r in running where r.bundleID != ownBundleID {
            if extraBundleIDs.contains(r.bundleID) { out.append(IslConflict(app: .custom, bundleID: r.bundleID, pid: r.pid)); continue }
            let hay = (r.bundleID + " " + r.name).lowercased()
            if let app = IslConflictApp.allCases.first(where: { a in a.needles.contains { hay.contains($0) } }) {
                out.append(IslConflict(app: app, bundleID: r.bundleID, pid: r.pid))
            }
        }
        return out
    }

    public static func notice(_ conflicts: [IslConflict]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        var seen = Set<String>()
        let names = conflicts.map(\.app.title).filter { seen.insert($0).inserted }
        return "Запущено: \(names.joined(separator: ", ")). Два острова над одним вырезом перекрывают друг друга; закрой его перед использованием Мультитула."
    }
}
