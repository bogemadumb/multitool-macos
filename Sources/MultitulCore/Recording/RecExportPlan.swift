import Foundation
import CoreGraphics

public struct RecCompositionPiece: Equatable, Sendable {
    public var srcStart: Double
    public var srcDuration: Double
    public var outStart: Double
    public var outDuration: Double
    public var speed: Double
}

public struct RecAudioChannelPlan: Equatable, Sendable {
    public var kind: RecTrackKind
    public var sourceTrackIndex: Int
    public var gain: Double
}

public struct RecAudioGroup: Equatable, Sendable {
    public var title: String
    public var channels: [RecAudioChannelPlan]
    public var bitrate: Int
}

public struct RecExportPlan: Equatable, Sendable {
    public var preset: RecExportPreset
    public var document: RecEditDocument
    public var pieces: [RecCompositionPiece]
    public var outputDuration: Double
    public var canvas: CGSize
    public var fps: Int
    public var videoBitrate: Int
    public var audioGroups: [RecAudioGroup]
    public var needsCompositor: Bool
    public var gif: RecGifPlan?
    public var estimatedBytes: Int
    public var warnings: [String]

    public var isGif: Bool { preset.kind == .gif }
}

public enum RecExportPlanner {
    public static func pieces(_ t: RecTimeline) -> [RecCompositionPiece] {
        var out: [RecCompositionPiece] = []
        var acc = 0.0
        for s in t.segments {
            out.append(RecCompositionPiece(srcStart: s.srcStart, srcDuration: s.srcDuration, outStart: acc, outDuration: s.outDuration, speed: s.speed))
            acc += s.outDuration
        }
        return out
    }

    public static func needsCompositor(_ doc: RecEditDocument, hasLog: Bool) -> Bool {
        !doc.crop.isFull || !doc.style.isPlain || !doc.blurs.isEmpty || (doc.zoomEnabled && !doc.zoom.spans.isEmpty) || (doc.style.highlightClicks && hasLog)
    }

    public static func make(document raw: RecEditDocument, preset rawPreset: RecExportPreset, hasInputLog: Bool = false) -> RecExportPlan {
        let preset = rawPreset.sanitized
        var doc = raw
        doc.style = raw.style.sanitized
        doc.crop = raw.crop.sanitized
        var warnings: [String] = []
        let pcs = pieces(doc.timeline)
        let duration = doc.timeline.outputDuration
        let cap = preset.maxLongSide > 0 ? preset.maxLongSide : nil
        var canvas = RecLayoutMath.canvasSize(source: doc.source, crop: doc.crop, style: doc.style, maxLongSide: cap)
        if preset.kind == .gif {
            let g = RecGifPlanner.targetSize(width: Int(canvas.width), height: Int(canvas.height), maxWidth: preset.gif.maxWidth)
            canvas = CGSize(width: RecGeometry.even(Double(g.width)), height: RecGeometry.even(Double(g.height)))
        }
        let fps = preset.fps > 0 ? min(preset.fps, max(doc.source.fps, 1)) : max(doc.source.fps, 1)
        let bitrate = RecEstimate.videoBitrate(width: Int(canvas.width), height: Int(canvas.height), fps: fps, quality: preset.quality, codec: preset.codec)
        var groups: [RecAudioGroup] = []
        if preset.kind == .video, preset.includeAudio {
            var channels: [RecAudioChannelPlan] = []
            var idx = 0
            if doc.source.hasSystemAudio {
                channels.append(RecAudioChannelPlan(kind: .systemAudio, sourceTrackIndex: idx, gain: doc.audio.gain(.systemAudio)))
                idx += 1
            }
            if doc.source.hasMicrophone {
                channels.append(RecAudioChannelPlan(kind: .microphone, sourceTrackIndex: idx, gain: doc.audio.gain(.microphone)))
            }
            let live = channels.filter { $0.gain > 0.0001 }
            if live.isEmpty {
                if !channels.isEmpty { warnings.append("Все дорожки звука выключены: в файле будет тишина без звуковой дорожки") }
            } else if preset.separateTracks {
                groups = live.map { RecAudioGroup(title: $0.kind.title, channels: [$0], bitrate: RecTrackLayout.audioBitrate($0.kind, quality: preset.quality)) }
            } else {
                groups = [RecAudioGroup(title: "Звук", channels: live, bitrate: RecTrackLayout.audioBitrate(.systemAudio, quality: preset.quality))]
            }
        }
        if doc.timeline.segments.isEmpty { warnings.append("В записи не осталось ни одного фрагмента") }
        var gifPlan: RecGifPlan?
        var bytes = 0
        if preset.kind == .gif {
            let p = RecGifPlanner.plan(outputDuration: duration, sourceWidth: Int(canvas.width), sourceHeight: Int(canvas.height), options: preset.gif)
            gifPlan = p
            bytes = RecEstimate.gifBytes(width: p.width, height: p.height, frames: p.times.count, colors: preset.gif.colors)
            if p.truncated { warnings.append("GIF длиннее лимита кадров: будет обрезан") }
        } else {
            bytes = Int((duration * (Double(bitrate) + Double(groups.reduce(0) { $0 + $1.bitrate })) / 8 * 1.02).rounded())
        }
        return RecExportPlan(preset: preset, document: doc, pieces: pcs, outputDuration: duration, canvas: canvas, fps: fps, videoBitrate: bitrate, audioGroups: groups,
                             needsCompositor: needsCompositor(doc, hasLog: hasInputLog), gif: gifPlan, estimatedBytes: bytes, warnings: warnings)
    }
}

