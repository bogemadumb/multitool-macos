import Foundation

public struct TvConfig: Equatable, Sendable {
    public var tvIP = "192.168.1.50"
    public var upnpPort = 9197
    public var upnpControlPath = "/upnp/control/AVTransport1"
    public var streamPort = 8909
    public var fastPort = 8911
    public var width = 1920
    public var height = 1080
    public var fps = 30
    public var bitrate = "25M"
    public var gop = 10
    public var dlnaProfile = "AVC_TS_MP_HD_AAC_ISO"
    public var fakeContentLength: Int64 = 10 * 1024 * 1024 * 1024 * 1024

    public var mainRes = "1920x1243"
    public var mainHz = 60
    public var mainColorDepth = 8
    public var virtualHz = 60
    public var virtualColorDepth = 4
    public var mainDisplayId = ""
    public var virtualDisplayId = ""

    public var fastWidth = 1280
    public var fastHeight = 720
    public var fastFPS = 15
    public var fastQuality = 7

    public var audioTvDevice = "BlackHole 2ch"
    public var audioMacDevice = "Динамики MacBook Air"
    public var audioInputMatch = "blackhole"

    public var deskpadName = "DeskPad"
    public var watchdogSeconds = 5
    public var deskpadBootDelay = 4
    public var arrangeDelay = 2
    public var castDelay = 1

    public var remoteScript = "~/tvcast/home-tv.py"
    public var remotePython = "python3"

    public var samsungWsPort = 8002
    public var samsungRestPort = 8080
    public var samsungName = "Zerkalo"
    public var tokenPath = ""
    public var legacyTokenPath = "~/tvcast/tv-token.txt"

    public var displayplacerPath = "/opt/homebrew/bin/displayplacer"
    public var switchAudioPath = "/opt/homebrew/bin/SwitchAudioSource"
    public var brewPath = "/opt/homebrew/bin/brew"

    public init() {}

    public static let defaults = TvConfig()

    public static func parseBitrate(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = t.last else { return nil }
        var mult = 1.0
        var num = t
        if last == "k" { mult = 1_000; num = String(t.dropLast()) } else if last == "m" { mult = 1_000_000; num = String(t.dropLast()) }
        guard let v = Double(num), v > 0 else { return nil }
        return Int(v * mult)
    }

    public static func parseSize(_ s: String) -> (w: Int, h: Int)? {
        let p = s.lowercased().split(separator: "x")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    public static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }
    }

    public var bitrateBps: Int { Self.parseBitrate(bitrate) ?? 25_000_000 }
    public var mainWidth: Int { Self.parseSize(mainRes)?.w ?? 1920 }

    // ffmpeg mjpeg -q:v scale (2 best … 31 worst) to ImageIO compression quality.
    public var jpegQuality: Double { min(max(1.0 - Double(fastQuality) * 0.03, 0.05), 0.98) }

    public var avTransportURL: String { "http://\(tvIP):\(upnpPort)\(upnpControlPath)" }
    public func streamURL(localIP: String) -> String { "http://\(localIP):\(streamPort)/screen.ts" }
    public func fastURL(localIP: String) -> String { "http://\(localIP):\(fastPort)/" }

    public var resolvedTokenPath: String {
        tokenPath.isEmpty ? MultitulPaths.home + "/tv/tv-token.txt" : (tokenPath as NSString).expandingTildeInPath
    }
    public var resolvedLegacyTokenPath: String { (legacyTokenPath as NSString).expandingTildeInPath }
    public var resolvedRemoteScript: String { (remoteScript as NSString).expandingTildeInPath }

    public func validate() -> [String] {
        var e: [String] = []
        if !Self.isIPv4(tvIP) { e.append("IP телевизора: нужен адрес вида 192.168.1.50") }
        for (name, v) in [("порт UPnP", upnpPort), ("порт потока", streamPort), ("порт быстрого режима", fastPort), ("порт Samsung WS", samsungWsPort), ("порт Samsung REST", samsungRestPort)] where !(1...65535).contains(v) {
            e.append("\(name): 1–65535")
        }
        if streamPort == fastPort { e.append("порты потока и быстрого режима должны различаться") }
        if width < 16 || height < 16 || width % 2 != 0 || height % 2 != 0 { e.append("разрешение: чётные размеры от 16") }
        if !(1...60).contains(fps) { e.append("FPS: 1–60") }
        if Self.parseBitrate(bitrate) == nil { e.append("битрейт: например 25M или 8000k") }
        if gop < 1 { e.append("GOP: от 1") }
        if Self.parseSize(mainRes) == nil { e.append("масштаб основного экрана: например 1920x1243") }
        if fastWidth < 16 || fastHeight < 16 { e.append("размер быстрого режима: от 16") }
        if !(1...30).contains(fastFPS) { e.append("FPS быстрого режима: 1–30") }
        if !(2...31).contains(fastQuality) { e.append("качество JPEG: 2 (лучшее) – 31") }
        if watchdogSeconds < 1 { e.append("сторож DeskPad: от 1 с") }
        return e
    }
}

