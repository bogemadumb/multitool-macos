import Foundation

public struct MediaToolPaths: Equatable, Sendable {
    public var ffmpeg: String?
    public var ffprobe: String?
    public var ytDlp: String?

    public init(ffmpeg: String? = nil, ffprobe: String? = nil, ytDlp: String? = nil) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.ytDlp = ytDlp
    }

    public var canProcess: Bool { ffmpeg != nil && ffprobe != nil }
    public var ffmpegDirectory: String? { ffmpeg.map { ($0 as NSString).deletingLastPathComponent } }
}

public struct MissingMediaTool: Equatable, Sendable {
    public var name: String
    public var formula: String
}

public enum MediaToolCheck {
    public static func detect(_ locator: ToolLocator) -> MediaToolPaths {
        MediaToolPaths(ffmpeg: locator.find("ffmpeg"), ffprobe: locator.find("ffprobe"), ytDlp: locator.find("yt-dlp"))
    }

    public static func missing(_ p: MediaToolPaths, needsDownload: Bool = false) -> [MissingMediaTool] {
        var out: [MissingMediaTool] = []
        if p.ffmpeg == nil { out.append(MissingMediaTool(name: "ffmpeg", formula: "ffmpeg")) }
        if p.ffprobe == nil && p.ffmpeg != nil { out.append(MissingMediaTool(name: "ffprobe", formula: "ffmpeg")) }
        if needsDownload && p.ytDlp == nil { out.append(MissingMediaTool(name: "yt-dlp", formula: "yt-dlp")) }
        return out
    }

    public static func installCommand(for missing: [MissingMediaTool]) -> String? {
        var seen = Set<String>()
        let formulas = missing.map(\.formula).filter { seen.insert($0).inserted }
        return formulas.isEmpty ? nil : "brew install " + formulas.joined(separator: " ")
    }
}

public protocol MediaFileOps: Sendable {
    func exists(_ path: String) -> Bool
    func size(_ path: String) -> Int64?
    func move(_ from: String, to: String) throws
    func remove(_ path: String)
    func makeDirectory(_ path: String) throws
}

public protocol ImageConverting: Sendable {
    func convert(input: String, output: String, options: ImageConvertOptions) throws
}

public protocol MediaTextExtracting: Sendable {
    func extractText(imagePath: String) throws -> String
}

public enum MediaOutputNamer {
    public static func tempPath(forFinal final: String, token: Int) -> String {
        let dir = (final as NSString).deletingLastPathComponent
        let name = (final as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return dir + "/." + base + ".multitul-part\(token)." + ext
    }

    public static func path(input: String, suffix: String, ext: String, folder: String, overwrite: Bool, taken: (String) -> Bool) -> String {
        let name = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = folder.isEmpty ? (input as NSString).deletingLastPathComponent : folder
        func candidate(_ n: Int) -> String {
            let tail = n <= 1 ? "" : " \(n)"
            return dir + "/" + name + suffix + tail + "." + ext
        }
        var n = 1
        var p = candidate(n)
        while p == input || (!overwrite && taken(p)) {
            n += 1
            p = candidate(n)
            if n > 9999 { break }
        }
        return p
    }
}

public enum MediaOperation: Equatable, Sendable {
    case compress(VideoCompressOptions)
    case trim(TrimOptions)
    case gif(GifOptions)
    case watermark(WatermarkOptions)
    case extractAudio(AudioFormat, kbps: Int)
    case convertVideo(VideoContainer)
    case convertImage(ImageConvertOptions)
    case extractText(at: Double)

    public var title: String {
        switch self {
        case .compress: "Сжатие видео"
        case .trim: "Обрезка"
        case .gif: "GIF из видео"
        case .watermark: "Водяной знак"
        case .extractAudio: "Звук из файла"
        case .convertVideo: "Конвертация видео"
        case .convertImage: "Конвертация картинки"
        case .extractText: "Текст из файла"
        }
    }

    public var suffix: String {
        switch self {
        case .compress: "-compressed"
        case .trim: "-trimmed"
        case .gif: ""
        case .watermark: "-watermark"
        case .extractAudio: ""
        case .convertVideo: "-converted"
        case .convertImage: ""
        case .extractText: ""
        }
    }

    public func outputExtension(forInput input: String) -> String {
        let src = (input as NSString).pathExtension.lowercased()
        switch self {
        case .compress(let o): return o.container.fileExtension
        case .trim: return src
        case .gif: return "gif"
        case .watermark: return src
        case .extractAudio(let f, _): return f.rawValue
        case .convertVideo(let c): return c.fileExtension
        case .convertImage(let o): return o.format.fileExtension
        case .extractText: return "txt"
        }
    }

