import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

final class RecFakeClock: RecHostClock {
    var hostNow: Double = 1000
}

final class RecFakeCapture: RecCapturing, @unchecked Sendable {
    var config: RecCaptureConfig?
    var onSample: (@Sendable (RecSample) -> Void)?
    var onStop: (@Sendable (String) -> Void)?
    var startError: Error?
    var starts = 0
    var stops = 0

    func start(_ config: RecCaptureConfig, onSample: @escaping @Sendable (RecSample) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws {
        starts += 1
        if let startError { throw startError }
        self.config = config
        self.onSample = onSample
        self.onStop = onStop
    }

    func stop() async { stops += 1 }
    func emit(_ s: RecSample) { onSample?(s) }
}

final class RecFakeWriter: RecFileWriting, @unchecked Sendable {
    var prepared: RecWriterConfig?
    var appended: [(track: RecTrackKind, out: Double, trim: Double)] = []
    var prepareError: Error?
    var finishResult: Result<RecFinishInfo, RecFailure> = .success(RecFinishInfo(bytes: 4_200_000, framesWritten: 90, framesDropped: 0))
    var finishEnd: Double?
    var cancelled = false

    func prepare(_ config: RecWriterConfig) throws {
        if let prepareError { throw prepareError }
        prepared = config
    }

    func append(_ sample: RecSample, outPTS: Double, trimHead: Double) { appended.append((sample.track, outPTS, trimHead)) }

    func finish(endTime: Double) async -> Result<RecFinishInfo, RecFailure> {
        finishEnd = endTime
        return finishResult
    }

    func cancel() { cancelled = true }
}

final class RecFakeInput: RecInputCapturing, @unchecked Sendable {
    var onEvent: (@Sendable (RecRawInput) -> Void)?
    var starts = 0
    var stops = 0
    func start(onEvent: @escaping @Sendable (RecRawInput) -> Void) { starts += 1; self.onEvent = onEvent }
    func stop() { stops += 1 }
}

final class RecFakeFiles: RecFiling {
    var existing: Set<String> = []
    var sizes: [String: Int] = [:]
    var moves: [(String, String)] = []
    var removed: [String] = []
    var dirs: [String] = []
    var dirOK = true
    var moveOK = true
    var free: Int? = 50_000_000_000

    func exists(_ path: String) -> Bool { existing.contains(path) }
    func makeDirectory(_ path: String) -> Bool { dirs.append(path); return dirOK }

    func move(_ from: String, to: String) -> Bool {
        guard moveOK else { return false }
        moves.append((from, to))
        existing.insert(to)
        return true
    }

    func remove(_ path: String) -> Bool { removed.append(path); return true }
    func size(_ path: String) -> Int? { sizes[path] }
    func freeBytes(at path: String) -> Int? { free }
}

private struct Boom: Error {}

private let display = ShotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)

private struct Rig {
    let clock = RecFakeClock()
    let capture = RecFakeCapture()
    let writer = RecFakeWriter()
    let input = RecFakeInput()
    let files = RecFakeFiles()
    let hub = ShotEventHub()
    let session: RecSession
    var settings = RecSettings()
    let events = EventBox()

    final class EventBox { var list: [ShotEvent] = []; var states: [RecState] = [] }

    init(configure: (inout RecSettings) -> Void = { _ in }) {
        var s = RecSettings()
        s.minFreeMegabytes = 500
        configure(&s)
        settings = s
        session = RecSession(capture: capture, writerFactory: { [writer] in writer }, input: input, clock: clock, files: files, events: hub)
        let box = events
        hub.subscribe { box.list.append($0) }
        session.onState = { box.states.append($0) }
    }

    var plan: RecCapturePlan { RecGeometry.plan(mode: .area, rect: CGRect(x: 100, y: 100, width: 800, height: 600), displays: [display], resolution: .native)! }

    var paths: RecSavePaths {
        RecSavePaths(directory: "/rec", fileName: "Запись.mp4", finalPath: "/rec/Запись.mp4", partialPath: "/rec/.Запись.part.mp4")
    }

