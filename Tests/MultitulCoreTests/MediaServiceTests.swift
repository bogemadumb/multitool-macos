import Testing
import Foundation
@testable import MultitulCore

private let probeVideo = #"{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30/1"},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"100","size":"5000000","bit_rate":"400000"}}"#
private let probePhoto = #"{"streams":[{"codec_type":"video","codec_name":"png","width":3000,"height":2000}],"format":{"format_name":"png_pipe"}}"#

@MainActor
private struct MRig {
    let runner = MgrRunner()
    let files: MgrFiles
    let images: MgrImages
    let ocr = MgrOcr()
    let service: MediaService

    init(tools: [String] = ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", "/opt/homebrew/bin/yt-dlp"], settings: MediaSettings = MediaSettings(), seed: [String: Int64] = [:]) {
        files = MgrFiles(seed)
        images = MgrImages(files: files)
        let f = files
        runner.hook = { cmd in
            if cmd.executable.hasSuffix("/ffmpeg"), let out = cmd.arguments.last, out.contains(".multitul-") || out.hasSuffix(".png") { f.put(out, 4000) }
        }
        service = MediaService(runner: runner, locator: ToolLocator(files: mgrFiles(executables: tools)), files: files, images: images, ocr: ocr, settings: settings)
    }

    func scriptProbe(_ json: String = probeVideo) { runner.on("-v error -print_format json", out: json) }
    func ffmpegCalls() -> [ManagerCommand] { runner.calls.filter { $0.executable.hasSuffix("/ffmpeg") } }
}