    func allows(_ kind: MediaKind) -> Bool {
        switch self {
        case .compress, .gif, .convertVideo: kind == .video
        case .trim: kind == .video || kind == .audio
        case .watermark: kind == .video || kind == .image
        case .extractAudio: kind == .video || kind == .audio
        case .convertImage: kind == .image
        case .extractText: kind == .image || kind == .video
        }
    }

    var needsProbe: Bool {
        switch self {
        case .convertImage, .extractText: false
        default: true
        }
    }
}

public struct MediaPlan: Equatable, Sendable {
    public var input: String
    public var output: String
    public var operation: MediaOperation
    public var overwrite = false
}

public struct MediaBatchResult: Equatable, Sendable {
    public var jobs: [Int]
    public var rejected: [String: MediaError]
}

struct MediaExecutor: Sendable {
    var runner: ManagerRunning
    var tools: MediaToolPaths
    var files: MediaFileOps
    var images: ImageConverting?
    var ocr: MediaTextExtracting?

    private func lastLines(_ text: String, _ n: Int = 3) -> String {
        text.split(whereSeparator: \.isNewline).suffix(n).joined(separator: " ")
    }

    private func probe(_ input: String) async -> Result<MediaInfo, MediaError> {
        guard let ffprobe = tools.ffprobe else { return .failure(.toolMissing("ffprobe")) }
        let r = await runner.run(ManagerCommand(ffprobe, FfprobeParser.arguments(for: input), timeout: 60))
        if r.cancelled { return .failure(.probeFailed("отменено")) }
        guard r.ok else { return .failure(.probeFailed(lastLines(r.stderr.isEmpty ? r.stdout : r.stderr))) }
        do { return .success(try FfprobeParser.parse(r.stdout)) } catch let e as MediaError { return .failure(e) } catch { return .failure(.probeFailed("\(error)")) }
    }

    private func invocation(_ op: MediaOperation, input: String, output: String, info: MediaInfo?) throws -> FfmpegInvocation {
        switch op {
        case .compress(let o): return try FfmpegArgs.compress(input: input, output: output, info: try need(info), options: o)
        case .trim(let o): return try FfmpegArgs.trim(input: input, output: output, info: info, options: o)
        case .gif(let o): return try FfmpegArgs.gif(input: input, output: output, info: try need(info), options: o)
        case .watermark(let o): return try FfmpegArgs.watermark(input: input, output: output, info: try need(info), options: o)
        case .extractAudio(let f, let k): return try FfmpegArgs.audio(input: input, output: output, info: info, format: f, kbps: k)
        case .convertVideo(let c): return try FfmpegArgs.convertVideo(input: input, output: output, info: try need(info), container: c)
        case .convertImage(let o): return FfmpegArgs.convertImage(input: input, output: output, info: info, options: o)
        case .extractText: throw MediaError.invalidOptions("extractText has no ffmpeg run")
        }
    }

    private func need(_ info: MediaInfo?) throws -> MediaInfo {
        guard let info else { throw MediaError.probeFailed("нет данных о файле") }
        return info
    }

    func execute(_ op: MediaOperation, plan: MediaPlan, token: Int, ctx: JobContext) async -> JobOutcome {
        if case .extractText(let at) = op { return await extractText(plan: plan, at: at, token: token) }
        if case .convertImage(let o) = op, o.format != .webp, let images {
            do {
                try? files.makeDirectory((plan.output as NSString).deletingLastPathComponent)
                let tmp = MediaOutputNamer.tempPath(forFinal: plan.output, token: token)
                try images.convert(input: plan.input, output: tmp, options: o)
                return finalize(tmp: tmp, plan: plan, token: token)
            } catch {
                ctx.log("ImageIO: \(error.localizedDescription); пробую ffmpeg")
            }
        }
        guard let ffmpeg = tools.ffmpeg else { return .failure(MediaError.toolMissing("ffmpeg").message) }
        var info: MediaInfo?
        var isImageConvert = false
        if case .convertImage = op { isImageConvert = true }
        if op.needsProbe || isImageConvert {
            switch await probe(plan.input) {
            case .success(let i): info = i
            case .failure(let e):
                if op.needsProbe { return .failure(e.message) }
            }
        }
        let tmp = MediaOutputNamer.tempPath(forFinal: plan.output, token: token)
        let inv: FfmpegInvocation
        do { inv = try invocation(op, input: plan.input, output: tmp, info: info) } catch let e as MediaError { return .failure(e.message) } catch { return .failure("\(error)") }
        do { try files.makeDirectory((plan.output as NSString).deletingLastPathComponent) } catch { return .failure(MediaError.ioFailure("\(error.localizedDescription)").message) }
        if !inv.note.isEmpty { ctx.log(inv.note) }
        let box = ProgressBox()
        let duration = inv.duration
        let result = await runner.stream(ManagerCommand(ffmpeg, inv.arguments, timeout: 6 * 3600)) { line in
            if line.stream == .out {
                if let s = box.feed(line.text) {
                    ctx.setProgress(s.fraction(duration: duration), detail: Self.etaText(s.remaining(duration: duration)))
                }
            } else if !line.text.isEmpty {
                ctx.log(line.text)
            }
        }
        if result.cancelled { files.remove(tmp); return .cancelled }
        guard result.ok else {
            files.remove(tmp)
            let detail = lastLines(result.stderr)
            return .failure(result.timedOut ? "ffmpeg не уложился во время" : (detail.isEmpty ? "ffmpeg завершился с кодом \(result.status)" : detail))
        }
        return finalize(tmp: tmp, plan: plan, token: token)
    }

