import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum TvClock {
    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
}

struct TvCaptureError: Error, CustomStringConvertible {
    let description: String
}

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var stream: SCStream?
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let pixelFormat: OSType
    var onStopped: ((Error) -> Void)?

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, pixelFormat: OSType) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.pixelFormat = pixelFormat
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw TvCaptureError(description: "дисплей \(displayID) не найден среди доступных для захвата")
        }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = pixelFormat
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.scalesToFit = true
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dev.multitool.app.tv.capture", qos: .userInitiated))
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        onStopped = nil
        Task { try? await s?.stopCapture() }
    }

    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestBuffer
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStopped?(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb), let px = CMSampleBufferGetImageBuffer(sb) else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let st = att.first?[.status] as? Int, st != SCFrameStatus.complete.rawValue { return }
        lock.lock()
        latestBuffer = px
        lock.unlock()
    }
}

final class FrameTicker {
    private let timer: DispatchSourceTimer

    init(fps: Int, queue: DispatchQueue, handler: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(fps, 1)), leeway: .milliseconds(1))
        timer.setEventHandler(handler: handler)
    }

    func start() { timer.resume() }
    func stop() { timer.cancel() }
}

struct EncodedVideo {
    let data: Data
    let isKey: Bool
    let seconds: Double
}

private let h264OutputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    guard status == noErr, let sampleBuffer, let refcon, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue().handle(sampleBuffer)
}

final class H264Encoder {
    private var session: VTCompressionSession?
    private let onFrame: (EncodedVideo) -> Void
    private let fps: Int

    init(width: Int, height: Int, fps: Int, bitrate: Int, gop: Int, onFrame: @escaping (EncodedVideo) -> Void) throws {
        self.onFrame = onFrame
        self.fps = fps
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: h264OutputCallback, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &s)
        guard st == noErr, let s else { throw TvCaptureError(description: "не удалось создать кодер H.264 (\(st))") }
        session = s
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, gop as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { finish() }

    func encode(_ pixelBuffer: CVPixelBuffer, seconds: Double) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90000),
                                        duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    func finish() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    fileprivate func handle(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var isKey = true
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let first = att.first {
            isKey = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        var count = 0
        var nalSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalSize)
        var sets: [Data] = []
        if isKey {
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return }
        guard let annexB = H264Stream.annexB(fromAVCC: Data(bytes), nalLengthSize: Int(nalSize), parameterSets: sets) else { return }
        onFrame(EncodedVideo(data: annexB, isKey: isKey, seconds: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))))
    }
}

enum TvJpeg {
    static func data(from pixelBuffer: CVPixelBuffer, quality: Double) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: audio

enum TvAudioFormat {
    static let sampleRate = 48000.0
    static let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    static let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])!
}

final class AacEncoder {
    private let converter: AVAudioConverter
    private var normalizers: [String: AVAudioConverter] = [:]
    private var queue: [AVAudioPCMBuffer] = []
    private var basePTS: Double?
    private var packets = 0
    private let onPacket: (Data, Double) -> Void

    init?(onPacket: @escaping (Data, Double) -> Void) {
        guard let c = AVAudioConverter(from: TvAudioFormat.canonical, to: TvAudioFormat.aac) else { return nil }
        converter = c
        self.onPacket = onPacket
    }

    private func normalize(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if b.format == TvAudioFormat.canonical { return b }
        let key = "\(b.format.sampleRate)-\(b.format.channelCount)-\(b.format.commonFormat.rawValue)-\(b.format.isInterleaved)"
        let conv: AVAudioConverter
        if let c = normalizers[key] { conv = c } else {
            guard let c = AVAudioConverter(from: b.format, to: TvAudioFormat.canonical) else { return nil }
            normalizers[key] = c
            conv = c
        }
        let cap = AVAudioFrameCount(Double(b.frameLength) * TvAudioFormat.sampleRate / b.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: TvAudioFormat.canonical, frameCapacity: cap) else { return nil }
        var given = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return b
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    func feed(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        guard let pcm = normalize(buffer) else { return }
        if basePTS == nil { basePTS = seconds }
        queue.append(pcm)
        while true {
            let out = AVAudioCompressedBuffer(format: TvAudioFormat.aac, packetCapacity: 4, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] _, st in
                if queue.isEmpty { st.pointee = .noDataNow; return nil }
                st.pointee = .haveData
                return queue.removeFirst()
            }
            if status == .error || out.packetCount == 0 { break }
            guard let descs = out.packetDescriptions else { break }
            for i in 0..<Int(out.packetCount) {
                let d = descs[i]
                let payload = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                let pts = (basePTS ?? seconds) + Double(packets) * 1024.0 / TvAudioFormat.sampleRate
                packets += 1
                if let header = AdtsHeader.make(payloadLength: payload.count) { onPacket(header + payload, pts) }
            }
        }
    }
}

final class BlackHoleSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.multitool.app.tv.audio", qos: .userInitiated)
    private var onPCM: ((AVAudioPCMBuffer, Double) -> Void)?

    static func device(matching name: String) -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        return found.first { $0.localizedName.lowercased().contains(name.lowercased()) }
    }

    init?(device: AVCaptureDevice) {
        super.init()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
    }

    func start(_ handler: @escaping (AVAudioPCMBuffer, Double) -> Void) {
        onPCM = handler
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        onPCM = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var desc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &desc) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        onPCM?(pcm, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
    }
}

