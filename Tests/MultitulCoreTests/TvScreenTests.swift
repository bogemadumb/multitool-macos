import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

private func tvDefaults() -> InMemoryKeyValueStore {
    let d = InMemoryKeyValueStore()
    return d
}

@Suite struct TvSettingsTests {
    @Test func defaultsEqualOldConstants() {
        let c = TvConfig()
        #expect(c.tvIP == "192.168.1.50" && c.upnpPort == 9197 && c.streamPort == 8909 && c.fastPort == 8911)
        #expect(c.width == 1920 && c.height == 1080 && c.fps == 30 && c.bitrate == "25M" && c.gop == 10)
        #expect(c.mainRes == "1920x1243" && c.fastWidth == 1280 && c.fastHeight == 720 && c.fastFPS == 15 && c.fastQuality == 7)
        #expect(c.fakeContentLength == 10 * 1024 * 1024 * 1024 * 1024)
        #expect(c.avTransportURL == "http://192.168.1.50:9197/upnp/control/AVTransport1")
        #expect(c.streamURL(localIP: "192.168.1.10") == "http://192.168.1.10:8909/screen.ts")
        #expect(c.fastURL(localIP: "192.168.1.10") == "http://192.168.1.10:8911/")
        #expect(c.audioTvDevice == "BlackHole 2ch" && c.watchdogSeconds == 5)
        #expect(c.validate().isEmpty)
        #expect(TvSettings.load(tvDefaults()) == TvConfig())
    }

    @Test func keysAreAsciiAndRoundTrip() {
        #expect(TvSettings.allKeys.allSatisfy { $0.allSatisfy(\.isASCII) })
        let d = tvDefaults()
        var c = TvConfig()
        c.tvIP = "10.0.0.5"
        c.fps = 24
        c.bitrate = "8000k"
        c.fakeContentLength = 123
        TvSettings.save(c, to: d)
        #expect(TvSettings.load(d) == c)
        #expect(d.string(forKey: "tv.ip") == "10.0.0.5")
        c.tvIP = TvConfig().tvIP
        TvSettings.save(c, to: d)
        #expect(d.object(forKey: "tv.ip") == nil)
        TvSettings.reset(d)
        #expect(TvSettings.load(d) == TvConfig())
    }

    @Test func parsingAndValidation() {
        #expect(TvConfig.parseBitrate("25M") == 25_000_000)
        #expect(TvConfig.parseBitrate("8000k") == 8_000_000)
        #expect(TvConfig.parseBitrate("1500000") == 1_500_000)
        #expect(TvConfig.parseBitrate("x") == nil && TvConfig.parseBitrate("") == nil && TvConfig.parseBitrate("0") == nil)
        #expect(TvConfig.parseSize("1920x1243")?.w == 1920 && TvConfig.parseSize("1920x1243")?.h == 1243)
        #expect(TvConfig.parseSize("1920") == nil)
        #expect(TvConfig.isIPv4("192.168.1.50") && !TvConfig.isIPv4("192.168.1") && !TvConfig.isIPv4("192.168.1.300") && !TvConfig.isIPv4("a.b.c.d"))
        var c = TvConfig()
        c.tvIP = "nope"; c.fps = 0; c.width = 1921; c.streamPort = c.fastPort
        #expect(c.validate().count >= 4)
        #expect(TvConfig().jpegQuality > 0.7 && TvConfig().jpegQuality < 0.85)
        #expect(TvConfig().resolvedTokenPath.hasSuffix("/tv/tv-token.txt"))
    }
}

@Suite struct TvPlacementTests {
    static let sample = """
    Persistent screen id: AAAAAAAA-1111-2222-3333-444444444444
    Contextual screen id: 1
    Type: MacBook built in screen
    Resolution: 1470x956
    Hertz: 60

    Persistent screen id: AAAA-BBBB
    Contextual screen id: 4
    Type: 27 inch external screen
    Resolution: 1920x1080
    """

