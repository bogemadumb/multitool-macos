import Foundation

public enum IslPlaybackCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(TimeInterval)
}

public struct IslNowPlayingInfo: Equatable, Sendable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var duration: TimeInterval?
    public var elapsed: TimeInterval?
    public var timestamp: Date?
    public var rate = 0.0
    public var isPlaying: Bool?
    public var bundleID: String?
    public var appName: String?
    public var artworkData: Data?
    public var artworkID: String?
    public var contentID: String?

    public init() {}

    public var isEmpty: Bool {
        [title, artist, album].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var playing: Bool { isPlaying ?? (rate > 0) }
}

public struct IslTrack: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    public var bundleID: String?
    public var appName: String?
    public var contentID: String?
    public var artworkKey: String

    public init(_ info: IslNowPlayingInfo) {
        title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        album = info.album.trimmingCharacters(in: .whitespacesAndNewlines)
        duration = info.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        bundleID = info.bundleID
        appName = info.appName
        contentID = info.contentID
        artworkKey = IslArtworkKey.make(title: title, artist: artist, album: album, bundleID: info.bundleID, artworkID: info.artworkID)
    }

    public var identity: String {
        [IslArtworkKey.normalize(title), IslArtworkKey.normalize(artist), IslArtworkKey.normalize(album), contentID ?? "", bundleID ?? ""].joined(separator: "\u{1F}")
    }

    public var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

public enum IslArtworkKey {
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func make(title: String, artist: String, album: String, bundleID: String?, artworkID: String?) -> String {
        let app = bundleID ?? ""
        let raw: String
        if let id = artworkID, !id.isEmpty {
            raw = "id|\(app)|\(id)"
        } else if normalize(album).isEmpty {
            raw = "t|\(app)|\(normalize(artist))|\(normalize(title))"
        } else {
            raw = "a|\(app)|\(normalize(artist))|\(normalize(album))"
        }
        return "art-" + fnv1a(raw)
    }

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

public struct IslLRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    private var recency: [Key] = []

    public init(capacity: Int) { self.capacity = max(capacity, 1) }

    public var count: Int { storage.count }
    public var keys: [Key] { recency }

    public mutating func get(_ key: Key) -> Value? {
        guard let v = storage[key] else { return nil }
        touch(key)
        return v
    }

    public func peek(_ key: Key) -> Value? { storage[key] }

    public mutating func set(_ key: Key, _ value: Value) {
        storage[key] = value
        touch(key)
        while recency.count > capacity {
            let old = recency.removeFirst()
            storage[old] = nil
        }
    }

    public mutating func removeAll() {
        storage = [:]
        recency = []
    }

    private mutating func touch(_ key: Key) {
        if let i = recency.firstIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
    }
}

public struct IslNowPlayingChange: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let track = IslNowPlayingChange(rawValue: 1)
    public static let playback = IslNowPlayingChange(rawValue: 2)
    public static let app = IslNowPlayingChange(rawValue: 4)
    public static let seeked = IslNowPlayingChange(rawValue: 8)
    public static let cleared = IslNowPlayingChange(rawValue: 16)
}

public struct IslNowPlaying: Equatable, Sendable {
    public var track: IslTrack?
    public var isPlaying = false
    public var rate = 0.0
    public var anchorElapsed = 0.0
    public var anchorTime = Date.distantPast
    public var updatedAt = Date.distantPast

    public init() {}

    public var duration: TimeInterval? { track?.duration }

    func raw(at now: Date) -> TimeInterval {
        anchorElapsed + max(0, now.timeIntervalSince(anchorTime)) * rate
    }

    public func elapsed(at now: Date) -> TimeInterval {
        let e = raw(at: now)
        if let d = duration { return min(max(e, 0), d) }
        return max(e, 0)
    }

    public func progress(at now: Date) -> Double {
        guard let d = duration, d > 0 else { return 0 }
        return min(max(elapsed(at: now) / d, 0), 1)
    }

    public func remaining(at now: Date) -> TimeInterval? {
        duration.map { max($0 - elapsed(at: now), 0) }
    }
}

public struct IslNowPlayingModel {
    public private(set) var value = IslNowPlaying()
    public var stalePausedAfter: TimeInterval = 3600
    public var missingGrace: TimeInterval = 2
    public var seekHold: TimeInterval = 1.2
    public var playHold: TimeInterval = 1.0
    public var overrunTolerance: TimeInterval = 5
    public var jumpThreshold: TimeInterval = 2.5

    private var missingSince: Date?
    private var seekUntil: Date?
    private var playHoldUntil: Date?

    public init() {}

