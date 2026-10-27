import Foundation

public enum MediaKind: String, Sendable {
    case video, audio, image, unknown
}

public enum MediaFormats {
    public static let video: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "ts", "3gp"]
    public static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    public static let image: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]

    public static func kind(of path: String) -> MediaKind {
        let e = (path as NSString).pathExtension.lowercased()
        if video.contains(e) { return .video }
        if audio.contains(e) { return .audio }
        if image.contains(e) { return .image }
        return .unknown
    }
}

public enum MediaError: Error, Equatable, Sendable {
    case toolMissing(String)
    case probeFailed(String)
    case noVideoStream
    case targetTooSmall(minimumBytes: Int64)
    case invalidTrim(String)
    case invalidOptions(String)
    case unsupportedInput(String)
    case invalidURL(String)
    case ioFailure(String)

    public var message: String {
        switch self {
        case .toolMissing(let t): "Не найден \(t)"
        case .probeFailed(let m): "Не удалось прочитать файл: \(m)"
        case .noVideoStream: "В файле нет видео"
        case .targetTooSmall(let b): "Целевой размер слишком мал, нужно не меньше \(ManagerBytes.format(b))"
        case .invalidTrim(let m): "Неверные границы обрезки: \(m)"
        case .invalidOptions(let m): "Неверные параметры: \(m)"
        case .unsupportedInput(let m): "Файл не подходит для этой операции: \(m)"
        case .invalidURL(let m): "Неверная ссылка: \(m)"
        case .ioFailure(let m): "Ошибка файла: \(m)"
        }
    }
}

public struct MediaInfo: Equatable, Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Double
    public var videoCodec: String?
    public var audioCodec: String?
    public var bitrate: Int
    public var sizeBytes: Int64
    public var rotation: Int

    public init(duration: Double = 0, width: Int = 0, height: Int = 0, fps: Double = 0, videoCodec: String? = nil, audioCodec: String? = nil,
                bitrate: Int = 0, sizeBytes: Int64 = 0, rotation: Int = 0) {
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.bitrate = bitrate
        self.sizeBytes = sizeBytes
        self.rotation = rotation
    }

    public var hasVideo: Bool { videoCodec != nil && width > 0 && height > 0 }
    public var hasAudio: Bool { audioCodec != nil }
    public var isQuarterTurned: Bool { abs(rotation) % 180 == 90 }
    public var displayWidth: Int { isQuarterTurned ? height : width }
    public var displayHeight: Int { isQuarterTurned ? width : height }
}

public enum FfprobeParser {
    public static func arguments(for input: String) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", input]
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // "30000/1001" -> 29.97
    static func fraction(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
        return Double(s)
    }

    public static func parse(_ json: String) throws -> MediaInfo {
        guard let data = json.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MediaError.probeFailed("ответ ffprobe не разобран")
        }
        let streams = (root["streams"] as? [[String: Any]]) ?? []
        let format = (root["format"] as? [String: Any]) ?? [:]
        guard !streams.isEmpty || !format.isEmpty else { throw MediaError.probeFailed("пустой ответ ffprobe") }
        var info = MediaInfo()
        if let v = streams.first(where: { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) != 1 }) ?? streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            info.videoCodec = v["codec_name"] as? String
            info.width = (v["width"] as? Int) ?? 0
            info.height = (v["height"] as? Int) ?? 0
            info.fps = fraction(v["avg_frame_rate"]).flatMap { $0 > 0 ? $0 : nil } ?? fraction(v["r_frame_rate"]) ?? 0
            if let tags = v["tags"] as? [String: Any], let r = number(tags["rotate"]) { info.rotation = Int(r) }
            if let side = v["side_data_list"] as? [[String: Any]], let r = side.compactMap({ number($0["rotation"]) }).first { info.rotation = Int(r) }
            if info.duration == 0, let d = number(v["duration"]) { info.duration = d }
        }
        if let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            info.audioCodec = a["codec_name"] as? String
            if info.duration == 0, let d = number(a["duration"]) { info.duration = d }
        }
        if let d = number(format["duration"]) { info.duration = d }
        info.bitrate = Int(number(format["bit_rate"]) ?? 0)
        info.sizeBytes = Int64(number(format["size"]) ?? 0)
        return info
    }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc

    public var title: String { self == .h264 ? "H.264 (совместимо везде)" : "H.265 / HEVC (меньше размер)" }
}

