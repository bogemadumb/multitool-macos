import Foundation
import CoreGraphics

public struct RecNormRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public static let full = RecNormRect(x: 0, y: 0, w: 1, h: 1)
    public static let minSide = 0.04

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(_ r: CGRect) { self.init(x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height)) }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var isFull: Bool { x <= 0.0001 && y <= 0.0001 && w >= 0.9999 && h >= 0.9999 }

    public var sanitized: RecNormRect {
        func f(_ v: Double, _ d: Double) -> Double { v.isFinite ? v : d }
        let ww = min(max(f(w, 1), Self.minSide), 1)
        let hh = min(max(f(h, 1), Self.minSide), 1)
        return RecNormRect(x: min(max(f(x, 0), 0), 1 - ww), y: min(max(f(y, 0), 0), 1 - hh), w: ww, h: hh)
    }
}

public enum RecAspect: String, CaseIterable, Codable, Sendable {
    case free, wide, classic, square, tall, portrait45, ultra

    public var title: String {
        switch self {
        case .free: "Свободно"
        case .wide: "16:9"
        case .classic: "4:3"
        case .square: "1:1"
        case .tall: "9:16"
        case .portrait45: "4:5"
        case .ultra: "21:9"
        }
    }

    public var ratio: Double? {
        switch self {
        case .free: nil
        case .wide: 16.0 / 9
        case .classic: 4.0 / 3
        case .square: 1
        case .tall: 9.0 / 16
        case .portrait45: 4.0 / 5
        case .ultra: 21.0 / 9
        }
    }
}

public struct RecBlurRegion: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var rect: RecNormRect
    public var srcStart: Double
    public var srcEnd: Double
    public var strength: Double
    public var pixelate: Bool

    public init(id: Int, rect: RecNormRect, srcStart: Double, srcEnd: Double, strength: Double = 0.7, pixelate: Bool = false) {
        self.id = id
        self.rect = rect
        self.srcStart = srcStart
        self.srcEnd = srcEnd
        self.strength = strength
        self.pixelate = pixelate
    }

    public func isActive(at t: Double) -> Bool { t >= srcStart && t <= srcEnd }
}

public struct RecAudioMix: Equatable, Codable, Sendable {
    public static let volumeRange = 0.0...2.0
    public var systemVolume = 1.0
    public var micVolume = 1.0
    public var systemMuted = false
    public var micMuted = false

    public init() {}

    public func gain(_ kind: RecTrackKind) -> Double {
        switch kind {
        case .video: 0
        case .systemAudio: systemMuted ? 0 : ToolsClamp.double(systemVolume, Self.volumeRange)
        case .microphone: micMuted ? 0 : ToolsClamp.double(micVolume, Self.volumeRange)
        }
    }
}

public struct RecFrameStyle: Equatable, Codable, Sendable {
    public var background = "none"
    public var padding = 0
    public var corner = 0
    public var shadow = true
    public var clickColor = "#FFD60A"
    public var highlightClicks = true
    public var clickRadius = 0.035

    public init() {}

    public var backgroundValue: ShotBackground { ShotBackground(stored: background) }
    public var isPlain: Bool { padding == 0 && corner == 0 && backgroundValue.isNone }

    public var sanitized: RecFrameStyle {
        var s = self
        s.padding = ToolsClamp.int(padding, 0...400)
        s.corner = ToolsClamp.int(corner, 0...120)
        s.clickRadius = ToolsClamp.double(clickRadius, 0.01...0.15)
        if ShotColor(hex: clickColor) == nil { s.clickColor = "#FFD60A" }
        return s
    }
}

public struct RecSourceInfo: Equatable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public var duration: Double
    public var fps: Int
    public var scale: Double
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool

    public init(width: Int, height: Int, duration: Double, fps: Int = 30, scale: Double = 2, hasSystemAudio: Bool = false, hasMicrophone: Bool = false) {
        self.width = width
        self.height = height
        self.duration = duration
        self.fps = fps
        self.scale = scale
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
    }

    public var size: CGSize { CGSize(width: width, height: height) }
}

