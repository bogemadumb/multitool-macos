import Foundation

public final class WindowSettingsStore {
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { kv.removeObject(forKey: key) } else { kv.set(v, forKey: key) }
    }

    private func bool(_ key: String, _ d: Bool) -> Bool { (kv.object(forKey: key) as? Bool) ?? d }
    private func int(_ key: String, _ d: Int) -> Int { (kv.object(forKey: key) as? Int) ?? d }
    private func double(_ key: String, _ d: Double) -> Double { (kv.object(forKey: key) as? Double) ?? d }
    private func string(_ key: String) -> String? { kv.object(forKey: key) as? String }

    private func list(_ key: String, _ d: [String]) -> AppExceptionList {
        if let a = kv.object(forKey: key) as? [String] { return AppExceptionList(a) }
        return AppExceptionList(d)
    }

    private func putList(_ key: String, _ l: AppExceptionList, _ d: [String]) {
        if l == AppExceptionList(d) { kv.removeObject(forKey: key) } else { kv.set(l.entries, forKey: key) }
    }

    public func loadLayout() -> WindowLayoutSettings {
        var s = WindowLayoutSettings()
        let p = "windowLayout."
        s.shortcutsEnabled = bool(p + "shortcutsEnabled", s.shortcutsEnabled)
        s.gaps = WindowGaps(window: int(p + "gap.window", 0), screen: int(p + "gap.screen", 0))
        s.marginPercent = double(p + "marginPercent", s.marginPercent)
        if let v = string(p + "repeatMode"), let m = LayoutRepeat(rawValue: v) { s.repeatMode = m }
        s.ignoredApps = list(p + "ignoredApps", [])
        s.cursorDisplayEnabled = bool(p + "cursorDisplay", s.cursorDisplayEnabled)
        for slot in WindowLayoutAction.customSlots {
            guard let r = string(p + "custom.\(slot).rect"), let rect = FractionRect(stored: r) else { continue }
            s.custom[slot] = CustomLayout(name: string(p + "custom.\(slot).name") ?? "Макет \(slot)", rect: rect)
        }
        s.edge.enabled = bool(p + "edge.enabled", false)
        s.edge.disabledZones = Set((string(p + "edge.disabledZones") ?? "").split(separator: ",").compactMap { SnapZone(rawValue: String($0)) })
        s.edge.layout = SnapZoneLayout(storageValue: string(p + "edge.layout"))
        s.edge.distance = int(p + "edge.distance", s.edge.distance)
        s.edge.showPreview = bool(p + "edge.preview", true)
        s.gesture.enabled = bool(p + "gesture.enabled", false)
        if let m = GestureModifiers.parse(string(p + "gesture.move")) { s.gesture.move = m }
        if let m = GestureModifiers.parse(string(p + "gesture.resize")) { s.gesture.resize = m }
        s.gesture.raiseWindow = bool(p + "gesture.raise", false)
        s.ring.enabled = bool(p + "ring.enabled", false)
        if let t = string(p + "ring.trigger"), let c = KeyCombo(stored: t), !c.isNone { s.ring.trigger = c }
        return s.sanitized
    }

    public func saveLayout(_ settings: WindowLayoutSettings) {
        let s = settings.sanitized
        let b = WindowLayoutSettings()
        let p = "windowLayout."
        put(p + "shortcutsEnabled", s.shortcutsEnabled, b.shortcutsEnabled)
        put(p + "gap.window", s.gaps.window, 0)
        put(p + "gap.screen", s.gaps.screen, 0)
        put(p + "marginPercent", s.marginPercent, b.marginPercent)
        put(p + "repeatMode", s.repeatMode.rawValue, b.repeatMode.rawValue)
        putList(p + "ignoredApps", s.ignoredApps, [])
        put(p + "cursorDisplay", s.cursorDisplayEnabled, b.cursorDisplayEnabled)
        for slot in WindowLayoutAction.customSlots {
            if let c = s.custom[slot] {
                kv.set(c.rect.stored, forKey: p + "custom.\(slot).rect")
                kv.set(c.name, forKey: p + "custom.\(slot).name")
            } else {
                kv.removeObject(forKey: p + "custom.\(slot).rect")
                kv.removeObject(forKey: p + "custom.\(slot).name")
            }
        }
        put(p + "edge.enabled", s.edge.enabled, false)
        let zones = SnapZone.allCases.filter { s.edge.disabledZones.contains($0) }.map(\.rawValue).joined(separator: ",")
        put(p + "edge.disabledZones", zones, "")
        put(p + "edge.layout", s.edge.layout.storageValue, "")
        put(p + "edge.distance", s.edge.distance, b.edge.distance)
        put(p + "edge.preview", s.edge.showPreview, true)
        put(p + "gesture.enabled", s.gesture.enabled, false)
        put(p + "gesture.move", String(s.gesture.move.rawValue), String(b.gesture.move.rawValue))
        put(p + "gesture.resize", String(s.gesture.resize.rawValue), String(b.gesture.resize.rawValue))
        put(p + "gesture.raise", s.gesture.raiseWindow, false)
        put(p + "ring.enabled", s.ring.enabled, false)
        put(p + "ring.trigger", s.ring.trigger.stored, RingSettings.defaultTrigger.stored)
    }

    public func loadMaximizer() -> MaximizerSettings {
        var s = MaximizerSettings()
        s.excluded = list("windowMaximizer.excluded", MaximizerSettings.suggestedExcluded)
        s.inset = int("windowMaximizer.inset", s.inset)
        s.toggleRestores = bool("windowMaximizer.toggleRestores", s.toggleRestores)
        return s.sanitized
    }

    public func saveMaximizer(_ settings: MaximizerSettings) {
        let s = settings.sanitized
        let b = MaximizerSettings()
        putList("windowMaximizer.excluded", s.excluded, MaximizerSettings.suggestedExcluded)
        put("windowMaximizer.inset", s.inset, b.inset)
        put("windowMaximizer.toggleRestores", s.toggleRestores, b.toggleRestores)
    }

    public func loadAutoQuit() -> AutoQuitSettings {
        var s = AutoQuitSettings()
        s.exceptions = list("autoQuit.exceptions", [])
        s.delayMs = int("autoQuit.delayMs", s.delayMs)
        return s.sanitized
    }

    public func saveAutoQuit(_ settings: AutoQuitSettings) {
        let s = settings.sanitized
        putList("autoQuit.exceptions", s.exceptions, [])
        put("autoQuit.delayMs", s.delayMs, AutoQuitSettings().delayMs)
    }

    public func loadDockClick() -> DockClickSettings {
        var s = DockClickSettings()
        if let v = string("dockClick.mode"), let m = DockClickMode(rawValue: v) { s.mode = m }
        s.cycleWindows = bool("dockClick.cycle", s.cycleWindows)
        s.exceptions = list("dockClick.exceptions", [])
        return s
    }

    public func saveDockClick(_ s: DockClickSettings) {
        let b = DockClickSettings()
        put("dockClick.mode", s.mode.rawValue, b.mode.rawValue)
        put("dockClick.cycle", s.cycleWindows, b.cycleWindows)
        putList("dockClick.exceptions", s.exceptions, [])
    }
}
