import Foundation

public struct FinderCutSettings: Equatable, Sendable {
    public var pasteImage = true
    public var indicator = true
    public init() {}
}

public final class ClipSettingsStore {
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    private func bool(_ key: String, _ d: Bool) -> Bool { (defaults.object(forKey: key) as? Bool) ?? d }
    private func int(_ key: String, _ d: Int) -> Int { (defaults.object(forKey: key) as? Int) ?? d }

    public func loadClipboard() -> ClipSettings {
        var s = ClipSettings()
        s.maxItems = int("clipboard.maxItems", s.maxItems)
        s.maxAgeDays = int("clipboard.maxAgeDays", s.maxAgeDays)
        s.keepRich = bool("clipboard.keepRich", s.keepRich)
        s.keepImages = bool("clipboard.keepImages", s.keepImages)
        s.keepFiles = bool("clipboard.keepFiles", s.keepFiles)
        s.keepColors = bool("clipboard.keepColors", s.keepColors)
        s.maxItemKB = int("clipboard.maxItemKB", s.maxItemKB)
        s.maxTotalMB = int("clipboard.maxTotalMB", s.maxTotalMB)
        s.skipSensitive = bool("clipboard.skipSensitive", s.skipSensitive)
        s.skipConcealed = bool("clipboard.skipConcealed", s.skipConcealed)
        s.skipTransient = bool("clipboard.skipTransient", s.skipTransient)
        if let a = defaults.array(forKey: "clipboard.ignoredApps") as? [String] { s.ignoredApps = a }
        s.autoClearSeconds = int("clipboard.autoClear", s.autoClearSeconds)
        s.clearOnSleep = bool("clipboard.clearOnSleep", s.clearOnSleep)
        s.clearOnLock = bool("clipboard.clearOnLock", s.clearOnLock)
        s.menuBarPreview = bool("clipboard.menuBarPreview", s.menuBarPreview)
        s.pasteOnPick = bool("clipboard.pasteOnPick", s.pasteOnPick)
        return s.sanitized
    }

    public func saveClipboard(_ settings: ClipSettings) {
        let s = settings.sanitized
        let b = ClipSettings()
        put("clipboard.maxItems", s.maxItems, b.maxItems)
        put("clipboard.maxAgeDays", s.maxAgeDays, b.maxAgeDays)
        put("clipboard.keepRich", s.keepRich, b.keepRich)
        put("clipboard.keepImages", s.keepImages, b.keepImages)
        put("clipboard.keepFiles", s.keepFiles, b.keepFiles)
        put("clipboard.keepColors", s.keepColors, b.keepColors)
        put("clipboard.maxItemKB", s.maxItemKB, b.maxItemKB)
        put("clipboard.maxTotalMB", s.maxTotalMB, b.maxTotalMB)
        put("clipboard.skipSensitive", s.skipSensitive, b.skipSensitive)
        put("clipboard.skipConcealed", s.skipConcealed, b.skipConcealed)
        put("clipboard.skipTransient", s.skipTransient, b.skipTransient)
        if s.ignoredApps == b.ignoredApps { defaults.removeObject(forKey: "clipboard.ignoredApps") } else { defaults.set(s.ignoredApps, forKey: "clipboard.ignoredApps") }
        put("clipboard.autoClear", s.autoClearSeconds, b.autoClearSeconds)
        put("clipboard.clearOnSleep", s.clearOnSleep, b.clearOnSleep)
        put("clipboard.clearOnLock", s.clearOnLock, b.clearOnLock)
        put("clipboard.menuBarPreview", s.menuBarPreview, b.menuBarPreview)
        put("clipboard.pasteOnPick", s.pasteOnPick, b.pasteOnPick)
    }

    public func loadPlain() -> PastePlainSettings {
        var s = PastePlainSettings()
        s.trimEdges = bool("pastePlain.trim", s.trimEdges)
        return s
    }

