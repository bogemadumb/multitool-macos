import Foundation

public enum AudioConnectPolicy: String, CaseIterable, Sendable {
    case takeOverIfHigher, onlyOnDisconnect

    public var title: String {
        switch self {
        case .takeOverIfHigher: "Подключилось устройство выше текущего: переключиться"
        case .onlyOnDisconnect: "Переключаться только когда текущее отключилось"
        }
    }
}

public enum AudioNewDevicePolicy: String, CaseIterable, Sendable {
    case append, adoptIfSystemChose

    public var title: String {
        switch self {
        case .append: "Новое устройство: в конец списка"
        case .adoptIfSystemChose: "Новое устройство: наверх, если macOS выбрала его сама"
        }
    }
}

public struct AudioPriorityRule: Equatable, Sendable {
    public var enabled = false
    public var order: [String] = []
    public var ignored: Set<String> = []

    public init(enabled: Bool = false, order: [String] = [], ignored: Set<String> = []) {
        self.enabled = enabled
        self.order = order
        self.ignored = ignored
    }
}

public struct AudioPriorityConfig: Equatable, Sendable {
    public var output = AudioPriorityRule()
    public var input = AudioPriorityRule()
    public var onConnect = AudioConnectPolicy.takeOverIfHigher
    public var newDevice = AudioNewDevicePolicy.append
    public var syncSystemOutput = true
    public var notify = false

    public init() {}

    public func rule(_ scope: AudioScope) -> AudioPriorityRule { scope == .output ? output : input }

    public mutating func setRule(_ scope: AudioScope, _ rule: AudioPriorityRule) {
        if scope == .output { output = rule } else { input = rule }
    }
}

public enum AudioPriorityTrigger: Equatable, Sendable {
    case enforce
    case devicesChanged(added: Set<String>, removed: Set<String>, previousDefault: String?)
    case defaultChanged
}

public enum AudioPriorityReason: String, Equatable, Sendable {
    case enforce, activeLost, systemMoved, higherConnected
}

public enum AudioPriorityKeep: String, Equatable, Sendable {
    case disabled, noRanked, alreadyBest, currentIgnored, manualChoice, policyOnlyOnDisconnect, notHigher, noChange
}

public enum AudioPriorityOutcome: Equatable, Sendable {
    case keep(AudioPriorityKeep)
    case switchTo(String, AudioPriorityReason)
}

public enum AudioPriorityLogic {
    public static func decide(rule: AudioPriorityRule, policy: AudioConnectPolicy, available: Set<String>, current: String?, trigger: AudioPriorityTrigger) -> AudioPriorityOutcome {
        guard rule.enabled else { return .keep(.disabled) }
        if case .defaultChanged = trigger { return .keep(.manualChoice) }
        if let current, rule.ignored.contains(current) { return .keep(.currentIgnored) }
        let candidates = rule.order.filter { available.contains($0) && !rule.ignored.contains($0) }
        guard let best = candidates.first else { return .keep(.noRanked) }

        func go(_ uid: String, _ reason: AudioPriorityReason) -> AudioPriorityOutcome {
            uid == current ? .keep(.alreadyBest) : .switchTo(uid, reason)
        }

        switch trigger {
        case .enforce:
            return go(best, .enforce)
        case .defaultChanged:
            return .keep(.manualChoice)
        case .devicesChanged(let added, let removed, let previous):
            if let previous, removed.contains(previous) { return go(best, .activeLost) }
            if added.isEmpty { return .keep(.noChange) }
            if current != previous {
                return policy == .onlyOnDisconnect ? .keep(.policyOnlyOnDisconnect) : go(best, .systemMoved)
            }
            guard policy == .takeOverIfHigher else { return .keep(.policyOnlyOnDisconnect) }
            guard let top = candidates.first(where: { added.contains($0) }) else { return .keep(.noChange) }
            let currentRank = current.flatMap { rule.order.firstIndex(of: $0) }
            let topRank = rule.order.firstIndex(of: top) ?? Int.max
            if let currentRank, currentRank <= topRank { return .keep(.notHigher) }
            return go(top, .higherConnected)
        }
    }