@Suite struct MediaToolCheckTests {
    @Test func detectsAllThreeTools() {
        let p = MediaToolCheck.detect(ToolLocator(files: mgrFiles(executables: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffprobe", "/opt/homebrew/bin/yt-dlp"])))
        #expect(p == MediaToolPaths(ffmpeg: "/opt/homebrew/bin/ffmpeg", ffprobe: "/usr/local/bin/ffprobe", ytDlp: "/opt/homebrew/bin/yt-dlp"))
        #expect(p.canProcess && p.ffmpegDirectory == "/opt/homebrew/bin")
    }

    @Test func missingToolsProduceABrewCommand() {
        let none = MediaToolCheck.detect(ToolLocator(files: mgrFiles()))
        let m = MediaToolCheck.missing(none)
        #expect(m.map(\.name) == ["ffmpeg"] && !none.canProcess)
        #expect(MediaToolCheck.installCommand(for: m) == "brew install ffmpeg")
        #expect(MediaToolCheck.installCommand(for: MediaToolCheck.missing(none, needsDownload: true)) == "brew install ffmpeg yt-dlp")
    }

    @Test func ffprobeAloneMissingIsReportedOnceAsFfmpeg() {
        let p = MediaToolPaths(ffmpeg: "/opt/homebrew/bin/ffmpeg")
        let m = MediaToolCheck.missing(p)
        #expect(m.map(\.name) == ["ffprobe"] && MediaToolCheck.installCommand(for: m) == "brew install ffmpeg")
    }

    @Test func nothingMissingMeansNoCommand() {
        let p = MediaToolPaths(ffmpeg: "/a/ffmpeg", ffprobe: "/a/ffprobe", ytDlp: "/a/yt-dlp")
        #expect(MediaToolCheck.missing(p, needsDownload: true).isEmpty && MediaToolCheck.installCommand(for: []) == nil)
    }
}

@Suite struct MediaNamingTests {
    @Test func suffixAndExtension() {
        let p = MediaOutputNamer.path(input: "/v/clip.mov", suffix: "-compressed", ext: "mp4", folder: "", overwrite: false, taken: { _ in false })
        #expect(p == "/v/clip-compressed.mp4")
    }

    @Test func takenNamesGetANumber() {
        let taken: Set<String> = ["/v/clip-compressed.mp4", "/v/clip-compressed 2.mp4"]
        let p = MediaOutputNamer.path(input: "/v/clip.mov", suffix: "-compressed", ext: "mp4", folder: "", overwrite: false, taken: { taken.contains($0) })
        #expect(p == "/v/clip-compressed 3.mp4")
    }

    @Test func outputFolderOverridesTheSourceFolder() {
        #expect(MediaOutputNamer.path(input: "/v/clip.mov", suffix: "", ext: "gif", folder: "/out", overwrite: false, taken: { _ in false }) == "/out/clip.gif")
    }

    @Test func overwriteIgnoresExistingFilesButNeverTheInput() {
        #expect(MediaOutputNamer.path(input: "/v/a.png", suffix: "", ext: "jpg", folder: "", overwrite: true, taken: { _ in true }) == "/v/a.jpg")
        #expect(MediaOutputNamer.path(input: "/v/a.png", suffix: "", ext: "png", folder: "", overwrite: true, taken: { _ in true }) == "/v/a 2.png")
    }

    @Test func dotsInNamesSurvive() {
        #expect(MediaOutputNamer.path(input: "/v/my.holiday.2025.mov", suffix: "-trimmed", ext: "mov", folder: "", overwrite: false, taken: { _ in false }) == "/v/my.holiday.2025-trimmed.mov")
    }

    @Test func tempFileIsHiddenAndKeepsTheExtension() {
        let t = MediaOutputNamer.tempPath(forFinal: "/v/clip-compressed.mp4", token: 7)
        #expect(t == "/v/.clip-compressed.multitul-part7.mp4")
        #expect(MediaFormats.kind(of: t) == .video)
    }

    @Test func operationsKnowTheirSuffixAndExtension() {
        #expect(MediaOperation.compress(VideoCompressOptions()).outputExtension(forInput: "a.mov") == "mp4")
        #expect(MediaOperation.trim(TrimOptions(start: 1)).outputExtension(forInput: "a.MOV") == "mov")
        #expect(MediaOperation.extractAudio(.m4a, kbps: 128).outputExtension(forInput: "a.mp4") == "m4a")
        #expect(MediaOperation.convertImage({ var o = ImageConvertOptions(); o.format = .jpeg; return o }()).outputExtension(forInput: "a.heic") == "jpg")
        #expect(MediaOperation.gif(GifOptions()).outputExtension(forInput: "a.mp4") == "gif")
        #expect(MediaOperation.compress(VideoCompressOptions()).suffix == "-compressed" && MediaOperation.watermark(WatermarkOptions(source: .text("x"))).suffix == "-watermark")
    }
}

@MainActor @Suite struct MediaPlanTests {
    @Test func unknownExtensionsAreRejected() {
        let r = MRig()
        #expect(throws: MediaError.self) { try r.service.plan(.compress(VideoCompressOptions()), input: "/v/readme.pdf") }
    }

    @Test func operationMustMatchTheFileKind() {
        let r = MRig()
        #expect(throws: MediaError.self) { try r.service.plan(.compress(VideoCompressOptions()), input: "/v/photo.png") }
        #expect(throws: MediaError.self) { try r.service.plan(.convertImage(ImageConvertOptions()), input: "/v/clip.mp4") }
        #expect(throws: MediaError.self) { try r.service.plan(.gif(GifOptions()), input: "/v/song.mp3") }
        #expect((try? r.service.plan(.trim(TrimOptions(start: 1)), input: "/v/song.mp3")) != nil)
        #expect((try? r.service.plan(.watermark(WatermarkOptions(source: .text("x"))), input: "/v/photo.jpg")) != nil)
    }

    @Test func missingFfmpegBlocksVideoWork() {
        let r = MRig(tools: [])
        #expect(throws: MediaError.toolMissing("ffmpeg")) { try r.service.plan(.compress(VideoCompressOptions()), input: "/v/a.mp4") }
        #expect(r.service.missingTools.map(\.name) == ["ffmpeg"] && r.service.installHint == "brew install ffmpeg")
    }

    @Test func imageConversionAndOcrNeedNoFfmpeg() {
        let r = MRig(tools: [])
        #expect((try? r.service.plan(.convertImage(ImageConvertOptions()), input: "/v/a.heic")) != nil)
        #expect((try? r.service.plan(.extractText(at: 0), input: "/v/a.png")) != nil)
        var webp = ImageConvertOptions()
        webp.format = .webp
        #expect(throws: MediaError.toolMissing("ffmpeg")) { try r.service.plan(.convertImage(webp), input: "/v/a.png") }
        #expect(throws: MediaError.self) { try r.service.plan(.extractText(at: 1), input: "/v/a.mp4") }
    }

    @Test func ffprobeMissingStopsVideoWork() {
        let r = MRig(tools: ["/opt/homebrew/bin/ffmpeg"])
        #expect(throws: MediaError.toolMissing("ffprobe")) { try r.service.plan(.gif(GifOptions()), input: "/v/a.mp4") }
    }

    @Test func existingOutputsAreAvoided() throws {
        let r = MRig(seed: ["/v/a-compressed.mp4": 1])
        let p = try r.service.plan(.compress(VideoCompressOptions()), input: "/v/a.mp4")
        #expect(p.output == "/v/a-compressed 2.mp4")
    }

    @Test func queuedJobsReserveTheirOutputs() throws {
        let r = MRig()
        r.runner.on("", hang: true)
        let a = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mp4")
        let b = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mp4")
        #expect(r.service.plan(forJob: a)?.output == "/v/a-compressed.mp4" && r.service.plan(forJob: b)?.output == "/v/a-compressed 2.mp4")
        r.service.cancelAll()
    }
}

@MainActor @Suite struct MediaJobTests {
    private func done(_ r: MRig) async { await r.service.queue.waitUntilIdle() }

    @Test func compressRunsProbeThenFfmpegAndMovesTheResult() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", lines: [ManagerLine(.out, "out_time_us=50000000"), ManagerLine(.out, "speed=2.0x"), ManagerLine(.out, "progress=continue"), ManagerLine(.out, "out_time_us=100000000"), ManagerLine(.out, "progress=end")])
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        let j = try #require(r.service.queue.job(id))
        #expect(j.state == .succeeded && j.result == "/v/a-compressed.mp4" && j.progress == 1)
        #expect(r.files.exists("/v/a-compressed.mp4") && r.files.moves.count == 1 && r.files.moves[0].0 == "/v/.a-compressed.multitul-part1.mp4")
        let calls = r.runner.calls
        #expect(calls.first?.executable == "/opt/homebrew/bin/ffprobe" && calls.last?.executable == "/opt/homebrew/bin/ffmpeg")
        #expect(calls.last?.arguments.contains("/v/a.mov") == true && calls.last?.arguments.last == "/v/.a-compressed.multitul-part1.mp4")
    }

    @Test func progressTracksTheStream() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", lines: [ManagerLine(.out, "out_time_us=25000000"), ManagerLine(.out, "speed=1.0x"), ManagerLine(.out, "progress=continue")], hang: true)
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await mgrWait { r.service.queue.job(id)?.progress != nil }
        #expect(r.service.queue.job(id)?.progress == 0.25 && r.service.queue.job(id)?.detail == "осталось 1 мин 15 с")
        r.service.cancel(id)
        await done(r)
    }

    @Test func cancelStopsFfmpegAndRemovesThePartialFile() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", hang: true)
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await mgrWait { r.ffmpegCalls().count == 1 }
        r.service.cancel(id)
        await done(r)
        #expect(r.service.queue.job(id)?.state == .cancelled)
        #expect(r.files.removed.contains("/v/.a-compressed.multitul-part1.mp4") && !r.files.exists("/v/a-compressed.mp4") && r.files.moves.isEmpty)
    }

