import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private struct Rig {
    let files = ShotFakeFiles()
    let encoder = ShotFakeEncoder()
    let clip = ShotFakeClipboard()
    let shelf = ShotFakeShelf()
    let indexer = ShotFakeIndexer()
    let history: ShotHistoryStore
    let kv = WndMemoryStore()
    let events = ShotEventHub()
    let settings: Box
    let pipeline: ShotPipeline

    final class Box { var s = ShotSettings() }

    init(_ tweak: (inout ShotSettings) -> Void = { _ in }, withShelf: Bool = true, withHistory: Bool = true) {
        history = try! ShotHistoryStore(store: ShotHistorySchema.openStore(path: ":memory:"))
        let box = Box()
        box.s.saveDirectory = "/shots"
        box.s.nameTemplate = "shot {counter}"
        tweak(&box.s)
        settings = box
        pipeline = ShotPipeline(settings: { box.s }, files: files, encoder: encoder, clipboard: clip, shelf: withShelf ? shelf : nil,
                                history: withHistory ? history : nil, indexer: indexer, counter: ShotCounter(kv), events: events, cacheDir: "/cache",
                                timeZone: TimeZone(identifier: "UTC")!)
    }

    func capture(_ mode: ShotMode = .area, w: Int = 100, h: Int = 60, scale: CGFloat = 2, app: String? = "Safari") -> ShotCaptureResult {
        ShotCaptureResult(image: shotImage(w, h), mode: mode, rect: CGRect(x: 0, y: 0, width: 50, height: 30), scale: scale, appName: app, date: Date(timeIntervalSince1970: 1_792_760_733))
    }
}

@Suite struct ShotPipelineTests {
    @Test func savesCopiesAndRecords() throws {
        let r = Rig()
        let o = r.pipeline.process(r.capture())
        #expect(o.error == nil && o.path == "/shots/shot 1.png" && o.fileName == "shot 1.png")
        #expect(r.files.files["/shots/shot 1.png"] == Data("png:100x60".utf8))
        #expect(o.copied && r.clip.images == [Data("png:100x60".utf8)])
        let rec = o.record!
        #expect(rec.id > 0 && rec.path == "/shots/shot 1.png" && !rec.owned && rec.mode == .area && rec.width == 100 && rec.app == "Safari" && rec.title == "shot 1")
        #expect(try r.history.count() == 1)
        #expect(try r.history.thumbnail(id: rec.id) != nil)
    }

    @Test func counterAdvancesOnlyWhenTheTemplateUsesIt() {
        let r = Rig()
        _ = r.pipeline.process(r.capture())
        _ = r.pipeline.process(r.capture())
        #expect(r.files.files.keys.sorted() == ["/shots/shot 1.png", "/shots/shot 2.png"])
        let r2 = Rig { $0.nameTemplate = "fixed" }
        _ = r2.pipeline.process(r2.capture())
        #expect(r2.kv.values.isEmpty)
    }

    @Test func collidingNamesGetASuffix() {
        let r = Rig { $0.nameTemplate = "same" }
        let a = r.pipeline.process(r.capture()), b = r.pipeline.process(r.capture()), c = r.pipeline.process(r.capture())
        #expect([a.fileName, b.fileName, c.fileName] == ["same.png", "same 2.png", "same 3.png"])
    }

    @Test func templateRendersAppAndMode() {
        let r = Rig { $0.nameTemplate = "{app} {mode} {size}" }
        let o = r.pipeline.process(r.capture(.window, app: "Pages"))
        #expect(o.fileName == "Pages окно 100x60.png")
    }

    @Test func formatDecidesTheExtensionAndEncoder() {
        let r = Rig { $0.format = .jpeg }
        let o = r.pipeline.process(r.capture())
        #expect(o.fileName == "shot 1.jpg" && r.encoder.calls.contains { $0.0 == .jpeg })
        #expect(r.clip.images == [Data("png:100x60".utf8)])
    }

    @Test func unsupportedFormatFallsBackToPng() {
        let r = Rig { $0.format = .heic }
        r.encoder.supported = [.png, .jpeg]
        let o = r.pipeline.process(r.capture())
        #expect(o.fileName == "shot 1.png")
    }

    @Test func notSavingKeepsAPrivateCopyForTheHistory() {
        let r = Rig { $0.saveToDisk = false }
        let o = r.pipeline.process(r.capture())
        #expect(o.path?.hasPrefix("/cache/") == true && o.record?.owned == true)
        #expect(r.files.files.keys.allSatisfy { $0.hasPrefix("/cache/") })
        #expect(o.copied)
    }

