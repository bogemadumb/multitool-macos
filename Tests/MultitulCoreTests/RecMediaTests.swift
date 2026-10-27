import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MultitulCore

private let tmpRoot = "/private/tmp/claude-501/rec-media-tests"

private func tmpURL(_ name: String) -> URL {
    try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
    let u = URL(fileURLWithPath: tmpRoot + "/" + UUID().uuidString.prefix(8) + "-" + name)
    return u
}

private func audioBuffer(frames: Int, startFrame: Int, rate: Double) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
                                           mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(sin(2 * Double.pi * 440 * Double(startFrame + i) / rate) * 0.3)
        samples[i * 2] = v
        samples[i * 2 + 1] = v
    }
    let bytes = samples.count * 4
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                             flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(rate))
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
    return sb
}

private func makeSource(seconds: Int = 2, fps: Int = 10, width: Int = 160, height: Int = 96, audio: Bool = true) throws -> URL {
    let url = tmpURL("source.mov")
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
    ])
    w.add(vIn)
    var aIn: AVAssetWriterInput?
    if audio {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000])
        w.add(a)
        aIn = a
    }
    guard w.startWriting() else { throw RecFailure("writer: \(w.error?.localizedDescription ?? "?")") }
    w.startSession(atSourceTime: .zero)
    let rate = 48_000.0
    let chunk = Int(rate) / fps
    let total = seconds * fps
    let group = DispatchGroup()
    var nextVideo = 0
    group.enter()
    vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "rec.test.video")) {
        while vIn.isReadyForMoreMediaData {
            if nextVideo >= total {
                vIn.markAsFinished()
                group.leave()
                return
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let red = nextVideo < fps
            for y in 0..<height {
                for x in 0..<width {
                    let o = y * stride + x * 4
                    base[o] = red ? 0 : 255
                    base[o + 1] = 0
                    base[o + 2] = red ? 255 : 0
                    base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(nextVideo), timescale: CMTimeScale(fps)))
            nextVideo += 1
        }
    }
    if let aIn {
        var nextAudio = 0
        group.enter()
        aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "rec.test.audio")) {
            while aIn.isReadyForMoreMediaData {
                if nextAudio >= total {
                    aIn.markAsFinished()
                    group.leave()
                    return
                }
                if let sb = audioBuffer(frames: chunk, startFrame: nextAudio * chunk, rate: rate) { aIn.append(sb) }
                nextAudio += 1
            }
        }
    }
    group.wait()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    sem.wait()
    guard w.status == .completed else { throw RecFailure("finish: \(w.error?.localizedDescription ?? "?")") }
    return url
}

private func plan(_ doc: RecEditDocument, _ preset: RecExportPreset) -> RecExportPlan { RecExportPlanner.make(document: doc, preset: preset) }

private let sourcePreset = RecExportPreset(id: "t", title: "t", container: .mp4, codec: .h264, quality: .high)

private func frameColor(_ url: URL, at t: Double) async -> (UInt8, UInt8, UInt8, UInt8)? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, let bmp = ShotBitmap(image: img) else { return nil }
    return bmp.pixel(bmp.width / 2, bmp.height / 2)
}

private final class ProgressBox: @unchecked Sendable { var value = 0.0 }

@Suite(.serialized) struct RecMediaTests {
    @Test func probeReadsTheSyntheticSource() async throws {
        let url = try makeSource()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = await RecMedia.probe(url: url, scale: 1)
        #expect(info != nil && info!.width == 160 && info!.height == 96 && abs(info!.duration - 2) < 0.1 && info!.fps == 10 && info!.hasSystemAudio && !info!.hasMicrophone)
    }

