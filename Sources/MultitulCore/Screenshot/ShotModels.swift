import Foundation
import CoreGraphics

public enum ShotMode: String, CaseIterable, Sendable {
    case area, window, screen, allScreens, scroll

    public var title: String {
        switch self {
        case .area: "Область"
        case .window: "Окно"
        case .screen: "Экран"
        case .allScreens: "Все экраны"
        case .scroll: "Прокрутка"
        }
    }

    public var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .allScreens: "rectangle.on.rectangle"
        case .scroll: "arrow.down.to.line"
        }
    }
}

public enum ShotFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .heic: "image/heic"
        }
    }

    public var usesQuality: Bool { self != .png }
    public var keepsAlpha: Bool { self != .jpeg }

    public static func from(fileExtension ext: String) -> ShotFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        default: nil
        }
    }
}

public enum ShotAfterAction: String, CaseIterable, Sendable {
    case overlay, editor, pin, copyOnly, saveOnly, nothing

    public var title: String {
        switch self {
        case .overlay: "Плашка с действиями"
        case .editor: "Открыть редактор"
        case .pin: "Закрепить поверх окон"
        case .copyOnly: "Только скопировать"
        case .saveOnly: "Только сохранить"
        case .nothing: "Ничего"
        }
    }
}

public enum ShotCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Слева сверху"
        case .topRight: "Справа сверху"
        case .bottomLeft: "Слева снизу"
        case .bottomRight: "Справа снизу"
        }
    }

    public var isRight: Bool { self == .topRight || self == .bottomRight }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

public enum ShotLinkTTL: Int, CaseIterable, Sendable {
    case hour1 = 1, hours6 = 6, hours24 = 24

    public var hours: Int { rawValue }
    public var seconds: Int { rawValue * 3600 }

    public var title: String {
        switch self {
        case .hour1: "1 час"
        case .hours6: "6 часов"
        case .hours24: "24 часа"
        }
    }
}

