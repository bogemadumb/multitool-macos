import Testing
import Foundation
@testable import MultitulCore

private func settings(_ tweak: (inout ShotUploadSettings) -> Void = { _ in }) -> ShotUploadSettings {
    var s = ShotUploadSettings()
    s.endpoint = "https://files.example.com/upload"
    tweak(&s)
    return s
}

private func job(_ data: Data = Data("PNGDATA".utf8), name: String = "shot.png", ttl: ShotLinkTTL = .hours6) -> ShotUploadJob {
    ShotUploadJob(fileName: name, data: data, format: .png, ttl: ttl)
}

private func text(_ d: Data?) -> String { String(decoding: d ?? Data(), as: UTF8.self) }

@Suite struct ShotMultipartTests {
    @Test func bodyHasFieldsAndTheFilePart() {
        let b = text(ShotMultipart.body(boundary: "BB", fields: [("ttl", "6"), ("kind", "shot")], file: ("file", "a.png", "image/png", Data("DATA".utf8))))
        #expect(b.hasPrefix("--BB\r\n"))
        #expect(b.contains("Content-Disposition: form-data; name=\"ttl\"\r\n\r\n6\r\n"))
        #expect(b.contains("name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\nDATA\r\n--BB--\r\n"))
        #expect(b.hasSuffix("--BB--\r\n"))
    }

    @Test func fieldsComeBeforeTheFile() {
        let b = text(ShotMultipart.body(boundary: "BB", fields: [("a", "1")], file: ("file", "x", "image/png", Data())))
        #expect(b.range(of: "name=\"a\"")!.lowerBound < b.range(of: "name=\"file\"")!.lowerBound)
    }

    @Test func binaryDataIsKeptByteForByte() {
        let bin = Data((0..<256).map { UInt8($0) })
        let body = ShotMultipart.body(boundary: "BB", fields: [], file: ("file", "a.bin", "application/octet-stream", bin))
        #expect(body.range(of: bin) != nil)
    }

    @Test func headerValuesCannotInjectLines() {
        let b = text(ShotMultipart.body(boundary: "BB", fields: [("na\"me\r\nX: y", "v")], file: ("file", "a\"\r\nContent-Type: text/html.png", "image/png", Data())))
        #expect(!b.contains("\r\nX: y") && !b.contains("\r\nContent-Type: text/html"))
        #expect(!b.contains("na\"me"))
    }

    @Test func contentTypeCarriesTheBoundary() {
        #expect(ShotMultipart.contentType(boundary: "XYZ") == "multipart/form-data; boundary=XYZ")
        var n: UInt64 = 0xABC
        #expect(ShotMultipart.boundary(random: { n }) == "MultitulBoundaryabc")
        #expect(ShotMultipart.boundary() != ShotMultipart.boundary())
    }

    @Test func safeTokenKeepsOnlyAsciiWithoutSeparators() {
        #expect(ShotMultipart.safeToken("fi le:\"x;", fallback: "f") == "filex")
        #expect(ShotMultipart.safeToken("файл", fallback: "file") == "file")
        #expect(ShotMultipart.safeToken("", fallback: "file") == "file")
    }
}

@Suite struct ShotUploadBuilderTests {
    @Test func validatesEndpoints() {
        #expect(ShotUploadBuilder.validate(endpoint: "https://a.example/u") == nil)
        #expect(ShotUploadBuilder.validate(endpoint: "http://localhost:8080/u") == nil)
        #expect(ShotUploadBuilder.validate(endpoint: "http://127.0.0.1/u") == nil)
        #expect(ShotUploadBuilder.validate(endpoint: "http://a.example/u") != nil)
        #expect(ShotUploadBuilder.validate(endpoint: "ftp://a.example/u") != nil)
        #expect(ShotUploadBuilder.validate(endpoint: "https://user:pw@a.example/u") != nil)
        #expect(ShotUploadBuilder.validate(endpoint: "") != nil && ShotUploadBuilder.validate(endpoint: "not a url") != nil)
        #expect(ShotUploadBuilder.validate(endpoint: "https://") != nil)
    }

    @Test func isConfiguredFollowsTheEndpoint() {
        #expect(!ShotUploadSettings().isConfigured && settings().isConfigured)
    }

    @Test func requestIsAPostWithMultipartAndBearer() throws {
        let r = try ShotUploadBuilder.request(settings: settings(), job: job(), token: "sekret", boundary: "BB")
        #expect(r.method == "POST" && r.url == "https://files.example.com/upload")
        #expect(r.headers["Content-Type"] == "multipart/form-data; boundary=BB" && r.headers["Authorization"] == "Bearer sekret")
        let b = text(r.body)
        #expect(b.contains("name=\"ttl\"\r\n\r\n6\r\n") && b.contains("filename=\"shot.png\"") && b.contains("PNGDATA"))
    }

