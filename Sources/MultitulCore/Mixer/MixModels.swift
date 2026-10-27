import Foundation

public enum MixIdentity {
    public static let aggregateUIDPrefix = "dev.multitool.app.mix."
    public static let aggregateNamePrefix = "Multitul Mix "
    public static let tapNamePrefix = "Multitul Tap "
    public static let ownBundleID = "dev.multitool.app"
    public static let ignoredBundlePrefixes = ["com.apple.audio.", "com.apple.coreaudio", "com.apple.AudioComponentRegistrar", "com.apple.audioclocksyncd"]
    public static let exeKeyPrefix = "exe."

    public static func aggregateUID(for sessionID: String) -> String { aggregateUIDPrefix + sessionID }
    public static func isOwnAggregateUID(_ uid: String) -> Bool { uid.hasPrefix(aggregateUIDPrefix) }
}

public enum MixHotkeys {
    public static let muteFront = HotkeySpec(id: "mixer.muteFront", title: "Микшер: заглушить / включить приложение на переднем плане", defaultCombo: .none)
    public static let resetAll = HotkeySpec(id: "mixer.resetAll", title: "Микшер: сбросить все приложения к 100%", defaultCombo: .none)
    public static let all = [muteFront, resetAll]
}

public struct MixAppSetting: Equatable, Sendable {
    public var volume: Double = 1
    public var muted = false
    public var outputUID: String?
    public var pinned = false
    public var name = ""
    public var lastUsed: TimeInterval = 0

    public init(volume: Double = 1, muted: Bool = false, outputUID: String? = nil, pinned: Bool = false, name: String = "", lastUsed: TimeInterval = 0) {
        self.volume = volume
        self.muted = muted
        self.outputUID = outputUID
        self.pinned = pinned
        self.name = name
        self.lastUsed = lastUsed
    }

    public var needsProcessing: Bool { volume != 1 || muted || outputUID != nil }
    public var isNeutral: Bool { !needsProcessing && !pinned }

    public var params: MixParams {
        MixParams(volume: Float(MixGain.clampVolume(volume)), muted: muted)
    }
}

public struct MixSettings: Equatable, Sendable {
    public static let maxRemembered = 200

    public var maxBoost: Double = MixGain.defaultMaxBoost
    public var hideInactive = true
    public var fineSteps = false
    public var showMeters = true
    public var headphoneGuard = false
    public var guardCapPercent = 30
    public var order: [String] = []

    public init() {}

    public static let guardRange = 5...100
}

public struct MixProcessInfo: Equatable, Sendable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var isRunningOutput: Bool
    public var executablePath: String?

    public init(objectID: UInt32, pid: Int32, bundleID: String? = nil, isRunningOutput: Bool = false, executablePath: String? = nil) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.executablePath = executablePath
    }
}

public struct MixRunningApp: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var bundlePath: String?
    public var isRegular: Bool

    public init(pid: Int32, bundleID: String?, name: String, bundlePath: String? = nil, isRegular: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.isRegular = isRegular
    }
}

public struct MixAppEntry: Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var processObjectIDs: [UInt32]
    public var pids: [Int32]
    public var isOutputting: Bool

    public var id: String { key }

    public init(key: String, name: String, processObjectIDs: [UInt32], pids: [Int32], isOutputting: Bool) {
        self.key = key
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.pids = pids
        self.isOutputting = isOutputting
    }
}

public enum MixTapMode: String, Equatable, Sendable {
    case process, meter
}

public struct MixDesiredTap: Equatable, Sendable {
    public var key: String
    public var name: String
    public var processObjectIDs: [UInt32]
    public var mode: MixTapMode
    public var outputUID: String
    public var params: MixParams

    public init(key: String, name: String, processObjectIDs: [UInt32], mode: MixTapMode, outputUID: String, params: MixParams = .unity) {
        self.key = key
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.mode = mode
        self.outputUID = outputUID
        self.params = params
    }

    public func sameShape(as other: MixDesiredTap) -> Bool {
        key == other.key && mode == other.mode && outputUID == other.outputUID && processObjectIDs == other.processObjectIDs
    }
}

public enum MixTapError: Error, Equatable, Sendable {
    case unsupported
    case permissionDenied
    case deviceUnavailable
    case tapFailed(Int32)
    case aggregateFailed(Int32)
    case ioFailed(Int32)
    case badFormat

    public var text: String {
        switch self {
        case .unsupported: "нужна macOS 14.2 или новее"
        case .permissionDenied: "нет доступа к звуку системы"
        case .deviceUnavailable: "устройство вывода недоступно"
        case .tapFailed(let s): "не удалось перехватить звук (\(s))"
        case .aggregateFailed(let s): "не удалось создать устройство (\(s))"
        case .ioFailed(let s): "не удалось запустить обработку (\(s))"
        case .badFormat: "неподдерживаемый формат звука"
        }
    }
}

public enum MixAction: Equatable, Sendable {
    case create(MixDesiredTap)
    case replace(MixDesiredTap)
    case destroy(String)
    case update(String, MixParams)
}
