import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

public final class LiveRecClock: RecHostClock {
    public init() {}
    public var hostNow: Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
}

public final class LiveRecFiles: RecFiling, RecDataReading {
    public init() {}

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func makeDirectory(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
    }

    public func move(_ from: String, to: String) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: to) { return false }
            try FileManager.default.moveItem(atPath: from, toPath: to)
            return true
        } catch {
            Log.write("recorder move failed: \(error.localizedDescription)")
            return false
        }
    }

    public func remove(_ path: String) -> Bool { (try? FileManager.default.removeItem(atPath: path)) != nil }

    public func size(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    }

    public func freeBytes(at path: String) -> Int? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let n = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(n)
    }

    public func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

public enum RecMic {
    // empty or unknown uid means the system default input
    public static func resolve(uid: String, inputs: [AudioDeviceInfo]) -> (uid: String?, note: String?) {
        let t = uid.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return (nil, nil) }
        if inputs.contains(where: { $0.uid == t }) { return (t, nil) }
        return (nil, "Выбранный микрофон не подключён: используется микрофон по умолчанию")
    }
}

public final class SCRecCapture: NSObject, RecCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var onSample: (@Sendable (RecSample) -> Void)?
    private var onStop: (@Sendable (String) -> Void)?
    private var fps = 30
    private var micFallback: RecMicFallback?
    private let videoQueue = DispatchQueue(label: "dev.multitool.app.rec.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "dev.multitool.app.rec.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stopping = false

    public override init() { super.init() }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func start(_ config: RecCaptureConfig, onSample: @escaping @Sendable (RecSample) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws {
        self.onSample = onSample
        self.onStop = onStop
        fps = config.fps
        stopping = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter
        switch config.plan.target {
        case .display(let id, let rect):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw RecFailure("Экран не найден среди доступных для записи") }
            filter = SCContentFilter(display: d, excludingApplications: config.excludeOwnWindows ? own : [], exceptingWindows: [])
            if let rect { cfg.sourceRect = rect }
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw RecFailure("Окно не найдено: возможно, оно закрыто") }
            filter = SCContentFilter(desktopIndependentWindow: w)
        }
        cfg.width = config.plan.pixelWidth
        cfg.height = config.plan.pixelHeight
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(config.fps, 1)))
        cfg.showsCursor = config.showCursor
        cfg.queueDepth = 6
        cfg.scalesToFit = true
        cfg.colorSpaceName = CGColorSpace.sRGB
        if config.systemAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }
        var micViaStream = false
        if config.microphone, #available(macOS 15.0, *) {
            cfg.captureMicrophone = true
            if !config.micDeviceUID.isEmpty { cfg.microphoneCaptureDeviceID = config.micDeviceUID }
            micViaStream = true
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if micViaStream, #available(macOS 15.0, *) { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue) }
        if config.microphone, !micViaStream {
            let m = RecMicFallback(uid: config.micDeviceUID, queue: audioQueue) { [weak self] sample in self?.onSample?(sample) }
            try m.start()
            micFallback = m
        }
        try await s.startCapture()
        stream = s
    }

    private func markStopping() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    public func stop() async {
        markStopping()
        micFallback?.stop()
        micFallback = nil
        let s = stream
        stream = nil
        try? await s?.stopCapture()
        onSample = nil
        onStop = nil
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let quiet = stopping
        lock.unlock()
        if !quiet { onStop?(error.localizedDescription) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sb), CMSampleBufferDataIsReady(sb) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let dur = CMSampleBufferGetDuration(sb)
        var seconds = dur.isValid ? CMTimeGetSeconds(dur) : 0
        let track: RecTrackKind
        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
            if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let st = att.first?[.status] as? Int, st != SCFrameStatus.complete.rawValue { return }
            track = .video
            if seconds <= 0 { seconds = 1.0 / Double(max(fps, 1)) }
        case .audio:
            track = .systemAudio
        default:
            if #available(macOS 15.0, *), type == .microphone { track = .microphone } else { return }
        }
        onSample?(RecSample(track: track, pts: pts, duration: seconds, payload: sb as AnyObject))
    }
}

final class RecMicFallback: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let uid: String
    private let queue: DispatchQueue
    private let handler: @Sendable (RecSample) -> Void

    init(uid: String, queue: DispatchQueue, handler: @escaping @Sendable (RecSample) -> Void) {
        self.uid = uid
        self.queue = queue
        self.handler = handler
    }

    func start() throws {
        let device = (uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecFailure("Микрофон не найден") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecFailure("Микрофон нельзя подключить") }
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw RecFailure("Не удалось читать звук микрофона") }
        session.addOutput(out)
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        for o in session.outputs { (o as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sb), CMSampleBufferDataIsReady(sb) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if let clock = session.synchronizationClock { pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()) }
        let dur = CMSampleBufferGetDuration(sb)
        handler(RecSample(track: .microphone, pts: CMTimeGetSeconds(pts), duration: dur.isValid ? CMTimeGetSeconds(dur) : 0, payload: sb as AnyObject))
    }
}

