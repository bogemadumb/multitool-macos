import Foundation

public struct MixAppDiff: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var changed: [String] = []

    public init(added: [String] = [], removed: [String] = [], changed: [String] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public static func compute(old: [MixAppEntry], new: [MixAppEntry]) -> MixAppDiff {
        let o = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var d = MixAppDiff()
        for e in new {
            guard let prev = o[e.key] else { d.added.append(e.key); continue }
            if prev.processObjectIDs != e.processObjectIDs || prev.isOutputting != e.isOutputting || prev.name != e.name { d.changed.append(e.key) }
        }
        for e in old where n[e.key] == nil { d.removed.append(e.key) }
        return d
    }
}

public struct MixAppRow: Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var isRunning: Bool
    public var isOutputting: Bool
    public var setting: MixAppSetting

    public var id: String { key }
}

public enum MixOrdering {
    public static func sorted(_ rows: [MixAppRow], order: [String]) -> [MixAppRow] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.sorted { a, b in
            if a.setting.pinned != b.setting.pinned { return a.setting.pinned }
            let ia = index[a.key] ?? Int.max, ib = index[b.key] ?? Int.max
            if ia != ib { return ia < ib }
            if a.isOutputting != b.isOutputting { return a.isOutputting }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.key < b.key
        }
    }

    // Moves `key` to the place of `target`; keys missing from the order are first filled in from the visible list.
    public static func move(_ order: [String], visible: [String], key: String, before target: String) -> [String] {
        guard key != target, visible.contains(key), visible.contains(target) else { return order }
        var base = order.filter { visible.contains($0) }
        for k in visible where !base.contains(k) { base.append(k) }
        let rest = order.filter { !visible.contains($0) }
        base.removeAll { $0 == key }
        let at = base.firstIndex(of: target) ?? base.endIndex
        base.insert(key, at: at)
        return base + rest
    }

    public static func move(_ order: [String], visible: [String], key: String, by delta: Int) -> [String] {
        guard let i = visible.firstIndex(of: key) else { return order }
        let j = i + delta
        guard visible.indices.contains(j) else { return order }
        var v = visible
        v.swapAt(i, j)
        let rest = order.filter { !visible.contains($0) }
        return v + rest
    }
}

// Which rows the panel shows: outputting apps; just-stopped ones for a grace period; pinned and configured ones.
public struct MixAppListModel {
    public static let graceSeconds: TimeInterval = 8

    public private(set) var entries: [MixAppEntry] = []
    private var lastOutput: [String: TimeInterval] = [:]

    public init() {}

    @discardableResult
    public mutating func update(_ new: [MixAppEntry], now: TimeInterval) -> MixAppDiff {
        let diff = MixAppDiff.compute(old: entries, new: new)
        for e in new where e.isOutputting { lastOutput[e.key] = now }
        let keys = Set(new.map(\.key))
        lastOutput = lastOutput.filter { keys.contains($0.key) }
        entries = new
        return diff
    }

    public func isRecentlyActive(_ key: String, now: TimeInterval) -> Bool {
        guard let t = lastOutput[key] else { return false }
        return now - t <= Self.graceSeconds
    }

    public func rows(settings: MixSettings, apps: [String: MixAppSetting], now: TimeInterval) -> [MixAppRow] {
        var out: [MixAppRow] = []
        var seen = Set<String>()
        for e in entries {
            seen.insert(e.key)
            let s = apps[e.key] ?? MixAppSetting()
            let visible = !settings.hideInactive || e.isOutputting || isRecentlyActive(e.key, now: now) || s.pinned || s.needsProcessing
            if visible { out.append(MixAppRow(key: e.key, name: e.name, isRunning: true, isOutputting: e.isOutputting, setting: s)) }
        }
        for (key, s) in apps where !seen.contains(key) && s.pinned {
            out.append(MixAppRow(key: key, name: s.name.isEmpty ? key : s.name, isRunning: false, isOutputting: false, setting: s))
        }
        return MixOrdering.sorted(out, order: settings.order)
    }
}