    @Test func ffmpegFailureShowsTheTailOfStderr() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", status: 1, err: "noise\n[libx264] broken\nError while opening encoder\nConversion failed!")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("Conversion failed!") && !m.contains("noise"))
        #expect(r.files.removed.contains("/v/.a-compressed.multitul-part1.mp4"))
    }

    @Test func probeFailureNeverStartsFfmpeg() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.runner.on("-v error", status: 1, err: "a.mov: Invalid data found when processing input")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("Invalid data") && r.ffmpegCalls().isEmpty)
    }

    @Test func invalidOptionsAreReportedAsAJobFailure() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        let id = try r.service.submit(.trim(TrimOptions(start: 500)), input: "/v/a.mov")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("обрезки") && r.ffmpegCalls().isEmpty)
    }

    @Test func tooSmallTargetSizeFailsBeforeEncoding() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        var o = VideoCompressOptions()
        o.mode = .targetSize(1000)
        let id = try r.service.submit(.compress(o), input: "/v/a.mov")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("слишком мал") && r.ffmpegCalls().isEmpty)
    }

    @Test func ffmpegThatWritesNothingFails() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.runner.hook = nil
        r.scriptProbe()
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("не создал"))
    }

    @Test func outputAppearingDuringTheRunGetsANumber() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        let files = r.files
        let base = r.runner.hook
        r.runner.hook = { cmd in base?(cmd); if cmd.executable.hasSuffix("/ffmpeg") { files.put("/v/a-compressed.mp4", 1) } }
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        #expect(r.service.queue.job(id)?.result == "/v/a-compressed 2.mp4" && r.files.size("/v/a-compressed.mp4") == 1)
    }

    @Test func failedMoveIsReported() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.files.failMove = true
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        if case .failed = r.service.queue.job(id)?.state {} else { Issue.record("expected failure") }
        #expect(r.files.removed.contains("/v/.a-compressed.multitul-part1.mp4"))
    }

    @Test func outputFolderIsCreated() async throws {
        var s = MediaSettings()
        s.outputFolder = "/Users/x/Out"
        let r = MRig(settings: s, seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.compress(VideoCompressOptions()), input: "/v/a.mov")
        await done(r)
        #expect(r.files.directories.contains("/Users/x/Out") && r.service.queue.job(id)?.result == "/Users/x/Out/a-compressed.mp4")
    }

    @Test func gifJobUsesTheProbedDuration() async throws {
        let r = MRig(seed: ["/v/a.mov": 9000])
        r.scriptProbe()
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.gif(GifOptions()), input: "/v/a.mov")
        await done(r)
        #expect(r.service.queue.job(id)?.result == "/v/a.gif")
        #expect(r.ffmpegCalls().first?.arguments.contains("-filter_complex") == true)
    }

    @Test func imageConversionGoesThroughImageIO() async throws {
        let r = MRig(tools: [], seed: ["/v/a.heic": 9000])
        var o = ImageConvertOptions()
        o.format = .jpeg
        o.quality = 70
        let id = try r.service.submit(.convertImage(o), input: "/v/a.heic")
        await done(r)
        #expect(r.service.queue.job(id)?.state == .succeeded && r.service.queue.job(id)?.result == "/v/a.jpg")
        #expect(r.images.conversions.count == 1 && r.images.conversions[0].2.quality == 70 && r.runner.calls.isEmpty)
    }

    @Test func imageIOFailureFallsBackToFfmpeg() async throws {
        let r = MRig(seed: ["/v/a.png": 9000])
        r.images.fail = true
        r.scriptProbe(probePhoto)
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.convertImage(ImageConvertOptions()), input: "/v/a.png")
        await done(r)
        #expect(r.service.queue.job(id)?.state == .succeeded && r.ffmpegCalls().count == 1)
        #expect(r.service.queue.job(id)?.log.contains { $0.contains("ImageIO") } == true)
    }

    @Test func webpIsAlwaysWrittenByFfmpeg() async throws {
        let r = MRig(seed: ["/v/a.png": 9000])
        r.scriptProbe(probePhoto)
        r.runner.on("-hide_banner", out: "")
        var o = ImageConvertOptions()
        o.format = .webp
        let id = try r.service.submit(.convertImage(o), input: "/v/a.png")
        await done(r)
        #expect(r.images.conversions.isEmpty && r.service.queue.job(id)?.result == "/v/a.webp")
        #expect(r.ffmpegCalls().first?.arguments.contains("libwebp") == true)
    }

    @Test func batchRejectsOnlyTheBadFiles() async {
        let r = MRig(tools: [], seed: [:])
        let res = r.service.submitBatch(.convertImage(ImageConvertOptions()), inputs: ["/v/a.heic", "/v/b.png", "/v/notes.txt", "/v/clip.mp4"])
        #expect(res.jobs.count == 2 && Set(res.rejected.keys) == ["/v/notes.txt", "/v/clip.mp4"])
        await done(r)
        #expect(r.images.conversions.count == 2)
    }

    @Test func batchOutputsDoNotCollide() async {
        let r = MRig(tools: [], seed: [:])
        let res = r.service.submitBatch(.convertImage(ImageConvertOptions()), inputs: ["/v/a.heic", "/v/a.png"])
        await done(r)
        let results = res.jobs.compactMap { r.service.queue.job($0)?.result }
        #expect(results.sorted() == ["/v/a 2.jpg", "/v/a.jpg"])
    }

    @Test func textFromAnImage() async throws {
        let r = MRig(tools: [], seed: ["/v/a.png": 9000])
        r.ocr.text = "Накладная №5"
        let id = try r.service.submit(.extractText(at: 0), input: "/v/a.png")
        await done(r)
        #expect(r.service.queue.job(id)?.result == "Накладная №5" && r.ocr.paths == ["/v/a.png"])
    }

    @Test func textFromAVideoFrameCleansUpTheTempImage() async throws {
        let r = MRig(seed: ["/v/a.mp4": 9000])
        r.runner.on("-hide_banner", out: "")
        let id = try r.service.submit(.extractText(at: 12), input: "/v/a.mp4")
        await done(r)
        let frame = try #require(r.ocr.paths.first)
        #expect(frame.hasSuffix(".png") && r.files.removed.contains(frame))
        #expect(r.service.queue.job(id)?.state == .succeeded)
        #expect(r.ffmpegCalls().first?.arguments.contains("12") == true)
    }

    @Test func emptyOcrResultIsAnError() async throws {
        let r = MRig(tools: [], seed: ["/v/a.png": 9000])
        r.ocr.text = ""
        let id = try r.service.submit(.extractText(at: 0), input: "/v/a.png")
        await done(r)
        #expect(r.service.queue.job(id)?.state == .failed("Текст не найден"))
    }

    @Test func downloadReportsProgressAndTheFinalFile() async throws {
        let r = MRig()
        r.runner.on("--no-playlist", lines: [ManagerLine(.out, "download:  10.0%|1.0MiB/s|00:30"), ManagerLine(.out, "[download] Destination: /Users/x/Downloads/v [abc].mp4"), ManagerLine(.out, "download: 100%|NA|NA")])
        let id = try r.service.submitDownload(url: "https://example.com/v", mode: .bestVideo, folder: "/Users/x/Downloads")
        await done(r)
        let j = r.service.queue.job(id)
        #expect(j?.state == .succeeded && j?.result == "/Users/x/Downloads/v [abc].mp4" && j?.kind == "download")
        #expect(r.runner.calls.first?.executable == "/opt/homebrew/bin/yt-dlp" && r.runner.calls.first?.arguments.last == "https://example.com/v")
    }

    @Test func downloadFailureAndGuards() async throws {
        let r = MRig()
        r.runner.on("--no-playlist", status: 1, err: "WARNING: x\nERROR: Unsupported URL: https://example.com/v")
        let id = try r.service.submitDownload(url: "https://example.com/v", mode: .audio(.m4a), folder: "/x")
        await done(r)
        guard case .failed(let m)? = r.service.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("Unsupported URL"))
        #expect(throws: MediaError.self) { try r.service.submitDownload(url: "-o /etc/x", mode: .bestVideo, folder: "/x") }
        let bare = MRig(tools: ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe"])
        #expect(throws: MediaError.toolMissing("yt-dlp")) { try bare.service.submitDownload(url: "https://example.com", mode: .bestVideo, folder: "/x") }
    }

    @Test func finishMessages() {
        func snap(_ s: JobState) -> JobSnapshot { JobSnapshot(id: 1, title: "Сжатие: a.mov", kind: "media", state: s, progress: nil, detail: "", log: [], result: "") }
        #expect(MediaService.finishMessage(snap(.succeeded))?.title == "Готово")
        #expect(MediaService.finishMessage(snap(.failed("x")))?.body == "Сжатие: a.mov: x")
        #expect(MediaService.finishMessage(snap(.cancelled)) == nil && MediaService.finishMessage(snap(.running)) == nil)
    }

    @Test func parallelJobsSettingSizesTheQueue() {
        var s = MediaSettings()
        s.parallelJobs = 3
        #expect(MRig(settings: s).service.queue.maxConcurrent == 3)
        s.parallelJobs = 99
        #expect(MRig(settings: s).service.queue.maxConcurrent == 3)
    }
}