    @Test func notSavingAndNoHistoryLeavesNoFiles() {
        let r = Rig { $0.saveToDisk = false; $0.recordHistory = false }
        let o = r.pipeline.process(r.capture())
        #expect(o.path == nil && o.record == nil && r.files.files.isEmpty && o.data != nil)
    }

    @Test func clipboardCanBeDisabled() {
        let r = Rig { $0.copyToClipboard = false }
        let o = r.pipeline.process(r.capture())
        #expect(!o.copied && r.clip.images.isEmpty)
    }

    @Test func failedClipboardIsReported() {
        let r = Rig()
        r.clip.ok = false
        #expect(!r.pipeline.process(r.capture()).copied)
    }

    @Test func writeFailureIsReportedButTheImageSurvives() {
        let r = Rig()
        r.files.failWrites = true
        let o = r.pipeline.process(r.capture())
        #expect(o.error?.contains("/shots") == true && o.path == nil && o.data != nil)
    }

    @Test func encodeFailureStopsEverything() {
        let r = Rig()
        r.encoder.fail = true
        let o = r.pipeline.process(r.capture())
        #expect(o.error != nil && o.data == nil && r.files.files.isEmpty && r.clip.images.isEmpty && o.record == nil)
    }

    @Test func shelfReceivesTheSavedFilePath() {
        let r = Rig { $0.addToShelf = true }
        let o = r.pipeline.process(r.capture())
        #expect(o.shelved && r.shelf.added.count == 1 && r.shelf.added[0].path == "/shots/shot 1.png")
    }

    @Test func shelfGetsTheImageDataWhenOnlyAPrivateCopyExists() {
        let r = Rig { $0.addToShelf = true; $0.saveToDisk = false }
        _ = r.pipeline.process(r.capture())
        #expect(r.shelf.added.count == 1 && r.shelf.added[0].path == nil && r.shelf.added[0].name.hasSuffix(".png"))
    }

    @Test func shelfIsSkippedWhenOffOrUnavailable() {
        let off = Rig()
        _ = off.pipeline.process(off.capture())
        #expect(off.shelf.added.isEmpty)
        let gone = Rig { $0.addToShelf = true }
        gone.shelf.isAvailable = false
        #expect(!gone.pipeline.process(gone.capture()).shelved && gone.shelf.added.isEmpty)
        let none = Rig({ $0.addToShelf = true }, withShelf: false)
        #expect(!none.pipeline.process(none.capture()).shelved)
    }

    @Test func nextActionFollowsTheSettings() {
        let a = Rig { $0.afterCapture = .pin }
        #expect(a.pipeline.process(a.capture()).next == .pin)
        let b = Rig { $0.afterCapture = .pin; $0.openEditorImmediately = true }
        #expect(b.pipeline.process(b.capture()).next == .editor)
        #expect(Rig().pipeline.process(Rig().capture()).next == .overlay)
    }

    @Test func windowCapturesGetPaddingAndBackground() {
        let r = Rig { $0.windowPadding = 20; $0.background = .solid(.white) }
        let o = r.pipeline.process(r.capture(.window))
        #expect(o.image.width == 100 + 80 && o.image.height == 60 + 80)
        let other = Rig { $0.windowPadding = 20; $0.background = .solid(.white) }
        #expect(other.pipeline.process(other.capture(.area)).image.width == 100)
    }

    @Test func watermarkAppliesToEveryMode() {
        let r = Rig { $0.watermark.enabled = true; $0.watermark.text = "wm" }
        let o = r.pipeline.process(r.capture(.screen))
        #expect(o.image.width == 100 && o.image.height == 60)
        #expect(ShotBitmap(image: o.image)! != ShotBitmap(image: shotImage(100, 60))!)
    }

    @Test func retinaDownscaleHalvesTheOutput() {
        let r = Rig { $0.downscaleRetina = true }
        let o = r.pipeline.process(r.capture(scale: 2))
        #expect(o.image.width == 50 && o.image.height == 30)
        let one = Rig { $0.downscaleRetina = true }
        #expect(one.pipeline.process(one.capture(scale: 1)).image.width == 100)
    }

    @Test func historyIsPrunedAfterEachCapture() throws {
        let r = Rig { $0.historyLimit = 20 }
        r.settings.s.recordHistory = true
        for _ in 0..<25 { _ = r.pipeline.process(r.capture()) }
        #expect(try r.history.count() == 20)
    }

