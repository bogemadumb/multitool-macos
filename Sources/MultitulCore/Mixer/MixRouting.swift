import Foundation

public enum MixRouteDecision: Equatable, Sendable {
    case device(uid: String, usedFallback: Bool)
    case none

    public var uid: String? {
        if case .device(let uid, _) = self { return uid }
        return nil
    }
}

public struct MixRouteOption: Equatable, Identifiable, Sendable {
    public var uid: String?
    public var name: String
    public var transport: AudioTransport?
    public var isDefault: Bool

    public var id: String { uid ?? "-default" }
}

public enum MixRouting {
    public static func candidates(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        AudioDeviceInfo.visible(devices, scope: .output).filter { !MixIdentity.isOwnAggregateUID($0.uid) }
    }

    // A missing preferred device falls back to the system default; the preference itself is kept for when it returns.
    public static func resolve(preferred: String?, devices: [AudioDeviceInfo], defaultUID: String?) -> MixRouteDecision {
        let online = candidates(devices)
        let isOnline = { (uid: String) in online.contains { $0.uid == uid } }
        if let p = preferred, isOnline(p) { return .device(uid: p, usedFallback: false) }
        let fallback = preferred != nil
        if let d = defaultUID, isOnline(d) { return .device(uid: d, usedFallback: fallback) }
        if let first = online.first(where: { !$0.transport.isSynthetic }) ?? online.first { return .device(uid: first.uid, usedFallback: true) }
        return .none
    }

    public static func options(devices: [AudioDeviceInfo], defaultUID: String?, defaultName: String = "Как в системе") -> [MixRouteOption] {
        var list = [MixRouteOption(uid: nil, name: defaultName, transport: nil, isDefault: false)]
        let rank = { (d: AudioDeviceInfo) -> Int in d.transport == .airplay ? 2 : (d.transport.isSynthetic ? 1 : 0) }
        let sorted = candidates(devices).sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for d in sorted { list.append(MixRouteOption(uid: d.uid, name: d.name, transport: d.transport, isDefault: d.uid == defaultUID)) }
        return list
    }

    public static func isOffline(preferred: String?, devices: [AudioDeviceInfo]) -> Bool {
        guard let p = preferred else { return false }
        return !candidates(devices).contains { $0.uid == p }
    }
}

public struct MixRetryBackoff: Equatable, Sendable {
    public static let base: TimeInterval = 1
    public static let cap: TimeInterval = 30

    private var failures: [String: Int] = [:]
    private var retryAt: [String: TimeInterval] = [:]

    public init() {}

    public func canTry(_ key: String, now: TimeInterval) -> Bool { now >= (retryAt[key] ?? 0) }

    public mutating func fail(_ key: String, now: TimeInterval) {
        let n = (failures[key] ?? 0) + 1
        failures[key] = n
        retryAt[key] = now + min(Self.cap, Self.base * pow(2, Double(n - 1)))
    }

    public mutating func succeed(_ key: String) {
        failures[key] = nil
        retryAt[key] = nil
    }

    public func failureCount(_ key: String) -> Int { failures[key] ?? 0 }
}