    func begin(countdown: Int = 0, mic: Bool = false) async {
        var s = settings
        s.microphone = mic
        let layout = RecTrackLayout.make(settings: s, micAvailable: true)
        let cfg = RecCaptureConfig(plan: plan, fps: s.fps, showCursor: true, systemAudio: s.systemAudio, microphone: s.microphone, micDeviceUID: "", excludeOwnWindows: true)
        await session.start(config: cfg, settings: s, layout: layout, paths: paths, countdown: countdown)
    }

    func video(at host: Double, dur: Double = 0.033) { capture.emit(RecSample(track: .video, pts: host, duration: dur)) }
    func audio(_ k: RecTrackKind = .systemAudio, at host: Double, dur: Double = 0.02) { capture.emit(RecSample(track: k, pts: host, duration: dur)) }
}

@Suite struct RecSessionTests {
    @Test func startWithoutCountdownConfiguresWriterAndCapture() async {
        let r = Rig()
        await r.begin()
        #expect(r.session.state == .recording && r.capture.starts == 1 && r.input.starts == 1)
        let w = r.writer.prepared!
        #expect(w.width == 1600 && w.height == 1200 && w.fps == 30 && w.codec == .h264 && w.container == .mp4 && w.url.path == "/rec/.Запись.part.mp4")
        #expect(w.videoBitrate == RecEstimate.videoBitrate(width: 1600, height: 1200, fps: 30, quality: .high, codec: .h264))
        #expect(w.layout.tracks.map(\.kind) == [.video, .systemAudio])
    }

    @Test func directoryIsCreatedBeforeRecording() async {
        let r = Rig()
        await r.begin()
        #expect(r.files.dirs == ["/rec"])
    }

    @Test func countdownDelaysTheCapture() async {
        let r = Rig()
        await r.begin(countdown: 2)
        #expect(r.session.state == .countdown(remaining: 2) && r.capture.starts == 0)
        await r.session.tick()
        #expect(r.session.state == .countdown(remaining: 1) && r.capture.starts == 0)
        await r.session.tick()
        #expect(r.session.state == .recording && r.capture.starts == 1)
    }

    @Test func cancellingTheCountdownNeverStartsCapture() async {
        let r = Rig()
        await r.begin(countdown: 3)
        await r.session.cancel()
        #expect(r.session.state == .idle && r.capture.starts == 0 && r.writer.prepared == nil)
    }

    @Test func videoIsRetimedAgainstTheStartMoment() async {
        let r = Rig()
        r.clock.hostNow = 1000
        await r.begin()
        r.video(at: 1000.5)
        #expect(r.writer.appended.count == 1 && abs(r.writer.appended[0].out - 0.5) < 1e-9)
    }

    @Test func micAndSystemAudioShareTheVideoTimeline() async {
        let r = Rig()
        await r.begin(mic: true)
        r.video(at: 1001)
        r.audio(.systemAudio, at: 1001)
        r.audio(.microphone, at: 1001)
        #expect(r.writer.appended.map(\.track) == [.video, .systemAudio, .microphone])
        #expect(Set(r.writer.appended.map { $0.out }).count == 1)
    }

    @Test func pausedSamplesAreDroppedAndTimeResumesSeamlessly() async {
        let r = Rig()
        await r.begin()
        r.video(at: 1001)
        r.clock.hostNow = 1002
        r.session.pause()
        r.video(at: 1003)
        r.audio(at: 1003)
        r.clock.hostNow = 1007
        r.session.resume()
        r.video(at: 1007.1)
        #expect(r.writer.appended.count == 2 && abs(r.writer.appended[1].out - 2.1) < 1e-9)
        #expect(r.session.state == .recording)
    }

