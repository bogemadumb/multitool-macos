import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics

public final class RecFrameRenderer {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var backdropKey = ""
    private var backdropImage: CIImage?
    private var maskKey = ""
    private var maskImage: CIImage?
    private let space = CGColorSpace(name: CGColorSpace.sRGB)

    public init() {}

    private func flip(_ r: CGRect, _ h: CGFloat) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }

    private func cgImageToCI(_ draw: (CGContext) -> Void, width: Int, height: Int) -> CIImage? {
        guard width > 0, height > 0, let ctx = ShotRenderer.makeContext(width, height, data: nil) else { return nil }
        draw(ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    func backdrop(for p: RecFrameParams) -> CIImage? {
        let l = p.layout
        let key = "\(Int(l.canvas.width))x\(Int(l.canvas.height))|\(p.background.stored)|\(l.destRect)|\(l.cornerRadius)|\(l.shadow)"
        if key == backdropKey, let b = backdropImage { return b }
        let w = Int(l.canvas.width), h = Int(l.canvas.height)
        let img = cgImageToCI({ ctx in
            switch p.background {
            case .none:
                ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            case .solid(let c):
                ctx.setFillColor(ShotRenderer.cgColor(c))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            case .gradient(let a, let b, let angle):
                ctx.setFillColor(ShotRenderer.cgColor(a))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [ShotRenderer.cgColor(a), ShotRenderer.cgColor(b)] as CFArray, locations: [0, 1]) {
                    let ends = ShotBackdropMath.gradientEndpoints(angleDegrees: angle, in: l.canvas)
                    ctx.drawLinearGradient(g, start: ends.start, end: ends.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            if l.shadow {
                let r = self.flip(l.destRect, CGFloat(h))
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -r.height * 0.02 - 6), blur: max(r.width, r.height) * 0.03 + 12, color: CGColor(gray: 0, alpha: 0.4))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: CGFloat(l.cornerRadius), cornerHeight: CGFloat(l.cornerRadius), transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }, width: w, height: h)
        backdropKey = key
        backdropImage = img
        return img
    }

    func mask(for l: RecFrameLayout) -> CIImage? {
        guard l.cornerRadius > 0.5 else { return nil }
        let key = "\(l.destRect)|\(l.cornerRadius)|\(l.canvas)"
        if key == maskKey, let m = maskImage { return m }
        let w = Int(l.canvas.width), h = Int(l.canvas.height)
        let img = cgImageToCI({ ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: self.flip(l.destRect, CGFloat(h)), cornerWidth: CGFloat(l.cornerRadius), cornerHeight: CGFloat(l.cornerRadius), transform: nil))
            ctx.fillPath()
        }, width: w, height: h)
        maskKey = key
        maskImage = img
        return img
    }

    func ripple(_ r: RecRippleDraw) -> CIImage? {
        let d = Int(ceil(r.radius * 2 + 10))
        guard d > 4, d < 2000 else { return nil }
        return cgImageToCI({ ctx in
            let c = CGPoint(x: CGFloat(d) / 2, y: CGFloat(d) / 2)
            let col = ShotRenderer.cgColor(r.color)
            ctx.setFillColor(col.copy(alpha: CGFloat(r.alpha * 0.22)) ?? col)
            ctx.fillEllipse(in: CGRect(x: c.x - CGFloat(r.radius), y: c.y - CGFloat(r.radius), width: CGFloat(r.radius * 2), height: CGFloat(r.radius * 2)))
            ctx.setStrokeColor(col.copy(alpha: CGFloat(r.alpha * 0.95)) ?? col)
            ctx.setLineWidth(CGFloat(max(2, r.radius * 0.14)))
            ctx.strokeEllipse(in: CGRect(x: c.x - CGFloat(r.radius), y: c.y - CGFloat(r.radius), width: CGFloat(r.radius * 2), height: CGFloat(r.radius * 2)))
        }, width: d, height: d)
    }

    public func compose(source: CIImage, sourcePixels: CGSize, params p: RecFrameParams) -> CIImage {
        let l = p.layout
        let H = l.canvas.height
        let canvasRect = CGRect(origin: .zero, size: l.canvas)
        let kx = sourcePixels.width / max(l.sourceSize.width, 1), ky = sourcePixels.height / max(l.sourceSize.height, 1)
        let srcTop = CGRect(x: l.sourceRect.minX * kx, y: l.sourceRect.minY * ky, width: l.sourceRect.width * kx, height: l.sourceRect.height * ky)
        let srcCI = flip(srcTop, sourcePixels.height)
        let dest = flip(l.destRect, H)
        var content = source.cropped(to: srcCI)
            .transformed(by: CGAffineTransform(translationX: -srcCI.minX, y: -srcCI.minY))
            .transformed(by: CGAffineTransform(scaleX: dest.width / srcCI.width, y: dest.height / srcCI.height))
            .transformed(by: CGAffineTransform(translationX: dest.minX, y: dest.minY))
            .cropped(to: dest)
        for b in p.blurs {
            let r = flip(b.rect, H).intersection(dest)
            guard !r.isNull, r.width > 1, r.height > 1 else { continue }
            let patch: CIImage
            if b.pixelate {
                let scale = max(4, b.strength * min(r.width, r.height) * 0.3)
                patch = content.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)]).cropped(to: r)
            } else {
                let radius = min(max(6, b.strength * min(r.width, r.height) * 0.25), 80)
                patch = content.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: r)
            }
            content = patch.composited(over: content)
        }
        for r in p.ripples {
            guard let img = ripple(r), l.destRect.contains(r.center) else { continue }
            let o = CGAffineTransform(translationX: r.center.x - img.extent.width / 2, y: H - r.center.y - img.extent.height / 2)
            content = img.transformed(by: o).cropped(to: dest).composited(over: content)
        }
        if let m = mask(for: l) {
            content = content.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
        }
        if let bd = backdrop(for: p) { return content.composited(over: bd).cropped(to: canvasRect) }
        return content.cropped(to: canvasRect)
    }

    public func render(source: CVPixelBuffer, params: RecFrameParams, into out: CVPixelBuffer) {
        let src = CIImage(cvPixelBuffer: source)
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let img = compose(source: src, sourcePixels: size, params: params)
        ci.render(img, to: out, bounds: CGRect(origin: .zero, size: params.layout.canvas), colorSpace: space)
    }
}