    @discardableResult
    public mutating func apply(_ info: IslNowPlayingInfo?, now: Date) -> IslNowPlayingChange {
        guard let info, !info.isEmpty else {
            if value.track != nil, missingSince == nil { missingSince = now }
            return []
        }
        missingSince = nil
        let track = IslTrack(info)
        var change: IslNowPlayingChange = []
        let first = value.track == nil
        if first || value.track?.identity != track.identity { change.insert(.track) }
        if !first, value.track?.bundleID != track.bundleID { change.insert(.app) }
        let newTrack = change.contains(.track)

        var playing = info.playing
        if !newTrack, let until = playHoldUntil, now < until { playing = value.isPlaying } else { playHoldUntil = nil }
        let rate = playing ? (info.rate > 0 ? info.rate : 1) : 0

        let projected = value.elapsed(at: now)
        var elapsed: Double
        if let e = info.elapsed, e.isFinite {
            let ts = min(info.timestamp ?? now, now)
            elapsed = e + (playing ? max(0, now.timeIntervalSince(ts)) * rate : 0)
            if let d = track.duration { elapsed = min(max(elapsed, 0), d) } else { elapsed = max(elapsed, 0) }
            let holdingSeek = !newTrack && (seekUntil.map { now < $0 } ?? false)
            if holdingSeek, abs(elapsed - projected) > 2 {
                elapsed = projected
            } else {
                if holdingSeek { seekUntil = nil }
                if !newTrack, !first, abs(elapsed - projected) > jumpThreshold { change.insert(.seeked) }
            }
        } else {
            elapsed = newTrack ? 0 : projected
        }
        if newTrack { seekUntil = nil; playHoldUntil = nil }
        if !first, value.isPlaying != playing || abs(value.rate - rate) > 0.001 { change.insert(.playback) }
        if first { change.insert(.playback) }

        value.track = track
        value.isPlaying = playing
        value.rate = rate
        value.anchorElapsed = elapsed
        value.anchorTime = now
        value.updatedAt = now
        return change
    }

    @discardableResult
    public mutating func seek(to time: TimeInterval, now: Date) -> IslNowPlayingChange {
        guard value.track != nil, time.isFinite else { return [] }
        var t = max(time, 0)
        if let d = value.duration { t = min(t, d) }
        value.anchorElapsed = t
        value.anchorTime = now
        seekUntil = now.addingTimeInterval(seekHold)
        return .seeked
    }

    @discardableResult
    public mutating func setPlaying(_ on: Bool, now: Date) -> IslNowPlayingChange {
        guard value.track != nil, value.isPlaying != on else { return [] }
        value.anchorElapsed = value.elapsed(at: now)
        value.anchorTime = now
        value.isPlaying = on
        value.rate = on ? (value.rate > 0 ? value.rate : 1) : 0
        playHoldUntil = now.addingTimeInterval(playHold)
        return .playback
    }

    @discardableResult
    public mutating func prune(now: Date) -> IslNowPlayingChange {
        guard value.track != nil else { return [] }
        if let m = missingSince, now.timeIntervalSince(m) >= missingGrace { return clear() }
        if !value.isPlaying, now.timeIntervalSince(value.updatedAt) > stalePausedAfter { return clear() }
        if value.isPlaying, let d = value.duration, value.raw(at: now) > d + overrunTolerance, now.timeIntervalSince(value.updatedAt) > overrunTolerance {
            value.anchorElapsed = d
            value.anchorTime = now
            value.isPlaying = false
            value.rate = 0
            return .playback
        }
        return []
    }

    @discardableResult
    public mutating func clear() -> IslNowPlayingChange {
        guard value.track != nil else { return [] }
        value = IslNowPlaying()
        missingSince = nil
        seekUntil = nil
        playHoldUntil = nil
        return .cleared
    }
}

public struct IslSourceInfo: Equatable, Sendable {
    public var source: String
    public var info: IslNowPlayingInfo
    public var receivedAt: Date

    public init(source: String, info: IslNowPlayingInfo, receivedAt: Date) {
        self.source = source
        self.info = info
        self.receivedAt = receivedAt
    }
}

public enum IslNowPlayingMerge {
    public static func pick(_ candidates: [IslSourceInfo], previous: String?) -> IslSourceInfo? {
        let live = candidates.filter { !$0.info.isEmpty }
        let playing = live.filter { $0.info.playing }
        let pool = playing.isEmpty ? live : playing
        return pool.sorted { a, b in
            let ap = a.source == previous, bp = b.source == previous
            if ap != bp { return ap }
            if a.receivedAt != b.receivedAt { return a.receivedAt > b.receivedAt }
            return a.source < b.source
        }.first
    }
}

