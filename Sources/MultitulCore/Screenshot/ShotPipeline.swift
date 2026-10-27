import Foundation
import CoreGraphics

public struct ShotCaptureResult {
    public var image: CGImage
    public var mode: ShotMode
    public var rect: CGRect?
    public var scale: CGFloat
    public var appName: String?
    public var windowTitle: String?
    public var date: Date

    public init(image: CGImage, mode: ShotMode, rect: CGRect? = nil, scale: CGFloat = 2, appName: String? = nil, windowTitle: String? = nil, date: Date = Date()) {
        self.image = image
        self.mode = mode
        self.rect = rect
        self.scale = scale
        self.appName = appName
        self.windowTitle = windowTitle
        self.date = date
    }
}

public protocol ShotFileStoring: AnyObject {
    func exists(_ path: String) -> Bool
    func write(_ data: Data, to path: String) -> Bool
    func read(_ path: String) -> Data?
    func trash(_ path: String) -> Bool
    func remove(_ path: String) -> Bool
}

public protocol ShotClipboardWriting: AnyObject {
    func writeImage(png: Data) -> Bool
}

public protocol ShotShelfSinking: AnyObject {
    var isAvailable: Bool { get }
    func addScreenshot(path: String?, data: Data, fileName: String) -> Bool
}

public protocol ShotTextIndexing: AnyObject {
    func text(in image: CGImage) -> String
}

public enum ShotEvent: Equatable, Sendable {
    case captured(id: Int64, mode: ShotMode)
    case saved(path: String)
    case copied
    case linked(url: String)
    case deleted(id: Int64)
    case recordingStarted
    case recordingPaused
    case recordingResumed
    case recordingStopped(path: String)
    case recordingFailed(reason: String)
}

public final class ShotEventHub {
    private var handlers: [Int: (ShotEvent) -> Void] = [:]
    private var next = 1

    public init() {}

    @discardableResult
    public func subscribe(_ h: @escaping (ShotEvent) -> Void) -> Int {
        let id = next
        next += 1
        handlers[id] = h
        return id
    }

    public func unsubscribe(_ id: Int) { handlers[id] = nil }
    public func emit(_ e: ShotEvent) { for k in handlers.keys.sorted() { handlers[k]?(e) } }
}

public final class ShotOcrIndexer: ShotTextIndexing {
    private let recognizer: OcrRecognizing

    public init(recognizer: OcrRecognizing) { self.recognizer = recognizer }

    private final class NullClipboard: TextWriting {
        func write(_ text: String) {}
    }

    public func text(in image: CGImage) -> String {
        var s = OcrSettings()
        s.detectQr = false
        s.removeLineBreaks = true
        let engine = ScreenOcrEngine(recognizer: recognizer, clipboard: NullClipboard(), settings: s)
        if case .text(let t) = engine.process(image) { return String(t.prefix(20_000)) }
        return ""
    }
}

public struct ShotOutcome {
    public var record: ShotRecord?
    public var image: CGImage
    public var data: Data?
    public var path: String?
    public var fileName: String
    public var copied: Bool
    public var shelved: Bool
    public var next: ShotAfterAction
    public var error: String?
    public var pruned: [ShotRecord]
}

public final class ShotPipeline {
    public let files: ShotFileStoring
    public let encoder: ShotImageEncoding
    public let clipboard: ShotClipboardWriting
    public let shelf: ShotShelfSinking?
    public let history: ShotHistoryStore?
    public let indexer: ShotTextIndexing?
    public let counter: ShotCounter
    public let events: ShotEventHub
    public let cacheDir: String
    private let settings: () -> ShotSettings
    private let timeZone: TimeZone

    public init(settings: @escaping () -> ShotSettings, files: ShotFileStoring, encoder: ShotImageEncoding, clipboard: ShotClipboardWriting,
                shelf: ShotShelfSinking? = nil, history: ShotHistoryStore? = nil, indexer: ShotTextIndexing? = nil, counter: ShotCounter,
                events: ShotEventHub = ShotEventHub(), cacheDir: String = MultitulPaths.shotCacheDir, timeZone: TimeZone = .current) {
        self.settings = settings
        self.files = files
        self.encoder = encoder
        self.clipboard = clipboard
        self.shelf = shelf
        self.history = history
        self.indexer = indexer
        self.counter = counter
        self.events = events
        self.cacheDir = cacheDir
        self.timeZone = timeZone
    }

