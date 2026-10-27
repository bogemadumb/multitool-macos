import Foundation

public enum IslCloseBehavior: String, CaseIterable, Sendable {
    case onLeave, onOutsideClick, manual

    public var title: String {
        switch self {
        case .onLeave: "Когда курсор ушёл"
        case .onOutsideClick: "По клику снаружи"
        case .manual: "Только вручную"
        }
    }

    public var summary: String {
        switch self {
        case .onLeave: "Закрывается через короткую паузу после ухода курсора"
        case .onOutsideClick: "Остаётся открытым, пока не кликнешь мимо или не нажмёшь Esc"
        case .manual: "Закрывается кликом по острову, сочетанием или Esc"
        }
    }
}

public enum IslStartChoice: Equatable, Sendable {
    case last
    case auto
    case fixed(String)

    public var stored: String {
        switch self {
        case .last: "last"
        case .auto: "auto"
        case .fixed(let id): "id:" + id
        }
    }

    public init(stored: String?) {
        switch stored {
        case "auto": self = .auto
        case .some(let s) where s.hasPrefix("id:") && s.count > 3: self = .fixed(String(s.dropFirst(3)))
        default: self = .last
        }
    }
}

public enum IslSwipeAction: String, CaseIterable, Sendable {
    case track, section

    public var title: String {
        switch self {
        case .track: "Переключает трек"
        case .section: "Переключает раздел"
        }
    }
}

public struct IslSettings: Equatable, Sendable {
    public static let hoverDelayRange: ClosedRange<Double> = 0.05...1.5
    public static let leaveGraceRange: ClosedRange<Double> = 0.1...3
    public static let peekDurationRange: ClosedRange<Double> = 1...10

    public var sizePreset = IslSizePreset.standard
    public var openOnHover = true
    public var hoverDelay = 0.25
    public var openOnScroll = true
    public var openOnClick = true
    public var closeOnScrollUp = true
    public var closeBehavior = IslCloseBehavior.onLeave
    public var leaveGrace = 0.4
    public var peekOnChange = true
    public var peekDuration = 3.0
    public var displayMode = IslDisplayMode.builtin
    public var selectedDisplays = Set<String>()
    public var virtualPill = true
    public var hideInFullscreen = true
    public var avoidMenus = true
    public var glass = true
    public var hideMenuIcon = false
    public var start = IslStartChoice.last
    public var musicSwipe = IslSwipeAction.track
    public var mutedActivities = Set<String>()

    public init() {}

    public var sanitized: IslSettings {
        var s = self
        s.hoverDelay = Self.clamp(hoverDelay, Self.hoverDelayRange)
        s.leaveGrace = Self.clamp(leaveGrace, Self.leaveGraceRange)
        s.peekDuration = Self.clamp(peekDuration, Self.peekDurationRange)
        s.selectedDisplays = selectedDisplays.filter { !$0.isEmpty && $0.count <= 80 }
        s.mutedActivities = mutedActivities.filter { !$0.isEmpty && $0.count <= 80 }
        if case .fixed(let id) = start, id.isEmpty { s.start = .last }
        return s
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

public final class IslSettingsStore {
    private let a: KVAccess
    static let prefix = "notch."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslSettings {
        var s = IslSettings()
        let p = Self.prefix
        if let v = a.string(p + "size"), let m = IslSizePreset(rawValue: v) { s.sizePreset = m }
        s.openOnHover = a.bool(p + "openOnHover", s.openOnHover)
        s.hoverDelay = a.double(p + "hoverDelay", s.hoverDelay)
        s.openOnScroll = a.bool(p + "openOnScroll", s.openOnScroll)
        s.openOnClick = a.bool(p + "openOnClick", s.openOnClick)
        s.closeOnScrollUp = a.bool(p + "closeOnScrollUp", s.closeOnScrollUp)
        if let v = a.string(p + "closeBehavior"), let m = IslCloseBehavior(rawValue: v) { s.closeBehavior = m }
        s.leaveGrace = a.double(p + "leaveGrace", s.leaveGrace)
        s.peekOnChange = a.bool(p + "peekOnChange", s.peekOnChange)
        s.peekDuration = a.double(p + "peekDuration", s.peekDuration)
        if let v = a.string(p + "displayMode"), let m = IslDisplayMode(rawValue: v) { s.displayMode = m }
        s.selectedDisplays = Set(a.strings(p + "selectedDisplays") ?? [])
        s.virtualPill = a.bool(p + "virtualPill", s.virtualPill)
        s.hideInFullscreen = a.bool(p + "hideInFullscreen", s.hideInFullscreen)
        s.avoidMenus = a.bool(p + "avoidMenus", s.avoidMenus)
        s.glass = a.bool(p + "glass", s.glass)
        s.hideMenuIcon = a.bool(p + "hideMenuIcon", s.hideMenuIcon)
        s.start = IslStartChoice(stored: a.string(p + "start"))
        if let v = a.string(p + "musicSwipe"), let m = IslSwipeAction(rawValue: v) { s.musicSwipe = m }
        s.mutedActivities = Set(a.strings(p + "mutedActivities") ?? [])
        return s.sanitized
    }

    public func save(_ settings: IslSettings) {
        let s = settings.sanitized
        let b = IslSettings()
        let p = Self.prefix
        a.put(p + "size", s.sizePreset.rawValue, b.sizePreset.rawValue)
        a.put(p + "openOnHover", s.openOnHover, b.openOnHover)
        a.put(p + "hoverDelay", s.hoverDelay, b.hoverDelay)
        a.put(p + "openOnScroll", s.openOnScroll, b.openOnScroll)
        a.put(p + "openOnClick", s.openOnClick, b.openOnClick)
        a.put(p + "closeOnScrollUp", s.closeOnScrollUp, b.closeOnScrollUp)
        a.put(p + "closeBehavior", s.closeBehavior.rawValue, b.closeBehavior.rawValue)
        a.put(p + "leaveGrace", s.leaveGrace, b.leaveGrace)
        a.put(p + "peekOnChange", s.peekOnChange, b.peekOnChange)
        a.put(p + "peekDuration", s.peekDuration, b.peekDuration)
        a.put(p + "displayMode", s.displayMode.rawValue, b.displayMode.rawValue)
        putSet(p + "selectedDisplays", s.selectedDisplays)
        a.put(p + "virtualPill", s.virtualPill, b.virtualPill)
        a.put(p + "hideInFullscreen", s.hideInFullscreen, b.hideInFullscreen)
        a.put(p + "avoidMenus", s.avoidMenus, b.avoidMenus)
        a.put(p + "glass", s.glass, b.glass)
        a.put(p + "hideMenuIcon", s.hideMenuIcon, b.hideMenuIcon)
        a.put(p + "start", s.start.stored, b.start.stored)
        a.put(p + "musicSwipe", s.musicSwipe.rawValue, b.musicSwipe.rawValue)
        putSet(p + "mutedActivities", s.mutedActivities)
    }

    private func putSet(_ key: String, _ set: Set<String>) {
        if set.isEmpty { a.kv.removeObject(forKey: key) } else { a.kv.set(set.sorted(), forKey: key) }
    }
}

public enum IslHotkeys {
    public static let toggle = HotkeySpec(id: "notch.toggle", title: "Остров: открыть / закрыть", defaultCombo: .none)
    public static let all = [toggle]
}

public enum IslHintCombos {
    public static let all: [String: KeyCombo] = [
        IslHotkeys.toggle.id: KeyCombo(keyCode: 34, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd)
    ]
}