public struct RecEditDocument: Equatable, Codable, Sendable {
    public static let version = 1

    public var version = RecEditDocument.version
    public var source: RecSourceInfo
    public var timeline: RecTimeline
    public var crop = RecNormRect.full
    public var aspect = RecAspect.free
    public var style = RecFrameStyle()
    public var audio = RecAudioMix()
    public var zoomEnabled = true
    public var zoomSettings = RecZoomSettings()
    public var zoom = RecZoomTimeline()
    public var blurs: [RecBlurRegion] = []
    public var nextBlurID = 1

    public init(source: RecSourceInfo) {
        self.source = source
        timeline = RecTimeline(sourceDuration: source.duration)
    }

    public var isUntouched: Bool {
        timeline.isIdentity && crop.isFull && style.isPlain && blurs.isEmpty && zoom.spans.isEmpty
            && audio == RecAudioMix()
    }

    public mutating func addBlur(rect: RecNormRect, from: Double, to: Double, strength: Double = 0.7, pixelate: Bool = false) -> Int {
        let id = nextBlurID
        nextBlurID += 1
        let lo = max(min(from, to), 0), hi = min(max(from, to), source.duration)
        blurs.append(RecBlurRegion(id: id, rect: rect.sanitized, srcStart: lo, srcEnd: max(hi, lo + 0.1), strength: ToolsClamp.double(strength, 0...1), pixelate: pixelate))
        return id
    }

    public mutating func removeBlur(id: Int) { blurs.removeAll { $0.id == id } }

    public mutating func regenerateZoom(log: RecInputLog) {
        zoom = zoomEnabled ? RecAutoZoom.plan(log: log, duration: source.duration, settings: zoomSettings) : RecZoomTimeline()
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> RecEditDocument {
        var doc = try JSONDecoder().decode(RecEditDocument.self, from: data)
        guard doc.version <= Self.version else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported version \(doc.version)"))
        }
        doc.crop = doc.crop.sanitized
        doc.style = doc.style.sanitized
        doc.zoomSettings = doc.zoomSettings.sanitized
        return doc
    }
}

public struct RecEditSession: Sendable {
    public private(set) var document: RecEditDocument
    public private(set) var undoStack = RecUndoStack<RecEditDocument>(limit: 100)
    public var revision = 0

    public init(document: RecEditDocument) { self.document = document }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    @discardableResult
    public mutating func edit(_ body: (inout RecEditDocument) -> Bool) -> Bool {
        var copy = document
        guard body(&copy), copy != document else { return false }
        undoStack.record(before: document)
        document = copy
        revision += 1
        return true
    }

    public mutating func undo() -> Bool {
        guard let prev = undoStack.undo(current: document) else { return false }
        document = prev
        revision += 1
        return true
    }

    public mutating func redo() -> Bool {
        guard let next = undoStack.redo(current: document) else { return false }
        document = next
        revision += 1
        return true
    }

    public mutating func trim(from a: Double, to b: Double) -> Bool { edit { $0.timeline.trim(from: a, to: b) } }
    public mutating func cut(from a: Double, to b: Double) -> Bool { edit { $0.timeline.cut(from: a, to: b) } }
    public mutating func split(at t: Double) -> Bool { edit { $0.timeline.split(at: t) } }
    public mutating func setSpeed(from a: Double, to b: Double, speed: Double) -> Bool { edit { $0.timeline.setSpeed(from: a, to: b, speed: speed) } }
    public mutating func setCrop(_ r: RecNormRect) -> Bool { edit { $0.crop = r.sanitized; return true } }
    public mutating func setStyle(_ s: RecFrameStyle) -> Bool { edit { $0.style = s.sanitized; return true } }
    public mutating func setAudio(_ a: RecAudioMix) -> Bool { edit { $0.audio = a; return true } }
}