    @Test func parsesDisplayplacerList() {
        let l = DisplayplacerParser.parse(Self.sample)
        #expect(l.count == 2)
        #expect(l[0] == PlacerDisplay(id: "AAAAAAAA-1111-2222-3333-444444444444", ctx: "1", type: "MacBook built in screen", res: "1470x956"))
        #expect(l[1].ctx == "4" && !l[1].isBuiltin)
        #expect(DisplayplacerParser.parse("").isEmpty)
    }

    @Test func findsScreensAndHonoursPins() {
        let l = DisplayplacerParser.parse(Self.sample)
        var s = DisplayplacerParser.findScreens(l)
        #expect(s.built?.ctx == "1" && s.virt?.ctx == "4")
        s = DisplayplacerParser.findScreens(l, mainId: "", virtualId: "AAAA-BBBB")
        #expect(s.virt?.id == "AAAA-BBBB")
        s = DisplayplacerParser.findScreens(l, virtualId: "4")
        #expect(s.virt?.id == "AAAA-BBBB")
        #expect(DisplayplacerParser.findScreens([l[0]]).virt == nil)
    }

    @Test func commandsMatchPython() {
        let c = TvConfig()
        let a = TvPlacement.arrangeArgs(builtID: "B", virtualID: "V", config: c)
        #expect(a[0] == "id:B res:1920x1243 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0")
        #expect(a[1] == "id:V res:1920x1080 hz:60 color_depth:4 scaling:off origin:(1920,0) degree:0")
        #expect(TvPlacement.restoreArgs(builtID: "B", config: c) == ["id:B res:1920x1243 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0"])
    }

    @Test func audioHelpers() {
        #expect(TvAudio.setArgs("BlackHole 2ch") == ["-s", "BlackHole 2ch"])
        #expect(TvAudio.parseDevices("MacBook Air Speakers (output)\nBlackHole 2ch\n\n") == ["MacBook Air Speakers", "BlackHole 2ch"])
        #expect(TvAudio.parseCurrent("BlackHole 2ch\n") == "BlackHole 2ch" && TvAudio.parseCurrent("\n") == nil)
    }

    @Test func remoteCommand() {
        var c = TvConfig()
        c.remoteScript = "/x/home-tv.py"
        #expect(TvCommands.remote("start", config: c).exe == "/usr/bin/env")
        #expect(TvCommands.remote("start", config: c).args == ["python3", "/x/home-tv.py", "start"])
        c.remotePython = "/usr/bin/python3"
        #expect(TvCommands.remote("stop", config: c).exe == "/usr/bin/python3")
    }
}

@Suite struct TvUpnpTests {
    @Test func envelopeAndHeaders() {
        let r = Upnp.request(controlURL: "http://tv/x", action: "Play", inner: Upnp.playInner)
        #expect(r.headers["SOAPACTION"] == "\"urn:schemas-upnp-org:service:AVTransport:1#Play\"")
        #expect(r.headers["Content-Type"] == "text/xml; charset=\"utf-8\"")
        #expect(r.body.hasPrefix("<?xml version=\"1.0\"?><s:Envelope"))
        #expect(r.body.contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>"))
        #expect(r.body.hasSuffix("</s:Body></s:Envelope>"))
    }

    @Test func escapeMatchesPythonHtmlEscape() {
        #expect(Upnp.escape("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#x27;&amp;&#x27;&lt;/a&gt;")
    }

    @Test func setUriCarriesEscapedDidl() {
        let url = "http://192.168.1.10:8909/screen.ts"
        let inner = Upnp.setURIInner(url: url, features: Upnp.features(profile: "AVC_TS_MP_HD_AAC_ISO"))
        #expect(inner.hasPrefix("<InstanceID>0</InstanceID><CurrentURI>\(url)</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite"))
        #expect(inner.contains("DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=8D500000000000000000000000000000"))
        #expect(!inner.contains("<DIDL"))
        #expect(Upnp.unescape(Upnp.xmlValue("CurrentURIMetaData", in: "<x>" + inner + "</x>") ?? "").contains("<res protocolInfo=\"http-get:*:video/mpeg:"))
        #expect(Upnp.castSteps(url: url, profile: "P").map(\.action) == ["Stop", "SetAVTransportURI", "Play"])
    }