    @Test func elapsedExcludesPausedTime() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1004
        r.session.pause()
        r.clock.hostNow = 1010
        #expect(abs(r.session.elapsed - 4) < 1e-9)
        r.session.resume()
        r.clock.hostNow = 1013
        #expect(abs(r.session.elapsed - 7) < 1e-9)
    }

    @Test func togglePauseFlips() async {
        let r = Rig()
        await r.begin()
        r.session.togglePause()
        #expect(r.session.state == .paused)
        r.session.togglePause()
        #expect(r.session.state == .recording)
    }

    @Test func stopFinishesTheFileAndReturnsTheResult() async {
        let r = Rig()
        r.files.sizes["/rec/Запись.mp4"] = 4_200_000
        await r.begin()
        r.video(at: 1001)
        r.clock.hostNow = 1010
        let res = await r.session.stop()
        #expect(r.session.state == .finished && res != nil)
        #expect(abs(res!.duration - 10) < 1e-9 && res!.path == "/rec/Запись.mp4" && res!.bytes == 4_200_000)
        #expect(r.files.moves.count == 1 && r.files.moves[0].0 == "/rec/.Запись.part.mp4" && r.files.moves[0].1 == "/rec/Запись.mp4")
        #expect(abs((r.writer.finishEnd ?? 0) - 10) < 1e-9 && r.capture.stops == 1 && r.input.stops == 1)
    }

    @Test func stopWhilePausedUsesActiveDurationOnly() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1005
        r.session.pause()
        r.clock.hostNow = 1020
        let res = await r.session.stop()
        #expect(abs(res!.duration - 5) < 1e-9)
    }

    @Test func samplesAfterStopAreIgnored() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1005
        _ = await r.session.stop()
        r.video(at: 1006)
        #expect(r.writer.appended.isEmpty)
    }

    @Test func stopEmitsRecordingEventsInOrder() async {
        let r = Rig()
        await r.begin()
        r.session.pause()
        r.session.resume()
        _ = await r.session.stop()
        #expect(r.events.list == [.recordingStarted, .recordingPaused, .recordingResumed, .recordingStopped(path: "/rec/Запись.mp4")])
    }

    @Test func stateCallbackSeesTheWholeLifecycle() async {
        let r = Rig()
        await r.begin()
        r.session.pause()
        r.session.resume()
        _ = await r.session.stop()
        #expect(r.events.states == [.recording, .paused, .recording, .stopping, .finished])
    }

    @Test func cancelDiscardsTheFile() async {
        let r = Rig()
        await r.begin()
        r.video(at: 1001)
        await r.session.cancel()
        #expect(r.session.state == .idle && r.writer.cancelled && r.files.removed.contains("/rec/.Запись.part.mp4") && r.files.moves.isEmpty)
        #expect(r.session.result == nil)
    }

    @Test func captureStartFailureFailsTheSession() async {
        let r = Rig()
        r.capture.startError = Boom()
        await r.begin()
        #expect(r.session.state != .recording)
        if case .failed(let m) = r.session.state { #expect(m.contains("захват")) } else { Issue.record("not failed") }
        #expect(r.input.stops >= 1 && r.writer.cancelled && r.files.removed.contains("/rec/.Запись.part.mp4"))
    }

    @Test func writerPrepareFailureNeverStartsCapture() async {
        let r = Rig()
        r.writer.prepareError = Boom()
        await r.begin()
        if case .failed = r.session.state {} else { Issue.record("not failed") }
        #expect(r.capture.starts == 0)
    }

    @Test func directoryFailureFailsEarly() async {
        let r = Rig()
        r.files.dirOK = false
        await r.begin()
        if case .failed(let m) = r.session.state { #expect(m.contains("папку")) } else { Issue.record("not failed") }
        #expect(r.writer.prepared == nil && r.capture.starts == 0)
    }

    @Test func captureStoppingByItselfFailsAndCleansUp() async {
        let r = Rig()
        await r.begin()
        r.capture.onStop?("display disconnected")
        try? await Task.sleep(nanoseconds: 80_000_000)
        if case .failed(let m) = r.session.state { #expect(m.contains("display disconnected")) } else { Issue.record("not failed: \(r.session.state)") }
        #expect(r.files.removed.contains("/rec/.Запись.part.mp4") && r.events.list.contains { if case .recordingFailed = $0 { return true } else { return false } })
    }

    @Test func writerFinishFailureIsReported() async {
        let r = Rig()
        r.writer.finishResult = .failure(RecFailure("диск полон"))
        await r.begin()
        let res = await r.session.stop()
        #expect(res == nil && r.session.state == .failed("диск полон") && r.files.moves.isEmpty && r.session.failure == "диск полон")
    }

    @Test func moveFailureIsReported() async {
        let r = Rig()
        r.files.moveOK = false
        await r.begin()
        let res = await r.session.stop()
        #expect(res == nil)
        if case .failed = r.session.state {} else { Issue.record("not failed") }
    }

    @Test func emptyRecordingGetsAWarning() async {
        let r = Rig()
        r.writer.finishResult = .success(RecFinishInfo(bytes: 1000, framesWritten: 0, framesDropped: 0))
        await r.begin()
        let res = await r.session.stop()
        #expect(res!.warnings.contains { $0.contains("нет кадров") })
    }

    @Test func layoutWarningsTravelWithTheResult() async {
        let r = Rig { $0.microphone = true }
        var s = r.settings
        s.microphone = true
        let layout = RecTrackLayout.make(settings: s, micAvailable: false)
        let cfg = RecCaptureConfig(plan: r.plan, fps: 30, showCursor: true, systemAudio: true, microphone: false, micDeviceUID: "", excludeOwnWindows: true)
        await r.session.start(config: cfg, settings: s, layout: layout, paths: r.paths, countdown: 0)
        let res = await r.session.stop()
        #expect(res!.warnings.contains { $0.contains("Микрофон") })
    }

    @Test func inputEventsLandInTheLogOnTheTimeline() async {
        let r = Rig()
        await r.begin()
        r.input.onEvent?(RecRawInput(host: 1002, kind: .down, point: CGPoint(x: 500, y: 400), button: .left))
        r.clock.hostNow = 1003
        let res = await r.session.stop()
        let clicks = res!.log.clicks
        #expect(clicks.count == 1 && abs(clicks[0].t - 2) < 1e-9)
        #expect(abs(clicks[0].x - (500.0 - 100) / 800) < 1e-9 && abs(clicks[0].y - (400.0 - 100) / 600) < 1e-9)
    }

    @Test func inputDuringPauseIsNotLogged() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1002
        r.session.pause()
        r.input.onEvent?(RecRawInput(host: 1003, kind: .down, point: CGPoint(x: 500, y: 400)))
        r.clock.hostNow = 1005
        r.session.resume()
        r.input.onEvent?(RecRawInput(host: 1006, kind: .down, point: CGPoint(x: 300, y: 300)))
        r.clock.hostNow = 1007
        let res = await r.session.stop()
        #expect(res!.log.clicks.count == 1 && abs(res!.log.clicks[0].t - 3) < 1e-9)
    }

    @Test func clickOutsideTheCaptureRectIsMarkedOutside() async {
        let r = Rig()
        await r.begin()
        r.input.onEvent?(RecRawInput(host: 1001, kind: .down, point: CGPoint(x: 1400, y: 900)))
        r.clock.hostNow = 1002
        let res = await r.session.stop()
        #expect(res!.log.events.count == 1 && !res!.log.events[0].inside && res!.log.clicks.isEmpty)
    }

    @Test func lowDiskStopsTheRecordingWithAWarning() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1010
        r.files.free = 100_000_000
        let v = await r.session.checkGuards()
        #expect(v == .lowDisk && r.session.state == .finished)
        #expect(r.session.result?.warnings.contains { $0.contains("мало места") } == true)
    }

    @Test func durationLimitStopsTheRecording() async {
        let r = Rig { $0.maxMinutes = 1 }
        await r.begin()
        r.clock.hostNow = 1000 + 61
        let v = await r.session.checkGuards()
        #expect(v == .durationLimit && r.session.state == .finished)
    }

    @Test func guardsDoNothingWhenHealthy() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1010
        let v = await r.session.checkGuards()
        #expect(v == .ok && r.session.state == .recording)
    }

    @Test func secondRecordingAfterTheFirstWorks() async {
        let r = Rig()
        await r.begin()
        r.clock.hostNow = 1005
        _ = await r.session.stop()
        r.clock.hostNow = 2000
        await r.begin()
        #expect(r.session.state == .recording && r.capture.starts == 2)
        r.video(at: 2000.2)
        #expect(abs(r.writer.appended.last!.out - 0.2) < 1e-9)
    }

    @Test func startIsIgnoredWhileActive() async {
        let r = Rig()
        await r.begin()
        await r.begin()
        #expect(r.capture.starts == 1)
    }

    @Test func statsAreReportedPerTrack() async {
        let r = Rig()
        await r.begin()
        r.video(at: 1001)
        r.video(at: 1001.5)
        r.audio(at: 1001)
        r.clock.hostNow = 1003
        let res = await r.session.stop()
        #expect(res!.stats[.video]?.written == 2 && res!.stats[.systemAudio]?.written == 1)
    }
}