@Suite struct MediaSettingsTests {
    @Test func defaultsAreNotPersisted() {
        let kv = WndMemoryStore()
        MediaSettingsStore(kv).save(MediaSettings())
        #expect(kv.values.isEmpty)
        #expect(MediaSettingsStore(kv).load() == MediaSettings())
    }

    @Test func roundTrip() {
        let kv = WndMemoryStore()
        var s = MediaSettings()
        s.outputFolder = "/Users/x/Out"
        s.codec = .hevc
        s.quality = 80
        s.preset = "slow"
        s.hardwareEncoder = true
        s.imageFormat = .webp
        s.watermarkCorner = .topLeft
        s.parallelJobs = 2
        s.revealWhenDone = true
        MediaSettingsStore(kv).save(s)
        #expect(MediaSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("mediaTools.") && $0.allSatisfy(\.isASCII) })
    }

    @Test func outOfRangeValuesAreClamped() {
        let kv = WndMemoryStore()
        kv.set(5000, forKey: "mediaTools.quality")
        kv.set(-3, forKey: "mediaTools.gifFps")
        kv.set(99, forKey: "mediaTools.parallel")
        kv.set("warp", forKey: "mediaTools.preset")
        kv.set("avi", forKey: "mediaTools.codec")
        let s = MediaSettingsStore(kv).load()
        #expect(s.quality == 100 && s.gifFps == 1 && s.parallelJobs == 3 && s.preset == "medium" && s.codec == .h264)
    }

    @Test func optionsInheritFromSettings() {
        var s = MediaSettings()
        s.codec = .hevc
        s.preset = "fast"
        s.maxHeight = 720
        s.hardwareEncoder = true
        s.imageMaxSide = 2000
        let v = VideoCompressOptions(settings: s)
        #expect(v.codec == .hevc && v.preset == "fast" && v.maxHeight == 720 && v.hardware && v.mode == .quality(60))
        #expect(ImageConvertOptions(settings: s).maxSide == 2000)
        #expect(VideoCompressOptions(settings: s, mode: .targetSize(5)).mode == .targetSize(5))
    }
}