    @Test func parsesResponses() {
        let ok = "<s:Envelope><s:Body><u:GetTransportInfoResponse><CurrentTransportState>PLAYING</CurrentTransportState></u:GetTransportInfoResponse></s:Body></s:Envelope>"
        #expect(Upnp.parse(status: 200, body: ok).isOK)
        #expect(Upnp.transportState(from: ok) == "PLAYING")
        let fault = "<s:Envelope><s:Body><s:Fault><faultstring>UPnPError</faultstring><detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
        #expect(Upnp.parse(status: 500, body: fault) == .fault(code: 701, text: "Transition not available"))
        #expect(Upnp.parse(status: 404, body: "") == .httpError(404))
        #expect(Upnp.transportState(from: "garbage") == nil)
    }

    @Test func clientCastsInOrderAndReportsFailures() {
        final class Fake: UpnpTransporting {
            var sent: [UpnpRequest] = []
            func post(_ r: UpnpRequest) -> UpnpResult {
                sent.append(r)
                if r.headers["SOAPACTION"]?.contains("#Stop") == true { return .fault(code: 701, text: "idle") }
                if r.headers["SOAPACTION"]?.contains("#GetTransportInfo") == true { return .ok("<CurrentTransportState>STOPPED</CurrentTransportState>") }
                return .ok("")
            }
        }
        let f = Fake()
        let client = UpnpClient(transport: f, config: TvConfig())
        let failed = client.cast(url: "http://h/screen.ts")
        #expect(failed.map(\.step) == ["Stop"])
        #expect(f.sent.map { $0.headers["SOAPACTION"] ?? "" }.map { String($0.split(separator: "#").last ?? "") } == ["Stop\"", "SetAVTransportURI\"", "Play\""])
        #expect(f.sent.allSatisfy { $0.url == "http://192.168.1.50:9197/upnp/control/AVTransport1" })
        #expect(client.state() == "STOPPED")
    }
}

@Suite struct TvHttpTests {
    @Test func streamHeadersLieAboutLength() {
        let h = String(decoding: TvHttp.streamHeaders(config: TvConfig()), as: UTF8.self)
        #expect(h.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(h.contains("Content-Length: 10995116277760\r\n"))
        #expect(h.contains("Content-Type: video/mpeg\r\n"))
        #expect(h.contains("transferMode.dlna.org: Streaming\r\n"))
        #expect(h.contains("contentFeatures.dlna.org: DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;"))
        #expect(h.contains("Accept-Ranges: none\r\n") && h.contains("Connection: close\r\n"))
        #expect(h.hasSuffix("\r\n\r\n"))
    }

    @Test func otherResponses() {
        let m = String(decoding: TvHttp.mjpegHeaders(), as: UTF8.self)
        #expect(m.contains("multipart/x-mixed-replace; boundary=kadr") && m.contains("Cache-Control: no-store, no-cache"))
        #expect(String(decoding: TvHttp.notFoundResponse(), as: UTF8.self) == "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        let p = String(decoding: TvHttp.pageHeaders(length: 42), as: UTF8.self)
        #expect(p.contains("Content-Length: 42") && p.contains("text/html; charset=utf-8"))
        let frame = TvHttp.multipartFrame(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        #expect(String(decoding: frame.prefix(70), as: UTF8.self).hasPrefix("--kadr\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n"))
        #expect(frame.suffix(6) == Data([0xFF, 0xD8, 0xFF, 0xD9, 0x0D, 0x0A]))
    }

    @Test func requestParsingAndRouting() {
        let raw = Data("GET /screen.ts HTTP/1.1\r\nHost: x\r\nUser-Agent: Samsung\r\n\r\n".utf8)
        let r = TvHttp.parseRequest(raw)
        #expect(r?.method == "GET" && r?.path == "/screen.ts" && r?.headers["host"] == "x")
        #expect(TvHttp.parseRequest(Data("GET /a HTTP/1.1\r\nHost".utf8)) == nil)
        #expect(TvHttp.streamRoute(r!) == .stream(headOnly: false))
        #expect(TvHttp.streamRoute(TvHttpRequest(method: "HEAD", path: "/", headers: [:])) == .stream(headOnly: true))
        #expect(TvHttp.streamRoute(TvHttpRequest(method: "POST", path: "/", headers: [:])) == .notFound)
        func fast(_ p: String) -> TvRoute { TvHttp.fastRoute(TvHttpRequest(method: "GET", path: p, headers: [:])) }
        #expect(fast("/") == .page && fast("/index.html") == .page && fast("/potok") == .mjpeg && fast("/zvuk.mp3") == .notFound && fast("/potok?x=1") == .mjpeg)
    }
}

@Suite struct TvTransportStreamTests {
    private func packets(_ d: Data) -> [[UInt8]] {
        let b = [UInt8](d)
        return stride(from: 0, to: b.count, by: 188).map { Array(b[$0..<min($0 + 188, b.count)]) }
    }
    private func pid(_ p: [UInt8]) -> UInt16 { (UInt16(p[1] & 0x1F) << 8) | UInt16(p[2]) }
    private func payload(_ p: [UInt8]) -> [UInt8] {
        let afc = (p[3] >> 4) & 3
        var i = 4
        if afc & 2 != 0 { i += 1 + Int(p[4]) }
        return afc & 1 != 0 ? Array(p[i...]) : []
    }

