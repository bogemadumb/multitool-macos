import Foundation

public struct FfmpegInvocation: Equatable, Sendable {
    public var arguments: [String]
    public var duration: Double?
    public var note: String

    public init(arguments: [String], duration: Double? = nil, note: String = "") {
        self.arguments = arguments
        self.duration = duration
        self.note = note
    }
}

public struct VideoCompressOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case quality(Int)
        case targetSize(Int64)
    }

    public var mode = Mode.quality(60)
    public var codec = VideoCodec.h264
    public var container = VideoContainer.mp4
    public var preset = "medium"
    public var audioKbps = 128
    public var maxHeight = 0
    public var hardware = false
    public var stripMetadata = true

    public init() {}

    public init(settings s: MediaSettings, mode: Mode? = nil) {
        self.mode = mode ?? .quality(s.quality)
        codec = s.codec
        preset = s.preset
        audioKbps = s.audioKbps
        maxHeight = s.maxHeight
        hardware = s.hardwareEncoder
        stripMetadata = s.stripMetadata
    }
}

public struct TrimOptions: Equatable, Sendable {
    public var start: Double
    public var end: Double?
    public var reencode: Bool

    public init(start: Double, end: Double? = nil, reencode: Bool = false) {
        self.start = start
        self.end = end
        self.reencode = reencode
    }
}

public struct GifOptions: Equatable, Sendable {
    public var fps = 12
    public var width = 480
    public var start = 0.0
    public var duration = 5.0
    public var loop = true

    public init() {}
}

public struct WatermarkOptions: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case image(String)
        case text(String)
    }

    public var source: Source
    public var corner = WatermarkCorner.bottomRight
    public var margin = 24
    public var scalePercent = 20
    public var opacityPercent = 70
    public var fontFile = "/System/Library/Fonts/Helvetica.ttc"

    public init(source: Source) { self.source = source }
}

public struct ImageConvertOptions: Equatable, Sendable {
    public var format = ImageTarget.jpeg
    public var quality = 85
    public var maxSide = 0
    public var stripMetadata = true

    public init() {}

    public init(settings s: MediaSettings) {
        format = s.imageFormat
        quality = s.imageQuality
        maxSide = s.imageMaxSide
        stripMetadata = s.stripMetadata
    }
}

public struct TargetSizePlan: Equatable, Sendable {
    public var videoBitrate: Int
    public var height: Int?
    public var width: Int?
}

public enum TargetSizePlanner {
    public static let ladder = [2160, 1440, 1080, 720, 540, 480, 360, 240]
    public static let minimumVideoBitrate = 60_000
    public static let overheadFactor = 0.93

    // Bits per pixel per frame that still looks acceptable for the codec.
    public static func minimumBitsPerPixel(_ codec: VideoCodec) -> Double { codec == .h264 ? 0.05 : 0.035 }

    public static func plan(info: MediaInfo, targetBytes: Int64, audioKbps: Int, codec: VideoCodec, maxHeight: Int) throws -> TargetSizePlan {
        guard info.hasVideo else { throw MediaError.noVideoStream }
        guard info.duration > 0 else { throw MediaError.invalidOptions("неизвестная длительность") }
        guard targetBytes > 0 else { throw MediaError.invalidOptions("размер должен быть больше нуля") }
        let audioBps = info.hasAudio ? audioKbps * 1000 : 0
        let total = Double(targetBytes) * 8 * overheadFactor / info.duration
        let video = Int(total) - audioBps
        guard video >= minimumVideoBitrate else {
            let needBytes = Int64((Double(minimumVideoBitrate + audioBps) * info.duration) / 8 / overheadFactor)
            throw MediaError.targetTooSmall(minimumBytes: needBytes)
        }
        let srcW = max(info.displayWidth, 2), srcH = max(info.displayHeight, 2)
        let fps = info.fps > 0 ? info.fps : 30
        let cap = maxHeight > 0 ? min(maxHeight, srcH) : srcH
        let bppMin = minimumBitsPerPixel(codec)
        var chosen: Int?
        let candidates = [cap] + ladder.filter { $0 < cap }
        for h in candidates {
            let w = Double(srcW) * Double(h) / Double(srcH)
            if Double(video) / (w * Double(h) * fps) >= bppMin { chosen = h; break }
        }
        let h = chosen ?? candidates.last ?? cap
        let resized = h < srcH
        let w = resized ? Int((Double(srcW) * Double(h) / Double(srcH) / 2).rounded()) * 2 : nil
        return TargetSizePlan(videoBitrate: video, height: resized ? h : nil, width: w)
    }
}