    // New devices join the list; synthetic (virtual / aggregate) ones only when the user adds them by hand.
    public static func placeNew(order: [String], ignored: Set<String>, devices: [AudioDeviceInfo], current: String?, policy: AudioNewDevicePolicy) -> [String] {
        var result = order
        let known = Set(order)
        let fresh = devices
            .filter { !known.contains($0.uid) && !ignored.contains($0.uid) && !$0.transport.isSynthetic && !$0.isHidden }
            .sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }
        for d in fresh {
            if policy == .adoptIfSystemChose, d.uid == current { result.insert(d.uid, at: 0) } else { result.append(d.uid) }
        }
        return result
    }

    public static func move(_ order: [String], uid: String, by delta: Int) -> [String] {
        guard let i = order.firstIndex(of: uid) else { return order }
        let j = min(max(i + delta, 0), order.count - 1)
        guard j != i else { return order }
        var r = order
        r.remove(at: i)
        r.insert(uid, at: j)
        return r
    }

    public static func sanitized(_ order: [String]) -> [String] {
        var seen = Set<String>()
        return order.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public struct AudioPriorityAction: Equatable, Sendable {
    public var scope: AudioScope
    public var from: String?
    public var to: String
    public var reason: AudioPriorityReason
    public var success: Bool
}

// Runs on one serial queue owned by the caller; the hardware may block.
public final class AudioPriorityEngine: @unchecked Sendable {
    public var config: AudioPriorityConfig
    public var onPlacement: ((AudioScope, [String]) -> Void)?
    public static let settleWindow: TimeInterval = 3
    private let hardware: AudioHardware
    private let now: () -> TimeInterval
    private var known: [AudioScope: Set<String>] = [:]
    private var lastDefault: [AudioScope: String] = [:]
    private var recent: [AudioScope: (added: Set<String>, at: TimeInterval)] = [:]
    private var primed = false

    public init(hardware: AudioHardware, config: AudioPriorityConfig = AudioPriorityConfig(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware
        self.config = config
        self.now = now
    }

    public func prime() {
        let all = hardware.devices()
        for scope in AudioScope.allCases {
            known[scope] = Set(AudioDeviceInfo.visible(all, scope: scope).map(\.uid))
            if let d = hardware.defaultUID(scope) { lastDefault[scope] = d } else { lastDefault[scope] = nil }
            mergeNew(scope, devices: AudioDeviceInfo.visible(all, scope: scope), current: lastDefault[scope])
        }
        primed = true
    }

    @discardableResult
    public func enforceAll() -> [AudioPriorityAction] {
        if !primed { prime() }
        let all = hardware.devices()
        var actions: [AudioPriorityAction] = []
        for scope in AudioScope.allCases {
            let devs = AudioDeviceInfo.visible(all, scope: scope)
            let cur = hardware.defaultUID(scope)
            mergeNew(scope, devices: devs, current: cur)
            known[scope] = Set(devs.map(\.uid))
            let outcome = AudioPriorityLogic.decide(rule: config.rule(scope), policy: config.onConnect, available: known[scope] ?? [], current: cur, trigger: .enforce)
            if let a = apply(scope, outcome, from: cur) { actions.append(a) }
            lastDefault[scope] = hardware.defaultUID(scope)
        }
        return actions
    }

    @discardableResult
    public func refresh() -> [AudioPriorityAction] {
        if !primed { prime(); return [] }
        let all = hardware.devices()
        var actions: [AudioPriorityAction] = []
        for scope in AudioScope.allCases {
            let devs = AudioDeviceInfo.visible(all, scope: scope)
            let avail = Set(devs.map(\.uid))
            let cur = hardware.defaultUID(scope)
            let prevKnown = known[scope] ?? []
            let added = avail.subtracting(prevKnown)
            let removed = prevKnown.subtracting(avail)
            let previous = lastDefault[scope]
            mergeNew(scope, devices: devs, current: cur)
            known[scope] = avail
            if added.isEmpty && removed.isEmpty {
                // macOS often moves the default a moment after the device list changes.
                if let r = recent[scope], now() - r.at <= Self.settleWindow, let cur, cur != previous {
                    let late = AudioPriorityLogic.decide(rule: config.rule(scope), policy: config.onConnect, available: avail, current: cur,
                                                         trigger: .devicesChanged(added: r.added, removed: [], previousDefault: previous))
                    if let a = apply(scope, late, from: cur) { actions.append(a) }
                    lastDefault[scope] = hardware.defaultUID(scope)
                } else {
                    lastDefault[scope] = cur
                }
                continue
            }
            if !added.isEmpty { recent[scope] = (added, now()) }
            let outcome = AudioPriorityLogic.decide(rule: config.rule(scope), policy: config.onConnect, available: avail, current: cur,
                                                    trigger: .devicesChanged(added: added, removed: removed, previousDefault: previous))
            if let a = apply(scope, outcome, from: cur) { actions.append(a) }
            lastDefault[scope] = hardware.defaultUID(scope)
        }
        return actions
    }

    private func mergeNew(_ scope: AudioScope, devices: [AudioDeviceInfo], current: String?) {
        let rule = config.rule(scope)
        let order = AudioPriorityLogic.placeNew(order: rule.order, ignored: rule.ignored, devices: devices, current: current, policy: config.newDevice)
        guard order != rule.order else { return }
        var r = rule
        r.order = order
        config.setRule(scope, r)
        onPlacement?(scope, order)
    }

    private func apply(_ scope: AudioScope, _ outcome: AudioPriorityOutcome, from: String?) -> AudioPriorityAction? {
        guard case .switchTo(let uid, let reason) = outcome else { return nil }
        var ok = hardware.setDefault(scope, uid: uid)
        if ok, scope == .output, config.syncSystemOutput { ok = hardware.setSystemOutput(uid: uid) && ok }
        return AudioPriorityAction(scope: scope, from: from, to: uid, reason: reason, success: ok)
    }
}
