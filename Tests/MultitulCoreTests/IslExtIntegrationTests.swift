import Testing
import Foundation
@testable import MultitulCore

private func act(_ id: String, _ section: String, _ priority: Int, started: TimeInterval = 0, expires: TimeInterval? = nil, token: String = "", peeks: Bool = false) -> IslActivity {
    IslFix.activity(id, section, priority: priority, started: started, expires: expires, peeks: peeks, token: token)
}

@Suite struct IslExtArbiterTests {
    @Test func priorityLadderIsStrictlyOrdered() {
        let ladder = [IslPriority.ambient, IslPriority.music, IslPriority.calendar, IslPriority.download, IslPriority.transient, IslPriority.notification,
                      IslPriority.calendarSoon, IslPriority.levelsHud, IslPriority.accessory, IslPriority.watch, IslPriority.calendarImminent, IslPriority.timer,
                      IslPriority.recording, IslPriority.critical]
        #expect(ladder == ladder.sorted() && Set(ladder).count == ladder.count)
    }

    @Test func timerBeatsEverythingExceptRecording() {
        var a = IslArbiter()
        let all = [act("music", "music", IslPriority.music), act("download", "downloads", IslPriority.download), act("calendar", "calendar", IslPriority.calendarImminent),
                   act("acc.x", "accessories", IslPriority.accessory), act("watch", "watch", IslPriority.watch), act("timer", "timer", IslPriority.timer)]
        #expect(a.resolve(all, now: IslFix.at(1)).winner?.id == "timer")
        var b = IslArbiter()
        #expect(b.resolve(all + [act("recording", "shots", IslPriority.recording)], now: IslFix.at(1)).winner?.id == "recording")
    }

    @Test func downloadBeatsMusicButYieldsToASoonCalendarEvent() {
        var a = IslArbiter()
        let music = act("music", "music", IslPriority.music, started: 5)
        let dl = act("download", "downloads", IslPriority.download)
        #expect(a.resolve([music, dl], now: IslFix.at(6)).winner?.id == "download")
        var b = IslArbiter()
        #expect(b.resolve([dl, act("calendar", "calendar", IslPriority.calendarSoon)], now: IslFix.at(6)).winner?.id == "calendar")
    }

    @Test func aFarCalendarEventLosesToADownload() {
        var a = IslArbiter()
        #expect(a.resolve([act("calendar", "calendar", IslPriority.calendar), act("download", "downloads", IslPriority.download)], now: IslFix.at(1)).winner?.id == "download")
    }

    @Test func runningWinnerIsNotStolenByALowerExtensionActivity() {
        var a = IslArbiter()
        let dl = act("download", "downloads", IslPriority.download)
        _ = a.resolve([dl], now: IslFix.at(1))
        let r = a.resolve([dl, act("calendar", "calendar", IslPriority.calendar, started: 5), act("music", "lyrics", IslPriority.music, started: 6)], now: IslFix.at(7))
        #expect(r.winner?.id == "download" && !r.changed)
    }

    @Test func imminentCalendarPreemptsARunningDownload() {
        var a = IslArbiter()
        let dl = act("download", "downloads", IslPriority.download)
        _ = a.resolve([dl], now: IslFix.at(1))
        let r = a.resolve([dl, act("calendar", "calendar", IslPriority.calendarImminent, started: 5)], now: IslFix.at(6))
        #expect(r.winner?.id == "calendar" && r.changed && r.secondary?.id == "download")
    }

    @Test func newNotificationPeeksOverMusic() {
        var a = IslArbiter()
        let music = act("music", "music", IslPriority.music, token: "t1", peeks: true)
        _ = a.resolve([music], now: IslFix.at(0))
        let r = a.resolve([music, act("notification", "notifications", IslPriority.notification, started: 5, token: "n1", peeks: true)], now: IslFix.at(5))
        #expect(r.winner?.id == "notification" && r.shouldPeek)
    }

    @Test func expiredAccessoryFallsBackToMusic() {
        var a = IslArbiter()
        let music = act("music", "music", IslPriority.music)
        let acc = act("acc.a", "accessories", IslPriority.accessory, started: 1, expires: 6, peeks: true)
        #expect(a.resolve([music, acc], now: IslFix.at(2)).winner?.id == "acc.a")
        #expect(a.resolve([music, acc], now: IslFix.at(6)).winner?.id == "music")
    }

    @Test func mutedExtensionSectionsAreSkipped() {
        var a = IslArbiter()
        let r = a.resolve([act("timer", "timer", IslPriority.timer), act("music", "music", IslPriority.music)], now: IslFix.at(1), muted: ["timer"])
        #expect(r.winner?.id == "music")
    }