    @Test func prunedOwnedFilesAreRemovedButUserFilesAreNot() {
        let r = Rig { $0.saveToDisk = false; $0.historyLimit = 20 }
        for _ in 0..<21 { _ = r.pipeline.process(r.capture()) }
        #expect(r.files.removed.count == 1 && r.files.removed[0].hasPrefix("/cache/"))
        let u = Rig { $0.historyLimit = 20 }
        for _ in 0..<21 { _ = u.pipeline.process(u.capture()) }
        #expect(u.files.removed.isEmpty && u.files.files.count == 21)
    }

    @Test func eventsAreEmittedForCaptureSaveAndCopy() {
        let r = Rig()
        var seen: [ShotEvent] = []
        r.events.subscribe { seen.append($0) }
        let o = r.pipeline.process(r.capture(.window))
        #expect(seen.contains(.copied) && seen.contains(.saved(path: "/shots/shot 1.png")) && seen.contains(.captured(id: o.record!.id, mode: .window)))
    }

    @Test func eventSubscribersCanLeave() {
        let hub = ShotEventHub()
        var n = 0
        let id = hub.subscribe { _ in n += 1 }
        hub.emit(.copied)
        hub.unsubscribe(id)
        hub.emit(.copied)
        #expect(n == 1)
    }

    @Test func indexingStoresRecognisedTextAndMakesItSearchable() throws {
        let r = Rig()
        r.indexer.result = "Квитанция об оплате"
        let o = r.pipeline.process(r.capture())
        r.pipeline.index(recordID: o.record!.id, image: o.image)
        #expect(try r.history.search("квитанция").count == 1)
    }

    @Test func indexingRespectsTheSwitch() throws {
        let r = Rig { $0.indexText = false }
        r.indexer.result = "текст"
        let o = r.pipeline.process(r.capture())
        r.pipeline.index(recordID: o.record!.id, image: o.image)
        #expect(r.indexer.calls == 0)
        let e = Rig()
        let o2 = e.pipeline.process(e.capture())
        e.pipeline.index(recordID: o2.record!.id, image: o2.image)
        #expect(try e.history.search("текст").isEmpty)
    }

    @Test func discardTrashesUserFilesAndRemovesPrivateOnes() throws {
        let r = Rig()
        let o = r.pipeline.process(r.capture())
        r.pipeline.discard(recordID: o.record!.id)
        #expect(r.files.trashed == ["/shots/shot 1.png"] && r.files.removed.isEmpty)
        #expect(try r.history.count() == 0)
        let p = Rig { $0.saveToDisk = false }
        let o2 = p.pipeline.process(p.capture())
        p.pipeline.discard(recordID: o2.record!.id)
        #expect(p.files.trashed.isEmpty && p.files.removed.count == 1)
    }

    @Test func saveCopyPersistsAPrivateShotIntoTheUserFolder() throws {
        let r = Rig { $0.saveToDisk = false }
        let o = r.pipeline.process(r.capture())
        let private1 = o.path!
        let path = r.pipeline.saveToDirectory(record: o.record, data: o.data!, format: .png, width: 100, height: 60, baseName: "my shot")
        #expect(path == "/shots/my shot.png" && r.files.files[path!] != nil)
        let rec = try r.history.record(id: o.record!.id)!
        #expect(rec.path == path && !rec.owned && r.files.removed == [private1])
    }

    @Test func saveCopyAvoidsOverwriting() {
        let r = Rig()
        r.files.files["/shots/x.png"] = Data()
        #expect(r.pipeline.saveToDirectory(record: nil, data: Data("d".utf8), format: .png, width: 1, height: 1, baseName: "x") == "/shots/x 2.png")
        r.files.failWrites = true
        #expect(r.pipeline.saveToDirectory(record: nil, data: Data(), format: .png, width: 1, height: 1, baseName: "y") == nil)
    }