    @Test func crcAndPsi() {
        #expect(TsMuxer.crc32(Array("123456789".utf8)) == 0x0376E6E7)
        let m = TsMuxer()
        for s in [m.patSection(), m.pmtSection()] {
            #expect(TsMuxer.crc32(s) == 0)
            let len = (Int(s[1] & 0x0F) << 8) | Int(s[2])
            #expect(len == s.count - 3)
        }
        let pp = packets(m.patPmt())
        #expect(pp.count == 2 && pp.allSatisfy { $0.count == 188 && $0[0] == 0x47 })
        #expect(pid(pp[0]) == 0 && pid(pp[1]) == TsMuxer.pmtPID)
        #expect(TsMuxer(hasAudio: false).pmtSection().count < m.pmtSection().count)
    }

    @Test func videoPesRoundTrip() {
        let m = TsMuxer()
        let au = Data((0..<1000).map { UInt8($0 % 251) })
        let out = m.video(annexB: au, pts: 90_000, isKey: true)
        let ps = packets(out)
        #expect(out.count % 188 == 0 && ps.allSatisfy { $0[0] == 0x47 })
        let video = ps.filter { pid($0) == TsMuxer.videoPID }
        #expect(!video.isEmpty && (video[0][1] & 0x40) != 0)
        #expect(video[1...].allSatisfy { ($0[1] & 0x40) == 0 })
        let af = video[0]
        #expect((af[3] >> 4) & 2 != 0 && (af[5] & 0x40) != 0 && (af[5] & 0x10) != 0)
        let pes = video.flatMap(payload)
        #expect(Array(pes.prefix(4)) == [0, 0, 1, 0xE0])
        #expect(Array(pes.prefix(9).suffix(3)) == [0x84, 0x80, 0x05])
        let t = (Int64(pes[9] >> 1) & 7) << 30 | Int64(pes[10]) << 22 | (Int64(pes[11]) >> 1) << 15 | Int64(pes[12]) << 7 | Int64(pes[13]) >> 1
        #expect(t == 90_000)
        #expect(Array(pes.suffix(1000)) == [UInt8](au))
        let ccs = video.map { $0[3] & 0x0F }
        #expect(ccs == (0..<video.count).map { UInt8($0 & 0x0F) })
        #expect(ps.prefix(2).map(pid) == [0, TsMuxer.pmtPID])
    }

    @Test func nonKeyFrameHasNoPsiAndCountersContinue() {
        let m = TsMuxer()
        let a = packets(m.video(annexB: Data(repeating: 1, count: 10), pts: 1, isKey: true))
        let b = packets(m.video(annexB: Data(repeating: 2, count: 10), pts: 2, isKey: false))
        #expect(b.allSatisfy { pid($0) == TsMuxer.videoPID })
        let lastA = a.last { pid($0) == TsMuxer.videoPID }!
        #expect((b[0][3] & 0x0F) == ((lastA[3] & 0x0F) + 1) & 0x0F)
    }

