import Foundation

public enum MicMuteScope: String, CaseIterable, Sendable {
    case allInputs, defaultInput

    public var title: String { self == .allInputs ? "Все микрофоны" : "Только микрофон по умолчанию" }
}

public struct MicMuteSettings: Equatable, Sendable {
    public var scope = MicMuteScope.allInputs
    public var showIndicator = true
    public var showHud = true

    public init() {}
}

public enum MicClaimKind: String, Codable, Sendable { case muteSwitch, volume }

public struct MicClaim: Codable, Equatable, Sendable {
    public var uid: String
    public var kind: MicClaimKind
    public var level: Float

    public init(uid: String, kind: MicClaimKind, level: Float = 0) {
        self.uid = uid
        self.kind = kind
        self.level = level
    }
}

public protocol MicClaimStoring: AnyObject {
    var active: Bool { get set }
    var claims: [MicClaim] { get set }
}

public struct MicMuteReport: Equatable, Sendable {
    public var muted: [String] = []
    public var released: [String] = []
    public var failed: [String] = []
    public var pending: [String] = []

    public init() {}
}

// Every device this engine silenced stays recorded until it has been put back, even while unplugged.
public final class MicMuteEngine: @unchecked Sendable {
    public var scope: MicMuteScope
    private let hardware: AudioHardware
    private let input: AudioInputControlling
    private let store: MicClaimStoring

    public init(hardware: AudioHardware, input: AudioInputControlling, store: MicClaimStoring, scope: MicMuteScope = .allInputs) {
        self.hardware = hardware
        self.input = input
        self.store = store
        self.scope = scope
    }

    public var isMuted: Bool { store.active }
    public var claimedUIDs: [String] { store.claims.map(\.uid) }

    @discardableResult
    public func setMuted(_ on: Bool) -> MicMuteReport {
        store.active = on
        return reassert()
    }

    @discardableResult
    public func toggle() -> MicMuteReport { setMuted(!store.active) }

    @discardableResult
    public func reassert() -> MicMuteReport {
        var report = MicMuteReport()
        let present = Set(AudioDeviceInfo.visible(hardware.devices(), scope: .input).map(\.uid))
        if store.active {
            let targets = targetUIDs(present: present)
            for uid in targets {
                if mute(uid) { report.muted.append(uid) } else { report.failed.append(uid) }
            }
            for claim in store.claims where present.contains(claim.uid) && !targets.contains(claim.uid) {
                if release(claim) { report.released.append(claim.uid) } else { report.failed.append(claim.uid) }
            }
        } else {
            for claim in store.claims {
                if present.contains(claim.uid) {
                    if release(claim) { report.released.append(claim.uid) } else { report.failed.append(claim.uid) }
                } else {
                    report.pending.append(claim.uid)
                }
            }
        }
        return report
    }

    private func targetUIDs(present: Set<String>) -> [String] {
        switch scope {
        case .allInputs:
            return AudioDeviceInfo.visible(hardware.devices(), scope: .input).map(\.uid)
        case .defaultInput:
            guard let d = hardware.defaultUID(.input), present.contains(d) else { return [] }
            return [d]
        }
    }

    private func claim(for uid: String) -> MicClaim? { store.claims.first { $0.uid == uid } }

    private func setClaim(_ c: MicClaim) {
        var all = store.claims.filter { $0.uid != c.uid }
        all.append(c)
        store.claims = all
    }

    private func dropClaim(_ uid: String) { store.claims = store.claims.filter { $0.uid != uid } }

    private func mute(_ uid: String) -> Bool {
        if let c = claim(for: uid) {
            switch c.kind {
            case .muteSwitch:
                if input.muteSwitch(uid: uid) == true { return true }
                return input.setMuteSwitch(uid: uid, true)
            case .volume:
                guard let v = input.inputVolume(uid: uid) else { return false }
                return v <= Self.silent || input.setInputVolume(uid: uid, 0)
            }
        }
        if let m = input.muteSwitch(uid: uid) {
            if m { return true }
            setClaim(MicClaim(uid: uid, kind: .muteSwitch))
            if input.setMuteSwitch(uid: uid, true) { return true }
            dropClaim(uid)
        }
        if let v = input.inputVolume(uid: uid) {
            if v <= Self.silent { return true }
            setClaim(MicClaim(uid: uid, kind: .volume, level: v))
            if input.setInputVolume(uid: uid, 0) { return true }
            dropClaim(uid)
        }
        return false
    }

    private func release(_ c: MicClaim) -> Bool {
        switch c.kind {
        case .muteSwitch:
            guard input.setMuteSwitch(uid: c.uid, false) else { return false }
        case .volume:
            if let now = input.inputVolume(uid: c.uid), now <= Self.silent {
                guard input.setInputVolume(uid: c.uid, max(c.level, Self.restoreFloor)) else { return false }
            }
        }
        dropClaim(c.uid)
        return true
    }

    static let silent: Float = 0.001
    static let restoreFloor: Float = 0.05
}

public final class MicDefaultsStore: MicClaimStoring {
    static let activeKey = "micMute.active"
    static let claimsKey = "micMute.claims"
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public var active: Bool {
        get { defaults.bool(forKey: Self.activeKey) }
        set { if newValue { defaults.set(true, forKey: Self.activeKey) } else { defaults.removeObject(forKey: Self.activeKey) } }
    }

    public var claims: [MicClaim] {
        get {
            guard let data = defaults.data(forKey: Self.claimsKey), let list = try? JSONDecoder().decode([MicClaim].self, from: data) else { return [] }
            return list
        }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.claimsKey); return }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.claimsKey) }
        }
    }
}