public enum VideoContainer: String, CaseIterable, Sendable {
    case mp4, mov, mkv, webm

    public var fileExtension: String { rawValue }
}

public enum AudioFormat: String, CaseIterable, Sendable {
    case mp3, m4a, flac, wav, opus, ogg

    public var title: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .opus: "Opus"
        case .ogg: "Ogg Vorbis"
        }
    }

    public var isLossless: Bool { self == .flac || self == .wav }
}

public enum ImageTarget: String, CaseIterable, Sendable {
    case png, jpeg, heic, tiff, bmp, gif, webp

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var isLossy: Bool { self == .jpeg || self == .heic || self == .webp }
    public var title: String { rawValue.uppercased() }
}

public enum WatermarkCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    public var title: String {
        switch self {
        case .topLeft: "Слева сверху"
        case .topRight: "Справа сверху"
        case .bottomLeft: "Слева снизу"
        case .bottomRight: "Справа снизу"
        case .center: "По центру"
        }
    }
}

public struct MediaSettings: Equatable, Sendable {
    public var outputFolder = ""
    public var overwriteExisting = false
    public var codec = VideoCodec.h264
    public var quality = 60
    public var preset = "medium"
    public var audioKbps = 128
    public var maxHeight = 0
    public var hardwareEncoder = false
    public var stripMetadata = true
    public var gifFps = 12
    public var gifWidth = 480
    public var imageFormat = ImageTarget.jpeg
    public var imageQuality = 85
    public var imageMaxSide = 0
    public var watermarkCorner = WatermarkCorner.bottomRight
    public var watermarkScale = 20
    public var watermarkOpacity = 70
    public var parallelJobs = 1
    public var notifyWhenDone = true
    public var revealWhenDone = false

    public static let qualityRange = 10...100
    public static let audioRange = 64...320
    public static let gifFpsRange = 1...30
    public static let gifWidthRange = 64...1280
    public static let imageQualityRange = 10...100
    public static let maxSideRange = 0...16000
    public static let watermarkScaleRange = 5...60
    public static let watermarkOpacityRange = 10...100
    public static let parallelRange = 1...3
    public static let presets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower"]

    public init() {}

    public var sanitized: MediaSettings {
        var s = self
        s.quality = ToolsClamp.int(s.quality, MediaSettings.qualityRange)
        s.audioKbps = ToolsClamp.int(s.audioKbps, MediaSettings.audioRange)
        s.gifFps = ToolsClamp.int(s.gifFps, MediaSettings.gifFpsRange)
        s.gifWidth = ToolsClamp.int(s.gifWidth, MediaSettings.gifWidthRange)
        s.imageQuality = ToolsClamp.int(s.imageQuality, MediaSettings.imageQualityRange)
        s.imageMaxSide = ToolsClamp.int(s.imageMaxSide, MediaSettings.maxSideRange)
        s.maxHeight = ToolsClamp.int(s.maxHeight, 0...4320)
        s.watermarkScale = ToolsClamp.int(s.watermarkScale, MediaSettings.watermarkScaleRange)
        s.watermarkOpacity = ToolsClamp.int(s.watermarkOpacity, MediaSettings.watermarkOpacityRange)
        s.parallelJobs = ToolsClamp.int(s.parallelJobs, MediaSettings.parallelRange)
        if !MediaSettings.presets.contains(s.preset) { s.preset = "medium" }
        return s
    }
}