    @Test func stuffingFillsEveryPacketForAnyPayloadSize() {
        for n in [0, 1, 2, 100, 160, 170, 171, 172, 173, 182, 183, 184, 185, 400] {
            let m = TsMuxer()
            let out = m.audio(adts: Data(repeating: 9, count: n), pts: 5)
            #expect(out.count % 188 == 0, "n=\(n)")
            let pes = packets(out).flatMap(payload)
            #expect(pes.count == 14 + n, "n=\(n)")
            #expect(Array(pes.prefix(4)) == [0, 0, 1, 0xC0])
        }
    }

    @Test func annexBConversion() {
        let nal1 = Data([0x65, 1, 2, 3]), nal2 = Data([0x41, 9])
        var avcc = Data([0, 0, 0, 4]); avcc.append(nal1)
        avcc.append(Data([0, 0, 0, 2])); avcc.append(nal2)
        let out = H264Stream.annexB(fromAVCC: avcc, nalLengthSize: 4, parameterSets: [Data([0x67, 7]), Data([0x68, 8])])!
        #expect([UInt8](out) == [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 7, 0, 0, 0, 1, 0x68, 8, 0, 0, 0, 1, 0x65, 1, 2, 3, 0, 0, 0, 1, 0x41, 9])
        #expect(H264Stream.annexB(fromAVCC: Data([0, 0, 0, 9, 1]), nalLengthSize: 4, parameterSets: []) == nil)
        #expect(H264Stream.annexB(fromAVCC: Data(), nalLengthSize: 4, parameterSets: []) == nil)
        #expect(H264Stream.annexB(fromAVCC: avcc, nalLengthSize: 5, parameterSets: []) == nil)
    }

    @Test func adts() {
        let h = [UInt8](AdtsHeader.make(payloadLength: 100)!)
        #expect(h.count == 7 && h[0] == 0xFF && h[1] == 0xF1)
        #expect(h[2] == 0x4C && h[3] == 0x80)
        let len = (Int(h[3] & 3) << 11) | (Int(h[4]) << 3) | Int(h[5] >> 5)
        #expect(len == 107)
        #expect(AdtsHeader.make(payloadLength: 10, sampleRate: 12345) == nil)
        #expect(AdtsHeader.make(payloadLength: 9000) == nil)
    }
}

@Suite struct TvDependencyTests {
    @Test func brewListParsing() {
        let s = TvDependencies.parseBrewList("==> Formulae\ndisplayplacer 1.4.0\nswitchaudio-osx\n\nhomebrew/cask/deskpad\n")
        #expect(s == ["displayplacer", "switchaudio-osx", "deskpad"])
        #expect(TvDependencies.parseBrewList("").isEmpty)
    }

    @Test func detectionByPathOrBrew() {
        let c = TvConfig()
        let r = TvDependencies.evaluate(config: c, formulae: ["displayplacer"], casks: ["blackhole-2ch"], brewAvailable: true) { $0 == "/Applications/DeskPad.app" }
        func st(_ id: String) -> DependencyStatus { r.items.first { $0.dep.id == id }!.status }
        #expect(st("deskpad") == .present("/Applications/DeskPad.app"))
        #expect(st("displayplacer") == .present("brew"))
        #expect(st("blackhole") == .present("brew"))
        #expect(st("switchaudio") == .missing)
        #expect(r.missing.map(\.id) == ["switchaudio"] && !r.allPresent)
        #expect(TvDependencies.installHint(r) == "brew install switchaudio-osx")
    }

    @Test func formulaeAndCasksAreNotMixed() {
        let r = TvDependencies.evaluate(config: TvConfig(), formulae: ["deskpad", "blackhole-2ch"], casks: [], brewAvailable: true) { _ in false }
        #expect(r.missing.count == 4)
        #expect(TvDependencies.installHint(r) == "brew install displayplacer switchaudio-osx\nbrew install --cask deskpad blackhole-2ch")
    }

