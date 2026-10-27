import Foundation

public struct MixLiveTapInfo: Equatable, Sendable {
    public var desired: MixDesiredTap
    public var appliedParams: MixParams

    public init(desired: MixDesiredTap, appliedParams: MixParams? = nil) {
        self.desired = desired
        self.appliedParams = appliedParams ?? desired.params
    }
}

public struct MixLevelDemand: Equatable, Sendable {
    public var allApps: Bool
    public var keys: Set<String>
    public var bandKeys: Set<String>

    public init(allApps: Bool = false, keys: Set<String> = [], bandKeys: Set<String> = []) {
        self.allApps = allApps
        self.keys = keys
        self.bandKeys = bandKeys
    }

    public static let none = MixLevelDemand()

    public func wants(_ key: String) -> Bool { allApps || keys.contains(key) || bandKeys.contains(key) }
}

public enum MixPlanner {
    public static func desired(entries: [MixAppEntry], apps: [String: MixAppSetting], settings: MixSettings, devices: [AudioDeviceInfo],
                               defaultUID: String?, demand: MixLevelDemand, failedKeys: Set<String> = []) -> [MixDesiredTap] {
        var out: [MixDesiredTap] = []
        for e in entries where !e.processObjectIDs.isEmpty && !failedKeys.contains(e.key) {
            let s = apps[e.key] ?? MixAppSetting()
            let bands = demand.bandKeys.contains(e.key)
            if s.needsProcessing {
                guard let uid = MixRouting.resolve(preferred: s.outputUID, devices: devices, defaultUID: defaultUID).uid else { continue }
                var p = s.params
                p.volume = Float(MixGain.clampVolume(s.volume, maxBoost: settings.maxBoost))
                p.bandsOn = bands
                out.append(MixDesiredTap(key: e.key, name: e.name, processObjectIDs: e.processObjectIDs, mode: .process, outputUID: uid, params: p))
            } else if e.isOutputting, demand.wants(e.key) {
                guard let uid = MixRouting.resolve(preferred: nil, devices: devices, defaultUID: defaultUID).uid else { continue }
                out.append(MixDesiredTap(key: e.key, name: e.name, processObjectIDs: e.processObjectIDs, mode: .meter, outputUID: uid, params: MixParams(bandsOn: bands)))
            }
        }
        return out
    }

    public static func reconcile(desired: [MixDesiredTap], live: [String: MixLiveTapInfo]) -> [MixAction] {
        var actions: [MixAction] = []
        let want = Dictionary(desired.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for key in live.keys.sorted() where want[key] == nil { actions.append(.destroy(key)) }
        for d in desired {
            guard let l = live[d.key] else { actions.append(.create(d)); continue }
            if !l.desired.sameShape(as: d) { actions.append(.replace(d)) } else if l.appliedParams != d.params { actions.append(.update(d.key, d.params)) }
        }
        return actions
    }
}

public struct MixAggregateInfo: Equatable, Sendable {
    public var objectID: UInt32
    public var uid: String
    public var name: String

    public init(objectID: UInt32, uid: String, name: String) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
    }
}

public struct MixTapInfo: Equatable, Sendable {
    public var objectID: UInt32
    public var uid: String
    public var name: String

    public init(objectID: UInt32, uid: String, name: String) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
    }
}

public struct MixCleanupPlan: Equatable, Sendable {
    public var aggregates: [UInt32]
    public var taps: [UInt32]
    public var isEmpty: Bool { aggregates.isEmpty && taps.isEmpty }
}

public enum MixOrphans {
    public static func isOurAggregate(_ a: MixAggregateInfo) -> Bool {
        a.uid.hasPrefix(MixIdentity.aggregateUIDPrefix) || a.name.hasPrefix(MixIdentity.aggregateNamePrefix)
    }

    public static func isOurTap(_ t: MixTapInfo) -> Bool { t.name.hasPrefix(MixIdentity.tapNamePrefix) }

    // Run at start (owned is empty) and after a crash-restart: whatever carries our prefix and is not in use gets destroyed.
    public static func plan(aggregates: [MixAggregateInfo], taps: [MixTapInfo], ownedAggregateUIDs: Set<String> = [], ownedTapUIDs: Set<String> = []) -> MixCleanupPlan {
        MixCleanupPlan(
            aggregates: aggregates.filter { isOurAggregate($0) && !ownedAggregateUIDs.contains($0.uid) }.map(\.objectID),
            taps: taps.filter { isOurTap($0) && !ownedTapUIDs.contains($0.uid) }.map(\.objectID)
        )
    }
}

public struct MixGuardAction: Equatable, Sendable {
    public var deviceUID: String
    public var from: Float
    public var to: Float
}

// Personal outputs (Bluetooth, USB, AirPlay) falling back to built-in speakers: cap the speaker volume.
public enum MixHeadphoneGuard {
    public static let personal: Set<AudioTransport> = [.bluetooth, .usb, .airplay]

    public static func decide(previous: AudioDeviceInfo?, current: AudioDeviceInfo?, currentVolume: Float?, settings: MixSettings) -> MixGuardAction? {
        guard settings.headphoneGuard, let previous, let current, previous.uid != current.uid else { return nil }
        guard personal.contains(previous.transport), current.transport == .builtIn, let v = currentVolume else { return nil }
        let cap = Float(min(max(settings.guardCapPercent, MixSettings.guardRange.lowerBound), MixSettings.guardRange.upperBound)) / 100
        guard v > cap + 0.001 else { return nil }
        return MixGuardAction(deviceUID: current.uid, from: v, to: cap)
    }
}