public enum FfmpegEscape {
    // drawtext text (expansion=none): backslash, quote, colon and comma need two levels of escaping inside a filtergraph.
    public static func drawtext(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\\\\\"
            case "'": out += "\\\\\\'"
            case ":": out += "\\\\:"
            case ",": out += "\\,"
            case "\n", "\r": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    public static func fontPath(_ p: String) -> String {
        p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "\\'")
    }
}

public enum FfmpegArgs {
    public static let prefix = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats"]

    public static func number(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public static func crf(forQuality quality: Int, codec: VideoCodec) -> Int {
        let q = ToolsClamp.int(quality, 1...100)
        let base = Int((36.0 - Double(q) / 100.0 * 18.0).rounded())
        return codec == .hevc ? base + 4 : base
    }

    private static func videoCodecArgs(_ o: VideoCompressOptions, plan: TargetSizePlan?) -> [String] {
        var a: [String] = []
        switch (o.hardware, o.codec) {
        case (false, .h264): a += ["-c:v", "libx264", "-preset", o.preset, "-pix_fmt", "yuv420p"]
        case (false, .hevc): a += ["-c:v", "libx265", "-preset", o.preset, "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
        case (true, .h264): a += ["-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p"]
        case (true, .hevc): a += ["-c:v", "hevc_videotoolbox", "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
        }
        switch o.mode {
        case .quality(let q):
            if o.hardware { a += ["-q:v", String(ToolsClamp.int(q, 1...100))] } else { a += ["-crf", String(crf(forQuality: q, codec: o.codec))] }
        case .targetSize:
            let b = plan?.videoBitrate ?? 1_000_000
            a += ["-b:v", String(b), "-maxrate", String(Int(Double(b) * 1.3)), "-bufsize", String(b * 2)]
        }
        return a
    }

    public static func compress(input: String, output: String, info: MediaInfo, options o: VideoCompressOptions) throws -> FfmpegInvocation {
        guard info.hasVideo else { throw MediaError.noVideoStream }
        guard o.container != .webm else { throw MediaError.invalidOptions("WebM не поддержан для сжатия") }
        var plan: TargetSizePlan?
        var height: Int?
        switch o.mode {
        case .quality:
            if o.maxHeight > 0 && info.displayHeight > o.maxHeight { height = o.maxHeight }
        case .targetSize(let bytes):
            let p = try TargetSizePlanner.plan(info: info, targetBytes: bytes, audioKbps: o.audioKbps, codec: o.codec, maxHeight: o.maxHeight)
            plan = p
            height = p.height
        }
        var a = prefix + ["-i", input, "-map", "0:v:0", "-map", "0:a:0?"]
        a += ["-vf", height.map { "scale=-2:\($0)" } ?? "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        a += videoCodecArgs(o, plan: plan)
        a += info.hasAudio ? ["-c:a", "aac", "-b:a", "\(o.audioKbps)k"] : ["-an"]
        if o.stripMetadata { a += ["-map_metadata", "-1"] }
        if o.container != .mkv { a += ["-movflags", "+faststart"] }
        a.append(output)
        return FfmpegInvocation(arguments: a, duration: info.duration > 0 ? info.duration : nil,
                                note: plan.map { "\($0.videoBitrate / 1000) кбит/с" + ($0.height.map { ", \($0) p" } ?? "") } ?? "")
    }

    public static func trim(input: String, output: String, info: MediaInfo?, options o: TrimOptions) throws -> FfmpegInvocation {
        guard o.start >= 0 else { throw MediaError.invalidTrim("начало меньше нуля") }
        if let e = o.end, e <= o.start { throw MediaError.invalidTrim("конец раньше начала") }
        let total = info?.duration ?? 0
        if total > 0 && o.start >= total { throw MediaError.invalidTrim("начало за пределами файла") }
        var length: Double?
        if let e = o.end { length = e - o.start } else if total > 0 { length = total - o.start }
        if let l = length, total > 0 { length = min(l, total - o.start) }
        var a = prefix
        if o.start > 0 { a += ["-ss", number(o.start)] }
        a += ["-i", input]
        if let l = length { a += ["-t", number(l)] }
        let hasVideo = info?.hasVideo ?? true
        if o.reencode {
            if hasVideo {
                a += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
            }
        } else {
            a += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        a.append(output)
        return FfmpegInvocation(arguments: a, duration: length, note: o.reencode ? "с перекодированием" : "без перекодирования, по ключевым кадрам")
    }

    public static func gif(input: String, output: String, info: MediaInfo, options o: GifOptions) throws -> FfmpegInvocation {
        guard info.hasVideo else { throw MediaError.noVideoStream }
        guard o.start >= 0 else { throw MediaError.invalidTrim("начало меньше нуля") }
        if info.duration > 0 && o.start >= info.duration { throw MediaError.invalidTrim("начало за пределами файла") }
        let fps = ToolsClamp.int(o.fps, MediaSettings.gifFpsRange)
        var width = ToolsClamp.int(o.width, MediaSettings.gifWidthRange)
        if info.displayWidth > 0 { width = min(width, info.displayWidth) }
        var length = ToolsClamp.double(o.duration, 0.5...60)
        if info.duration > 0 { length = min(length, info.duration - o.start) }
        let graph = "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        var a = prefix
        if o.start > 0 { a += ["-ss", number(o.start)] }
        a += ["-t", number(length), "-i", input, "-filter_complex", graph, "-an", "-loop", o.loop ? "0" : "-1", output]
        return FfmpegInvocation(arguments: a, duration: length, note: "\(fps) к/с, \(width) пикс.")
    }

    static func overlayPosition(_ corner: WatermarkCorner, margin m: Int) -> (x: String, y: String) {
        switch corner {
        case .topLeft: ("\(m)", "\(m)")
        case .topRight: ("main_w-overlay_w-\(m)", "\(m)")
        case .bottomLeft: ("\(m)", "main_h-overlay_h-\(m)")
        case .bottomRight: ("main_w-overlay_w-\(m)", "main_h-overlay_h-\(m)")
        case .center: ("(main_w-overlay_w)/2", "(main_h-overlay_h)/2")
        }
    }

    static func textPosition(_ corner: WatermarkCorner, margin m: Int) -> (x: String, y: String) {
        switch corner {
        case .topLeft: ("\(m)", "\(m)")
        case .topRight: ("w-text_w-\(m)", "\(m)")
        case .bottomLeft: ("\(m)", "h-text_h-\(m)")
        case .bottomRight: ("w-text_w-\(m)", "h-text_h-\(m)")
        case .center: ("(w-text_w)/2", "(h-text_h)/2")
        }
    }

    public static func watermark(input: String, output: String, info: MediaInfo, options o: WatermarkOptions, video: VideoCompressOptions = VideoCompressOptions()) throws -> FfmpegInvocation {
        guard info.hasVideo else { throw MediaError.noVideoStream }
        let scale = Double(ToolsClamp.int(o.scalePercent, MediaSettings.watermarkScaleRange)) / 100
        let opacity = Double(ToolsClamp.int(o.opacityPercent, MediaSettings.watermarkOpacityRange)) / 100
        let isImage = MediaFormats.kind(of: output) == .image
        var a = prefix + ["-i", input]
        var videoMap: [String]
        switch o.source {
        case .image(let wm):
            guard !wm.isEmpty else { throw MediaError.invalidOptions("не выбрана картинка водяного знака") }
            let w = max(8, Int((Double(info.displayWidth) * scale / 2).rounded()) * 2)
            let pos = overlayPosition(o.corner, margin: o.margin)
            let graph = "[1:v]scale=\(w):-1,format=rgba,colorchannelmixer=aa=\(number(opacity))[wm];[0:v][wm]overlay=\(pos.x):\(pos.y)[out]"
            a += ["-i", wm, "-filter_complex", graph]
            videoMap = ["-map", "[out]"]
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MediaError.invalidOptions("пустой текст водяного знака") }
            let size = max(10, Int(Double(min(info.displayWidth, info.displayHeight)) * scale * 0.4))
            let pos = textPosition(o.corner, margin: o.margin)
            let filter = "drawtext=fontfile=\(FfmpegEscape.fontPath(o.fontFile)):expansion=none:text=\(FfmpegEscape.drawtext(text)):fontsize=\(size):fontcolor=white@\(number(opacity)):x=\(pos.x):y=\(pos.y):shadowcolor=black@0.4:shadowx=1:shadowy=1"
            a += ["-vf", filter]
            videoMap = ["-map", "0:v:0"]
        }
        a += videoMap
        if isImage {
            a += ["-frames:v", "1"]
            let ext = (output as NSString).pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" { a += ["-q:v", "2"] }
        } else {
            a += ["-map", "0:a:0?"]
            a += videoCodecArgs(video, plan: nil)
            a += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
            if video.stripMetadata { a += ["-map_metadata", "-1"] }
            a += ["-movflags", "+faststart"]
        }
        a.append(output)
        return FfmpegInvocation(arguments: a, duration: isImage ? nil : (info.duration > 0 ? info.duration : nil))
    }

    public static func audioCodecArgs(_ f: AudioFormat, kbps: Int) -> [String] {
        let k = "\(ToolsClamp.int(kbps, MediaSettings.audioRange))k"
        switch f {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", k]
        case .m4a: return ["-c:a", "aac", "-b:a", k]
        case .flac: return ["-c:a", "flac"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .opus: return ["-c:a", "libopus", "-b:a", k]
        case .ogg: return ["-c:a", "libvorbis", "-b:a", k]
        }
    }

    public static func audio(input: String, output: String, info: MediaInfo?, format: AudioFormat, kbps: Int, stripMetadata: Bool = true) throws -> FfmpegInvocation {
        if let info, !info.hasAudio { throw MediaError.unsupportedInput("в файле нет звука") }
        var a = prefix + ["-i", input, "-vn", "-map", "0:a:0"]
        a += audioCodecArgs(format, kbps: kbps)
        if stripMetadata { a += ["-map_metadata", "-1"] }
        a.append(output)
        return FfmpegInvocation(arguments: a, duration: (info?.duration ?? 0) > 0 ? info?.duration : nil)
    }

    public static func convertVideo(input: String, output: String, info: MediaInfo, container: VideoContainer, settings s: MediaSettings = MediaSettings()) throws -> FfmpegInvocation {
        guard info.hasVideo else { throw MediaError.noVideoStream }
        var a = prefix + ["-i", input, "-map", "0:v:0", "-map", "0:a:0?"]
        switch container {
        case .mp4, .mov:
            a += ["-c:v", "libx264", "-preset", s.preset, "-crf", String(crf(forQuality: s.quality, codec: .h264)), "-pix_fmt", "yuv420p",
                  "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:a", "aac", "-b:a", "\(s.audioKbps)k", "-movflags", "+faststart"]
        case .webm:
            a += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus", "-b:a", "\(s.audioKbps)k"]
        case .mkv:
            a += ["-c", "copy"]
        }
        if s.stripMetadata { a += ["-map_metadata", "-1"] }
        a.append(output)
        return FfmpegInvocation(arguments: a, duration: info.duration > 0 ? info.duration : nil)
    }

    // Used for WebP (ImageIO cannot write it) and as the fallback when ImageIO fails on an input.
    public static func convertImage(input: String, output: String, info: MediaInfo?, options o: ImageConvertOptions) -> FfmpegInvocation {
        var a = prefix + ["-i", input]
        if o.maxSide > 0, let info, max(info.width, info.height) > o.maxSide {
            let ratio = Double(o.maxSide) / Double(max(info.width, info.height))
            let w = max(1, Int((Double(info.width) * ratio).rounded())), h = max(1, Int((Double(info.height) * ratio).rounded()))
            a += ["-vf", "scale=\(w):\(h):flags=lanczos"]
        }
        a += ["-frames:v", "1"]
        let q = ToolsClamp.int(o.quality, MediaSettings.imageQualityRange)
        switch o.format {
        case .webp: a += ["-c:v", "libwebp", "-quality", String(q)]
        case .jpeg: a += ["-q:v", String(ToolsClamp.int(Int((31.0 - Double(q) * 0.29).rounded()), 2...31))]
        case .png: a += ["-c:v", "png"]
        case .tiff: a += ["-c:v", "tiff"]
        case .bmp: a += ["-c:v", "bmp"]
        case .gif: a += ["-c:v", "gif"]
        case .heic: break
        }
        if o.stripMetadata { a += ["-map_metadata", "-1"] }
        a.append(output)
        return FfmpegInvocation(arguments: a)
    }

    public static func frame(input: String, at seconds: Double, output: String) -> FfmpegInvocation {
        var a = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        if seconds > 0 { a += ["-ss", number(seconds)] }
        a += ["-i", input, "-frames:v", "1", output]
        return FfmpegInvocation(arguments: a)
    }
}