    public func finalImage(_ cap: ShotCaptureResult, settings s: ShotSettings) -> CGImage {
        var img = cap.image
        let pad = cap.mode == .window ? s.windowPadding : 0
        if pad > 0 || s.watermark.isActive {
            img = ShotRenderer.compose(img, padding: pad, scale: cap.scale, background: cap.mode == .window ? s.background : .none,
                                       cornerRadius: pad > 0 ? s.backgroundCorner : 0, watermark: s.watermark) ?? img
        }
        if s.downscaleRetina, cap.scale > 1, let d = ShotRenderer.downscaled(img, factor: 1 / cap.scale) { img = d }
        return img
    }

    public func nextAction(_ s: ShotSettings) -> ShotAfterAction {
        s.openEditorImmediately ? .editor : s.afterCapture
    }

    @discardableResult
    public func process(_ cap: ShotCaptureResult) -> ShotOutcome {
        let s = settings().sanitized
        let img = finalImage(cap, settings: s)
        let counterValue = ShotNaming.usesCounter(s.nameTemplate) ? counter.next() : counter.current
        let ctx = ShotNameContext(date: cap.date, mode: cap.mode, appName: cap.appName, windowTitle: cap.windowTitle, width: img.width, height: img.height,
                                  counter: counterValue, timeZone: timeZone)
        let base = ShotNaming.baseName(template: s.nameTemplate, context: ctx)
        var out = ShotOutcome(record: nil, image: img, data: nil, path: nil, fileName: base + "." + s.format.fileExtension, copied: false, shelved: false,
                              next: nextAction(s), error: nil, pruned: [])
        let encoded = encoder.supports(s.format) ? s.format : .png
        guard let data = encoder.encode(img, format: encoded, quality: s.quality) else {
            out.error = "Не удалось закодировать снимок"
            return out
        }
        out.data = data
        var owned = false
        var path: String?
        var fileName = ShotNaming.fileName(template: s.nameTemplate, context: ctx, format: encoded, exists: { _ in false })
        if s.saveToDisk {
            let dir = s.resolvedDirectory()
            fileName = ShotNaming.uniqueFileName(base: base, ext: encoded.fileExtension) { files.exists(dir + "/" + $0) }
            let target = dir + "/" + fileName
            if files.write(data, to: target) { path = target } else { out.error = "Не удалось сохранить в \(dir)" }
        }
        if path == nil, s.recordHistory {
            let name = UUID().uuidString.prefix(12) + "." + encoded.fileExtension
            let target = cacheDir + "/" + name
            if files.write(data, to: target) { path = target; owned = true }
        }
        out.path = path
        out.fileName = fileName
        if s.copyToClipboard, let png = pngData(img, current: encoded, data: data) {
            out.copied = clipboard.writeImage(png: png)
            if out.copied { events.emit(.copied) }
        }
        if s.addToShelf, let shelf, shelf.isAvailable {
            out.shelved = shelf.addScreenshot(path: owned ? nil : path, data: data, fileName: fileName)
        }
        if let path, !owned { events.emit(.saved(path: path)) }
        if s.recordHistory, let history {
            let rec = ShotRecord(created: cap.date, mode: cap.mode, title: base, app: cap.appName ?? "", path: path, owned: owned, width: img.width, height: img.height,
                                 bytes: data.count, format: encoded.rawValue)
            let thumb = ShotThumbnail.jpegData(from: img, encoder: encoder)
            if let id = try? history.insert(rec, thumbnail: thumb) {
                var r = rec
                r.id = id
                out.record = r
                events.emit(.captured(id: id, mode: cap.mode))
                out.pruned = prune(history, settings: s)
            }
        }
        return out
    }

    private func pngData(_ img: CGImage, current: ShotFormat, data: Data) -> Data? {
        current == .png ? data : encoder.encode(img, format: .png, quality: 1)
    }

    @discardableResult
    public func prune(_ history: ShotHistoryStore, settings s: ShotSettings, now: Date = Date()) -> [ShotRecord] {
        let removed = (try? history.prune(ShotPrunePolicy(maxCount: s.historyLimit, maxAgeDays: s.historyKeepDays), now: now)) ?? []
        for r in removed where r.owned { if let p = r.path { _ = files.remove(p) } }
        return removed
    }

    public func index(recordID: Int64, image: CGImage) {
        guard settings().indexText, let history, let indexer else { return }
        let t = indexer.text(in: image)
        if !t.isEmpty { try? history.setOcr(id: recordID, text: t) }
    }

    public func discard(recordID: Int64) {
        guard let history, let removed = try? history.delete(ids: [recordID]).first else { return }
        if let p = removed.path {
            if removed.owned { _ = files.remove(p) } else { _ = files.trash(p) }
        }
        events.emit(.deleted(id: recordID))
    }

