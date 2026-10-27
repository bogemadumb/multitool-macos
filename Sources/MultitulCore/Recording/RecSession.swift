import Foundation
import CoreGraphics

public struct RecSample: @unchecked Sendable {
    public var track: RecTrackKind
    public var pts: Double
    public var duration: Double
    public var payload: AnyObject?

    public init(track: RecTrackKind, pts: Double, duration: Double, payload: AnyObject? = nil) {
        self.track = track
        self.pts = pts
        self.duration = duration
        self.payload = payload
    }
}

public struct RecRawInput: Sendable {
    public var host: Double
    public var kind: RecInputKind
    public var point: CGPoint
    public var button: RecButton

    public init(host: Double, kind: RecInputKind, point: CGPoint, button: RecButton = .left) {
        self.host = host
        self.kind = kind
        self.point = point
        self.button = button
    }
}

public struct RecCaptureConfig: Sendable {
    public var plan: RecCapturePlan
    public var fps: Int
    public var showCursor: Bool
    public var systemAudio: Bool
    public var microphone: Bool
    public var micDeviceUID: String
    public var excludeOwnWindows: Bool

    public init(plan: RecCapturePlan, fps: Int, showCursor: Bool, systemAudio: Bool, microphone: Bool, micDeviceUID: String, excludeOwnWindows: Bool) {
        self.plan = plan
        self.fps = fps
        self.showCursor = showCursor
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.micDeviceUID = micDeviceUID
        self.excludeOwnWindows = excludeOwnWindows
    }
}

public struct RecWriterConfig: Sendable {
    public var url: URL
    public var layout: RecTrackLayout
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: RecCodec
    public var container: RecContainer
    public var videoBitrate: Int

    public init(url: URL, layout: RecTrackLayout, width: Int, height: Int, fps: Int, codec: RecCodec, container: RecContainer, videoBitrate: Int) {
        self.url = url
        self.layout = layout
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.container = container
        self.videoBitrate = videoBitrate
    }
}

public struct RecFinishInfo: Equatable, Sendable {
    public var bytes: Int
    public var framesWritten: Int
    public var framesDropped: Int

    public init(bytes: Int, framesWritten: Int, framesDropped: Int) {
        self.bytes = bytes
        self.framesWritten = framesWritten
        self.framesDropped = framesDropped
    }
}

public struct RecFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public protocol RecCapturing: AnyObject {
    func start(_ config: RecCaptureConfig, onSample: @escaping @Sendable (RecSample) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws
    func stop() async
}

public protocol RecFileWriting: AnyObject {
    func prepare(_ config: RecWriterConfig) throws
    func append(_ sample: RecSample, outPTS: Double, trimHead: Double)
    func finish(endTime: Double) async -> Result<RecFinishInfo, RecFailure>
    func cancel()
}

public protocol RecInputCapturing: AnyObject {
    func start(onEvent: @escaping @Sendable (RecRawInput) -> Void)
    func stop()
}

public protocol RecHostClock: AnyObject {
    var hostNow: Double { get }
}

public protocol RecFiling: AnyObject {
    func exists(_ path: String) -> Bool
    func makeDirectory(_ path: String) -> Bool
    func move(_ from: String, to: String) -> Bool
    func remove(_ path: String) -> Bool
    func size(_ path: String) -> Int?
    func freeBytes(at path: String) -> Int?
}

public struct RecSavePaths: Equatable, Sendable {
    public var directory: String
    public var fileName: String
    public var finalPath: String
    public var partialPath: String

    public init(directory: String, fileName: String, finalPath: String, partialPath: String) {
        self.directory = directory
        self.fileName = fileName
        self.finalPath = finalPath
        self.partialPath = partialPath
    }
}

public enum RecSavePlanner {
    public static func paths(settings s: RecSettings, mode: RecMode, appName: String?, windowTitle: String?, width: Int, height: Int, counter: Int, date: Date,
                             timeZone: TimeZone = .current, home: String = NSHomeDirectory(), exists: (String) -> Bool) -> RecSavePaths {
        let dir = s.resolvedDirectory(home: home)
        let ctx = ShotNameContext(date: date, mode: mode.shotMode, appName: appName, windowTitle: windowTitle, width: width, height: height, counter: counter, timeZone: timeZone)
        var base = ShotNaming.baseName(template: s.nameTemplate, context: ctx)
        if base.isEmpty || base == "Screenshot" { base = "Запись экрана" }
        let name = ShotNaming.uniqueFileName(base: base, ext: s.container.fileExtension) { exists(dir + "/" + $0) }
        let partial = dir + "/." + (name as NSString).deletingPathExtension + ".part." + s.container.fileExtension
        return RecSavePaths(directory: dir, fileName: name, finalPath: dir + "/" + name, partialPath: partial)
    }
}

public final class RecSampleHub: @unchecked Sendable {
    private let lock = NSLock()
    private var router: RecSampleRouter
    private var log = RecInputLog()
    private var mapper: RecInputMapper
    private let writer: RecFileWriting
    private var writing = true