@Suite struct RecSavePlannerTests {
    @Test func buildsFinalAndHiddenPartialPaths() {
        var s = RecSettings()
        s.saveDirectory = "/Users/x/Rec"
        let p = RecSavePlanner.paths(settings: s, mode: .area, appName: "Safari", windowTitle: nil, width: 800, height: 600, counter: 1,
                                     date: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!, exists: { _ in false })
        #expect(p.directory == "/Users/x/Rec" && p.fileName.hasPrefix("Запись экрана 2027-01-15") && p.fileName.hasSuffix(".mp4"))
        #expect(p.finalPath == "/Users/x/Rec/" + p.fileName)
        #expect((p.partialPath as NSString).lastPathComponent.hasPrefix(".") && p.partialPath.hasSuffix(".part.mp4"))
    }

    @Test func existingNamesGetASuffix() {
        var s = RecSettings()
        s.saveDirectory = "/r"
        s.nameTemplate = "clip"
        let p = RecSavePlanner.paths(settings: s, mode: .display, appName: nil, windowTitle: nil, width: 1, height: 1, counter: 1, date: Date(),
                                     exists: { $0 == "/r/clip.mp4" || $0 == "/r/clip 2.mp4" })
        #expect(p.fileName == "clip 3.mp4")
    }

    @Test func containerDecidesTheExtension() {
        var s = RecSettings()
        s.saveDirectory = "/r"
        s.container = .mov
        s.nameTemplate = "clip"
        let p = RecSavePlanner.paths(settings: s, mode: .area, appName: nil, windowTitle: nil, width: 1, height: 1, counter: 1, date: Date(), exists: { _ in false })
        #expect(p.fileName == "clip.mov" && p.partialPath.hasSuffix(".part.mov"))
    }