    public func savePlain(_ s: PastePlainSettings) { put("pastePlain.trim", s.trimEdges, PastePlainSettings().trimEdges) }

    public func loadUrl() -> UrlCleanerSettings {
        var s = UrlCleanerSettings()
        s.cleanOnCopy = bool("urlCleaner.auto", s.cleanOnCopy)
        s.showHud = bool("urlCleaner.hud", s.showHud)
        s.rules.unwrapRedirects = bool("urlCleaner.unwrap", false)
        s.rules.added = UrlCleanRules.parse(defaults.string(forKey: "urlCleaner.added"))
        s.rules.disabled = UrlCleanRules.parse(defaults.string(forKey: "urlCleaner.disabled"))
        s.rules.disabledSites = Set((defaults.array(forKey: "urlCleaner.disabledSites") as? [String]) ?? [])
        return s
    }

    public func saveUrl(_ s: UrlCleanerSettings) {
        let b = UrlCleanerSettings()
        put("urlCleaner.auto", s.cleanOnCopy, b.cleanOnCopy)
        put("urlCleaner.hud", s.showHud, b.showHud)
        put("urlCleaner.unwrap", s.rules.unwrapRedirects, false)
        let added = UrlCleanRules.serialize(s.rules.added)
        let disabled = UrlCleanRules.serialize(s.rules.disabled)
        if added.isEmpty { defaults.removeObject(forKey: "urlCleaner.added") } else { defaults.set(added, forKey: "urlCleaner.added") }
        if disabled.isEmpty { defaults.removeObject(forKey: "urlCleaner.disabled") } else { defaults.set(disabled, forKey: "urlCleaner.disabled") }
        if s.rules.disabledSites.isEmpty { defaults.removeObject(forKey: "urlCleaner.disabledSites") } else { defaults.set(s.rules.disabledSites.sorted(), forKey: "urlCleaner.disabledSites") }
    }

    public func loadDmg() -> DmgSettings {
        var s = DmgSettings()
        s.askFirst = bool("dmg.askFirst", s.askFirst)
        if let v = defaults.string(forKey: "dmg.destination"), let d = DmgDestination(rawValue: v) { s.destination = d }
        s.ejectAfter = bool("dmg.eject", s.ejectAfter)
        s.trashDmg = bool("dmg.trash", s.trashDmg)
        s.reveal = bool("dmg.reveal", s.reveal)
        s.requireValidSignature = bool("dmg.requireSignature", s.requireValidSignature)
        s.reinstallSameVersion = bool("dmg.reinstall", s.reinstallSameVersion)
        s.watchDownloads = bool("dmg.watchDownloads", s.watchDownloads)
        return s
    }

    public func saveDmg(_ s: DmgSettings) {
        let b = DmgSettings()
        put("dmg.askFirst", s.askFirst, b.askFirst)
        put("dmg.destination", s.destination.rawValue, b.destination.rawValue)
        put("dmg.eject", s.ejectAfter, b.ejectAfter)
        put("dmg.trash", s.trashDmg, b.trashDmg)
        put("dmg.reveal", s.reveal, b.reveal)
        put("dmg.requireSignature", s.requireValidSignature, b.requireValidSignature)
        put("dmg.reinstall", s.reinstallSameVersion, b.reinstallSameVersion)
        put("dmg.watchDownloads", s.watchDownloads, b.watchDownloads)
    }

    public func loadFinderCut() -> FinderCutSettings {
        var s = FinderCutSettings()
        s.pasteImage = bool("finderCut.pasteImage", s.pasteImage)
        s.indicator = bool("finderCut.indicator", s.indicator)
        return s
    }

    public func saveFinderCut(_ s: FinderCutSettings) {
        let b = FinderCutSettings()
        put("finderCut.pasteImage", s.pasteImage, b.pasteImage)
        put("finderCut.indicator", s.indicator, b.indicator)
    }
}
