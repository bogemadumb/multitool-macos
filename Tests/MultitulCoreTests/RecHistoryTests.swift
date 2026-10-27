import Testing
import Foundation
@testable import MultitulCore

private func store() -> RecHistoryStore { try! RecHistoryStore(store: RecHistorySchema.openStore(path: ":memory:")) }

private func rec(_ title: String, at t: Double, mode: RecMode = .area, app: String = "", path: String? = nil, pinned: Bool = false, bytes: Int = 1000, duration: Double = 12.5) -> RecRecord {
    RecRecord(created: Date(timeIntervalSince1970: t), mode: mode, title: title, app: app, path: path, width: 1920, height: 1080, duration: duration, bytes: bytes,
              codec: "hevc", fps: 60, hasSystemAudio: true, hasMicrophone: false, pinned: pinned)
}

@Suite struct RecHistoryTests {
    @Test func insertAndReadBack() throws {
        let s = store()
        let id = try s.insert(rec("Демо", at: 1000, mode: .window, app: "Safari", path: "/tmp/a.mp4"), thumbnail: Data([1, 2, 3]))
        let r = try s.record(id: id)!
        #expect(r.title == "Демо" && r.mode == .window && r.app == "Safari" && r.path == "/tmp/a.mp4" && r.width == 1920 && r.duration == 12.5)
        #expect(r.codec == "hevc" && r.fps == 60 && r.hasSystemAudio && !r.hasMicrophone && !r.pinned && r.link == nil)
        #expect(try s.thumbnail(id: id) == Data([1, 2, 3]))
        #expect(try s.count() == 1)
    }

    @Test func recentIsNewestFirstWithPaging() throws {
        let s = store()
        for i in 1...5 { try s.insert(rec("n\(i)", at: Double(i * 10))) }
        #expect(try s.recent(limit: 3).map(\.title) == ["n5", "n4", "n3"])
        #expect(try s.recent(limit: 3, offset: 3).map(\.title) == ["n2", "n1"])
        #expect(try s.latest()?.title == "n5")
    }

    @Test func emptyStoreHasNoLatest() throws {
        let s = store()
        #expect(try s.latest() == nil)
        #expect(try s.count() == 0)
    }

    @Test func searchMatchesTitleAppAndMode() throws {
        let s = store()
        try s.insert(rec("Разбор багов", at: 1, app: "Xcode"))
        try s.insert(rec("Созвон", at: 2, mode: .display, app: "Zoom"))
        #expect(try s.search("баг").map(\.title) == ["Разбор багов"])
        #expect(try s.search("zoom").map(\.title) == ["Созвон"])
        #expect(try s.search("весь экран").map(\.title) == ["Созвон"])
        #expect(try s.search("xcode разбор").count == 1)
        #expect(try s.search("  ").count == 2)
    }

    @Test func searchTreatsYoAsYe() throws {
        let s = store()
        try s.insert(rec("Ёлка", at: 1))
        #expect(try s.search("елка").count == 1)
    }

    @Test func searchEscapesLikeWildcards() throws {
        let s = store()
        try s.insert(rec("100% готово", at: 1))
        try s.insert(rec("обычная", at: 2))
        #expect(try s.search("%").map(\.title) == ["100% готово"])
        #expect(try s.search("_").isEmpty)
    }

    @Test func renameUpdatesSearch() throws {
        let s = store()
        let id = try s.insert(rec("старое", at: 1, app: "Notes"))
        try s.rename(id: id, title: "новое имя")
        #expect(try s.search("новое").count == 1)
        #expect(try s.search("старое").isEmpty)
        #expect(try s.search("notes").count == 1)
    }