    public init(enabled: Set<RecTrackKind>, mapper: RecInputMapper, writer: RecFileWriting) {
        router = RecSampleRouter(enabled: enabled)
        self.mapper = mapper
        self.writer = writer
    }

    public func begin(at host: Double) { lock.lock(); router.begin(at: host); lock.unlock() }
    public func pause(at host: Double) { lock.lock(); router.pause(at: host); lock.unlock() }
    public func resume(at host: Double) { lock.lock(); router.resume(at: host); lock.unlock() }

    public func stop(at host: Double) {
        lock.lock()
        router.stop(at: host)
        writing = false
        lock.unlock()
    }

    public func ingest(_ s: RecSample) {
        lock.lock()
        guard writing else { lock.unlock(); return }
        let r = router.route(s.track, pts: s.pts, duration: s.duration)
        lock.unlock()
        if case .write(let out, let trim) = r { writer.append(s, outPTS: out, trimHead: trim) }
    }

    public func ingest(input raw: RecRawInput) {
        lock.lock()
        defer { lock.unlock() }
        guard writing, let t = router.clock.timeline(for: raw.host), let n = mapper.normalize(raw.point) else { return }
        log.append(RecInputEvent(t: t, kind: raw.kind, x: n.x, y: n.y, button: raw.button, inside: n.inside))
    }

    public func elapsed(at host: Double) -> Double { lock.lock(); defer { lock.unlock() }; return router.clock.elapsed(at: host) }
    public var snapshot: (router: RecSampleRouter, log: RecInputLog) { lock.lock(); defer { lock.unlock() }; return (router, log) }
}

public struct RecSessionResult: Sendable {
    public var path: String
    public var bytes: Int
    public var duration: Double
    public var plan: RecCapturePlan
    public var layout: RecTrackLayout
    public var log: RecInputLog
    public var stats: [RecTrackKind: RecTrackStats]
    public var fileName: String
    public var warnings: [String]
}

public final class RecSession {
    public private(set) var machine = RecStateMachine()
    public private(set) var failure: String?
    public private(set) var result: RecSessionResult?
    public var onState: ((RecState) -> Void)?

    private let capture: RecCapturing
    private let writerFactory: () -> RecFileWriting
    private let input: RecInputCapturing?
    private let clock: RecHostClock
    private let files: RecFiling
    private let events: ShotEventHub?
    private var hub: RecSampleHub?
    private var writer: RecFileWriting?
    private var paths: RecSavePaths?
    private var config: RecCaptureConfig?
    private var settings = RecSettings()
    private var layout = RecTrackLayout(tracks: [], warnings: [])
    private var warnings: [String] = []
    private var stopReason: String?

    public init(capture: RecCapturing, writerFactory: @escaping () -> RecFileWriting, input: RecInputCapturing?, clock: RecHostClock, files: RecFiling, events: ShotEventHub? = nil) {
        self.capture = capture
        self.writerFactory = writerFactory
        self.input = input
        self.clock = clock
        self.files = files
        self.events = events
    }

    public var state: RecState { machine.state }
    public var elapsed: Double { hub?.elapsed(at: clock.hostNow) ?? 0 }

    private func transition(_ a: RecAction) -> RecTransition {
        let t = machine.send(a)
        if t.accepted, t.from != t.to { onState?(t.to) }
        return t
    }

    public func start(config: RecCaptureConfig, settings: RecSettings, layout: RecTrackLayout, paths: RecSavePaths, countdown: Int) async {
        guard !machine.state.isActive else { return }
        self.config = config
        self.settings = settings
        self.layout = layout
        self.paths = paths
        warnings = layout.warnings
        failure = nil
        result = nil
        stopReason = nil
        let t = transition(.start(countdown: max(countdown, 0)))
        guard t.accepted else { return }
        if t.effects.contains(.beginCapture) { await beginCapture() }
    }

    public func tick() async {
        let t = transition(.tick)
        if t.effects.contains(.beginCapture) { await beginCapture() }
    }

    public func cancelCountdown() { _ = transition(.cancel) }

    public func completeCountdown() async {
        while case .countdown = machine.state { await tick() }
    }