    @Test func ttlCanGoInSecondsOrBeOmitted() throws {
        let sec = try ShotUploadBuilder.request(settings: settings { $0.ttlInSeconds = true }, job: job(ttl: .hour1), token: "t", boundary: "B")
        #expect(text(sec.body).contains("\r\n\r\n3600\r\n"))
        let none = try ShotUploadBuilder.request(settings: settings { $0.ttlField = "" }, job: job(), token: "t", boundary: "B")
        #expect(!text(none.body).contains("name=\"ttl\""))
    }

    @Test func customHeaderAndPrefix() throws {
        let r = try ShotUploadBuilder.request(settings: settings { $0.authHeader = "X-Api-Key"; $0.authPrefix = "" }, job: job(), token: " k ", boundary: "B")
        #expect(r.headers["X-Api-Key"] == "k" && r.headers["Authorization"] == nil)
    }

    @Test func noAuthHeaderMeansNoTokenIsNeeded() throws {
        let r = try ShotUploadBuilder.request(settings: settings { $0.authHeader = "" }, job: job(), token: nil, boundary: "B")
        #expect(r.headers.keys.filter { $0 != "Content-Type" && $0 != "Accept" }.isEmpty)
    }

    @Test func missingTokenIsAnError() {
        #expect(throws: ShotUploadError.missingToken) { try ShotUploadBuilder.request(settings: settings(), job: job(), token: nil, boundary: "B") }
        #expect(throws: ShotUploadError.missingToken) { try ShotUploadBuilder.request(settings: settings(), job: job(), token: "", boundary: "B") }
    }

    @Test func notConfiguredAndBadEndpointAreErrors() {
        #expect(throws: ShotUploadError.notConfigured) { try ShotUploadBuilder.request(settings: ShotUploadSettings(), job: job(), token: "t", boundary: "B") }
        #expect(throws: (any Error).self) { try ShotUploadBuilder.request(settings: settings { $0.endpoint = "http://evil.example/u" }, job: job(), token: "t", boundary: "B") }
    }

    @Test func oversizeFilesAreRefusedBeforeBuilding() {
        let big = Data(count: 2000)
        #expect(throws: ShotUploadError.tooLarge(2000)) { try ShotUploadBuilder.request(settings: settings { $0.maxBytes = 1000 }, job: job(big), token: "t", boundary: "B") }
    }

    @Test func extraFieldsAreSentAndBadOnesDropped() throws {
        let s = settings { $0.extraFields = ["album=screens", "broken", "=novalue", "note=a=b"] }.sanitized
        #expect(s.extraFields == ["album=screens", "note=a=b"])
        let r = try ShotUploadBuilder.request(settings: s, job: job(), token: "t", boundary: "B")
        #expect(text(r.body).contains("name=\"album\"\r\n\r\nscreens") && text(r.body).contains("name=\"note\"\r\n\r\na=b"))
        #expect(ShotUploadBuilder.parseField("k=v") != nil && ShotUploadBuilder.parseField("kv") == nil)
    }

    @Test func fileNameFallsBackWhenItIsEmptyAfterSanitising() throws {
        let r = try ShotUploadBuilder.request(settings: settings(), job: job(name: "///"), token: "t", boundary: "B")
        #expect(text(r.body).contains("filename=\"screenshot.png\""))
    }

    @Test func cyrillicNamesPassThrough() throws {
        let r = try ShotUploadBuilder.request(settings: settings(), job: job(name: "Снимок экрана.png"), token: "t", boundary: "B")
        #expect(text(r.body).contains("filename=\"Снимок экрана.png\""))
    }

    @Test func settingsKeysAreAsciiAndRoundTrip() {
        let kv = WndMemoryStore()
        var s = settings { $0.fileField = "image"; $0.ttlField = "lifetime"; $0.ttlInSeconds = true; $0.authHeader = "X-Key"; $0.authPrefix = ""; $0.extraFields = ["a=b"]; $0.responsePath = "data.0.link"; $0.maxBytes = 5000 }
        ShotUploadSettingsStore(kv).save(s)
        s = s.sanitized
        #expect(ShotUploadSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("screenshot.upload.") && $0.allSatisfy(\.isASCII) })
        let kv2 = WndMemoryStore()
        ShotUploadSettingsStore(kv2).save(ShotUploadSettings())
        #expect(kv2.values.isEmpty)
    }

    @Test func keychainServiceNameIsAscii() {
        #expect(ShotUploadSettings.keychainService.allSatisfy { $0.isASCII })
    }
}