    func finalize(tmp: String, plan: MediaPlan, token: Int) -> JobOutcome {
        guard let size = files.size(tmp), size > 0 else {
            files.remove(tmp)
            return .failure(MediaError.ioFailure("ffmpeg не создал файл").message)
        }
        var target = plan.output
        if files.exists(target) {
            if !(plan.overwrite && target != plan.input) {
                target = MediaOutputNamer.path(input: plan.input, suffix: plan.operation.suffix, ext: plan.operation.outputExtension(forInput: plan.input),
                                               folder: (plan.output as NSString).deletingLastPathComponent, overwrite: false, taken: files.exists)
            } else {
                files.remove(target)
            }
        }
        do { try files.move(tmp, to: target) } catch {
            files.remove(tmp)
            return .failure(MediaError.ioFailure(error.localizedDescription).message)
        }
        return .success(target)
    }

    func extractText(plan: MediaPlan, at seconds: Double, token: Int) async -> JobOutcome {
        guard let ocr else { return .failure("Распознавание текста недоступно") }
        var imagePath = plan.input
        var temp: String?
        if MediaFormats.kind(of: plan.input) == .video {
            guard let ffmpeg = tools.ffmpeg else { return .failure(MediaError.toolMissing("ffmpeg").message) }
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("multitul-frame\(token).png")
            let inv = FfmpegArgs.frame(input: plan.input, at: seconds, output: tmp)
            let r = await runner.run(ManagerCommand(ffmpeg, inv.arguments, timeout: 120))
            if r.cancelled { files.remove(tmp); return .cancelled }
            guard r.ok else { files.remove(tmp); return .failure(lastLines(r.stderr)) }
            imagePath = tmp
            temp = tmp
        }
        defer { if let temp { files.remove(temp) } }
        do {
            let text = try ocr.extractText(imagePath: imagePath)
            return text.isEmpty ? .failure("Текст не найден") : .success(text)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func etaText(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite else { return "" }
        let t = Int(s.rounded())
        return t >= 60 ? "осталось \(t / 60) мин \(t % 60) с" : "осталось \(t) с"
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = FfmpegProgressParser()

    func feed(_ line: String) -> FfmpegProgressSample? {
        lock.lock(); defer { lock.unlock() }
        return parser.feed(line)
    }
}

@MainActor
public final class MediaService {
    public let queue: JobQueue
    public private(set) var tools = MediaToolPaths()
    public var settings: MediaSettings

    private let runner: ManagerRunning
    private let locator: ToolLocator
    private let files: MediaFileOps
    private let images: ImageConverting?
    private let ocr: MediaTextExtracting?
    private var reserved: [Int: String] = [:]
    private var plans: [Int: MediaPlan] = [:]
    private var tokens = 0

    public init(runner: ManagerRunning, locator: ToolLocator, files: MediaFileOps, images: ImageConverting? = nil, ocr: MediaTextExtracting? = nil,
                queue: JobQueue? = nil, settings: MediaSettings = MediaSettings()) {
        self.runner = runner
        self.locator = locator
        self.files = files
        self.images = images
        self.ocr = ocr
        self.settings = settings.sanitized
        self.queue = queue ?? JobQueue(maxConcurrent: settings.sanitized.parallelJobs)
        let q = self.queue
        let previous = q.onFinish
        q.onFinish = { [weak self] snap in
            self?.reserved[snap.id] = nil
            previous?(snap)
        }
        refreshTools()
    }

    @discardableResult
    public func refreshTools() -> MediaToolPaths {
        tools = MediaToolCheck.detect(locator)
        return tools
    }

    public var missingTools: [MissingMediaTool] { MediaToolCheck.missing(tools) }
    public var installHint: String? { MediaToolCheck.installCommand(for: missingTools) }

    public func plan(_ op: MediaOperation, input: String) throws -> MediaPlan {
        let kind = MediaFormats.kind(of: input)
        guard kind != .unknown else { throw MediaError.unsupportedInput((input as NSString).lastPathComponent) }
        guard op.allows(kind) else { throw MediaError.unsupportedInput("\(op.title): \(kind.rawValue)") }
        if case .convertImage(let o) = op, o.format == .webp, tools.ffmpeg == nil { throw MediaError.toolMissing("ffmpeg") }
        var needsFfmpeg = true
        if case .convertImage(let o) = op, o.format != .webp, images != nil { needsFfmpeg = false }
        if case .extractText = op, kind == .image { needsFfmpeg = false }
        if needsFfmpeg && !tools.canProcess { throw MediaError.toolMissing(tools.ffmpeg == nil ? "ffmpeg" : "ffprobe") }
        let taken = Set(reserved.values)
        let ext = op.outputExtension(forInput: input)
        let out = MediaOutputNamer.path(input: input, suffix: op.suffix, ext: ext, folder: settings.outputFolder, overwrite: settings.overwriteExisting) { files.exists($0) || taken.contains($0) }
        return MediaPlan(input: input, output: out, operation: op, overwrite: settings.overwriteExisting)
    }

    @discardableResult
    public func submit(_ op: MediaOperation, input: String) throws -> Int {
        let p = try plan(op, input: input)
        tokens += 1
        let token = tokens
        let exec = MediaExecutor(runner: runner, tools: tools, files: files, images: images, ocr: ocr)
        let name = (input as NSString).lastPathComponent
        let id = queue.enqueue(title: "\(op.title): \(name)", kind: "media") { ctx in
            await exec.execute(op, plan: p, token: token, ctx: ctx)
        }
        reserved[id] = p.output
        plans[id] = p
        return id
    }

    public func submitBatch(_ op: MediaOperation, inputs: [String]) -> MediaBatchResult {
        var jobs: [Int] = []
        var rejected: [String: MediaError] = [:]
        for i in inputs {
            do { jobs.append(try submit(op, input: i)) } catch let e as MediaError { rejected[i] = e } catch { rejected[i] = .ioFailure("\(error)") }
        }
        return MediaBatchResult(jobs: jobs, rejected: rejected)
    }

    @discardableResult
    public func submitDownload(url: String, mode: YtDlpArgs.Mode, folder: String) throws -> Int {
        guard let ytdlp = tools.ytDlp else { throw MediaError.toolMissing("yt-dlp") }
        let args = try YtDlpArgs.download(url: url, folder: folder, mode: mode, ffmpegDirectory: tools.ffmpegDirectory)
        let runner = self.runner
        let host = YtDlpArgs.validURL(url)?.host ?? url
        return queue.enqueue(title: "Скачивание: \(host)", kind: "download") { ctx in
            let box = DestinationBox()
            let result = await runner.stream(ManagerCommand(ytdlp, args, timeout: 6 * 3600)) { line in
                guard line.stream == .out else { if !line.text.isEmpty { ctx.log(line.text) }; return }
                if let p = YtDlpArgs.parseProgress(line.text) {
                    ctx.setProgress(p.percent / 100, detail: [p.speed, p.eta].filter { !$0.isEmpty && $0 != "NA" }.joined(separator: ", "))
                } else if let d = YtDlpArgs.destination(in: line.text) {
                    box.set(d)
                }
            }
            if result.cancelled { return .cancelled }
            if result.ok { return .success(box.value ?? folder) }
            let detail = result.stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
            return .failure(detail.isEmpty ? "yt-dlp завершился с кодом \(result.status)" : detail)
        }
    }

    public func cancel(_ id: Int) { queue.cancel(id) }
    public func cancelAll() { queue.cancelAll() }
    public func plan(forJob id: Int) -> MediaPlan? { plans[id] }

    public static func finishMessage(_ job: JobSnapshot) -> (title: String, body: String)? {
        switch job.state {
        case .succeeded: ("Готово", job.title)
        case .failed(let m): ("Не получилось", "\(job.title): \(m)")
        default: nil
        }
    }
}

private final class DestinationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return path }
    func set(_ p: String) { lock.lock(); path = p; lock.unlock() }
}