    @Test func sameTokenDoesNotPeekAgain() {
        var a = IslArbiter()
        let n = act("download", "downloads", IslPriority.download, token: "run|a", peeks: true)
        _ = a.resolve([], now: IslFix.at(0))
        #expect(a.resolve([n], now: IslFix.at(1)).shouldPeek)
        #expect(!a.resolve([n], now: IslFix.at(2)).shouldPeek)
    }

    @Test func realActivitiesFromEveryFeatureHaveUniqueIdsAndKnownSections() {
        let now = ExtFix.now
        var ids: [String] = []
        var sections: [IslSectionID] = []
        func take(_ a: IslActivity?) { if let a { ids.append(a.id); sections.append(a.section) } }
        take(IslCalActivityFactory.activity(.until(ExtFix.event("e", start: ExtFix.at(600)), 600), now: now))
        var hub = IslTmrHub()
        hub.startTimer(seconds: 60, now: now)
        take(hub.activity(now: now))
        take(IslAccActivityFactory.activity(for: .connected(IslAccDevice(id: "a", name: "A")), now: now))
        var center = IslNtfCenter()
        _ = center.ingest([IslNtfItem(id: "n", bundleID: "x", title: "t", body: "b", date: now)], now: now, settings: IslNtfSettings())
        take(center.activity(now: now, settings: IslNtfSettings()))
        take(IslDlActivityFactory.activity([IslDlItem(id: "t|a", name: "a", tempName: "a.crdownload", browser: .chromium, state: .downloading, bytes: 1, expectedTotal: nil, startedAt: now,
                                                      lastGrowthAt: now, finishedAt: nil, speed: 0)], now: now))
        var w = IslWatDetector()
        _ = w.begin(nil, now: now)
        take(IslWatActivityFactory.activity(w, settledAt: nil, now: now))
        #expect(Set(ids).count == ids.count && ids.count == 6)
        let known = Set(IslCoreSections.descriptors.map(\.id))
        #expect(sections.allSatisfy { known.contains($0) })
    }
}

@Suite struct IslExtRegistryTests {
    @Test func everyExtensionModuleHasAnIslandGroupInfo() {
        #expect(IslExtModules.all.count == 10)
        for id in IslExtModules.all {
            let i = id.info
            #expect(i.group == .island && !i.enabledByDefault && !i.title.isEmpty && !i.summary.isEmpty && !i.symbol.isEmpty)
            #expect(id.rawValue.allSatisfy { $0.isASCII } && id.enabledKey.allSatisfy { $0.isASCII })
        }
    }

    @Test func titlesAreUniqueAmongAllModules() {
        let titles = ModuleID.allCases.map { $0.info.title }
        #expect(Set(titles).count == titles.count)
    }

    @Test func permissionsMatchTheCatalog() {
        #expect(ModuleID.notchCalendar.info.permissions == [.calendars])
        #expect(ModuleID.notchNotifications.info.permissions.contains(.accessibility))
        #expect(ModuleID.notchAccessories.info.permissions == [.bluetooth])
        #expect(ModuleID.notchQueue.info.permissions == [.automation])
        #expect(ModuleID.notchLiveEq.info.permissions == [.systemAudio])
        #expect(ModuleID.notchWatch.info.permissions == [.screenRecording])
        #expect(ModuleID.notchTimer.info.permissions.isEmpty && ModuleID.notchMascot.info.permissions.isEmpty && ModuleID.notchLyrics.info.permissions.isEmpty)
    }

    @Test func extensionDescriptorsPointAtTheirModules() {
        for d in IslExtModules.descriptors {
            #expect(d.module != nil && IslExtModules.all.contains(d.module!) && d.module!.info.group == .island)
            #expect(!d.title.isEmpty && !d.symbol.isEmpty && !d.summary.isEmpty && d.id.rawValue.allSatisfy { $0.isASCII })
        }
        #expect(Set(IslExtModules.descriptors.compactMap(\.module)).count == IslExtModules.descriptors.count)
    }

    @Test func coreDescriptorListIncludesTheExtensionsAfterTheCoreSections() {
        let all = IslCoreSections.descriptors
        #expect(Set(all.map(\.id)).count == all.count && Set(all.map(\.defaultOrder)).count == all.count)
        let coreMax = all.filter { $0.module == nil || !IslExtModules.all.contains($0.module!) }.map(\.defaultOrder).max() ?? 0
        #expect(IslExtModules.descriptors.allSatisfy { $0.defaultOrder > coreMax })
        #expect(all.count == 9 + IslExtModules.descriptors.count)
    }

