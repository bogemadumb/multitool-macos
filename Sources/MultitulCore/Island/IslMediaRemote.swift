import Foundation
import AppKit

public enum IslMediaRemoteKeys {
    public static let title = "kMRMediaRemoteNowPlayingInfoTitle"
    public static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
    public static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
    public static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
    public static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    public static let rate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    public static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
    public static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    public static let artworkID = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
    public static let contentID = "kMRMediaRemoteNowPlayingInfoContentItemIdentifier"
    public static let uniqueID = "kMRMediaRemoteNowPlayingInfoUniqueIdentifier"

    public static let notifications = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
    ]

    public static let commandPlay: UInt32 = 0
    public static let commandPause: UInt32 = 1
    public static let commandToggle: UInt32 = 2
    public static let commandNext: UInt32 = 4
    public static let commandPrevious: UInt32 = 5
}

public enum IslMediaRemoteParser {
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    public static func parse(_ dict: [String: Any], isPlaying: Bool?, bundleID: String?, appName: String?) -> IslNowPlayingInfo {
        var i = IslNowPlayingInfo()
        i.title = (dict[IslMediaRemoteKeys.title] as? String) ?? ""
        i.artist = (dict[IslMediaRemoteKeys.artist] as? String) ?? ""
        i.album = (dict[IslMediaRemoteKeys.album] as? String) ?? ""
        if let d = double(dict[IslMediaRemoteKeys.duration]), d.isFinite, d > 0 { i.duration = d }
        if let e = double(dict[IslMediaRemoteKeys.elapsed]), e.isFinite, e >= 0 { i.elapsed = e }
        i.rate = double(dict[IslMediaRemoteKeys.rate]) ?? 0
        i.timestamp = dict[IslMediaRemoteKeys.timestamp] as? Date
        i.isPlaying = isPlaying
        i.bundleID = bundleID
        i.appName = appName
        if let a = dict[IslMediaRemoteKeys.artworkData] as? Data, !a.isEmpty { i.artworkData = a }
        i.artworkID = dict[IslMediaRemoteKeys.artworkID] as? String
        i.contentID = (dict[IslMediaRemoteKeys.contentID] as? String) ?? (dict[IslMediaRemoteKeys.uniqueID] as? String)
        return i
    }
}

public enum IslScriptPlayer: String, CaseIterable, Sendable {
    case music, spotify

    public var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    public var appName: String { self == .music ? "Музыка" : "Spotify" }
    public var scriptName: String { self == .music ? "Music" : "Spotify" }
    public var notificationName: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }

    public func commandScript(_ c: IslPlaybackCommand) -> String? {
        let tell = "tell application \"\(scriptName)\" to "
        switch c {
        case .play: return tell + "play"
        case .pause: return tell + "pause"
        case .toggle: return tell + "playpause"
        case .next: return tell + "next track"
        case .previous: return tell + "previous track"
        case .seek(let t):
            guard t.isFinite, t >= 0 else { return nil }
            return tell + "set player position to " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), t)
        }
    }

    public func parse(userInfo: [AnyHashable: Any]) -> IslNowPlayingInfo? {
        func str(_ k: String) -> String? { userInfo[k] as? String }
        func num(_ k: String) -> Double? { IslMediaRemoteParser.double(userInfo[k]) }
        let state = (str("Player State") ?? "").lowercased()
        if state == "stopped" || state.isEmpty { return nil }
        var i = IslNowPlayingInfo()
        i.title = str("Name") ?? ""
        i.artist = str("Artist") ?? ""
        i.album = str("Album") ?? ""
        let ms = num(self == .music ? "Total Time" : "Duration")
        if let ms, ms > 0 { i.duration = ms / 1000 }
        if self == .spotify, let p = num("Playback Position"), p >= 0 { i.elapsed = p }
        i.isPlaying = state == "playing"
        i.rate = state == "playing" ? 1 : 0
        i.bundleID = bundleID
        i.appName = appName
        i.contentID = str("Persistent ID") ?? str("Track ID")
        return i.isEmpty ? nil : i
    }
}

private struct IslMediaRemoteApi {
    typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias GetPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    typealias Register = @convention(c) (DispatchQueue) -> Void
    typealias SetElapsed = @convention(c) (Double) -> Void

    let getInfo: GetInfo
    let getPlaying: GetPlaying
    let getPID: GetPID?
    let send: SendCommand
    let register: Register
    let setElapsed: SetElapsed?

