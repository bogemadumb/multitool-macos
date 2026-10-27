import Foundation

public final class MixSettingsStore {
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { kv.removeObject(forKey: key) } else { kv.set(v, forKey: key) }
    }

    public func loadSettings() -> MixSettings {
        var s = MixSettings()
        if let v = kv.object(forKey: "mixer.maxBoost") as? Double { s.maxBoost = MixGain.clampBoost(v) }
        if let v = kv.object(forKey: "mixer.hideInactive") as? Bool { s.hideInactive = v }
        if let v = kv.object(forKey: "mixer.fineSteps") as? Bool { s.fineSteps = v }
        if let v = kv.object(forKey: "mixer.showMeters") as? Bool { s.showMeters = v }
        if let v = kv.object(forKey: "mixer.guard") as? Bool { s.headphoneGuard = v }
        if let v = kv.object(forKey: "mixer.guardCap") as? Int { s.guardCapPercent = min(max(v, MixSettings.guardRange.lowerBound), MixSettings.guardRange.upperBound) }
        s.order = Self.cleanOrder((kv.object(forKey: "mixer.order") as? [String]) ?? [])
        return s
    }

    public func saveSettings(_ s: MixSettings) {
        let base = MixSettings()
        put("mixer.maxBoost", MixGain.clampBoost(s.maxBoost), base.maxBoost)
        put("mixer.hideInactive", s.hideInactive, base.hideInactive)
        put("mixer.fineSteps", s.fineSteps, base.fineSteps)
        put("mixer.showMeters", s.showMeters, base.showMeters)
        put("mixer.guard", s.headphoneGuard, base.headphoneGuard)
        put("mixer.guardCap", min(max(s.guardCapPercent, MixSettings.guardRange.lowerBound), MixSettings.guardRange.upperBound), base.guardCapPercent)
        let order = Self.cleanOrder(s.order)
        if order.isEmpty { kv.removeObject(forKey: "mixer.order") } else { kv.set(order, forKey: "mixer.order") }
    }

    public static func cleanOrder(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && $0.count <= 200 && seen.insert($0).inserted }
    }

    public func loadApps(maxBoost: Double = MixGain.defaultMaxBoost) -> [String: MixAppSetting] {
        var out: [String: MixAppSetting] = [:]
        for d in (kv.object(forKey: "mixer.apps") as? [[String: Any]]) ?? [] {
            guard let id = d["id"] as? String, !id.isEmpty, id.count <= 200 else { continue }
            var a = MixAppSetting()
            if let v = d["v"] as? Double { a.volume = MixGain.clampVolume(v, maxBoost: maxBoost) }
            if let m = d["m"] as? Bool { a.muted = m }
            if let o = d["o"] as? String, !o.isEmpty { a.outputUID = o }
            if let p = d["p"] as? Bool { a.pinned = p }
            if let n = d["n"] as? String { a.name = n }
            if let t = d["t"] as? Double, t.isFinite { a.lastUsed = t }
            if !a.isNeutral { out[id] = a }
        }
        return out
    }

    public func saveApps(_ apps: [String: MixAppSetting]) {
        let kept = Self.prune(apps)
        if kept.isEmpty { kv.removeObject(forKey: "mixer.apps"); return }
        let rows: [[String: Any]] = kept.keys.sorted().map { id in
            let a = kept[id]!
            var d: [String: Any] = ["id": id]
            if a.volume != 1 { d["v"] = a.volume }
            if a.muted { d["m"] = true }
            if let o = a.outputUID { d["o"] = o }
            if a.pinned { d["p"] = true }
            if !a.name.isEmpty { d["n"] = a.name }
            if a.lastUsed > 0 { d["t"] = a.lastUsed }
            return d
        }
        kv.set(rows, forKey: "mixer.apps")
    }

    // Neutral entries are not stored; beyond the limit the least recently used unpinned ones go first.
    public static func prune(_ apps: [String: MixAppSetting], limit: Int = MixSettings.maxRemembered) -> [String: MixAppSetting] {
        var live = apps.filter { !$0.value.isNeutral && !$0.key.isEmpty }
        guard live.count > limit else { return live }
        let victims = live.sorted {
            if $0.value.pinned != $1.value.pinned { return !$0.value.pinned }
            if $0.value.lastUsed != $1.value.lastUsed { return $0.value.lastUsed < $1.value.lastUsed }
            return $0.key < $1.key
        }.prefix(live.count - limit)
        for (k, _) in victims { live[k] = nil }
        return live
    }
}
