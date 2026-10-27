import Foundation
import CoreGraphics

public enum RecCaptureTarget: Equatable, Sendable {
    case display(id: UInt32, sourceRect: CGRect?)
    case window(id: UInt32)
}

public struct RecCapturePlan: Equatable, Sendable {
    public var mode: RecMode
    public var target: RecCaptureTarget
    public var pointRect: CGRect
    public var scale: CGFloat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var clippedToDisplay: Bool

    public var isEmpty: Bool { pixelWidth < RecGeometry.minPixel || pixelHeight < RecGeometry.minPixel }
    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}

public enum RecGeometry {
    public static let minPixel = 16
    public static let maxPixel = 8192

    public static func even(_ v: Double) -> Int {
        let n = Int(v.rounded(.down))
        return max(n - (n % 2), 2)
    }

    public static func pixelSize(points: CGSize, scale: CGFloat, resolution: RecResolution) -> (width: Int, height: Int) {
        guard points.width > 0, points.height > 0 else { return (0, 0) }
        let k = resolution == .oneX ? 1 : max(scale, 1)
        var w = Double(points.width * k)
        var h = Double(points.height * k)
        if let cap = resolution.maxLongSide {
            let longest = max(w, h)
            if longest > Double(cap) {
                let f = Double(cap) / longest
                w *= f
                h *= f
            }
        }
        let hard = Double(maxPixel)
        if max(w, h) > hard {
            let f = hard / max(w, h)
            w *= f
            h *= f
        }
        return (even(w), even(h))
    }

    public static func plan(mode: RecMode, rect: CGRect, windowID: UInt32? = nil, displays: [ShotDisplay], resolution: RecResolution) -> RecCapturePlan? {
        let r = rect.standardized
        guard !displays.isEmpty, r.width > 0, r.height > 0 else { return nil }
        switch mode {
        case .display:
            let center = CGPoint(x: r.midX, y: r.midY)
            guard let d = ShotSpace.display(containing: center, in: displays) else { return nil }
            let px = pixelSize(points: d.frame.size, scale: d.scale, resolution: resolution)
            return RecCapturePlan(mode: mode, target: .display(id: d.id, sourceRect: nil), pointRect: d.frame, scale: d.scale, pixelWidth: px.width, pixelHeight: px.height, clippedToDisplay: false)
        case .window:
            guard let windowID else { return nil }
            let center = CGPoint(x: r.midX, y: r.midY)
            let scale = ShotSpace.display(containing: center, in: displays)?.scale ?? 2
            let px = pixelSize(points: r.size, scale: scale, resolution: resolution)
            return RecCapturePlan(mode: mode, target: .window(id: windowID), pointRect: r, scale: scale, pixelWidth: px.width, pixelHeight: px.height, clippedToDisplay: false)
        case .area:
            let hits = displays.compactMap { d -> (ShotDisplay, CGRect)? in
                let i = r.intersection(d.frame)
                return i.isNull || i.width < 1 || i.height < 1 ? nil : (d, i)
            }
            guard let best = hits.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else { return nil }
            let d = best.0, i = best.1
            let local = CGRect(x: i.minX - d.frame.minX, y: i.minY - d.frame.minY, width: i.width, height: i.height)
            let px = pixelSize(points: i.size, scale: d.scale, resolution: resolution)
            return RecCapturePlan(mode: mode, target: .display(id: d.id, sourceRect: local), pointRect: i, scale: d.scale, pixelWidth: px.width, pixelHeight: px.height,
                                  clippedToDisplay: hits.count > 1 || i != r)
        }
    }
}

public struct RecTrackSpec: Equatable, Sendable {
    public var kind: RecTrackKind
    public var title: String
    public var sampleRate: Int
    public var channels: Int
    public var bitrate: Int
}

public struct RecTrackLayout: Equatable, Sendable {
    public var tracks: [RecTrackSpec]
    public var warnings: [String]

    public var enabled: Set<RecTrackKind> { Set(tracks.map(\.kind)) }
    public var audioTracks: [RecTrackSpec] { tracks.filter { $0.kind.isAudio } }
    public var hasAudio: Bool { !audioTracks.isEmpty }
    public func index(of kind: RecTrackKind) -> Int? { tracks.firstIndex { $0.kind == kind } }