public enum TvSettings {
    private static let strings: [(String, WritableKeyPath<TvConfig, String>)] = [
        ("tv.ip", \.tvIP), ("tv.upnpControlPath", \.upnpControlPath), ("tv.bitrate", \.bitrate), ("tv.dlnaProfile", \.dlnaProfile),
        ("tv.mainRes", \.mainRes), ("tv.mainDisplayId", \.mainDisplayId), ("tv.virtualDisplayId", \.virtualDisplayId),
        ("tv.audioTvDevice", \.audioTvDevice), ("tv.audioMacDevice", \.audioMacDevice), ("tv.audioInputMatch", \.audioInputMatch),
        ("tv.deskpadName", \.deskpadName), ("tv.remoteScript", \.remoteScript), ("tv.remotePython", \.remotePython),
        ("tv.samsungName", \.samsungName), ("tv.tokenPath", \.tokenPath), ("tv.legacyTokenPath", \.legacyTokenPath),
        ("tv.displayplacerPath", \.displayplacerPath), ("tv.switchAudioPath", \.switchAudioPath), ("tv.brewPath", \.brewPath)
    ]
    private static let ints: [(String, WritableKeyPath<TvConfig, Int>)] = [
        ("tv.upnpPort", \.upnpPort), ("tv.streamPort", \.streamPort), ("tv.fastPort", \.fastPort),
        ("tv.width", \.width), ("tv.height", \.height), ("tv.fps", \.fps), ("tv.gop", \.gop),
        ("tv.mainHz", \.mainHz), ("tv.mainColorDepth", \.mainColorDepth), ("tv.virtualHz", \.virtualHz), ("tv.virtualColorDepth", \.virtualColorDepth),
        ("tv.fastWidth", \.fastWidth), ("tv.fastHeight", \.fastHeight), ("tv.fastFPS", \.fastFPS), ("tv.fastQuality", \.fastQuality),
        ("tv.watchdogSeconds", \.watchdogSeconds), ("tv.deskpadBootDelay", \.deskpadBootDelay), ("tv.arrangeDelay", \.arrangeDelay), ("tv.castDelay", \.castDelay),
        ("tv.samsungWsPort", \.samsungWsPort), ("tv.samsungRestPort", \.samsungRestPort)
    ]
    private static let fakeLengthKey = "tv.fakeContentLength"

    public static var allKeys: [String] { strings.map(\.0) + ints.map(\.0) + [fakeLengthKey] }

    public static func load(_ d: KeyValueStoring = UserDefaults.standard) -> TvConfig {
        var c = TvConfig()
        for (k, p) in strings { if let v = d.string(forKey: k) { c[keyPath: p] = v } }
        for (k, p) in ints { if let v = d.object(forKey: k) as? Int { c[keyPath: p] = v } }
        if let v = d.object(forKey: fakeLengthKey) as? Int64 ?? (d.object(forKey: fakeLengthKey) as? Int).map(Int64.init) { c.fakeContentLength = v }
        return c
    }

    public static func save(_ c: TvConfig, to d: KeyValueStoring = UserDefaults.standard) {
        let base = TvConfig()
        for (k, p) in strings {
            if c[keyPath: p] == base[keyPath: p] { d.removeObject(forKey: k) } else { d.set(c[keyPath: p], forKey: k) }
        }
        for (k, p) in ints {
            if c[keyPath: p] == base[keyPath: p] { d.removeObject(forKey: k) } else { d.set(c[keyPath: p], forKey: k) }
        }
        if c.fakeContentLength == base.fakeContentLength { d.removeObject(forKey: fakeLengthKey) } else { d.set(c.fakeContentLength, forKey: fakeLengthKey) }
    }

    public static func reset(_ d: KeyValueStoring = UserDefaults.standard) {
        for k in allKeys { d.removeObject(forKey: k) }
    }
}