    @Test func editedSaveWritesANewFileAndUpdatesTheRecord() throws {
        let r = Rig()
        let o = r.pipeline.process(r.capture())
        var doc = AnnotationDocument(canvasWidth: 100, canvasHeight: 60)
        doc.add(.rectangle, points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)])
        let e = r.pipeline.saveEdited(record: o.record!, image: shotImage(90, 50), document: doc)
        #expect(e.error == nil && e.path == "/shots/shot 1 (ред.).png" && r.files.files["/shots/shot 1.png"] != nil)
        let rec = try r.history.record(id: o.record!.id)!
        #expect(rec.path == e.path && rec.width == 90 && rec.height == 50)
        let json = try r.history.document(id: o.record!.id)!
        #expect(try AnnotationDocument.decode(json) == doc)
    }

    @Test func editedSaveOfAPrivateCopyReplacesIt() {
        let r = Rig { $0.saveToDisk = false }
        let o = r.pipeline.process(r.capture())
        let e = r.pipeline.saveEdited(record: o.record!, image: shotImage(90, 50), document: nil)
        #expect(e.path?.hasPrefix("/cache/") == true && r.files.removed == [o.path!])
    }

    @Test func editedSaveReportsFailures() {
        let r = Rig()
        let o = r.pipeline.process(r.capture())
        r.files.failWrites = true
        #expect(r.pipeline.saveEdited(record: o.record!, image: shotImage(5, 5), document: nil).error != nil)
        r.files.failWrites = false
        r.encoder.fail = true
        #expect(r.pipeline.saveEdited(record: o.record!, image: shotImage(5, 5), document: nil).error != nil)
    }

    @Test func worksWithoutAHistoryStore() {
        let r = Rig({ _ in }, withHistory: false)
        let o = r.pipeline.process(r.capture())
        #expect(o.record == nil && o.path != nil)
        r.pipeline.discard(recordID: 5)
        r.pipeline.index(recordID: 5, image: o.image)
    }

    @Test func ocrIndexerUsesTheExistingEngineWithoutTouchingTheClipboard() {
        let rec = TlsRecognizer()
        rec.lines = [OcrLine("Привет", confidence: 1, box: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.1)), OcrLine("мир", confidence: 1, box: CGRect(x: 0, y: 0.6, width: 0.5, height: 0.1))]
        rec.codes = ["https://qr.example"]
        let idx = ShotOcrIndexer(recognizer: rec)
        #expect(idx.text(in: shotImage(60, 60)) == "Привет мир")
        #expect(rec.codeCalls == 0 && rec.textCalls == 1)
        #expect(idx.text(in: shotImage(2, 2)) == "")
        let empty = TlsRecognizer()
        #expect(ShotOcrIndexer(recognizer: empty).text(in: shotImage(60, 60)) == "")
        empty.error = NSError(domain: "t", code: 1)
        #expect(ShotOcrIndexer(recognizer: empty).text(in: shotImage(60, 60)) == "")
    }
}

@Suite struct ShotLinkServiceTests {
    private func make(http: ShotFakeHTTP = ShotFakeHTTP(), token: String? = "t") -> (ShotLinkService, ShotFakeHTTP, ShotFakeFiles, TlsTextSink, ShotHistoryStore, ShotEventHub) {
        let h = try! ShotHistoryStore(store: ShotHistorySchema.openStore(path: ":memory:"))
        let files = ShotFakeFiles()
        let sink = TlsTextSink()
        let hub = ShotEventHub()
        var s = ShotUploadSettings()
        s.endpoint = "https://files.example.com/up"
        let kc = MemoryKeychain(token.map { [ShotUploadSettings.keychainService: ["token": $0]] } ?? [:])
        let up = ShotUploader(settings: { s }, client: http, keychain: kc, boundary: { "B" })
        return (ShotLinkService(uploader: up, history: h, clipboard: sink, events: hub, files: files, encoder: ShotFakeEncoder()), http, files, sink, h, hub)
    }

    @Test func uploadsTheSavedFileAndCopiesTheLink() throws {
        let (svc, http, files, sink, hist, hub) = make()
        files.files["/shots/a.png"] = Data("FILEBYTES".utf8)
        let id = try hist.insert(ShotRecord(created: Date(), mode: .area, title: "a", path: "/shots/a.png"))
        var seen: [ShotEvent] = []
        hub.subscribe { seen.append($0) }
        let rec = try hist.record(id: id)
        let res = svc.makeLink(record: rec, image: shotImage(5, 5), format: .png, fileName: "x.png", ttl: .hours6, now: Date(timeIntervalSince1970: 1000))
        guard case .success(let r) = res else { Issue.record("failed \(res)"); return }
        #expect(r.url == "https://files.example.com/a.png" && sink.writes == [r.url])
        #expect(String(decoding: http.requests[0].body ?? Data(), as: UTF8.self).contains("FILEBYTES") && String(decoding: http.requests[0].body ?? Data(), as: UTF8.self).contains("filename=\"a.png\""))
        let stored = try hist.record(id: id)!
        #expect(stored.link == r.url && stored.linkExpires == Date(timeIntervalSince1970: 1000 + 6 * 3600))
        #expect(seen == [.linked(url: r.url)])
    }

    @Test func encodesTheImageWhenThereIsNoFile() {
        let (svc, http, _, _, _, _) = make()
        let res = svc.makeLink(record: nil, image: shotImage(7, 3), format: .png, fileName: "mem.png", ttl: .hour1)
        guard case .success = res else { Issue.record("failed"); return }
        #expect(String(decoding: http.requests[0].body ?? Data(), as: UTF8.self).contains("png:7x3"))
    }