public struct ShotColor: Equatable, Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, s.allSatisfy({ $0.isHexDigit }), let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255))
        } else {
            self.init(UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255))
        }
    }

    public var hex: String {
        let base = String(format: "#%02X%02X%02X", r, g, b)
        return a == 255 ? base : base + String(format: "%02X", a)
    }

    public var alpha: Double { Double(a) / 255 }
    public func withAlpha(_ alpha: Double) -> ShotColor { ShotColor(r, g, b, UInt8(max(0, min(255, (alpha * 255).rounded())))) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = ShotColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad color \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let red = ShotColor(255, 59, 48)
    public static let orange = ShotColor(255, 149, 0)
    public static let yellow = ShotColor(255, 214, 10)
    public static let green = ShotColor(52, 199, 89)
    public static let blue = ShotColor(10, 132, 255)
    public static let purple = ShotColor(175, 82, 222)
    public static let black = ShotColor(0, 0, 0)
    public static let white = ShotColor(255, 255, 255)
    public static let palette: [ShotColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

public enum ShotBackground: Equatable, Sendable {
    case none
    case solid(ShotColor)
    case gradient(ShotColor, ShotColor, angle: Int)

    public var stored: String {
        switch self {
        case .none: "none"
        case .solid(let c): "solid:" + c.hex
        case .gradient(let a, let b, let angle): "gradient:\(a.hex):\(b.hex):\(angle)"
        }
    }

    public init(stored: String) {
        let p = stored.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if p.count == 2, p[0] == "solid", let c = ShotColor(hex: p[1]) {
            self = .solid(c)
        } else if p.count == 4, p[0] == "gradient", let a = ShotColor(hex: p[1]), let b = ShotColor(hex: p[2]), let angle = Int(p[3]) {
            self = .gradient(a, b, angle: ((angle % 360) + 360) % 360)
        } else {
            self = .none
        }
    }

    public var isNone: Bool { self == .none }

    public static let presets: [(title: String, value: ShotBackground)] = [
        ("Без фона", .none),
        ("Белый", .solid(.white)),
        ("Графит", .solid(ShotColor(36, 36, 40))),
        ("Закат", .gradient(ShotColor(255, 126, 95), ShotColor(254, 180, 123), angle: 135)),
        ("Океан", .gradient(ShotColor(43, 88, 118), ShotColor(78, 205, 196), angle: 135)),
        ("Сирень", .gradient(ShotColor(131, 96, 195), ShotColor(46, 191, 145), angle: 45))
    ]
}

public struct ShotWatermark: Equatable, Sendable {
    public var enabled = false
    public var text = ""
    public var corner = ShotCorner.bottomRight
    public var opacity = 0.5
    public var fontSize = 14.0

    public init() {}

    public var isActive: Bool { enabled && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    public var sanitized: ShotWatermark {
        var w = self
        w.opacity = min(max(opacity, 0.05), 1)
        w.fontSize = min(max(fontSize, 8), 96)
        w.text = String(text.prefix(80))
        return w
    }
}

public enum ShotHotkeys {
    public static let area = HotkeySpec(id: "screenshot.area", title: "Скриншот: область", defaultCombo: .none)
    public static let screen = HotkeySpec(id: "screenshot.screen", title: "Скриншот: весь экран", defaultCombo: .none)
    public static let window = HotkeySpec(id: "screenshot.window", title: "Скриншот: окно", defaultCombo: .none)
    public static let allScreens = HotkeySpec(id: "screenshot.allScreens", title: "Скриншот: все экраны", defaultCombo: .none)
    public static let scroll = HotkeySpec(id: "screenshot.scroll", title: "Скриншот: прокручиваемая страница", defaultCombo: .none)
    public static let link = HotkeySpec(id: "screenshot.link", title: "Скриншот: область и ссылка", defaultCombo: .none)
    public static let editLast = HotkeySpec(id: "screenshot.editLast", title: "Скриншот: последний в редакторе", defaultCombo: .none)
    public static let history = HotkeySpec(id: "screenshot.history", title: "Скриншот: история", defaultCombo: .none)
    public static let editClipboard = HotkeySpec(id: "screenshot.editClipboard", title: "Скриншот: редактор из буфера", defaultCombo: .none)
    public static let pinsToggle = HotkeySpec(id: "screenshot.pinsToggle", title: "Скриншот: показать или скрыть закрепы", defaultCombo: .none)
    public static let all = [area, screen, window, allScreens, scroll, link, editLast, history, editClipboard, pinsToggle]
}

public enum ShotHintCombos {
    private static let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

    public static let all: [String: KeyCombo] = [
        ShotHotkeys.area.id: KeyCombo(keyCode: 21, modifiers: layer),
        ShotHotkeys.screen.id: KeyCombo(keyCode: 20, modifiers: layer),
        ShotHotkeys.link.id: KeyCombo(keyCode: 32, modifiers: layer),
        ShotHotkeys.editLast.id: KeyCombo(keyCode: 14, modifiers: layer),
        ShotHotkeys.history.id: KeyCombo(keyCode: 4, modifiers: layer),
        ShotHotkeys.editClipboard.id: KeyCombo(keyCode: 35, modifiers: layer)
    ]
}

public struct ShotSettings: Equatable, Sendable {
    public static let timerChoices = [0, 3, 5, 10]
    public static let qualityRange = 0.3...1.0
    public static let paddingRange = 0...200
    public static let historyLimitRange = 20...5000
    public static let overlaySecondsRange = 0...60
    public static let defaultDirectory = "Pictures/Screenshots"

    public var saveDirectory = ""
    public var nameTemplate = ShotNaming.defaultTemplate
    public var format = ShotFormat.png
    public var quality = 0.9
    public var saveToDisk = true
    public var copyToClipboard = true
    public var afterCapture = ShotAfterAction.overlay
    public var openEditorImmediately = false
    public var addToShelf = false
    public var includeCursor = false
    public var freezeScreen = true
    public var confirmOnRelease = true
    public var timerSeconds = 0
    public var windowShadow = true
    public var windowPadding = 0
    public var background = ShotBackground.none
    public var backgroundCorner = 12
    public var downscaleRetina = false
    public var recordHistory = true
    public var indexText = true
    public var historyLimit = 500
    public var historyKeepDays = 90
    public var overlaySeconds = 8
    public var overlayCorner = ShotCorner.bottomRight
    public var linkTTL = ShotLinkTTL.hours24
    public var takeOverSystemKeys = false
    public var scrollMaxHeight = 30000
    public var watermark = ShotWatermark()

    public init() {}

    public var sanitized: ShotSettings {
        var s = self
        s.saveDirectory = saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty { s.nameTemplate = ShotNaming.defaultTemplate }
        s.quality = ToolsClamp.double(quality, Self.qualityRange)
        s.timerSeconds = Self.timerChoices.contains(timerSeconds) ? timerSeconds : ToolsClamp.int(timerSeconds, 0...60)
        s.windowPadding = ToolsClamp.int(windowPadding, Self.paddingRange)
        s.backgroundCorner = ToolsClamp.int(backgroundCorner, 0...80)
        s.historyLimit = ToolsClamp.int(historyLimit, Self.historyLimitRange)
        s.historyKeepDays = ToolsClamp.int(historyKeepDays, 0...3650)
        s.overlaySeconds = ToolsClamp.int(overlaySeconds, Self.overlaySecondsRange)
        s.scrollMaxHeight = ToolsClamp.int(scrollMaxHeight, 2000...100_000)
        s.watermark = watermark.sanitized
        return s
    }

    public func resolvedDirectory(home: String = NSHomeDirectory()) -> String {
        let d = saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return home + "/" + Self.defaultDirectory }
        if d == "~" { return home }
        if d.hasPrefix("~/") { return home + String(d.dropFirst(1)) }
        return d
    }
}

public final class ShotSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> ShotSettings {
        var s = ShotSettings()
        let p = "screenshot."
        s.saveDirectory = a.string(p + "saveDirectory") ?? s.saveDirectory
        s.nameTemplate = a.string(p + "nameTemplate") ?? s.nameTemplate
        if let v = a.string(p + "format"), let x = ShotFormat(rawValue: v) { s.format = x }
        s.quality = a.double(p + "quality", s.quality)
        s.saveToDisk = a.bool(p + "saveToDisk", s.saveToDisk)
        s.copyToClipboard = a.bool(p + "copyToClipboard", s.copyToClipboard)
        if let v = a.string(p + "afterCapture"), let x = ShotAfterAction(rawValue: v) { s.afterCapture = x }
        s.openEditorImmediately = a.bool(p + "openEditorImmediately", s.openEditorImmediately)
        s.addToShelf = a.bool(p + "addToShelf", s.addToShelf)
        s.includeCursor = a.bool(p + "includeCursor", s.includeCursor)
        s.freezeScreen = a.bool(p + "freezeScreen", s.freezeScreen)
        s.confirmOnRelease = a.bool(p + "confirmOnRelease", s.confirmOnRelease)
        s.timerSeconds = a.int(p + "timerSeconds", s.timerSeconds)
        s.windowShadow = a.bool(p + "windowShadow", s.windowShadow)
        s.windowPadding = a.int(p + "windowPadding", s.windowPadding)
        if let v = a.string(p + "background") { s.background = ShotBackground(stored: v) }
        s.backgroundCorner = a.int(p + "backgroundCorner", s.backgroundCorner)
        s.downscaleRetina = a.bool(p + "downscaleRetina", s.downscaleRetina)
        s.recordHistory = a.bool(p + "recordHistory", s.recordHistory)
        s.indexText = a.bool(p + "indexText", s.indexText)
        s.historyLimit = a.int(p + "historyLimit", s.historyLimit)
        s.historyKeepDays = a.int(p + "historyKeepDays", s.historyKeepDays)
        s.overlaySeconds = a.int(p + "overlaySeconds", s.overlaySeconds)
        if let v = a.string(p + "overlayCorner"), let x = ShotCorner(rawValue: v) { s.overlayCorner = x }
        if let x = ShotLinkTTL(rawValue: a.int(p + "linkTTL", s.linkTTL.rawValue)) { s.linkTTL = x }
        s.takeOverSystemKeys = a.bool(p + "takeOverSystemKeys", s.takeOverSystemKeys)
        s.scrollMaxHeight = a.int(p + "scrollMaxHeight", s.scrollMaxHeight)
        var w = s.watermark
        w.enabled = a.bool(p + "watermark.enabled", w.enabled)
        w.text = a.string(p + "watermark.text") ?? w.text
        if let v = a.string(p + "watermark.corner"), let x = ShotCorner(rawValue: v) { w.corner = x }
        w.opacity = a.double(p + "watermark.opacity", w.opacity)
        w.fontSize = a.double(p + "watermark.fontSize", w.fontSize)
        s.watermark = w
        return s.sanitized
    }

    public func save(_ settings: ShotSettings) {
        let s = settings.sanitized
        let b = ShotSettings()
        let p = "screenshot."
        a.put(p + "saveDirectory", s.saveDirectory, b.saveDirectory)
        a.put(p + "nameTemplate", s.nameTemplate, b.nameTemplate)
        a.put(p + "format", s.format.rawValue, b.format.rawValue)
        a.put(p + "quality", s.quality, b.quality)
        a.put(p + "saveToDisk", s.saveToDisk, b.saveToDisk)
        a.put(p + "copyToClipboard", s.copyToClipboard, b.copyToClipboard)
        a.put(p + "afterCapture", s.afterCapture.rawValue, b.afterCapture.rawValue)
        a.put(p + "openEditorImmediately", s.openEditorImmediately, b.openEditorImmediately)
        a.put(p + "addToShelf", s.addToShelf, b.addToShelf)
        a.put(p + "includeCursor", s.includeCursor, b.includeCursor)
        a.put(p + "freezeScreen", s.freezeScreen, b.freezeScreen)
        a.put(p + "confirmOnRelease", s.confirmOnRelease, b.confirmOnRelease)
        a.put(p + "timerSeconds", s.timerSeconds, b.timerSeconds)
        a.put(p + "windowShadow", s.windowShadow, b.windowShadow)
        a.put(p + "windowPadding", s.windowPadding, b.windowPadding)
        a.put(p + "background", s.background.stored, b.background.stored)
        a.put(p + "backgroundCorner", s.backgroundCorner, b.backgroundCorner)
        a.put(p + "downscaleRetina", s.downscaleRetina, b.downscaleRetina)
        a.put(p + "recordHistory", s.recordHistory, b.recordHistory)
        a.put(p + "indexText", s.indexText, b.indexText)
        a.put(p + "historyLimit", s.historyLimit, b.historyLimit)
        a.put(p + "historyKeepDays", s.historyKeepDays, b.historyKeepDays)
        a.put(p + "overlaySeconds", s.overlaySeconds, b.overlaySeconds)
        a.put(p + "overlayCorner", s.overlayCorner.rawValue, b.overlayCorner.rawValue)
        a.put(p + "linkTTL", s.linkTTL.rawValue, b.linkTTL.rawValue)
        a.put(p + "takeOverSystemKeys", s.takeOverSystemKeys, b.takeOverSystemKeys)
        a.put(p + "scrollMaxHeight", s.scrollMaxHeight, b.scrollMaxHeight)
        a.put(p + "watermark.enabled", s.watermark.enabled, b.watermark.enabled)
        a.put(p + "watermark.text", s.watermark.text, b.watermark.text)
        a.put(p + "watermark.corner", s.watermark.corner.rawValue, b.watermark.corner.rawValue)
        a.put(p + "watermark.opacity", s.watermark.opacity, b.watermark.opacity)
        a.put(p + "watermark.fontSize", s.watermark.fontSize, b.watermark.fontSize)
    }
}

public struct ShotSystemShortcut: Sendable {
    public let spec: HotkeySpec
    public let symbolicID: Int32
    public let mode: ShotMode?
    public let clipboardOnly: Bool
}

public enum ShotSystemKeys {
    public static let journalKey = "screenshot.takeoverJournal"

    public static let entries: [ShotSystemShortcut] = [
        ShotSystemShortcut(spec: HotkeySpec(id: "screenshot.sys.screen", title: "⇧⌘3 весь экран", defaultCombo: KeyCombo(keyCode: 20, modifiers: KeyCombo.shift | KeyCombo.cmd)),
                           symbolicID: 28, mode: .screen, clipboardOnly: false),
        ShotSystemShortcut(spec: HotkeySpec(id: "screenshot.sys.screenCopy", title: "⌃⇧⌘3 весь экран в буфер", defaultCombo: KeyCombo(keyCode: 20, modifiers: KeyCombo.ctrl | KeyCombo.shift | KeyCombo.cmd)),
                           symbolicID: 29, mode: .screen, clipboardOnly: true),
        ShotSystemShortcut(spec: HotkeySpec(id: "screenshot.sys.area", title: "⇧⌘4 область", defaultCombo: KeyCombo(keyCode: 21, modifiers: KeyCombo.shift | KeyCombo.cmd)),
                           symbolicID: 30, mode: .area, clipboardOnly: false),
        ShotSystemShortcut(spec: HotkeySpec(id: "screenshot.sys.areaCopy", title: "⌃⇧⌘4 область в буфер", defaultCombo: KeyCombo(keyCode: 21, modifiers: KeyCombo.ctrl | KeyCombo.shift | KeyCombo.cmd)),
                           symbolicID: 31, mode: .area, clipboardOnly: true),
        ShotSystemShortcut(spec: HotkeySpec(id: "screenshot.sys.panel", title: "⇧⌘5 панель съёмки", defaultCombo: KeyCombo(keyCode: 23, modifiers: KeyCombo.shift | KeyCombo.cmd)),
                           symbolicID: 184, mode: nil, clipboardOnly: false)
    ]

    public static var symbolicIDs: [Int32] { entries.map(\.symbolicID) }
}