    @Test func documentAndInputLogBlobs() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        #expect(try s.document(id: id) == nil)
        #expect(try s.inputLog(id: id) == nil)
        try s.setDocument(id: id, json: Data("{}".utf8))
        try s.setInputLog(id: id, json: Data("[]".utf8))
        #expect(try s.document(id: id) == Data("{}".utf8))
        #expect(try s.inputLog(id: id) == Data("[]".utf8))
        try s.setDocument(id: id, json: nil)
        #expect(try s.document(id: id) == nil)
    }

    @Test func linkLifecycle() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        let exp = Date(timeIntervalSince1970: 5000)
        try s.setLink(id: id, url: "https://x.example/v", expires: exp)
        let r = try s.record(id: id)!
        #expect(r.link == "https://x.example/v" && r.linkIsAlive(now: Date(timeIntervalSince1970: 4999)) && !r.linkIsAlive(now: exp))
        try s.setLink(id: id, url: nil, expires: nil)
        #expect(try s.record(id: id)!.link == nil)
    }

    @Test func locationUpdateKeepsOtherFields() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1, path: "/a.mp4"))
        try s.setLocation(id: id, path: "/b.mp4", bytes: 77, width: 1280, height: 720, duration: 3)
        let r = try s.record(id: id)!
        #expect(r.path == "/b.mp4" && r.bytes == 77 && r.width == 1280 && r.duration == 3 && r.title == "a")
    }

    @Test func pinning() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        try s.setPinned(id: id, true)
        #expect(try s.record(id: id)!.pinned)
    }

    @Test func deleteReturnsTheRemovedRows() throws {
        let s = store()
        let a = try s.insert(rec("a", at: 1, path: "/a"))
        let b = try s.insert(rec("b", at: 2, path: "/b"))
        let removed = try s.delete(ids: [a, 999])
        let left = try s.count()
        let other = try s.record(id: b)
        #expect(removed.map(\.id) == [a] && left == 1 && other != nil)
    }

    @Test func pruneByCountKeepsNewestAndPinned() throws {
        let s = store()
        for i in 1...6 { try s.insert(rec("n\(i)", at: Double(i), pinned: i == 1)) }
        let gone = try s.prune(ShotPrunePolicy(maxCount: 2, maxAgeDays: 0))
        #expect(Set(gone.map(\.title)) == ["n2", "n3", "n4"])
        #expect(Set(try s.recent().map(\.title)) == ["n1", "n5", "n6"])
    }

    @Test func pruneByAge() throws {
        let s = store()
        let now = Date(timeIntervalSince1970: 100 * 86400)
        try s.insert(rec("old", at: 1 * 86400))
        try s.insert(rec("fresh", at: 99 * 86400))
        try s.insert(rec("old pinned", at: 2 * 86400, pinned: true))
        let gone = try s.prune(ShotPrunePolicy(maxCount: 0, maxAgeDays: 30), now: now)
        #expect(gone.map(\.title) == ["old"])
    }

    @Test func pruneWithNoLimitsDeletesNothing() throws {
        let s = store()
        try s.insert(rec("a", at: 1))
        #expect(try s.prune(ShotPrunePolicy(maxCount: 0, maxAgeDays: 0)).isEmpty)
    }

    @Test func totalBytesSums() throws {
        let s = store()
        try s.insert(rec("a", at: 1, bytes: 100))
        try s.insert(rec("b", at: 2, bytes: 250))
        #expect(try s.totalBytes() == 350)
    }

    @Test func sourceInfoCarriesTheTrackFlags() {
        let i = rec("a", at: 1).sourceInfo
        #expect(i.width == 1920 && i.fps == 60 && i.hasSystemAudio && !i.hasMicrophone && i.duration == 12.5)
    }

    @Test func schemaCoexistsWithTheScreenshotTable() throws {
        let path = NSTemporaryDirectory() + "rec-schema-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shots = try ShotHistoryStore.open(path: path)
        let recs = try RecHistoryStore.open(path: path)
        try shots.insert(ShotRecord(created: Date(), mode: .area, title: "s"))
        try recs.insert(rec("r", at: 1))
        #expect(try shots.count() == 1)
        #expect(try recs.count() == 1)
        let again = try RecHistoryStore.open(path: path)
        #expect(try again.count() == 1)
    }

    @Test func tableAndColumnNamesAreAscii() {
        #expect(RecHistorySchema.migrations.allSatisfy { $0.sql.allSatisfy(\.isASCII) && $0.scope.allSatisfy(\.isASCII) })
    }
}

private final class RecFakeReader: RecDataReading {
    var data: Data? = Data("VIDEOBYTES".utf8)
    var reads: [String] = []
    func read(_ path: String) -> Data? { reads.append(path); return data }
}

@Suite struct RecLinkTests {
    private func settings(_ tweak: (inout ShotUploadSettings) -> Void = { _ in }) -> ShotUploadSettings {
        var s = ShotUploadSettings()
        s.endpoint = "https://files.example.com/upload"
        tweak(&s)
        return s
    }

    private func make(_ s: ShotUploadSettings, token: String? = "KEY", http: ShotFakeHTTP = ShotFakeHTTP(), reader: RecFakeReader = RecFakeReader(), history: RecHistoryStore? = nil,
                      sink: TlsTextSink = TlsTextSink(), hub: ShotEventHub? = nil) -> RecLinkService {
        let kc = ScriptedKeychain()
        if let token { kc.items[ShotUploadSettings.keychainService] = ["token": token] }
        return RecLinkService(settings: { s }, client: http, keychain: kc, reader: reader, history: history, clipboard: sink, events: hub, boundary: { "BND" })
    }

    @Test func mimeByExtension() {
        #expect(RecLinkBuilder.mime(forExtension: "MP4") == "video/mp4" && RecLinkBuilder.mime(forExtension: "mov") == "video/quicktime")
        #expect(RecLinkBuilder.mime(forExtension: "gif") == "image/gif" && RecLinkBuilder.mime(forExtension: "xyz") == "application/octet-stream")
    }