    @Test func thumbnailComesFromTheVideo() async throws {
        let url = try makeSource(audio: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let img = await RecMedia.thumbnail(url: url, at: 0.3, maxSide: 64)
        #expect(img != nil && max(img!.width, img!.height) <= 64)
        let probe = await RecMedia.probe(url: url)
        #expect(probe?.hasSystemAudio == false)
    }

    @Test func trimAndCutProduceTheExpectedDurationAndFrames() async throws {
        let src = try makeSource()
        let dst = tmpURL("out.mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        var doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        _ = doc.timeline.cut(from: 0.5, to: 1.5)
        let p = plan(doc, sourcePreset)
        #expect(p.canvas == CGSize(width: 160, height: 96) && abs(p.outputDuration - 1) < 0.15)
        try await RecExporter().exportVideo(source: src, plan: p, log: nil, destination: dst, progress: { _ in })
        let out = AVURLAsset(url: dst)
        let dur = try await out.load(.duration).seconds
        #expect(abs(dur - p.outputDuration) < 0.2)
        let audio = try await out.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        let early = await frameColor(dst, at: 0.1), late = await frameColor(dst, at: dur - 0.15)
        #expect(early.map { $0.0 > 200 && $0.2 < 80 } == true)
        #expect(late.map { $0.2 > 200 && $0.0 < 80 } == true)
    }

    @Test func speedUpShortensTheOutput() async throws {
        let src = try makeSource(audio: false)
        let dst = tmpURL("fast.mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        var doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        _ = doc.timeline.setSpeed(from: 0, to: 2, speed: 2)
        let p = plan(doc, sourcePreset)
        try await RecExporter().exportVideo(source: src, plan: p, log: nil, destination: dst, progress: { _ in })
        let dur = try await AVURLAsset(url: dst).load(.duration).seconds
        #expect(abs(dur - 1) < 0.2)
    }

    @Test func cropPaddingAndMutedAudioShapeTheFile() async throws {
        let src = try makeSource()
        let dst = tmpURL("styled.mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        var doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        doc.crop = RecNormRect(x: 0, y: 0, w: 0.5, h: 0.5)
        doc.style.padding = 8
        doc.style.background = "solid:#112233"
        doc.audio.systemMuted = true
        let p = plan(doc, sourcePreset)
        #expect(p.canvas == CGSize(width: 96, height: 64) && p.audioGroups.isEmpty)
        let last = ProgressBox()
        try await RecExporter().exportVideo(source: src, plan: p, log: nil, destination: dst, progress: { last.value = $0 })
        let out = AVURLAsset(url: dst)
        let track = try await out.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 96 && Int(size.height) == 64 && last.value > 0.9)
        #expect(try await out.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func gifExportProducesTheRightFrames() async throws {
        let src = try makeSource(audio: false)
        let dst = tmpURL("out.gif")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        var g = RecGifOptions()
        g.fps = 5
        g.maxWidth = 80
        g.colors = 16
        g.dither = .none
        let preset = RecExportPreset(id: "g", title: "g", kind: .gif, includeAudio: false, gif: g)
        let p = plan(doc, preset)
        #expect(p.canvas == CGSize(width: 80, height: 48) && p.gif?.times.count == 10)
        let bytes = try await RecExporter().exportGIF(source: src, plan: p, log: nil, destination: dst, progress: { _ in })
        let data = try Data(contentsOf: dst)
        #expect(bytes == data.count && Array(data.prefix(6)) == Array("GIF89a".utf8))
        let isrc = CGImageSourceCreateWithData(data as CFData, nil)!
        let count = CGImageSourceGetCount(isrc)
        #expect((2...8).contains(count), "count=\(count) bytes=\(data.count)")
        let first = ShotBitmap(image: CGImageSourceCreateImageAtIndex(isrc, 0, nil)!)!
        let lastF = ShotBitmap(image: CGImageSourceCreateImageAtIndex(isrc, count - 1, nil)!)!
        #expect(first.width == 80 && first.pixel(40, 24).0 > 200 && lastF.pixel(40, 24).2 > 200)
    }

    @Test func cancelBeforeStartAbortsTheExport() async throws {
        let src = try makeSource(audio: false)
        let dst = tmpURL("cancel.mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        let ex = RecExporter()
        ex.cancel()
        var failed = false
        do { try await ex.exportVideo(source: src, plan: plan(doc, sourcePreset), log: nil, destination: dst, progress: { _ in }) } catch { failed = true }
        #expect(failed && !FileManager.default.fileExists(atPath: dst.path))
    }

    @Test func emptyTimelineIsRejected() async throws {
        let src = try makeSource(audio: false)
        defer { try? FileManager.default.removeItem(at: src) }
        var doc = RecEditDocument(source: await RecMedia.probe(url: src, scale: 1)!)
        doc.timeline = RecTimeline(sourceDuration: 0)
        var failed = false
        do { try await RecExporter().exportVideo(source: src, plan: plan(doc, sourcePreset), log: nil, destination: tmpURL("x.mp4"), progress: { _ in }) } catch { failed = true }
        #expect(failed)
    }

    @Test func sourceWithoutAVideoTrackIsRejected() async throws {
        let url = tmpURL("nothing.mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await RecMedia.probe(url: url) == nil)
    }
}