    @Test func tokensExpand() {
        var s = RecSettings()
        s.saveDirectory = "/r"
        s.nameTemplate = "{app}-{counter:3}-{size}-{mode}"
        let p = RecSavePlanner.paths(settings: s, mode: .window, appName: "Notes", windowTitle: "Todo", width: 1280, height: 720, counter: 7, date: Date(), exists: { _ in false })
        #expect(p.fileName == "Notes-007-1280x720-окно.mp4")
    }

    @Test func unsafeCharactersAreReplaced() {
        var s = RecSettings()
        s.saveDirectory = "/r"
        s.nameTemplate = "a/b:c"
        let p = RecSavePlanner.paths(settings: s, mode: .area, appName: nil, windowTitle: nil, width: 1, height: 1, counter: 1, date: Date(), exists: { _ in false })
        #expect(!p.fileName.contains("/") && !p.fileName.contains(":"))
    }

    @Test func emptyTemplateFallsBack() {
        var s = RecSettings()
        s.saveDirectory = "/r"
        s.nameTemplate = "{app}"
        let p = RecSavePlanner.paths(settings: s, mode: .area, appName: nil, windowTitle: nil, width: 1, height: 1, counter: 1, date: Date(), exists: { _ in false })
        #expect(!p.fileName.hasPrefix(".") && p.fileName.hasSuffix(".mp4") && p.fileName.count > 8)
    }
}
