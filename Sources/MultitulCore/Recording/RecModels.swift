import Foundation
import CoreGraphics

public enum RecMode: String, CaseIterable, Sendable, Codable {
    case area, window, display

    public var title: String {
        switch self {
        case .area: "Область"
        case .window: "Окно"
        case .display: "Весь экран"
        }
    }

    public var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .display: "display"
        }
    }

    public var shotMode: ShotMode {
        switch self {
        case .area: .area
        case .window: .window
        case .display: .screen
        }
    }
}

public enum RecCodec: String, CaseIterable, Sendable, Codable {
    case h264, hevc

    public var title: String {
        switch self {
        case .h264: "H.264 (совместимо везде)"
        case .hevc: "HEVC (файл меньше)"
        }
    }

    public var efficiency: Double { self == .hevc ? 0.62 : 1 }
}

public enum RecContainer: String, CaseIterable, Sendable, Codable {
    case mp4, mov

    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    public var mimeType: String { self == .mp4 ? "video/mp4" : "video/quicktime" }
}

public enum RecQuality: String, CaseIterable, Sendable, Codable {
    case low, medium, high, max

    public var title: String {
        switch self {
        case .low: "Лёгкое"
        case .medium: "Среднее"
        case .high: "Высокое"
        case .max: "Максимальное"
        }
    }

    // bits per pixel per frame for H.264 on screen content
    public var bitsPerPixel: Double {
        switch self {
        case .low: 0.035
        case .medium: 0.06
        case .high: 0.1
        case .max: 0.18
        }
    }
}

public enum RecResolution: String, CaseIterable, Sendable, Codable {
    case native, oneX, p1440, p1080, p720

    public var title: String {
        switch self {
        case .native: "Как на экране (Retina)"
        case .oneX: "Без Retina (1×)"
        case .p1440: "До 2560 px"
        case .p1080: "До 1920 px"
        case .p720: "До 1280 px"
        }
    }

    public var maxLongSide: Int? {
        switch self {
        case .native, .oneX: nil
        case .p1440: 2560
        case .p1080: 1920
        case .p720: 1280
        }
    }
}

public enum RecAfterAction: String, CaseIterable, Sendable, Codable {
    case editor, reveal, copyFile, nothing

    public var title: String {
        switch self {
        case .editor: "Открыть редактор"
        case .reveal: "Показать в Finder"
        case .copyFile: "Скопировать файл в буфер"
        case .nothing: "Ничего"
        }
    }
}

public enum RecTrackKind: String, CaseIterable, Sendable, Codable {
    case video, systemAudio, microphone

    public var title: String {
        switch self {
        case .video: "Экран"
        case .systemAudio: "Звук системы"
        case .microphone: "Микрофон"
        }
    }

    public var isAudio: Bool { self != .video }
}

public struct RecSettings: Equatable, Sendable {
    public static let fpsChoices = [24, 30, 60]
    public static let countdownChoices = [0, 3, 5, 10]
    public static let defaultDirectory = "Movies/Screen Recordings"
    public static let defaultTemplate = "Запись экрана {yyyy}-{MM}-{dd} в {HH}.{mm}.{ss}"
    public static let zoomLevelRange = 1.2...4.0

    public var mode = RecMode.area
    public var fps = 30
    public var codec = RecCodec.h264
    public var container = RecContainer.mp4
    public var quality = RecQuality.high
    public var resolution = RecResolution.native
    public var systemAudio = true
    public var microphone = false
    public var micDeviceUID = ""
    public var showCursor = true
    public var highlightClicks = true
    public var countdownSeconds = 3
    public var excludeOwnWindows = true
    public var saveDirectory = ""
    public var nameTemplate = RecSettings.defaultTemplate
    public var afterRecord = RecAfterAction.editor
    public var addToShelf = false
    public var recordHistory = true
    public var historyLimit = 100
    public var historyKeepDays = 60
    public var maxMinutes = 0
    public var minFreeMegabytes = 500
    public var autoZoom = true
    public var zoomLevel = 1.8
    public var presetID = "standard"
    public var editorBackground = ShotBackground.none
    public var editorPadding = 0
    public var editorCorner = 12

    public init() {}