public final class MediaSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> MediaSettings {
        var s = MediaSettings()
        let p = "mediaTools."
        s.outputFolder = a.string(p + "folder") ?? s.outputFolder
        s.overwriteExisting = a.bool(p + "overwrite", s.overwriteExisting)
        if let v = a.string(p + "codec"), let x = VideoCodec(rawValue: v) { s.codec = x }
        s.quality = a.int(p + "quality", s.quality)
        s.preset = a.string(p + "preset") ?? s.preset
        s.audioKbps = a.int(p + "audioKbps", s.audioKbps)
        s.maxHeight = a.int(p + "maxHeight", s.maxHeight)
        s.hardwareEncoder = a.bool(p + "hardware", s.hardwareEncoder)
        s.stripMetadata = a.bool(p + "stripMetadata", s.stripMetadata)
        s.gifFps = a.int(p + "gifFps", s.gifFps)
        s.gifWidth = a.int(p + "gifWidth", s.gifWidth)
        if let v = a.string(p + "imageFormat"), let x = ImageTarget(rawValue: v) { s.imageFormat = x }
        s.imageQuality = a.int(p + "imageQuality", s.imageQuality)
        s.imageMaxSide = a.int(p + "imageMaxSide", s.imageMaxSide)
        if let v = a.string(p + "wmCorner"), let x = WatermarkCorner(rawValue: v) { s.watermarkCorner = x }
        s.watermarkScale = a.int(p + "wmScale", s.watermarkScale)
        s.watermarkOpacity = a.int(p + "wmOpacity", s.watermarkOpacity)
        s.parallelJobs = a.int(p + "parallel", s.parallelJobs)
        s.notifyWhenDone = a.bool(p + "notify", s.notifyWhenDone)
        s.revealWhenDone = a.bool(p + "reveal", s.revealWhenDone)
        return s.sanitized
    }

    public func save(_ settings: MediaSettings) {
        let b = MediaSettings()
        let s = settings.sanitized
        let p = "mediaTools."
        a.put(p + "folder", s.outputFolder, b.outputFolder)
        a.put(p + "overwrite", s.overwriteExisting, b.overwriteExisting)
        a.put(p + "codec", s.codec.rawValue, b.codec.rawValue)
        a.put(p + "quality", s.quality, b.quality)
        a.put(p + "preset", s.preset, b.preset)
        a.put(p + "audioKbps", s.audioKbps, b.audioKbps)
        a.put(p + "maxHeight", s.maxHeight, b.maxHeight)
        a.put(p + "hardware", s.hardwareEncoder, b.hardwareEncoder)
        a.put(p + "stripMetadata", s.stripMetadata, b.stripMetadata)
        a.put(p + "gifFps", s.gifFps, b.gifFps)
        a.put(p + "gifWidth", s.gifWidth, b.gifWidth)
        a.put(p + "imageFormat", s.imageFormat.rawValue, b.imageFormat.rawValue)
        a.put(p + "imageQuality", s.imageQuality, b.imageQuality)
        a.put(p + "imageMaxSide", s.imageMaxSide, b.imageMaxSide)
        a.put(p + "wmCorner", s.watermarkCorner.rawValue, b.watermarkCorner.rawValue)
        a.put(p + "wmScale", s.watermarkScale, b.watermarkScale)
        a.put(p + "wmOpacity", s.watermarkOpacity, b.watermarkOpacity)
        a.put(p + "parallel", s.parallelJobs, b.parallelJobs)
        a.put(p + "notify", s.notifyWhenDone, b.notifyWhenDone)
        a.put(p + "reveal", s.revealWhenDone, b.revealWhenDone)
    }
}

public enum MediaTime {
    // "90", "1:30", "01:02:03.5", "1m30s" -> seconds
    public static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty && Double($0) != nil }) else { return nil }
            var total = 0.0
            for p in parts { total = total * 60 + (Double(p) ?? 0) }
            return total >= 0 ? total : nil
        }
        if let v = Double(t) { return v >= 0 ? v : nil }
        var total = 0.0
        var number = ""
        var seen = false
        for ch in t.lowercased() {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
            seen = true
        }
        return number.isEmpty && seen ? total : nil
    }

    public static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        let sec = s - Double(h * 3600 + m * 60)
        let secText = sec.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%02d", Int(sec)) : String(format: "%04.1f", sec)
        return h > 0 ? String(format: "%d:%02d:", h, m) + secText : String(format: "%d:", m) + secText
    }
}