@Suite struct ShotUploadResponseTests {
    private func resp(_ s: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, body: Data(s.utf8)) }

    @Test func plainJsonKey() {
        #expect(ShotUploadBuilder.extractURL(from: resp(#"{"url":"https://x.example/a.png"}"#), path: "url") == "https://x.example/a.png")
    }

    @Test func nestedPathAndArrayIndex() {
        let j = #"{"data":{"files":[{"link":"https://x.example/1"},{"link":"https://x.example/2"}]}}"#
        #expect(ShotUploadBuilder.extractURL(from: resp(j), path: "data.files.1.link") == "https://x.example/2")
        #expect(ShotUploadBuilder.extractURL(from: resp(j), path: "data.files.5.link") == nil)
        #expect(ShotUploadBuilder.extractURL(from: resp(j), path: "data.nope") == nil)
    }

    @Test func plainTextBody() {
        #expect(ShotUploadBuilder.extractURL(from: resp("  https://x.example/p \n"), path: "") == "https://x.example/p")
        #expect(ShotUploadBuilder.extractURL(from: resp("ok"), path: "") == nil)
    }

    @Test func jsonStringBodyWithEmptyPath() {
        #expect(ShotUploadBuilder.extractURL(from: resp(#""https://x.example/s""#), path: "") == "https://x.example/s")
    }

    @Test func nonWebUrlsAreRejected() {
        #expect(ShotUploadBuilder.extractURL(from: resp(#"{"url":"javascript:alert(1)"}"#), path: "url") == nil)
        #expect(ShotUploadBuilder.extractURL(from: resp(#"{"url":"file:///etc/passwd"}"#), path: "url") == nil)
        #expect(ShotUploadBuilder.extractURL(from: resp(#"{"url":"https://a b.example"}"#), path: "url") == nil)
        #expect(ShotUploadBuilder.extractURL(from: resp(#"{"url":42}"#), path: "url") == nil)
        #expect(ShotUploadBuilder.isWebURL("http://a.example/x") && !ShotUploadBuilder.isWebURL("https://"))
    }
}

@Suite struct ShotUploaderTests {
    private func make(_ http: ShotFakeHTTP, token: String? = "tok", tweak: @escaping (inout ShotUploadSettings) -> Void = { _ in }) -> ShotUploader {
        let kc = MemoryKeychain(token.map { [ShotUploadSettings.keychainService: ["token": $0]] } ?? [:])
        return ShotUploader(settings: { settings(tweak) }, client: http, keychain: kc, boundary: { "BND" })
    }

    @Test func successReturnsTheLinkAndExpiry() throws {
        let http = ShotFakeHTTP()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = try make(http).upload(job(ttl: .hours24), now: now)
        #expect(r.url == "https://files.example.com/a.png" && r.expires == now.addingTimeInterval(86400))
        #expect(http.requests.count == 1 && http.requests[0].headers["Authorization"] == "Bearer tok" && http.requests[0].headers["Content-Type"]?.hasSuffix("BND") == true)
    }

    @Test func badStatusIsAnError() {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 413)
        #expect(throws: ShotUploadError.http(413)) { try make(http).upload(job(), now: Date()) }
    }

    @Test func transportFailureIsReported() {
        let http = ShotFakeHTTP()
        http.error = HTTPTransportError("offline")
        do { _ = try make(http).upload(job(), now: Date()); Issue.record("expected throw") } catch let e as ShotUploadError {
            if case .transport(let m) = e { #expect(m.contains("offline")) } else { Issue.record("wrong error \(e)") }
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func responseWithoutALinkIsAnError() {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        #expect(throws: ShotUploadError.badResponse) { try make(http).upload(job(), now: Date()) }
    }

    @Test func missingKeychainItemStopsBeforeAnyRequest() {
        let http = ShotFakeHTTP()
        #expect(throws: ShotUploadError.missingToken) { try make(http, token: nil).upload(job(), now: Date()) }
        #expect(http.requests.isEmpty)
    }

    @Test func unconfiguredServiceNeverTouchesTheNetwork() {
        let http = ShotFakeHTTP()
        #expect(throws: ShotUploadError.notConfigured) { try make(http) { $0.endpoint = "" }.upload(job(), now: Date()) }
        #expect(http.requests.isEmpty)
    }

    @Test func customResponsePathIsHonoured() throws {
        let http = ShotFakeHTTP()
        http.response = HTTPResponse(status: 201, body: Data(#"{"result":{"short":"https://s.example/q"}}"#.utf8))
        #expect(try make(http) { $0.responsePath = "result.short" }.upload(job(), now: Date()).url == "https://s.example/q")
    }

    @Test func errorsHaveRussianDescriptions() {
        for e in [ShotUploadError.notConfigured, .badEndpoint("x"), .tooLarge(5_000_000), .http(500), .transport("t"), .badResponse, .missingToken] { #expect(!e.description.isEmpty) }
    }
}