    public static func audioBitrate(_ kind: RecTrackKind, quality: RecQuality) -> Int {
        switch (kind, quality) {
        case (.microphone, .low): 64_000
        case (.microphone, .medium): 96_000
        case (.microphone, .high): 128_000
        case (.microphone, .max): 192_000
        case (_, .low): 96_000
        case (_, .medium): 128_000
        case (_, .high): 160_000
        case (_, .max): 256_000
        }
    }

    public static func make(settings s: RecSettings, micAvailable: Bool, systemAudioAvailable: Bool = true) -> RecTrackLayout {
        var tracks = [RecTrackSpec(kind: .video, title: RecTrackKind.video.title, sampleRate: 0, channels: 0, bitrate: 0)]
        var warnings: [String] = []
        if s.systemAudio {
            if systemAudioAvailable {
                tracks.append(RecTrackSpec(kind: .systemAudio, title: RecTrackKind.systemAudio.title, sampleRate: 48_000, channels: 2,
                                           bitrate: audioBitrate(.systemAudio, quality: s.quality)))
            } else {
                warnings.append("Звук системы недоступен: запись без него")
            }
        }
        if s.microphone {
            if micAvailable {
                tracks.append(RecTrackSpec(kind: .microphone, title: RecTrackKind.microphone.title, sampleRate: 48_000, channels: 2,
                                           bitrate: audioBitrate(.microphone, quality: s.quality)))
            } else {
                warnings.append("Микрофон недоступен: запись без него")
            }
        }
        return RecTrackLayout(tracks: tracks, warnings: warnings)
    }
}

public enum RecEstimate {
    public static let minBitrate = 400_000
    public static let maxBitrate = 80_000_000

    public static func videoBitrate(width: Int, height: Int, fps: Int, quality: RecQuality, codec: RecCodec) -> Int {
        guard width > 0, height > 0, fps > 0 else { return minBitrate }
        let fpsFactor = pow(Double(fps) / 30, 0.8)
        let raw = Double(width * height) * 30 * quality.bitsPerPixel * codec.efficiency * fpsFactor
        return min(max(Int(raw.rounded()), minBitrate), maxBitrate)
    }

    public static func bytesPerSecond(videoBitrate: Int, layout: RecTrackLayout) -> Double {
        let audio = layout.audioTracks.reduce(0) { $0 + $1.bitrate }
        return Double(videoBitrate + audio) / 8
    }

    public static func bytes(seconds: Double, videoBitrate: Int, layout: RecTrackLayout) -> Int {
        Int((max(seconds, 0) * bytesPerSecond(videoBitrate: videoBitrate, layout: layout) * 1.02).rounded())
    }

    public static func secondsFitting(freeBytes: Int, reserveBytes: Int, videoBitrate: Int, layout: RecTrackLayout) -> Double {
        let room = Double(max(freeBytes - reserveBytes, 0))
        let bps = bytesPerSecond(videoBitrate: videoBitrate, layout: layout) * 1.02
        return bps > 0 ? room / bps : 0
    }

    public static func gifBytes(width: Int, height: Int, frames: Int, colors: Int = 256) -> Int {
        let bits = max(Int(ceil(log2(Double(max(colors, 2))))), 1)
        let perFrame = Double(width * height) * Double(bits) / 8 * 0.35
        return Int(perFrame * Double(max(frames, 0))) + 800
    }
}

public enum RecGuard {
    public enum Verdict: Equatable, Sendable {
        case ok
        case lowDisk
        case durationLimit
    }

    public static func check(elapsed: Double, maxMinutes: Int, freeBytes: Int?, minFreeMegabytes: Int) -> Verdict {
        if maxMinutes > 0, elapsed >= Double(maxMinutes) * 60 { return .durationLimit }
        if let free = freeBytes, minFreeMegabytes > 0, free < minFreeMegabytes * 1_000_000 { return .lowDisk }
        return .ok
    }
}
