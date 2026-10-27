import Foundation

public struct FfmpegProgressSample: Equatable, Sendable {
    public var frame: Int = 0
    public var fps: Double = 0
    public var bitrateKbps: Double?
    public var totalSize: Int64 = 0
    public var outTime: Double = 0
    public var speed: Double?
    public var dropped: Int = 0
    public var isEnd = false

    public init() {}

    public func fraction(duration: Double?) -> Double? {
        guard let d = duration, d > 0 else { return isEnd ? 1 : nil }
        return isEnd ? 1 : min(max(outTime / d, 0), 1)
    }

    public func remaining(duration: Double?) -> Double? {
        guard let d = duration, d > 0, let s = speed, s > 0, !isEnd else { return nil }
        return max(d - outTime, 0) / s
    }
}

// Reads the key=value blocks of `ffmpeg -progress pipe:1`; a block is closed by a `progress=` line.
public struct FfmpegProgressParser {
    private var current = FfmpegProgressSample()

    public init() {}

    // "00:01:02.500000" -> 62.5
    public static func clock(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-") || t == "N/A" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    public mutating func feed(_ line: String) -> FfmpegProgressSample? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "frame": current.frame = Int(value) ?? current.frame
        case "fps": current.fps = Double(value) ?? 0
        case "bitrate":
            let n = value.replacingOccurrences(of: "kbits/s", with: "").trimmingCharacters(in: .whitespaces)
            current.bitrateKbps = Double(n)
        case "total_size": current.totalSize = Int64(value) ?? current.totalSize
        case "out_time_us", "out_time_ms":
            if let v = Double(value), v >= 0 { current.outTime = v / 1_000_000 }
        case "out_time":
            if let t = Self.clock(value) { current.outTime = t }
        case "drop_frames": current.dropped = Int(value) ?? current.dropped
        case "speed":
            let n = value.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
            current.speed = Double(n)
        case "progress":
            var done = current
            done.isEnd = value == "end"
            current = FfmpegProgressSample()
            return done
        default: break
        }
        return nil
    }
}

public struct YtDlpProgress: Equatable, Sendable {
    public var percent: Double
    public var speed: String
    public var eta: String
}

public enum YtDlpArgs {
    public static let progressTemplate = "download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"

    public static func validURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.hasPrefix("-"), let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    public enum Mode: Equatable, Sendable {
        case bestVideo
        case maxHeight(Int)
        case audio(AudioFormat)
    }

    public static func download(url: String, folder: String, mode: Mode, ffmpegDirectory: String?) throws -> [String] {
        guard validURL(url) != nil else { throw MediaError.invalidURL(url) }
        guard !folder.isEmpty else { throw MediaError.invalidOptions("не выбрана папка") }
        var a = ["--no-playlist", "--newline", "--no-colors", "--progress", "--progress-template", progressTemplate, "-P", folder, "-o", "%(title).150B [%(id)s].%(ext)s"]
        switch mode {
        case .bestVideo: a += ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        case .maxHeight(let h): a += ["-f", "bv*[height<=\(ToolsClamp.int(h, 144...4320))]+ba/b[height<=\(ToolsClamp.int(h, 144...4320))]", "--merge-output-format", "mp4"]
        case .audio(let f): a += ["-x", "--audio-format", f == .m4a ? "m4a" : f.rawValue, "--audio-quality", "0"]
        }
        if let d = ffmpegDirectory, !d.isEmpty { a += ["--ffmpeg-location", d] }
        a += ["--", url.trimmingCharacters(in: .whitespacesAndNewlines)]
        return a
    }

    // "download:  45.3%|1.20MiB/s|00:05"
    public static func parseProgress(_ line: String) -> YtDlpProgress? {
        guard line.hasPrefix("download:") else { return nil }
        let body = line.dropFirst("download:".count)
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return nil }
        let pct = parts[0].replacingOccurrences(of: "%", with: "")
        guard let p = Double(pct) else { return nil }
        return YtDlpProgress(percent: min(max(p, 0), 100), speed: parts[1], eta: parts[2])
    }

    // "[download] Destination: /path/file.mp4" and "[Merger] Merging formats into ..."
    public static func destination(in line: String) -> String? {
        for marker in ["[download] Destination: ", "[Merger] Merging formats into \"", "[ExtractAudio] Destination: "] {
            if line.hasPrefix(marker) {
                var rest = String(line.dropFirst(marker.count))
                if rest.hasSuffix("\"") { rest.removeLast() }
                return rest
            }
        }
        return nil
    }
}
