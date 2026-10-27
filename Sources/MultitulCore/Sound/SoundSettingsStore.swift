import Foundation

public final class SoundSettingsStore {
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    private func strings(_ key: String) -> [String] {
        AudioPriorityLogic.sanitized((defaults.array(forKey: key) as? [String]) ?? [])
    }

    public func loadSwitcher() -> OutputSwitcherSettings {
        var s = OutputSwitcherSettings()
        s.cycle = strings("soundOutput.cycle")
        if let v = defaults.object(forKey: "soundOutput.syncSystem") as? Bool { s.syncSystemOutput = v }
        if let v = defaults.object(forKey: "soundOutput.hud") as? Bool { s.showHud = v }
        return s
    }

    public func saveSwitcher(_ s: OutputSwitcherSettings) {
        let base = OutputSwitcherSettings()
        if s.cycle.isEmpty { defaults.removeObject(forKey: "soundOutput.cycle") } else { defaults.set(AudioPriorityLogic.sanitized(s.cycle), forKey: "soundOutput.cycle") }
        put("soundOutput.syncSystem", s.syncSystemOutput, base.syncSystemOutput)
        put("soundOutput.hud", s.showHud, base.showHud)
    }

    public func loadPriority() -> AudioPriorityConfig {
        var c = AudioPriorityConfig()
        for scope in AudioScope.allCases {
            let p = "audioPriority.\(scope.rawValue)."
            var r = AudioPriorityRule()
            r.enabled = (defaults.object(forKey: p + "enabled") as? Bool) ?? false
            r.order = strings(p + "order")
            r.ignored = Set(strings(p + "ignored"))
            c.setRule(scope, r)
        }
        if let v = defaults.string(forKey: "audioPriority.onConnect"), let p = AudioConnectPolicy(rawValue: v) { c.onConnect = p }
        if let v = defaults.string(forKey: "audioPriority.newDevice"), let p = AudioNewDevicePolicy(rawValue: v) { c.newDevice = p }
        if let v = defaults.object(forKey: "audioPriority.syncSystem") as? Bool { c.syncSystemOutput = v }
        if let v = defaults.object(forKey: "audioPriority.notify") as? Bool { c.notify = v }
        return c
    }

    public func savePriority(_ c: AudioPriorityConfig) {
        let base = AudioPriorityConfig()
        for scope in AudioScope.allCases {
            let p = "audioPriority.\(scope.rawValue)."
            let r = c.rule(scope)
            put(p + "enabled", r.enabled, false)
            if r.order.isEmpty { defaults.removeObject(forKey: p + "order") } else { defaults.set(AudioPriorityLogic.sanitized(r.order), forKey: p + "order") }
            if r.ignored.isEmpty { defaults.removeObject(forKey: p + "ignored") } else { defaults.set(r.ignored.sorted(), forKey: p + "ignored") }
        }
        put("audioPriority.onConnect", c.onConnect.rawValue, base.onConnect.rawValue)
        put("audioPriority.newDevice", c.newDevice.rawValue, base.newDevice.rawValue)
        put("audioPriority.syncSystem", c.syncSystemOutput, base.syncSystemOutput)
        put("audioPriority.notify", c.notify, base.notify)
    }

    // Last seen name per device UID, so an unplugged device stays readable in the list.
    public func loadNames() -> [String: String] { (defaults.dictionary(forKey: "audioPriority.names") as? [String: String]) ?? [:] }

    public func saveNames(_ names: [String: String]) {
        if names.isEmpty { defaults.removeObject(forKey: "audioPriority.names") } else { defaults.set(names, forKey: "audioPriority.names") }
    }

    public func loadMic() -> MicMuteSettings {
        var s = MicMuteSettings()
        if let v = defaults.string(forKey: "micMute.scope"), let sc = MicMuteScope(rawValue: v) { s.scope = sc }
        if let v = defaults.object(forKey: "micMute.indicator") as? Bool { s.showIndicator = v }
        if let v = defaults.object(forKey: "micMute.hud") as? Bool { s.showHud = v }
        return s
    }

    public func saveMic(_ s: MicMuteSettings) {
        let base = MicMuteSettings()
        put("micMute.scope", s.scope.rawValue, base.scope.rawValue)
        put("micMute.indicator", s.showIndicator, base.showIndicator)
        put("micMute.hud", s.showHud, base.showHud)
    }
}