    public var sanitized: RecSettings {
        var s = self
        s.fps = Self.fpsChoices.contains(fps) ? fps : 30
        s.countdownSeconds = Self.countdownChoices.contains(countdownSeconds) ? countdownSeconds : ToolsClamp.int(countdownSeconds, 0...60)
        s.saveDirectory = saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty { s.nameTemplate = Self.defaultTemplate }
        s.historyLimit = ToolsClamp.int(historyLimit, 10...2000)
        s.historyKeepDays = ToolsClamp.int(historyKeepDays, 0...3650)
        s.maxMinutes = ToolsClamp.int(maxMinutes, 0...600)
        s.minFreeMegabytes = ToolsClamp.int(minFreeMegabytes, 0...100_000)
        s.zoomLevel = ToolsClamp.double(zoomLevel, Self.zoomLevelRange)
        s.editorPadding = ToolsClamp.int(editorPadding, 0...400)
        s.editorCorner = ToolsClamp.int(editorCorner, 0...120)
        s.micDeviceUID = micDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
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

public final class RecSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> RecSettings {
        var s = RecSettings()
        let p = "recorder."
        if let v = a.string(p + "mode"), let x = RecMode(rawValue: v) { s.mode = x }
        s.fps = a.int(p + "fps", s.fps)
        if let v = a.string(p + "codec"), let x = RecCodec(rawValue: v) { s.codec = x }
        if let v = a.string(p + "container"), let x = RecContainer(rawValue: v) { s.container = x }
        if let v = a.string(p + "quality"), let x = RecQuality(rawValue: v) { s.quality = x }
        if let v = a.string(p + "resolution"), let x = RecResolution(rawValue: v) { s.resolution = x }
        s.systemAudio = a.bool(p + "systemAudio", s.systemAudio)
        s.microphone = a.bool(p + "microphone", s.microphone)
        s.micDeviceUID = a.string(p + "micDeviceUID") ?? s.micDeviceUID
        s.showCursor = a.bool(p + "showCursor", s.showCursor)
        s.highlightClicks = a.bool(p + "highlightClicks", s.highlightClicks)
        s.countdownSeconds = a.int(p + "countdownSeconds", s.countdownSeconds)
        s.excludeOwnWindows = a.bool(p + "excludeOwnWindows", s.excludeOwnWindows)
        s.saveDirectory = a.string(p + "saveDirectory") ?? s.saveDirectory
        s.nameTemplate = a.string(p + "nameTemplate") ?? s.nameTemplate
        if let v = a.string(p + "afterRecord"), let x = RecAfterAction(rawValue: v) { s.afterRecord = x }
        s.addToShelf = a.bool(p + "addToShelf", s.addToShelf)
        s.recordHistory = a.bool(p + "recordHistory", s.recordHistory)
        s.historyLimit = a.int(p + "historyLimit", s.historyLimit)
        s.historyKeepDays = a.int(p + "historyKeepDays", s.historyKeepDays)
        s.maxMinutes = a.int(p + "maxMinutes", s.maxMinutes)
        s.minFreeMegabytes = a.int(p + "minFreeMegabytes", s.minFreeMegabytes)
        s.autoZoom = a.bool(p + "autoZoom", s.autoZoom)
        s.zoomLevel = a.double(p + "zoomLevel", s.zoomLevel)
        s.presetID = a.string(p + "presetID") ?? s.presetID
        if let v = a.string(p + "editorBackground") { s.editorBackground = ShotBackground(stored: v) }
        s.editorPadding = a.int(p + "editorPadding", s.editorPadding)
        s.editorCorner = a.int(p + "editorCorner", s.editorCorner)
        return s.sanitized
    }

    public func save(_ settings: RecSettings) {
        let s = settings.sanitized
        let b = RecSettings()
        let p = "recorder."
        a.put(p + "mode", s.mode.rawValue, b.mode.rawValue)
        a.put(p + "fps", s.fps, b.fps)
        a.put(p + "codec", s.codec.rawValue, b.codec.rawValue)
        a.put(p + "container", s.container.rawValue, b.container.rawValue)
        a.put(p + "quality", s.quality.rawValue, b.quality.rawValue)
        a.put(p + "resolution", s.resolution.rawValue, b.resolution.rawValue)
        a.put(p + "systemAudio", s.systemAudio, b.systemAudio)
        a.put(p + "microphone", s.microphone, b.microphone)
        a.put(p + "micDeviceUID", s.micDeviceUID, b.micDeviceUID)
        a.put(p + "showCursor", s.showCursor, b.showCursor)
        a.put(p + "highlightClicks", s.highlightClicks, b.highlightClicks)
        a.put(p + "countdownSeconds", s.countdownSeconds, b.countdownSeconds)
        a.put(p + "excludeOwnWindows", s.excludeOwnWindows, b.excludeOwnWindows)
        a.put(p + "saveDirectory", s.saveDirectory, b.saveDirectory)
        a.put(p + "nameTemplate", s.nameTemplate, b.nameTemplate)
        a.put(p + "afterRecord", s.afterRecord.rawValue, b.afterRecord.rawValue)
        a.put(p + "addToShelf", s.addToShelf, b.addToShelf)
        a.put(p + "recordHistory", s.recordHistory, b.recordHistory)
        a.put(p + "historyLimit", s.historyLimit, b.historyLimit)
        a.put(p + "historyKeepDays", s.historyKeepDays, b.historyKeepDays)
        a.put(p + "maxMinutes", s.maxMinutes, b.maxMinutes)
        a.put(p + "minFreeMegabytes", s.minFreeMegabytes, b.minFreeMegabytes)
        a.put(p + "autoZoom", s.autoZoom, b.autoZoom)
        a.put(p + "zoomLevel", s.zoomLevel, b.zoomLevel)
        a.put(p + "presetID", s.presetID, b.presetID)
        a.put(p + "editorBackground", s.editorBackground.stored, b.editorBackground.stored)
        a.put(p + "editorPadding", s.editorPadding, b.editorPadding)
        a.put(p + "editorCorner", s.editorCorner, b.editorCorner)
    }
}

public enum RecHotkeys {
    public static let toggle = HotkeySpec(id: "recorder.toggle", title: "Запись: начать или остановить", defaultCombo: .none)
    public static let area = HotkeySpec(id: "recorder.area", title: "Запись: область", defaultCombo: .none)
    public static let window = HotkeySpec(id: "recorder.window", title: "Запись: окно", defaultCombo: .none)
    public static let display = HotkeySpec(id: "recorder.display", title: "Запись: весь экран", defaultCombo: .none)
    public static let stop = HotkeySpec(id: "recorder.stop", title: "Запись: остановить", defaultCombo: .none)
    public static let pause = HotkeySpec(id: "recorder.pause", title: "Запись: пауза и продолжение", defaultCombo: .none)
    public static let editLast = HotkeySpec(id: "recorder.editLast", title: "Запись: последняя в редакторе", defaultCombo: .none)
    public static let history = HotkeySpec(id: "recorder.history", title: "Запись: история", defaultCombo: .none)
    public static let all = [toggle, area, window, display, stop, pause, editLast, history]
}

public enum RecHintCombos {
    private static let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

    public static let all: [String: KeyCombo] = [
        RecHotkeys.toggle.id: KeyCombo(keyCode: 23, modifiers: layer)
    ]
}
