import Foundation
import CoreGraphics
@testable import MultitulCore

enum IslFix {
    static let notchScreen = IslScreenInfo(id: 1, key: "builtin", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1069), safeAreaTop: 38, auxLeftWidth: 762.5, auxRightWidth: 762.5,
                                           scale: 2, isBuiltin: true, isMain: true)
    static let externalScreen = IslScreenInfo(id: 2, key: "0610-a001-00000001", name: "Studio", frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
                                              visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1416), safeAreaTop: 0, scale: 2, isBuiltin: false, isMain: false)
    static let leftScreen = IslScreenInfo(id: 3, key: "left", name: "Left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                          visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1056), safeAreaTop: 0, scale: 1, isBuiltin: false, isMain: false)
    static let all = [notchScreen, externalScreen, leftScreen]

    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func activity(_ id: String, _ section: String = "music", priority: Int = 50, started: TimeInterval = 0, expires: TimeInterval? = nil,
                         urgent: Bool = false, peeks: Bool = false, token: String = "") -> IslActivity {
        IslActivity(id: id, section: IslSectionID(section), priority: priority, startedAt: at(started), expiresAt: expires.map(at), urgent: urgent, peeks: peeks, token: token)
    }

    static func info(_ title: String = "Song", artist: String = "Band", album: String = "Album", duration: TimeInterval? = 200, elapsed: TimeInterval? = 10,
                     playing: Bool = true, bundle: String? = "com.apple.Music", timestamp: Date? = nil) -> IslNowPlayingInfo {
        var i = IslNowPlayingInfo()
        i.title = title
        i.artist = artist
        i.album = album
        i.duration = duration
        i.elapsed = elapsed
        i.timestamp = timestamp
        i.rate = playing ? 1 : 0
        i.isPlaying = playing
        i.bundleID = bundle
        i.appName = "Music"
        return i
    }

    static func descriptor(_ id: String, order: Int, hidden: Bool = false) -> IslSectionDescriptor {
        IslSectionDescriptor(id: IslSectionID(id), title: id, symbol: "circle", defaultOrder: order, defaultHidden: hidden)
    }
}

@MainActor
final class IslFakeDriver: IslNowPlayingDriving {
    let sourceName: String
    var health = IslSourceHealth.ok
    var onInfo: ((IslNowPlayingInfo?) -> Void)?
    var started = 0
    var stopped = 0
    var refreshes = 0
    var sent: [IslPlaybackCommand] = []
    var owned: Set<String>
    var sendResult = true

    init(_ name: String = "fake", owned: Set<String> = []) {
        sourceName = name
        self.owned = owned
    }

    func start() { started += 1 }
    func stop() { stopped += 1 }
    func refresh() { refreshes += 1 }
    func owns(bundleID: String?) -> Bool { bundleID.map(owned.contains) ?? false }
    func send(_ command: IslPlaybackCommand) -> Bool { sent.append(command); return sendResult }
    func push(_ info: IslNowPlayingInfo?) { onInfo?(info) }
}

final class IslFakeLevels: IslLevelsDriving {
    var volume: Float? = 0.5
    var muted: Bool? = false
    func outputVolume() -> Float? { volume }
    func setOutputVolume(_ value: Float) -> Bool { volume = value; return true }
    func isMuted() -> Bool? { muted }
    func setMuted(_ on: Bool) -> Bool { muted = on; return true }
}