    @Test func failuresDoNotTouchTheClipboardOrTheRecord() throws {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 500)
        let (svc, _, _, sink, hist, hub) = make(http: http)
        let id = try hist.insert(ShotRecord(created: Date(), mode: .area, title: "a"))
        var seen: [ShotEvent] = []
        hub.subscribe { seen.append($0) }
        let res = svc.makeLink(record: try hist.record(id: id), image: shotImage(5, 5), format: .png, fileName: "a.png", ttl: .hours24)
        if case .failure(.http(500)) = res {} else { Issue.record("expected http 500") }
        let stored = try hist.record(id: id)
        #expect(sink.writes.isEmpty && seen.isEmpty && stored?.link == nil)
    }

    @Test func missingTokenIsSurfaced() {
        let (svc, http, _, _, _, _) = make(token: nil)
        let res = svc.makeLink(record: nil, image: shotImage(5, 5), format: .png, fileName: "a.png", ttl: .hour1)
        if case .failure(.missingToken) = res {} else { Issue.record("expected missingToken") }
        #expect(http.requests.isEmpty)
    }
}

@Suite struct ShotEncodeTests {
    @Test func pngRoundTripKeepsPixels() {
        let enc = ImageIOShotEncoder()
        let img = ShotBitmap(width: 6, height: 5) { x, y in (UInt8(x * 40), UInt8(y * 50), 9, 255) }.makeImage()!
        let data = enc.encode(img, format: .png, quality: 1)!
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(ShotBitmap(image: ShotImageOps.decode(data)!)! == ShotBitmap(image: img)!)
    }

    @Test func jpegIsFlattenedAndLossy() {
        let enc = ImageIOShotEncoder()
        let img = ShotBitmap(width: 32, height: 32, color: (200, 20, 20, 255)).makeImage()!
        let d = enc.encode(img, format: .jpeg, quality: 0.8)!
        #expect(d.starts(with: [0xFF, 0xD8]))
        let back = ShotBitmap(image: ShotImageOps.decode(d)!)!
        #expect(abs(Int(back.pixel(16, 16).0) - 200) < 8)
    }

    @Test func transparentPixelsBecomeWhiteInJpeg() {
        let enc = ImageIOShotEncoder()
        let img = ShotBitmap(width: 16, height: 16, color: (0, 0, 0, 0)).makeImage()!
        let back = ShotBitmap(image: ShotImageOps.decode(enc.encode(img, format: .jpeg, quality: 0.9)!)!)!
        #expect(back.pixel(8, 8).0 > 240)
    }

    @Test func supportReportsTheBasics() {
        let enc = ImageIOShotEncoder()
        #expect(enc.supports(.png) && enc.supports(.jpeg))
    }

    @Test func heicEncodesWhenTheSystemCan() {
        let enc = ImageIOShotEncoder()
        guard enc.supports(.heic) else { return }
        let d = enc.encode(shotImage(64, 64), format: .heic, quality: 0.8)
        #expect(d != nil && d!.count > 20)
    }

    @Test func thumbnailFitMath() {
        #expect(ShotThumbnail.fit(width: 4000, height: 2000, maxSide: 320) == (320, 160))
        #expect(ShotThumbnail.fit(width: 100, height: 50, maxSide: 320) == (100, 50))
        #expect(ShotThumbnail.fit(width: 500, height: 3000, maxSide: 300) == (50, 300))
        #expect(ShotThumbnail.fit(width: 0, height: 10, maxSide: 100) == (0, 0))
        #expect(ShotThumbnail.fit(width: 4000, height: 1, maxSide: 100) == (100, 1))
    }

    @Test func thumbnailsAreSmallAndDecodable() {
        let t = ShotThumbnail.make(from: shotImage(1600, 800), maxSide: 200)!
        #expect(t.width == 200 && t.height == 100)
        let data = ShotThumbnail.jpegData(from: shotImage(1600, 800), maxSide: 200)!
        #expect(ShotImageOps.decode(data)?.width == 200)
    }

    @Test func decodeAndLoadHandleGarbage() {
        #expect(ShotImageOps.decode(Data("not an image".utf8)) == nil)
        #expect(ShotImageOps.load(path: "/definitely/not/here.png") == nil)
    }

    @Test func loadReadsAFileFromDisk() {
        let path = NSTemporaryDirectory() + "shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: ImageIOShotEncoder().encode(shotImage(12, 9), format: .png, quality: 1))
        let img = ShotImageOps.load(path: path)
        #expect(img?.width == 12 && img?.height == 9)
    }
}