    @Test func layoutPlacesNewSectionsAtTheEndAndKeepsUserOrder() {
        let known = IslCoreSections.descriptors
        let oldOrder = known.filter { !IslExtModules.descriptors.contains($0) }.map(\.id.rawValue).reversed()
        let layout = IslLayout(order: Array(oldOrder), hidden: [])
        let resolved = layout.resolved(known: known).map(\.id.rawValue)
        #expect(Array(resolved.prefix(9)) == Array(oldOrder))
        #expect(Set(resolved.suffix(IslExtModules.descriptors.count)) == Set(IslExtModules.descriptors.map(\.id.rawValue)))
    }

    @Test func registryOnlyExposesSectionsOfRunningModules() {
        let runningModules: Set<ModuleID> = [.notchTimer]
        let visible = IslCoreSections.descriptors.filter { d in d.module.map { !IslExtModules.all.contains($0) || runningModules.contains($0) } ?? true }
        #expect(visible.contains { $0.id == IslSectionIDs.timer } && !visible.contains { $0.id == IslSectionIDs.calendar })
    }

    @Test func extensionHotkeysStayUnassignedAndUnique() {
        let specs = IslExtModules.all.flatMap { $0.info.hotkeys }
        #expect(specs.allSatisfy { $0.defaultCombo.isNone && $0.id.allSatisfy(\.isASCII) && $0.id.hasPrefix("notch.") })
        let all = HotkeyHints.allSpecs.map(\.id)
        #expect(Set(all).count == all.count)
        #expect(HotkeyHints.suggested.count == 44)
    }

    @Test func everySettingsKeyIsAsciiAndNamespaced() {
        let kv = WndMemoryStore()
        var cal = IslCalSettings(); cal.leadMinutes = 30; cal.hiddenCalendars = ["x"]
        IslCalSettingsStore(kv).save(cal)
        var tmr = IslTmrSettings(); tmr.defaultMinutes = 5; tmr.pomodoro.focusMinutes = 30
        IslTmrSettingsStore(kv).save(tmr)
        var acc = IslAccSettings(); acc.lowThreshold = 10; acc.hiddenDevices = ["a"]
        IslAccSettingsStore(kv).save(acc)
        var lyr = IslLyrSettings(); lyr.fetchOnline = false
        IslLyrSettingsStore(kv).save(lyr)
        var que = IslQueueSettings(); que.limit = 3
        IslQueueSettingsStore(kv).save(que)
        var eq = IslEqSettings(); eq.compactBars = 5
        IslEqSettingsStore(kv).save(eq)
        var dl = IslDlSettings(); dl.folder = "/tmp/Загрузки"
        IslDlSettingsStore(kv).save(dl)
        var wat = IslWatSettings(); wat.interval = 5
        IslWatSettingsStore(kv).save(wat)
        var msc = IslMscSettings(); msc.style = .robot
        IslMscSettingsStore(kv).save(msc)
        var ntf = IslNtfSettings(); ntf.hideSystemBanner = true
        IslNtfSettingsStore(kv).save(ntf)
        var h = IslTmrHub(); h.startTimer(seconds: 9, now: ExtFix.now)
        IslTmrPersistence(kv).save(h.state)
        #expect(kv.values.count >= 14)
        #expect(kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) && $0.hasPrefix("notch.") })
        let prefixes = Set(kv.values.keys.map { $0.split(separator: ".").prefix(2).joined(separator: ".") })
        #expect(prefixes == ["notch.calendar", "notch.timer", "notch.accessories", "notch.lyrics", "notch.queue", "notch.liveEq", "notch.downloads", "notch.watch", "notch.mascot", "notch.notifications"])
    }

    @Test func settingsStoresDoNotTouchRealPreferences() {
        let before = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Preferences/notch.calendar.plist")
        let kv = WndMemoryStore()
        IslCalSettingsStore(kv).save({ var s = IslCalSettings(); s.leadMinutes = 20; return s }())
        #expect(kv.values.count == 1)
        #expect(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Preferences/notch.calendar.plist") == before)
    }

    @Test func sectionIdentifiersAreStableStrings() {
        let ids = [IslSectionIDs.calendar, IslSectionIDs.notifications, IslSectionIDs.timer, IslSectionIDs.accessories, IslSectionIDs.lyrics, IslSectionIDs.queue,
                   IslSectionIDs.downloads, IslSectionIDs.watch].map(\.rawValue)
        #expect(ids == ["calendar", "notifications", "timer", "accessories", "lyrics", "queue", "downloads", "watch"])
    }

    @Test func textHelpers() {
        #expect(IslExtText.trimmed("  abc  ", max: 10) == "abc")
        #expect(IslExtText.trimmed("abcdefghij", max: 5) == "abcd…")
        #expect(IslExtText.oneLine("a\n  b \n\nc") == "a b c")
    }
}