    @Test func noBrewHint() {
        let r = TvDependencies.evaluate(config: TvConfig(), formulae: [], casks: [], brewAvailable: false) { _ in false }
        #expect(TvDependencies.installHint(r).hasPrefix("Сначала поставь Homebrew"))
        let ok = TvDependencies.evaluate(config: TvConfig(), formulae: [], casks: [], brewAvailable: false) { _ in true }
        #expect(ok.allPresent && TvDependencies.installHint(ok).isEmpty)
    }
}

@Suite struct SamsungRemoteTests {
    @Test func urlAndMessages() {
        #expect(SamsungRemote.socketURL(host: "1.2.3.4", port: 8002, name: "Zerkalo", token: nil) == "wss://1.2.3.4:8002/api/v2/channels/samsung.remote.control?name=WmVya2Fsbw==")
        #expect(SamsungRemote.socketURL(host: "1.2.3.4", port: 8002, name: "Zerkalo", token: "123").hasSuffix("&token=123"))
        let m = SamsungRemote.launchBrowserMessage(url: "http://h:1/")
        #expect(m.contains("\"appId\":\"org.tizen.browser\"") && m.contains("\"action_type\":\"NATIVE_LAUNCH\"") && m.contains("\"event\":\"ed.apps.launch\"") && m.contains("\"metaTag\":\"http:\\/\\/h:1\\/\""))
        #expect(SamsungRemote.parseEvent("{\"event\":\"ms.channel.connect\",\"data\":{\"token\":\"4242\"}}") == .connected(token: "4242"))
        #expect(SamsungRemote.parseEvent("{\"event\":\"ms.channel.connect\"}") == .connected(token: nil))
        #expect(SamsungRemote.parseEvent("x") == .other(""))
        #expect(SamsungRemote.restFallbackRequest(host: "h", port: 8080, url: "u").url == "http://h:8080/ws/app/Internet")
    }
}

private final class TvFakeRunner: ProcessRunning, @unchecked Sendable {
    var calls: [String] = []
    var listOutput = TvPlacementTests.sample
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        calls.append(([executable] + arguments).joined(separator: " "))
        if arguments == ["list"] { return ProcessOutput(status: 0, stdout: listOutput) }
        if executable.hasSuffix("brew") { return ProcessOutput(status: 0, stdout: "displayplacer\n") }
        if executable.hasSuffix("SwitchAudioSource") { return ProcessOutput(status: 0, stdout: "BlackHole 2ch\n") }
        return ProcessOutput(status: 0)
    }
}

private final class TvFakeApps: AppControlling {
    var running = false
    var calls: [String] = []
    func isRunning(_ name: String) -> Bool { running }
    func launch(_ name: String) { calls.append("launch"); running = true }
    func hide(_ name: String) { calls.append("hide") }
    func quit(_ name: String) { calls.append("quit"); running = false }
}

private final class TvFakeEngine: TvStreamEngine {
    var clientCount = 0
    var onEvent: ((String) -> Void)?
    var started: [(TvMode, UInt32)] = []
    var stopped = 0
    var failStart: String?
    func start(mode: TvMode, displayID: UInt32, config: TvConfig) throws {
        if let f = failStart { throw TvSessionError(f) }
        started.append((mode, displayID))
    }
    func stop() { stopped += 1 }
}

private final class TvFakeUpnp: UpnpTransporting {
    var actions: [String] = []
    func post(_ r: UpnpRequest) -> UpnpResult {
        actions.append(String((r.headers["SOAPACTION"] ?? "").split(separator: "#").last?.dropLast() ?? ""))
        return .ok("")
    }
}

private final class TvFakeBrowser: TvBrowserLaunching {
    var urls: [String] = []
    func openBrowser(url: String, config: TvConfig) -> String { urls.append(url); return "ok" }
}