public enum IslSourceHealth: Equatable, Sendable {
    case unknown
    case ok
    case restricted
    case unavailable(String)

    public var note: String? {
        switch self {
        case .unknown, .ok: nil
        case .restricted: "Система не отдаёт данные плеера (macOS 15.4+ закрывает MediaRemote для сторонних приложений). Работают Музыка и Spotify через автоматизацию."
        case .unavailable(let r): "Источник недоступен: \(r)"
        }
    }
}

public struct IslHealthTracker: Sendable {
    public static let threshold = 3
    public private(set) var health = IslSourceHealth.unknown
    private var suspicious = 0

    public init() {}

    @discardableResult
    public mutating func observe(isPlayingFlag: Bool, infoEmpty: Bool) -> IslSourceHealth {
        if !infoEmpty {
            suspicious = 0
            health = .ok
        } else if isPlayingFlag {
            suspicious += 1
            if suspicious >= Self.threshold { health = .restricted }
        } else if health != .restricted {
            suspicious = 0
        }
        return health
    }

    public mutating func markUnavailable(_ reason: String) { health = .unavailable(reason) }
}

@MainActor
public protocol IslNowPlayingDriving: AnyObject {
    var sourceName: String { get }
    var health: IslSourceHealth { get }
    var onInfo: ((IslNowPlayingInfo?) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
    func owns(bundleID: String?) -> Bool
    @discardableResult func send(_ command: IslPlaybackCommand) -> Bool
}

@MainActor
public final class IslNowPlayingService {
    public private(set) var model = IslNowPlayingModel()
    public private(set) var artwork = IslLRUCache<String, Data>(capacity: 16)
    public private(set) var activeSource: String?
    public var onChange: ((IslNowPlayingChange) -> Void)?

    private let drivers: [IslNowPlayingDriving]
    private let clock: () -> Date
    private var latest: [String: IslSourceInfo] = [:]
    private var running = false

    public init(drivers: [IslNowPlayingDriving], clock: @escaping () -> Date = { Date() }) {
        self.drivers = drivers
        self.clock = clock
    }

    public var value: IslNowPlaying { model.value }

    public var currentArtwork: Data? { value.track.flatMap { artwork.peek($0.artworkKey) } }

    public var healthNotes: [String] { drivers.compactMap(\.health.note) }

    public func start() {
        guard !running else { return }
        running = true
        for d in drivers {
            let name = d.sourceName
            d.onInfo = { [weak self] info in self?.receive(source: name, info: info) }
            d.start()
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        for d in drivers { d.stop(); d.onInfo = nil }
        latest = [:]
        activeSource = nil
        _ = model.clear()
        artwork.removeAll()
    }

    public func refresh() { drivers.forEach { $0.refresh() } }

    public func receive(source: String, info: IslNowPlayingInfo?) {
        let now = clock()
        if let info, !info.isEmpty { latest[source] = IslSourceInfo(source: source, info: info, receivedAt: now) } else { latest[source] = nil }
        let picked = IslNowPlayingMerge.pick(Array(latest.values), previous: activeSource)
        activeSource = picked?.source
        if let p = picked, let data = p.info.artworkData, !data.isEmpty {
            artwork.set(IslTrack(p.info).artworkKey, data)
        }
        let change = model.apply(picked?.info, now: now)
        onChange?(change)
    }

    public func tick() {
        let change = model.prune(now: clock())
        if !change.isEmpty { onChange?(change) }
    }

    private func driver(for bundleID: String?) -> IslNowPlayingDriving? {
        if let src = activeSource, let d = drivers.first(where: { $0.sourceName == src }) { return d }
        return drivers.first { $0.owns(bundleID: bundleID) } ?? drivers.first
    }

    @discardableResult
    public func send(_ command: IslPlaybackCommand) -> Bool {
        let now = clock()
        var change: IslNowPlayingChange = []
        let playing = value.isPlaying
        switch command {
        case .play: change = model.setPlaying(true, now: now)
        case .pause: change = model.setPlaying(false, now: now)
        case .toggle: change = model.setPlaying(!playing, now: now)
        case .seek(let t): change = model.seek(to: t, now: now)
        case .next, .previous: break
        }
        if !change.isEmpty { onChange?(change) }
        return driver(for: value.track?.bundleID)?.send(command) ?? false
    }

    public func skip(by seconds: TimeInterval) {
        let now = clock()
        guard value.track != nil else { return }
        send(.seek(value.elapsed(at: now) + seconds))
    }
}