    public func saveToDirectory(record: ShotRecord?, data: Data, format: ShotFormat, width: Int, height: Int, baseName: String) -> String? {
        let s = settings().sanitized
        let dir = s.resolvedDirectory()
        let name = ShotNaming.uniqueFileName(base: ShotNaming.sanitize(baseName).isEmpty ? "Screenshot" : ShotNaming.sanitize(baseName), ext: format.fileExtension) { files.exists(dir + "/" + $0) }
        let target = dir + "/" + name
        guard files.write(data, to: target) else { return nil }
        if let record, record.id > 0 {
            try? history?.setLocation(id: record.id, path: target, owned: false, bytes: data.count, width: width, height: height, format: format.rawValue)
            if record.owned, let old = record.path, old != target { _ = files.remove(old) }
        }
        events.emit(.saved(path: target))
        return target
    }

    @discardableResult
    public func saveEdited(record: ShotRecord, image: CGImage, document: AnnotationDocument?) -> ShotOutcome {
        let s = settings().sanitized
        let encoded = encoder.supports(s.format) ? s.format : .png
        var out = ShotOutcome(record: record, image: image, data: nil, path: nil, fileName: "", copied: false, shelved: false, next: .nothing, error: nil, pruned: [])
        guard let data = encoder.encode(image, format: encoded, quality: s.quality) else {
            out.error = "Не удалось закодировать снимок"
            return out
        }
        out.data = data
        let dir = s.saveToDisk ? s.resolvedDirectory() : cacheDir
        let base = record.title + " (ред.)"
        let name = ShotNaming.uniqueFileName(base: ShotNaming.sanitize(base), ext: encoded.fileExtension) { files.exists(dir + "/" + $0) }
        let target = dir + "/" + name
        guard files.write(data, to: target) else {
            out.error = "Не удалось сохранить в \(dir)"
            return out
        }
        out.path = target
        out.fileName = name
        var r = record
        r.path = target
        r.owned = !s.saveToDisk
        r.width = image.width
        r.height = image.height
        r.bytes = data.count
        r.format = encoded.rawValue
        out.record = r
        if let history, record.id > 0 {
            try? history.setLocation(id: record.id, path: target, owned: r.owned, bytes: data.count, width: image.width, height: image.height, format: encoded.rawValue)
            try? history.setThumbnail(id: record.id, data: ShotThumbnail.jpegData(from: image, encoder: encoder))
            if let document, let json = try? document.json() { try? history.setDocument(id: record.id, json: json) }
        }
        if let old = record.path, record.owned, old != target { _ = files.remove(old) }
        events.emit(.saved(path: target))
        return out
    }
}

public final class ShotLinkService {
    private let uploader: ShotUploading
    private let history: ShotHistoryStore?
    private let clipboard: TextWriting
    private let events: ShotEventHub
    private let files: ShotFileStoring
    private let encoder: ShotImageEncoding

    public init(uploader: ShotUploading, history: ShotHistoryStore?, clipboard: TextWriting, events: ShotEventHub, files: ShotFileStoring, encoder: ShotImageEncoding) {
        self.uploader = uploader
        self.history = history
        self.clipboard = clipboard
        self.events = events
        self.files = files
        self.encoder = encoder
    }

    public func makeLink(record: ShotRecord?, image: CGImage, format: ShotFormat, fileName: String, ttl: ShotLinkTTL, now: Date = Date()) -> Result<ShotUploadResult, ShotUploadError> {
        var data: Data?
        if let p = record?.path, ShotFormat.from(fileExtension: (p as NSString).pathExtension) != nil { data = files.read(p) }
        if data == nil { data = encoder.encode(image, format: format, quality: 0.9) }
        guard let d = data else { return .failure(.transport("не удалось подготовить файл")) }
        let name = (record?.path).map { ($0 as NSString).lastPathComponent } ?? fileName
        let fmt = ShotFormat.from(fileExtension: (name as NSString).pathExtension) ?? format
        do {
            let res = try uploader.upload(ShotUploadJob(fileName: name, data: d, format: fmt, ttl: ttl), now: now)
            if let id = record?.id, id > 0 { try? history?.setLink(id: id, url: res.url, expires: res.expires) }
            clipboard.write(res.url)
            events.emit(.linked(url: res.url))
            return .success(res)
        } catch let e as ShotUploadError {
            return .failure(e)
        } catch {
            return .failure(.transport("\(error)"))
        }
    }
}