@Suite(.serialized) struct TvSessionTests {
    private func make(deskpadRunning: Bool = false, ip: String? = "192.168.1.10") -> (TvSessionRunner, TvFakeRunner, TvFakeApps, TvFakeEngine, TvFakeUpnp, TvFakeBrowser, () -> [String]) {
        let r = TvFakeRunner(), a = TvFakeApps(), e = TvFakeEngine(), u = TvFakeUpnp(), b = TvFakeBrowser()
        a.running = deskpadRunning
        nonisolated(unsafe) var logs: [String] = []
        let deps = TvSessionDeps(runner: r, apps: a, upnp: u, engine: e, browser: b, sleep: { _ in }, exists: { _ in true }, localIP: { _ in ip }, log: { logs.append($0) })
        return (TvSessionRunner(config: TvConfig(), deps: deps), r, a, e, u, b, { logs })
    }

    @Test func screenModeSequence() throws {
        let (s, r, a, e, u, b, _) = make()
        try s.start(mode: .screen)
        #expect(a.calls == ["launch", "hide"])
        #expect(r.calls.contains { $0.hasPrefix("/opt/homebrew/bin/displayplacer id:AAAAAAAA") && $0.contains("origin:(1920,0)") })
        #expect(e.started.count == 1 && e.started[0].0 == .screen && e.started[0].1 == 4)
        #expect(u.actions == ["Stop", "SetAVTransportURI", "Play"])
        #expect(b.urls.isEmpty)
        #expect(TvProtectedDisplays.ids == [4])
        s.stop(mode: .screen)
        #expect(u.actions.suffix(1) == ["Stop"])
        #expect(e.stopped == 1 && a.calls.contains("quit"))
        #expect(r.calls.last?.contains("id:AAAAAAAA-1111-2222-3333-444444444444 res:1920x1243") == true)
        #expect(TvProtectedDisplays.ids.isEmpty)
    }

    @Test func fastModeOpensBrowserAndSkipsUpnp() throws {
        let (s, _, _, e, u, b, _) = make(deskpadRunning: true)
        try s.start(mode: .fast)
        #expect(e.started[0].0 == .fast)
        #expect(u.actions.isEmpty)
        #expect(b.urls == ["http://192.168.1.10:8911/"])
        s.stop(mode: .fast)
        #expect(u.actions.isEmpty)
    }

    @Test func failuresCleanUp() {
        let (s, r, a, e, _, _, _) = make()
        e.failStart = "порт 8909 занят"
        #expect(throws: TvSessionError.self) { try s.start(mode: .screen) }
        #expect(a.calls.contains("quit"))
        #expect(r.calls.last?.contains("res:1920x1243") == true)

        let (s2, _, _, e2, _, _, _) = make(ip: nil)
        #expect(throws: TvSessionError.self) { try s2.start(mode: .screen) }
        #expect(e2.stopped == 1)

        let (s3, r3, _, e3, _, _, _) = make()
        r3.listOutput = "Persistent screen id: A\nContextual screen id: 1\nType: MacBook built in screen\n"
        #expect(throws: TvSessionError.self) { try s3.start(mode: .screen) }
        #expect(e3.started.isEmpty)
    }

    @Test func invalidSettingsAreRejectedBeforeAnything() {
        let (s, r, a, _, _, _, _) = make()
        s.config.fps = 0
        #expect(throws: TvSessionError.self) { try s.start(mode: .screen) }
        #expect(r.calls.isEmpty && a.calls.isEmpty)
    }

    @Test func audioRemoteAndDependencies() {
        let (s, r, _, _, _, _, _) = make()
        #expect(s.routeAudio(toTv: true).contains("BlackHole 2ch"))
        #expect(r.calls.last == "/opt/homebrew/bin/SwitchAudioSource -s BlackHole 2ch")
        _ = s.routeAudio(toTv: false)
        #expect(r.calls.last == "/opt/homebrew/bin/SwitchAudioSource -s Динамики MacBook Air")
        #expect(s.currentAudioDevice() == "BlackHole 2ch")
        _ = s.remote("start")
        #expect(r.calls.last?.hasPrefix("/usr/bin/env python3 ") == true && r.calls.last?.hasSuffix(" start") == true)
        #expect(s.dependencies().brewAvailable)
        #expect(r.calls.contains("/opt/homebrew/bin/brew list --cask -1"))
    }
}