public final class AVRecWriter: RecFileWriting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.multitool.app.rec.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: [RecTrackKind: AVAssetWriterInput] = [:]
    private var url: URL?
    private var started = false
    private var failed: String?
    private var written = 0
    private var dropped = 0
    private var finishing = false

    public init() {}

    public static func videoSettings(codec: RecCodec, width: Int, height: Int, fps: Int, bitrate: Int) -> [String: Any] {
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(fps * 2, 2),
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: props
        ]
    }

    public static func audioSettings(sampleRate: Int, channels: Int, bitrate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate]
    }

    public func prepare(_ c: RecWriterConfig) throws {
        try? FileManager.default.removeItem(at: c.url)
        let w = try AVAssetWriter(outputURL: c.url, fileType: c.container == .mp4 ? .mp4 : .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(codec: c.codec, width: c.width, height: c.height, fps: c.fps, bitrate: c.videoBitrate))
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw RecFailure("Кодер видео не подходит для этого размера кадра") }
        w.add(v)
        for spec in c.layout.audioTracks {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(sampleRate: spec.sampleRate, channels: spec.channels, bitrate: spec.bitrate))
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(a) else { throw RecFailure("Кодер звука не подходит") }
            w.add(a)
            audio[spec.kind] = a
        }
        guard w.startWriting() else { throw RecFailure(w.error?.localizedDescription ?? "Не удалось открыть файл для записи") }
        writer = w
        video = v
        url = c.url
    }

    private static func retimed(_ sb: CMSampleBuffer, to out: Double, from original: Double) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        let delta = CMTime(seconds: out - original, preferredTimescale: 90_000)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeAdd(infos[i].presentationTimeStamp, delta)
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = CMTimeAdd(infos[i].decodeTimeStamp, delta) }
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: infos, sampleBufferOut: &result)
        return result
    }

    public func append(_ s: RecSample, outPTS: Double, trimHead: Double) {
        queue.async { [self] in
            guard !finishing, failed == nil, let w = writer, let payload = s.payload, CFGetTypeID(payload) == CMSampleBufferGetTypeID() else { return }
            let sb = unsafeBitCast(payload, to: CMSampleBuffer.self)
            let input = s.track == .video ? video : audio[s.track]
            guard let input else { return }
            if !started {
                w.startSession(atSourceTime: .zero)
                started = true
            }
            guard w.status == .writing else {
                failed = w.error?.localizedDescription ?? "запись прервана"
                return
            }
            guard input.isReadyForMoreMediaData, let out = Self.retimed(sb, to: max(outPTS, 0), from: s.pts) else {
                if s.track == .video { dropped += 1 }
                return
            }
            if input.append(out) { if s.track == .video { written += 1 } } else {
                failed = w.error?.localizedDescription ?? "не удалось записать кадр"
            }
        }
    }

    public func finish(endTime: Double) async -> Result<RecFinishInfo, RecFailure> {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                finishing = true
                guard let w = writer, let url else {
                    cont.resume(returning: .failure(RecFailure("Файл не был открыт")))
                    return
                }
                guard started, w.status == .writing else {
                    w.cancelWriting()
                    cont.resume(returning: .failure(RecFailure(failed ?? (started ? (w.error?.localizedDescription ?? "запись прервана") : "Не пришло ни одного кадра: проверь доступ «Запись экрана»"))))
                    return
                }
                w.endSession(atSourceTime: CMTime(seconds: max(endTime, 0.01), preferredTimescale: 90_000))
                video?.markAsFinished()
                for a in audio.values { a.markAsFinished() }
                let framesWritten = written, framesDropped = dropped
                w.finishWriting {
                    if w.status == .completed {
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                        cont.resume(returning: .success(RecFinishInfo(bytes: size ?? 0, framesWritten: framesWritten, framesDropped: framesDropped)))
                    } else {
                        cont.resume(returning: .failure(RecFailure(w.error?.localizedDescription ?? "Не удалось завершить файл")))
                    }
                }
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            finishing = true
            writer?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }
}

public final class NSEventRecInput: RecInputCapturing {
    private var monitors: [Any] = []
    private let clock: RecHostClock
    private var primaryHeight: CGFloat = 0

    public init(clock: RecHostClock = LiveRecClock()) { self.clock = clock }

    @MainActor
    public func prepare() { primaryHeight = ShotLiveScreens.primaryHeight() }

    public func start(onEvent: @escaping @Sendable (RecRawInput) -> Void) {
        let clock = self.clock
        let h = primaryHeight
        func fire(_ kind: RecInputKind, _ button: RecButton) {
            let p = NSEvent.mouseLocation
            onEvent(RecRawInput(host: clock.hostNow, kind: kind, point: CGPoint(x: p.x, y: h - p.y), button: button))
        }
        let specs: [(NSEvent.EventTypeMask, RecInputKind, RecButton)] = [
            (.mouseMoved, .move, .left), (.leftMouseDragged, .move, .left), (.rightMouseDragged, .move, .right), (.otherMouseDragged, .move, .other),
            (.leftMouseDown, .down, .left), (.leftMouseUp, .up, .left), (.rightMouseDown, .down, .right), (.rightMouseUp, .up, .right),
            (.otherMouseDown, .down, .other), (.otherMouseUp, .up, .other)
        ]
        for (mask, kind, button) in specs {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in fire(kind, button) }) { monitors.append(m) }
        }
    }

    public func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }
}