    @Test func requestCarriesVideoMimeTtlAndAuth() throws {
        let job = RecUploadJob(fileName: "clip.mp4", path: "/c.mp4", mime: "video/mp4", ttl: .hours6)
        let req = try RecLinkBuilder.request(settings: settings(), job: job, data: Data("V".utf8), token: "KEY", boundary: "BND")
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        #expect(req.method == "POST" && req.headers["Authorization"] == "Bearer KEY" && req.headers["Content-Type"] == "multipart/form-data; boundary=BND")
        #expect(body.contains("filename=\"clip.mp4\"") && body.contains("Content-Type: video/mp4") && body.contains("name=\"ttl\"\r\n\r\n6\r\n"))
        #expect(req.timeout >= 120)
    }

    @Test func requestRejectsMissingEndpointBadSchemeAndHugeFiles() {
        let job = RecUploadJob(fileName: "a.mp4", path: "/a", mime: "video/mp4", ttl: .hour1)
        #expect(throws: ShotUploadError.notConfigured) { try RecLinkBuilder.request(settings: ShotUploadSettings(), job: job, data: Data(), token: "k", boundary: "B") }
        #expect(throws: (any Error).self) { try RecLinkBuilder.request(settings: settings { $0.endpoint = "http://evil.example/u" }, job: job, data: Data(), token: "k", boundary: "B") }
        #expect(throws: ShotUploadError.tooLarge(3000)) { try RecLinkBuilder.request(settings: settings { $0.maxBytes = 1000 }, job: job, data: Data(count: 3000), token: "k", boundary: "B") }
    }

    @Test func missingTokenIsAnError() {
        let job = RecUploadJob(fileName: "a.mp4", path: "/a", mime: "video/mp4", ttl: .hour1)
        #expect(throws: ShotUploadError.missingToken) { try RecLinkBuilder.request(settings: settings(), job: job, data: Data(), token: nil, boundary: "B") }
    }

    @Test func successCopiesTheLinkAndEmitsAnEvent() {
        let sink = TlsTextSink()
        let hub = ShotEventHub()
        var events: [ShotEvent] = []
        hub.subscribe { events.append($0) }
        let svc = make(settings(), sink: sink, hub: hub)
        let now = Date(timeIntervalSince1970: 1000)
        guard case .success(let r) = svc.makeLink(record: nil, path: "/x/clip.mp4", ttl: .hours24, now: now) else { Issue.record("failed"); return }
        #expect(r.url == "https://files.example.com/a.png" && r.expires == now.addingTimeInterval(86400))
        #expect(sink.writes == [r.url] && events == [.linked(url: r.url)])
    }

    @Test func successWritesTheLinkIntoHistory() throws {
        let h = store()
        let id = try h.insert(rec("a", at: 1))
        let svc = make(settings(), history: h)
        _ = svc.makeLink(record: try h.record(id: id), path: "/x/clip.mp4", ttl: .hours6, now: Date(timeIntervalSince1970: 500))
        let r = try h.record(id: id)!
        #expect(r.link == "https://files.example.com/a.png" && r.linkExpires == Date(timeIntervalSince1970: 500 + 6 * 3600))
    }

    @Test func httpErrorsAreMapped() {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 413)
        let svc = make(settings(), http: http)
        #expect(svc.makeLink(record: nil, path: "/x/a.mp4", ttl: .hour1).failureValue == .http(413))
    }

    @Test func badResponseBodyIsReported() {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 200, body: Data("{\"oops\":1}".utf8))
        #expect(make(settings(), http: http).makeLink(record: nil, path: "/x/a.mp4", ttl: .hour1).failureValue == .badResponse)
    }

    @Test func transportErrorsAreMapped() {
        struct Down: Error {}
        let http = ShotFakeHTTP()
        http.error = Down()
        if case .transport = make(settings(), http: http).makeLink(record: nil, path: "/x/a.mp4", ttl: .hour1).failureValue {} else { Issue.record("expected transport") }
    }

    @Test func unreadableFileFailsBeforeAnyRequest() {
        let reader = RecFakeReader()
        reader.data = nil
        let http = ShotFakeHTTP()
        let r = make(settings(), http: http, reader: reader).makeLink(record: nil, path: "/gone.mp4", ttl: .hour1)
        if case .transport = r.failureValue {} else { Issue.record("expected transport") }
        #expect(http.requests.isEmpty)
    }

    @Test func failureDoesNotTouchClipboardOrHistory() throws {
        let h = store()
        let id = try h.insert(rec("a", at: 1))
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 500)
        let sink = TlsTextSink()
        _ = make(settings(), http: http, history: h, sink: sink).makeLink(record: try h.record(id: id), path: "/x/a.mp4", ttl: .hour1)
        let after = try h.record(id: id)
        #expect(sink.writes.isEmpty && after!.link == nil)
    }
}

private extension Result where Failure == ShotUploadError {
    var failureValue: ShotUploadError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