    static func load() -> (IslMediaRemoteApi?, String?) {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let h = dlopen(path, RTLD_LAZY) else { return (nil, "MediaRemote не загружается") }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let info = sym("MRMediaRemoteGetNowPlayingInfo", GetInfo.self),
              let playing = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetPlaying.self),
              let send = sym("MRMediaRemoteSendCommand", SendCommand.self),
              let reg = sym("MRMediaRemoteRegisterForNowPlayingNotifications", Register.self)
        else { return (nil, "в MediaRemote нет нужных функций") }
        return (IslMediaRemoteApi(getInfo: info, getPlaying: playing, getPID: sym("MRMediaRemoteGetNowPlayingApplicationPID", GetPID.self), send: send, register: reg,
                                  setElapsed: sym("MRMediaRemoteSetElapsedTime", SetElapsed.self)), nil)
    }
}

@MainActor
public final class IslMediaRemoteDriver: IslNowPlayingDriving {
    public let sourceName = "mediaremote"
    public private(set) var health = IslSourceHealth.unknown
    public var onInfo: ((IslNowPlayingInfo?) -> Void)?

    private var api: IslMediaRemoteApi?
    private var tracker = IslHealthTracker()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let (loaded, error) = IslMediaRemoteApi.load()
        guard let loaded else {
            tracker.markUnavailable(error ?? "нет API")
            health = tracker.health
            return
        }
        api = loaded
        loaded.register(DispatchQueue.main)
        for name in IslMediaRemoteKeys.notifications {
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    public func stop() {
        guard started else { return }
        started = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        timer?.invalidate()
        timer = nil
        api = nil
    }

    public func refresh() {
        guard let api else { return }
        let q = DispatchQueue.main
        api.getInfo(q) { [weak self] cf in
            let dict = (cf as? [String: Any]) ?? [:]
            api.getPlaying(q) { playing in
                let finish: (Int32?) -> Void = { pid in
                    MainActor.assumeIsolated { self?.deliver(dict, playing: playing, pid: pid) }
                }
                if let getPID = api.getPID { getPID(q) { finish($0 > 0 ? $0 : nil) } } else { finish(nil) }
            }
        }
    }

    private func deliver(_ dict: [String: Any], playing: Bool, pid: Int32?) {
        guard started else { return }
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let info = IslMediaRemoteParser.parse(dict, isPlaying: playing, bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        health = tracker.observe(isPlayingFlag: playing, infoEmpty: info.isEmpty)
        onInfo?(info.isEmpty ? nil : info)
    }

    public func owns(bundleID: String?) -> Bool { true }

    @discardableResult
    public func send(_ command: IslPlaybackCommand) -> Bool {
        guard let api else { return false }
        switch command {
        case .play: return api.send(IslMediaRemoteKeys.commandPlay, nil)
        case .pause: return api.send(IslMediaRemoteKeys.commandPause, nil)
        case .toggle: return api.send(IslMediaRemoteKeys.commandToggle, nil)
        case .next: return api.send(IslMediaRemoteKeys.commandNext, nil)
        case .previous: return api.send(IslMediaRemoteKeys.commandPrevious, nil)
        case .seek(let t):
            guard let set = api.setElapsed else { return false }
            set(t)
            return true
        }
    }
}

@MainActor
public final class IslPlayerNotificationDriver: IslNowPlayingDriving {
    public let sourceName = "players"
    public private(set) var health = IslSourceHealth.ok
    public var onInfo: ((IslNowPlayingInfo?) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var latest: [IslScriptPlayer: IslNowPlayingInfo] = [:]
    private var lastPlayer: IslScriptPlayer?

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        for p in IslScriptPlayer.allCases {
            let o = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(p.notificationName), object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo
                MainActor.assumeIsolated { self?.received(p, info) }
            }
            observers.append(o)
        }
    }

    public func stop() {
        for o in observers { DistributedNotificationCenter.default().removeObserver(o) }
        observers = []
        latest = [:]
        lastPlayer = nil
    }

    public func refresh() {}

    private func received(_ p: IslScriptPlayer, _ userInfo: [AnyHashable: Any]?) {
        if let info = userInfo.flatMap({ p.parse(userInfo: $0) }) {
            latest[p] = info
            lastPlayer = p
            onInfo?(info)
        } else {
            latest[p] = nil
            if lastPlayer == p { lastPlayer = nil }
            onInfo?(latest.values.first)
        }
    }

    public func owns(bundleID: String?) -> Bool { IslScriptPlayer.allCases.contains { $0.bundleID == bundleID } }

    @discardableResult
    public func send(_ command: IslPlaybackCommand) -> Bool {
        guard let p = lastPlayer ?? IslScriptPlayer.allCases.first(where: { latest[$0] != nil }), let src = p.commandScript(command) else { return false }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).first != nil else { return false }
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }
}