final class RecInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let document: RecEditDocument
    let log: RecInputLog?
    let canvas: CGSize
    let trackID: CMPersistentTrackID

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, document: RecEditDocument, log: RecInputLog?, canvas: CGSize) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.document = document
        self.log = log
        self.canvas = canvas
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

public final class RecCompositor: NSObject, AVVideoCompositing {
    private let renderer = RecFrameRenderer()
    private let queue = DispatchQueue(label: "dev.multitool.app.rec.compositor", qos: .userInitiated)

    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }

    public override init() { super.init() }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instr = request.videoCompositionInstruction as? RecInstruction,
                  let src = request.sourceFrame(byTrackID: instr.trackID),
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: RecFailure("Не удалось получить кадр для сборки"))
                return
            }
            let t = CMTimeGetSeconds(request.compositionTime)
            let params = RecFrameParamsBuilder.make(document: instr.document, log: instr.log, outputTime: t, canvas: instr.canvas)
            renderer.render(source: src, params: params, into: out)
            request.finish(withComposedVideoFrame: out)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}
}

public struct RecBuiltComposition {
    public var composition: AVMutableComposition
    public var videoTrack: AVMutableCompositionTrack
    public var audioTracks: [(channel: RecAudioChannelPlan, track: AVMutableCompositionTrack)]
    public var videoComposition: AVMutableVideoComposition
}

public enum RecCompositionBuilder {
    static func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }

    public static func build(asset: AVAsset, plan: RecExportPlan, log: RecInputLog?, includeAudio: Bool) async throws -> RecBuiltComposition {
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { throw RecFailure("В файле нет видеодорожки") }
        let srcAudio = try await asset.loadTracks(withMediaType: .audio)
        guard !plan.pieces.isEmpty else { throw RecFailure("Нечего экспортировать: все фрагменты вырезаны") }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecFailure("Не удалось собрать видеодорожку") }
        var cas: [(RecAudioChannelPlan, AVMutableCompositionTrack)] = []
        if includeAudio {
            let wanted = plan.audioGroups.flatMap(\.channels)
            for ch in wanted where ch.sourceTrackIndex < srcAudio.count {
                if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { cas.append((ch, t)) }
            }
        }
        for piece in plan.pieces {
            let start = cm(piece.outStart)
            let range = CMTimeRange(start: cm(piece.srcStart), duration: cm(piece.srcDuration))
            try cv.insertTimeRange(range, of: srcVideo, at: start)
            for (ch, t) in cas { try t.insertTimeRange(range, of: srcAudio[ch.sourceTrackIndex], at: start) }
            if abs(piece.speed - 1) > 0.0001 {
                comp.scaleTimeRange(CMTimeRange(start: start, duration: cm(piece.srcDuration)), toDuration: cm(piece.outDuration))
            }
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = RecCompositor.self
        vc.renderSize = plan.canvas
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(plan.fps, 1)))
        vc.instructions = [RecInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), trackID: cv.trackID, document: plan.document, log: log, canvas: plan.canvas)]
        return RecBuiltComposition(composition: comp, videoTrack: cv, audioTracks: cas.map { (channel: $0.0, track: $0.1) }, videoComposition: vc)
    }

    public static func audioMix(for tracks: [(channel: RecAudioChannelPlan, track: AVMutableCompositionTrack)]) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { item in
            let p = AVMutableAudioMixInputParameters(track: item.track)
            p.setVolume(Float(item.channel.gain), at: .zero)
            return p
        }
        return mix
    }
}