final class SilenceSource {
    private let timer: DispatchSourceTimer
    private var produced = 0
    private var startedAt = 0.0
    private var onPCM: ((AVAudioPCMBuffer, Double) -> Void)?

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.multitool.app.tv.silence", qos: .userInitiated))
    }

    func start(_ handler: @escaping (AVAudioPCMBuffer, Double) -> Void) {
        onPCM = handler
        startedAt = TvClock.now()
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        onPCM = nil
    }

    private func tick() {
        let now = TvClock.now()
        let need = Int((now - startedAt) * TvAudioFormat.sampleRate) - produced
        guard need >= 1024, let buf = AVAudioPCMBuffer(pcmFormat: TvAudioFormat.canonical, frameCapacity: AVAudioFrameCount(need)) else { return }
        buf.frameLength = AVAudioFrameCount(need)
        if let ch = buf.floatChannelData {
            for c in 0..<Int(TvAudioFormat.canonical.channelCount) { memset(ch[c], 0, need * MemoryLayout<Float>.size) }
        }
        let pts = startedAt + Double(produced) / TvAudioFormat.sampleRate
        produced += need
        onPCM?(buf, pts)
    }
}

// MARK: pipelines

final class TsPipeline: @unchecked Sendable {
    private let config: TvConfig
    private let displayID: CGDirectDisplayID
    private let publish: (Data, Bool) -> Void
    private let log: (String) -> Void
    private let capturer: ScreenCapturer
    private var encoder: H264Encoder?
    private var ticker: FrameTicker?
    private var aac: AacEncoder?
    private var blackHole: BlackHoleSource?
    private var silence: SilenceSource?
    private let muxer = TsMuxer(hasAudio: true)
    private let muxLock = NSLock()
    private let tickQueue = DispatchQueue(label: "dev.multitool.app.tv.tick", qos: .userInitiated)
    private var base = 0.0
    private var stopped = false

    init(config: TvConfig, displayID: UInt32, publish: @escaping (Data, Bool) -> Void, log: @escaping (String) -> Void) {
        self.config = config
        self.displayID = displayID
        self.publish = publish
        self.log = log
        capturer = ScreenCapturer(displayID: displayID, width: config.width, height: config.height, fps: config.fps,
                                  pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    private func ticks(_ seconds: Double) -> Int64 { max(Int64((seconds - base + 1.0) * 90000), 0) }

    func start() async throws {
        base = TvClock.now()
        encoder = try H264Encoder(width: config.width, height: config.height, fps: config.fps, bitrate: config.bitrateBps, gop: config.gop) { [weak self] v in
            guard let self, !self.stopped else { return }
            self.muxLock.lock()
            let d = self.muxer.video(annexB: v.data, pts: self.ticks(v.seconds), isKey: v.isKey)
            self.muxLock.unlock()
            self.publish(d, v.isKey)
        }
        aac = AacEncoder { [weak self] adts, seconds in
            guard let self, !self.stopped else { return }
            self.muxLock.lock()
            let d = self.muxer.audio(adts: adts, pts: self.ticks(seconds))
            self.muxLock.unlock()
            self.publish(d, false)
        }
        await startAudio()
        capturer.onStopped = { [weak self] e in self?.log("захват экрана остановлен: \(e.localizedDescription)") }
        try await capturer.start()
        let t = FrameTicker(fps: config.fps, queue: tickQueue) { [weak self] in
            guard let self, !self.stopped, let px = self.capturer.latest() else { return }
            self.encoder?.encode(px, seconds: TvClock.now())
        }
        ticker = t
        t.start()
    }

    private func startAudio() async {
        let feed: (AVAudioPCMBuffer, Double) -> Void = { [weak self] b, s in self?.aac?.feed(b, seconds: s) }
        if let dev = BlackHoleSource.device(matching: config.audioInputMatch) {
            var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            if granted, let src = BlackHoleSource(device: dev) {
                blackHole = src
                src.start(feed)
                log("звук берётся с \(dev.localizedName)")
                return
            }
            log("нет доступа к микрофону для чтения \(dev.localizedName) — звук пустой")
        } else {
            log("BlackHole не найден — звук пустой")
        }
        let s = SilenceSource()
        silence = s
        s.start(feed)
    }

    func stop() {
        stopped = true
        ticker?.stop()
        ticker = nil
        capturer.stop()
        blackHole?.stop()
        silence?.stop()
        encoder?.finish()
        encoder = nil
        aac = nil
    }
}

final class MjpegPipeline: @unchecked Sendable {
    private let config: TvConfig
    private let publish: (Data) -> Void
    private let capturer: ScreenCapturer
    private var ticker: FrameTicker?
    private let tickQueue = DispatchQueue(label: "dev.multitool.app.tv.jpeg", qos: .userInitiated)
    private var busy = false
    private var stopped = false
    private let log: (String) -> Void

    init(config: TvConfig, displayID: UInt32, publish: @escaping (Data) -> Void, log: @escaping (String) -> Void) {
        self.config = config
        self.publish = publish
        self.log = log
        capturer = ScreenCapturer(displayID: displayID, width: config.fastWidth, height: config.fastHeight, fps: config.fastFPS,
                                  pixelFormat: kCVPixelFormatType_32BGRA)
    }

    func start() async throws {
        capturer.onStopped = { [weak self] e in self?.log("захват экрана остановлен: \(e.localizedDescription)") }
        try await capturer.start()
        let quality = config.jpegQuality
        let t = FrameTicker(fps: config.fastFPS, queue: tickQueue) { [weak self] in
            guard let self, !self.stopped, !self.busy, let px = self.capturer.latest() else { return }
            self.busy = true
            if let jpeg = TvJpeg.data(from: px, quality: quality) { self.publish(TvHttp.multipartFrame(jpeg)) }
            self.busy = false
        }
        ticker = t
        t.start()
    }

    func stop() {
        stopped = true
        ticker?.stop()
        ticker = nil
        capturer.stop()
    }
}
