import Foundation

public struct ColorPickerSettings: Equatable, Sendable {
    public static let loupeRange = 3...12
    public var format = ColorFormat.hex
    public var withoutHash = false
    public var uppercaseHex = true
    public var outputSpace = ColorSpaceKind.srgb
    public var loupeRadius = 6
    public var historyLimit = 30
    public var recordHistory = true
    public var showHud = true

    public init() {}

    public var sanitized: ColorPickerSettings {
        var s = self
        s.loupeRadius = ToolsClamp.int(s.loupeRadius, Self.loupeRange)
        s.historyLimit = ToolsClamp.int(s.historyLimit, ColorHistoryStore.limitRange)
        return s
    }

    public var options: ColorFormatOptions { ColorFormatOptions(withoutHash: withoutHash, uppercaseHex: uppercaseHex) }
}

public final class ColorPickerSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> ColorPickerSettings {
        var s = ColorPickerSettings()
        let p = "colorPicker."
        if let v = a.string(p + "format"), let f = ColorFormat(rawValue: v) { s.format = f }
        s.withoutHash = a.bool(p + "withoutHash", s.withoutHash)
        s.uppercaseHex = a.bool(p + "uppercaseHex", s.uppercaseHex)
        if let v = a.string(p + "space"), let x = ColorSpaceKind(rawValue: v) { s.outputSpace = x }
        s.loupeRadius = a.int(p + "loupeRadius", s.loupeRadius)
        s.historyLimit = a.int(p + "historyLimit", s.historyLimit)
        s.recordHistory = a.bool(p + "recordHistory", s.recordHistory)
        s.showHud = a.bool(p + "showHud", s.showHud)
        return s.sanitized
    }

    public func save(_ settings: ColorPickerSettings) {
        let s = settings.sanitized
        let b = ColorPickerSettings()
        let p = "colorPicker."
        a.put(p + "format", s.format.rawValue, b.format.rawValue)
        a.put(p + "withoutHash", s.withoutHash, b.withoutHash)
        a.put(p + "uppercaseHex", s.uppercaseHex, b.uppercaseHex)
        a.put(p + "space", s.outputSpace.rawValue, b.outputSpace.rawValue)
        a.put(p + "loupeRadius", s.loupeRadius, b.loupeRadius)
        a.put(p + "historyLimit", s.historyLimit, b.historyLimit)
        a.put(p + "recordHistory", s.recordHistory, b.recordHistory)
        a.put(p + "showHud", s.showHud, b.showHud)
    }
}

public enum PickerAction: Equatable, Sendable {
    case move(dx: Int, dy: Int)
    case copyAndClose
    case copyAndKeep
    case cancel
}

public enum PickerKeys {
    public static let bigStep = 10

    public static func action(keyCode: UInt32, shift: Bool) -> PickerAction? {
        let step = shift ? bigStep : 1
        switch keyCode {
        case Keys.left: return .move(dx: -step, dy: 0)
        case Keys.right: return .move(dx: step, dy: 0)
        case Keys.up: return .move(dx: 0, dy: -step)
        case Keys.down: return .move(dx: 0, dy: step)
        case Keys.returnKey, Keys.enterKey: return .copyAndClose
        case 8: return .copyAndKeep
        case Keys.escape: return .cancel
        default: return nil
        }
    }
}

public protocol PixelSource: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    func color(atX x: Int, y: Int) -> RGBAColor?
}

public enum PickerOutcome: Equatable, Sendable {
    case moved
    case copied(text: String, closes: Bool)
    case cancelled
    case nothing
}

public final class ColorPickerSession {
    public private(set) var x: Int
    public private(set) var y: Int
    public var settings: ColorPickerSettings
    private let source: PixelSource
    private let clipboard: TextWriting
    private let history: ColorHistoryStore?

    public init(source: PixelSource, settings: ColorPickerSettings, clipboard: TextWriting, history: ColorHistoryStore?, startX: Int = 0, startY: Int = 0) {
        self.source = source
        self.settings = settings
        self.clipboard = clipboard
        self.history = history
        x = min(max(startX, 0), max(source.pixelWidth - 1, 0))
        y = min(max(startY, 0), max(source.pixelHeight - 1, 0))
    }

    public func moveTo(x nx: Int, y ny: Int) {
        x = min(max(nx, 0), max(source.pixelWidth - 1, 0))
        y = min(max(ny, 0), max(source.pixelHeight - 1, 0))
    }

    public var current: RGBAColor? { source.color(atX: x, y: y)?.converted(to: settings.outputSpace) }

    public var currentText: String? {
        current.map { ColorFormatter.format($0, as: settings.format, options: settings.options) }
    }

    public func loupe() -> [[RGBAColor?]] {
        let r = settings.loupeRadius
        return (-r...r).map { dy in (-r...r).map { dx in source.color(atX: x + dx, y: y + dy)?.converted(to: settings.outputSpace) } }
    }

    @discardableResult
    public func handle(_ action: PickerAction) -> PickerOutcome {
        switch action {
        case .move(let dx, let dy):
            moveTo(x: x + dx, y: y + dy)
            return .moved
        case .cancel:
            return .cancelled
        case .copyAndClose, .copyAndKeep:
            guard let c = current, let text = currentText else { return .nothing }
            clipboard.write(text)
            if settings.recordHistory { history?.record(c) }
            return .copied(text: text, closes: action == .copyAndClose)
        }
    }
}