    private func beginCapture() async {
        guard let config, let paths else { return }
        guard files.makeDirectory(paths.directory) else {
            await failNow("Не удалось создать папку для записи")
            return
        }
        let w = writerFactory()
        let wcfg = RecWriterConfig(url: URL(fileURLWithPath: paths.partialPath), layout: layout, width: config.plan.pixelWidth, height: config.plan.pixelHeight, fps: config.fps,
                                   codec: settings.codec, container: settings.container,
                                   videoBitrate: RecEstimate.videoBitrate(width: config.plan.pixelWidth, height: config.plan.pixelHeight, fps: config.fps, quality: settings.quality, codec: settings.codec))
        do { try w.prepare(wcfg) } catch {
            await failNow("Не удалось начать запись файла: \(error)")
            return
        }
        writer = w
        let h = RecSampleHub(enabled: layout.enabled, mapper: RecInputMapper(captureRect: config.plan.pointRect), writer: w)
        hub = h
        h.begin(at: clock.hostNow)
        input?.start { [weak h] raw in h?.ingest(input: raw) }
        do {
            try await capture.start(config, onSample: { [weak h] s in h?.ingest(s) }, onStop: { [weak self] m in
                Task { await self?.captureStopped(m) }
            })
        } catch {
            input?.stop()
            await failNow("Не удалось начать захват: \(error)")
            return
        }
        events?.emit(.recordingStarted)
    }

    private func captureStopped(_ message: String) async {
        guard machine.state.isCapturing else { return }
        await failNow("Захват остановился: \(message)")
    }

    private func failNow(_ message: String) async {
        failure = message
        let t = transition(.fail(message))
        if t.effects.contains(where: { if case .endCapture = $0 { return true } else { return false } }) {
            hub?.stop(at: clock.hostNow)
            await capture.stop()
            input?.stop()
        }
        writer?.cancel()
        if let p = paths?.partialPath { _ = files.remove(p) }
        events?.emit(.recordingFailed(reason: message))
    }

    public func pause() {
        let t = transition(.pause)
        guard t.accepted else { return }
        hub?.pause(at: clock.hostNow)
        events?.emit(.recordingPaused)
    }

    public func resume() {
        let t = transition(.resume)
        guard t.accepted else { return }
        hub?.resume(at: clock.hostNow)
        events?.emit(.recordingResumed)
    }

    public func togglePause() {
        if machine.state == .paused { resume() } else { pause() }
    }

    public func checkGuards() async -> RecGuard.Verdict {
        guard machine.state.isCapturing, let paths else { return .ok }
        let v = RecGuard.check(elapsed: elapsed, maxMinutes: settings.maxMinutes, freeBytes: files.freeBytes(at: paths.directory), minFreeMegabytes: settings.minFreeMegabytes)
        switch v {
        case .ok: break
        case .lowDisk:
            warnings.append("Запись остановлена: на диске мало места")
            await stop()
        case .durationLimit:
            warnings.append("Запись остановлена: достигнут предел длительности")
            await stop()
        }
        return v
    }

    @discardableResult
    public func stop() async -> RecSessionResult? { await finish(discard: false) }

    public func cancel() async {
        if machine.state.isCountdown { cancelCountdown(); return }
        _ = await finish(discard: true)
    }

    private func finish(discard: Bool) async -> RecSessionResult? {
        let t = transition(discard ? .cancel : .stop)
        guard t.accepted, let hub, let writer, let paths, let config else { return nil }
        let now = clock.hostNow
        hub.stop(at: now)
        await capture.stop()
        input?.stop()
        let snap = hub.snapshot
        let duration = snap.router.duration ?? 0
        if discard {
            writer.cancel()
            _ = files.remove(paths.partialPath)
            _ = transition(.finalized)
            return nil
        }
        let r = await writer.finish(endTime: duration)
        switch r {
        case .failure(let f):
            _ = files.remove(paths.partialPath)
            failure = f.message
            _ = transition(.fail(f.message))
            events?.emit(.recordingFailed(reason: f.message))
            return nil
        case .success(let info):
            guard files.move(paths.partialPath, to: paths.finalPath) else {
                _ = files.remove(paths.partialPath)
                failure = "Не удалось сохранить файл записи"
                _ = transition(.fail(failure ?? ""))
                events?.emit(.recordingFailed(reason: failure ?? ""))
                return nil
            }
            if info.framesWritten == 0 { warnings.append("В файле нет кадров: экран мог не обновляться") }
            var log = snap.log
            log.duration = duration
            let res = RecSessionResult(path: paths.finalPath, bytes: files.size(paths.finalPath) ?? info.bytes, duration: duration, plan: config.plan, layout: layout, log: log,
                                       stats: snap.router.stats, fileName: paths.fileName, warnings: warnings)
            result = res
            _ = transition(.finalized)
            events?.emit(.recordingStopped(path: paths.finalPath))
            return res
        }
    }

    public func reset() { _ = transition(.reset) }
}

private extension RecState {
    var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }
}
