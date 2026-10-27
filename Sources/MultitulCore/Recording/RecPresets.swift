import Foundation

public enum RecExportKind: String, Codable, Sendable {
    case video, gif
}

public struct RecExportPreset: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var kind: RecExportKind
    public var container: RecContainer
    public var codec: RecCodec
    public var maxLongSide: Int
    public var fps: Int
    public var quality: RecQuality
    public var includeAudio: Bool
    public var separateTracks: Bool
    public var gif: RecGifOptions

    public init(id: String, title: String, summary: String = "", kind: RecExportKind = .video, container: RecContainer = .mp4, codec: RecCodec = .h264,
                maxLongSide: Int = 0, fps: Int = 0, quality: RecQuality = .high, includeAudio: Bool = true, separateTracks: Bool = false, gif: RecGifOptions = RecGifOptions()) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
        self.container = container
        self.codec = codec
        self.maxLongSide = maxLongSide
        self.fps = fps
        self.quality = quality
        self.includeAudio = includeAudio
        self.separateTracks = separateTracks
        self.gif = gif
    }

    public var fileExtension: String { kind == .gif ? "gif" : container.fileExtension }

    public var sanitized: RecExportPreset {
        var p = self
        p.id = RecPresets.safeID(id)
        if p.title.trimmingCharacters(in: .whitespaces).isEmpty { p.title = p.id }
        p.maxLongSide = maxLongSide <= 0 ? 0 : ToolsClamp.int(maxLongSide, 160...8192)
        p.fps = fps <= 0 ? 0 : ToolsClamp.int(fps, 1...60)
        p.gif = gif.sanitized
        return p
    }
}

public struct RecCapturePreset: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var apply: @Sendable (inout RecSettings) -> Void

    public static func == (a: RecCapturePreset, b: RecCapturePreset) -> Bool { a.id == b.id && a.title == b.title }
}

public enum RecPresets {
    public static let capture: [RecCapturePreset] = [
        RecCapturePreset(id: "standard", title: "Обычная", summary: "30 к/с, H.264, звук системы") { s in
            s.fps = 30; s.codec = .h264; s.container = .mp4; s.quality = .high; s.resolution = .native; s.systemAudio = true; s.microphone = false
        },
        RecCapturePreset(id: "tutorial", title: "Обучающее видео", summary: "Системный звук и микрофон, 30 к/с, клики подсвечены") { s in
            s.fps = 30; s.codec = .h264; s.container = .mp4; s.quality = .high; s.resolution = .p1080; s.systemAudio = true; s.microphone = true; s.highlightClicks = true; s.autoZoom = true
        },
        RecCapturePreset(id: "smooth", title: "Плавная (60 к/с)", summary: "Для игр и анимации: 60 к/с, HEVC") { s in
            s.fps = 60; s.codec = .hevc; s.container = .mov; s.quality = .max; s.resolution = .native; s.systemAudio = true; s.microphone = false
        },
        RecCapturePreset(id: "light", title: "Лёгкая", summary: "Для мессенджеров: до 1280 px, 24 к/с, файл маленький") { s in
            s.fps = 24; s.codec = .h264; s.container = .mp4; s.quality = .low; s.resolution = .p720; s.systemAudio = true; s.microphone = false
        },
        RecCapturePreset(id: "silent", title: "Без звука", summary: "Только картинка") { s in
            s.fps = 30; s.codec = .h264; s.container = .mp4; s.quality = .medium; s.systemAudio = false; s.microphone = false
        }
    ]

    public static let export: [RecExportPreset] = [
        RecExportPreset(id: "source", title: "Как записано", summary: "Исходный размер и частота, каждая дорожка отдельно", container: .mov, codec: .hevc, quality: .max, separateTracks: true),
        RecExportPreset(id: "web1080", title: "Веб, 1080p", summary: "MP4 H.264, до 1920 px, 30 к/с", container: .mp4, codec: .h264, maxLongSide: 1920, fps: 30, quality: .high),
        RecExportPreset(id: "messenger", title: "Для мессенджера", summary: "MP4 H.264, до 1280 px, 24 к/с, маленький файл", container: .mp4, codec: .h264, maxLongSide: 1280, fps: 24, quality: .low),
        RecExportPreset(id: "small720", title: "Компактный, 720p", summary: "MP4 HEVC, до 1280 px", container: .mp4, codec: .hevc, maxLongSide: 1280, fps: 30, quality: .medium),
        RecExportPreset(id: "gifLight", title: "GIF лёгкий", summary: "480 px, 10 к/с, 128 цветов", kind: .gif, includeAudio: false,
                        gif: { var g = RecGifOptions(); g.fps = 10; g.maxWidth = 480; g.colors = 128; g.dither = .ordered; return g }()),
        RecExportPreset(id: "gifQuality", title: "GIF качественный", summary: "800 px, 15 к/с, 256 цветов с диффузией", kind: .gif, includeAudio: false,
                        gif: { var g = RecGifOptions(); g.fps = 15; g.maxWidth = 800; g.colors = 256; g.dither = .floyd; return g }())
    ]

    public static func safeID(_ raw: String) -> String {
        let s = raw.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ($0.value >= 48 && $0.value <= 57) || $0 == "-") }
        let r = String(String.UnicodeScalarView(s))
        return r.isEmpty ? "custom" : String(r.prefix(40))
    }

    public static func exportPreset(id: String, custom: [RecExportPreset] = []) -> RecExportPreset {
        (custom + export).first { $0.id == id } ?? export[1]
    }

    public static func capturePreset(id: String) -> RecCapturePreset? { capture.first { $0.id == id } }
}

public final class RecPresetStore {
    public static let key = "recorder.exportPresets"
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    public func load() -> [RecExportPreset] {
        guard let s = kv.object(forKey: Self.key) as? String, let d = s.data(using: .utf8),
              let list = try? JSONDecoder().decode([RecExportPreset].self, from: d) else { return [] }
        var seen = Set(RecPresets.export.map(\.id))
        var out: [RecExportPreset] = []
        for p in list.map(\.sanitized) where !seen.contains(p.id) {
            seen.insert(p.id)
            out.append(p)
        }
        return out
    }

    public func save(_ list: [RecExportPreset]) {
        if list.isEmpty {
            kv.removeObject(forKey: Self.key)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(list.map(\.sanitized)), let s = String(data: d, encoding: .utf8) { kv.set(s, forKey: Self.key) }
    }

    @discardableResult
    public func upsert(_ preset: RecExportPreset) -> [RecExportPreset] {
        var list = load()
        let p = preset.sanitized
        if RecPresets.export.contains(where: { $0.id == p.id }) { return list }
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        save(list)
        return list
    }

    @discardableResult
    public func remove(id: String) -> [RecExportPreset] {
        let list = load().filter { $0.id != id }
        save(list)
        return list
    }
}
