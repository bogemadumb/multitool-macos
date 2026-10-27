import Foundation

public struct MusicBlockSettings: Equatable, Sendable {
    public var replacementPath = ""
    public var replacementBundleID = ""
    public var playInReplacement = true

    public init() {}

    public static let blockedBundleIDs: Set<String> = ["com.apple.Music", "com.apple.iTunes"]
    public static let armWindow: TimeInterval = 2.5
}

public struct MediaKeyPress: Equatable, Sendable {
    public static let play: UInt16 = 16
    public static let next: UInt16 = 17
    public static let previous: UInt16 = 18
    public static let fast: UInt16 = 19
    public static let rewind: UInt16 = 20
    public static let launching: Set<UInt16> = [play, next, previous, fast, rewind]

    public var code: UInt16
    public var isDown: Bool
    public var isRepeat: Bool

    public init(code: UInt16, isDown: Bool, isRepeat: Bool) {
        self.code = code
        self.isDown = isDown
        self.isRepeat = isRepeat
    }

    // NSEvent systemDefined: subtype 8 = auxiliary control buttons; data1 = code << 16 | flags (state in bits 8...15, repeat in bit 0).
    public static func decode(subtype: Int, data1: Int) -> MediaKeyPress? {
        guard subtype == 8 else { return nil }
        let raw = UInt32(truncatingIfNeeded: data1)
        let code = UInt16((raw >> 16) & 0xFFFF)
        let state = (raw >> 8) & 0xFF
        return MediaKeyPress(code: code, isDown: state == 0x0A, isRepeat: raw & 1 != 0)
    }
}

public enum MusicBlockAllow: String, Equatable, Sendable {
    case notMusicApp, alreadyJudged, noMediaKey, keyExpired, userGesture
}

public struct MusicBlockAction: Equatable, Sendable {
    public var openReplacement: Bool
    public var startPlayback: Bool
}

public enum MusicBlockDecision: Equatable, Sendable {
    case allow(MusicBlockAllow)
    case block(MusicBlockAction)
}

// A launch is blocked only when a media key was seen just before it and nothing the user clicked or typed came later.
public final class MusicBlockLogic {
    public var settings: MusicBlockSettings
    public private(set) var blockedCount = 0
    private var lastKey: (code: UInt16, at: TimeInterval)?
    private var consumedKey: (code: UInt16, at: TimeInterval)?
    private var judgedPID: Int32?

    public init(settings: MusicBlockSettings = MusicBlockSettings()) { self.settings = settings }

    public func keyPressed(_ key: MediaKeyPress, at now: TimeInterval) {
        guard key.isDown, !key.isRepeat, MediaKeyPress.launching.contains(key.code) else { return }
        lastKey = (key.code, now)
    }

    public func appLaunched(bundleID: String?, pid: Int32, at now: TimeInterval, secondsSinceGesture: TimeInterval) -> MusicBlockDecision {
        guard let bundleID, MusicBlockSettings.blockedBundleIDs.contains(bundleID) else { return .allow(.notMusicApp) }
        if pid == judgedPID { return .allow(.alreadyJudged) }
        judgedPID = pid
        let key = lastKey
        lastKey = nil
        consumedKey = key
        guard let key else { return .allow(.noMediaKey) }
        let elapsed = now - key.at
        guard now.isFinite, elapsed >= 0, elapsed <= MusicBlockSettings.armWindow else { return .allow(.keyExpired) }
        guard !secondsSinceGesture.isNaN, secondsSinceGesture > elapsed else { return .allow(.userGesture) }
        blockedCount += 1
        let hasReplacement = MusicBlockLogic.replacementUsable(settings.replacementPath, bundleID: settings.replacementBundleID)
        return .block(MusicBlockAction(openReplacement: hasReplacement,
                                       startPlayback: hasReplacement && settings.playInReplacement && key.code == MediaKeyPress.play))
    }

    // The process could not be stopped at will-launch: let the did-launch notification judge it again.
    public func cancelBlock(pid: Int32) {
        guard judgedPID == pid else { return }
        judgedPID = nil
        if blockedCount > 0 { blockedCount -= 1 }
        lastKey = consumedKey
    }

    public func reset() {
        lastKey = nil
        consumedKey = nil
        judgedPID = nil
    }

    public static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 255 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    // The replacement must never be a blocked app, or launch and kill would chase each other.
    public static func replacementUsable(_ path: String, bundleID: String) -> Bool {
        !path.isEmpty && !bundleID.isEmpty && !MusicBlockSettings.blockedBundleIDs.contains(bundleID)
    }
}

public enum MusicPlaybackRetry {
    public static let attempts = 3

    // -600 (process not found) and -609 (connection invalid): the command never arrived, so asking again cannot play twice.
    public static func neverArrived(_ status: Int) -> Bool { status == -600 || status == -609 }

    public static func shouldRetry(status: Int, attempt: Int) -> Bool { neverArrived(status) && attempt + 1 < attempts }
}

public final class MusicBlockStore {
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> MusicBlockSettings {
        var s = MusicBlockSettings()
        if let v = defaults.string(forKey: "musicBlock.replacementPath") { s.replacementPath = v }
        if let v = defaults.string(forKey: "musicBlock.replacementId") { s.replacementBundleID = v }
        if let v = defaults.object(forKey: "musicBlock.playInReplacement") as? Bool { s.playInReplacement = v }
        return s
    }

    public func save(_ s: MusicBlockSettings) {
        let base = MusicBlockSettings()
        if s.replacementPath == base.replacementPath { defaults.removeObject(forKey: "musicBlock.replacementPath") } else { defaults.set(s.replacementPath, forKey: "musicBlock.replacementPath") }
        if s.replacementBundleID == base.replacementBundleID { defaults.removeObject(forKey: "musicBlock.replacementId") } else { defaults.set(s.replacementBundleID, forKey: "musicBlock.replacementId") }
        if s.playInReplacement == base.playInReplacement { defaults.removeObject(forKey: "musicBlock.playInReplacement") } else { defaults.set(s.playInReplacement, forKey: "musicBlock.playInReplacement") }
    }
}