public final class RecExporter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func exportVideo(source: URL, plan: RecExportPlan, log: RecInputLog?, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let built = try await RecCompositionBuilder.build(asset: asset, plan: plan, log: log, includeAudio: true)
        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: built.composition)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [built.videoTrack], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.videoComposition
        guard reader.canAdd(vOut) else { throw RecFailure("Не удалось подготовить чтение видео") }
        reader.add(vOut)
        let writer = try AVAssetWriter(outputURL: destination, fileType: plan.preset.container == .mp4 ? .mp4 : .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: AVRecWriter.videoSettings(codec: plan.preset.codec, width: Int(plan.canvas.width), height: Int(plan.canvas.height),
                                                                                                  fps: plan.fps, bitrate: plan.videoBitrate))
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw RecFailure("Кодер видео не подходит для такого размера") }
        writer.add(vIn)
        var pairs: [(AVAssetWriterInput, AVAssetReaderOutput)] = []
        for group in plan.audioGroups {
            let tracks = built.audioTracks.filter { t in group.channels.contains { $0.sourceTrackIndex == t.channel.sourceTrackIndex && $0.kind == t.channel.kind } }
            guard !tracks.isEmpty else { continue }
            let out = AVAssetReaderAudioMixOutput(audioTracks: tracks.map(\.track), audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2
            ])
            out.audioMix = RecCompositionBuilder.audioMix(for: tracks)
            out.audioTimePitchAlgorithm = .spectral
            guard reader.canAdd(out) else { continue }
            reader.add(out)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: AVRecWriter.audioSettings(sampleRate: 48_000, channels: 2, bitrate: group.bitrate))
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                pairs.append((aIn, out))
            }
        }
        self.reader = reader
        self.writer = writer
        guard reader.startReading() else { throw RecFailure(reader.error?.localizedDescription ?? "Не удалось начать чтение") }
        guard writer.startWriting() else { throw RecFailure(writer.error?.localizedDescription ?? "Не удалось открыть файл экспорта") }
        writer.startSession(atSourceTime: .zero)
        let total = max(plan.outputDuration, 0.001)
        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, report: Bool) {
            group.enter()
            let q = DispatchQueue(label: "dev.multitool.app.rec.export.\(report ? "v" : "a")")
            input.requestMediaDataWhenReady(on: q) { [weak self] in
                while input.isReadyForMoreMediaData {
                    if self?.isCancelled ?? true {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if report { progress(min(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) / total, 1)) }
                    if !input.append(sb) {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(vIn, vOut, report: true)
        for (i, o) in pairs { pump(i, o, report: false) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
        if isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw RecFailure("Экспорт отменён")
        }
        if reader.status == .failed { throw RecFailure(reader.error?.localizedDescription ?? "Ошибка чтения") }
        await writer.finishWriting()
        if writer.status != .completed { throw RecFailure(writer.error?.localizedDescription ?? "Не удалось завершить файл") }
        progress(1)
    }

    public func exportGIF(source: URL, plan: RecExportPlan, log: RecInputLog?, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        guard let gp = plan.gif, !gp.times.isEmpty else { throw RecFailure("Нечего экспортировать") }
        let asset = AVURLAsset(url: source)
        let built = try await RecCompositionBuilder.build(asset: asset, plan: plan, log: log, includeAudio: false)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        let step = max(gp.times.count / 16, 1)
        var builder = RecPaletteBuilder()
        for i in stride(from: 0, to: gp.times.count, by: step) {
            if isCancelled { throw RecFailure("Экспорт отменён") }
            let img = try await gen.image(at: RecCompositionBuilder.cm(gp.times[i])).image
            if let bmp = ShotBitmap(image: img) { builder.add(bmp, stride: max(bmp.width * bmp.height / 20_000, 1)) }
        }
        let palette = builder.build(maxColors: plan.preset.gif.colors)
        var quant = RecQuantizer(palette: palette)
        var stream: RecGifStream?
        for (i, t) in gp.times.enumerated() {
            if isCancelled { throw RecFailure("Экспорт отменён") }
            let img = try await gen.image(at: RecCompositionBuilder.cm(t)).image
            guard let bmp = ShotBitmap(image: img) else { continue }
            if stream == nil { stream = RecGifStream(width: bmp.width, height: bmp.height, palette: palette, loop: plan.preset.gif.loop) }
            stream?.add(RecGifFrame(indices: quant.index(bmp, dither: plan.preset.gif.dither), delay: i < gp.delays.count ? gp.delays[i] : 8))
            progress(Double(i + 1) / Double(gp.times.count))
        }
        guard var s = stream else { throw RecFailure("Не удалось получить ни одного кадра") }
        let data = s.finish()
        try data.write(to: destination, options: .atomic)
        return data.count
    }
}

public enum RecMedia {
    public static func probe(url: URL, scale: Double = 2) async -> RecSourceInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), let video = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await video.load(.naturalSize) else { return nil }
        let fps = (try? await video.load(.nominalFrameRate)).map { Int($0.rounded()) } ?? 30
        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        return RecSourceInfo(width: Int(size.width), height: Int(size.height), duration: CMTimeGetSeconds(duration), fps: max(fps, 1), scale: scale, hasSystemAudio: audio >= 1, hasMicrophone: audio >= 2)
    }

    public static func thumbnail(url: URL, at seconds: Double = 0.4, maxSide: Int = 320) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