public struct RecBlurDraw: Equatable, Sendable {
    public var rect: CGRect
    public var strength: Double
    public var pixelate: Bool
}

public struct RecRippleDraw: Equatable, Sendable {
    public var center: CGPoint
    public var radius: Double
    public var alpha: Double
    public var color: ShotColor
    public var button: RecButton
}

public struct RecFrameParams: Equatable, Sendable {
    public var outputTime: Double
    public var sourceTime: Double
    public var layout: RecFrameLayout
    public var zoom: RecZoomSample
    public var blurs: [RecBlurDraw]
    public var ripples: [RecRippleDraw]
    public var background: ShotBackground
}

public enum RecFrameParamsBuilder {
    public static let rippleLifetime = 0.6

    public static func make(document doc: RecEditDocument, log: RecInputLog?, outputTime: Double, maxLongSide: Int? = nil, canvas: CGSize? = nil) -> RecFrameParams {
        let src = doc.timeline.outputToSource(outputTime)
        let zoom = doc.zoomEnabled ? doc.zoom.sample(at: src) : RecZoomSample.identity
        var layout = RecLayoutMath.layout(source: doc.source, crop: doc.crop, style: doc.style, zoom: zoom, maxLongSide: maxLongSide)
        if let c = canvas, c != layout.canvas, layout.canvas.width > 0 {
            let k = Double(c.width) / Double(layout.canvas.width)
            layout.destRect = CGRect(x: layout.destRect.minX * k, y: layout.destRect.minY * k, width: layout.destRect.width * k, height: layout.destRect.height * k)
            layout.cornerRadius *= k
            layout.canvas = c
        }
        let blurs: [RecBlurDraw] = doc.blurs.compactMap { b in
            guard b.isActive(at: src), let r = layout.map(rect: b.rect) else { return nil }
            return RecBlurDraw(rect: r, strength: b.strength, pixelate: b.pixelate)
        }
        var ripples: [RecRippleDraw] = []
        if doc.style.highlightClicks, let log {
            let color = ShotColor(hex: doc.style.clickColor) ?? ShotColor(255, 214, 10)
            let base = doc.style.clickRadius * Double(layout.destRect.width)
            for r in log.ripples(at: src, lifetime: rippleLifetime) {
                guard let c = layout.map(normalized: CGPoint(x: r.x, y: r.y)) else { continue }
                let e = RecEase.out.apply(r.progress)
                ripples.append(RecRippleDraw(center: c, radius: base * (0.35 + 1.15 * e), alpha: 1 - r.progress, color: color, button: r.button))
            }
        }
        return RecFrameParams(outputTime: outputTime, sourceTime: src, layout: layout, zoom: zoom, blurs: blurs, ripples: ripples, background: doc.style.backgroundValue)
    }
}
