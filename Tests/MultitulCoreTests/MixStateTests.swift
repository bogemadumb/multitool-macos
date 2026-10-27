import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixAppIdentityTests {
    private func resolve(_ procs: [MixProcessInfo], apps: [MixRunningApp] = [MixT.safari, MixT.music, MixT.chrome], pid: Int32 = 1) -> [MixAppEntry] {
        MixAppIdentity.resolve(procs, apps: apps, ownPID: pid)
    }

    @Test func ownProcessIsIgnored() {
        #expect(resolve([MixT.proc(1, pid: 1, "com.apple.Safari")]).isEmpty)
    }

    @Test func ownBundleAndItsHelpersAreIgnored() {
        #expect(resolve([MixT.proc(1, pid: 50, "dev.multitool.app"), MixT.proc(2, pid: 51, "dev.multitool.app.helper")]).isEmpty)
    }

    @Test func systemAudioDaemonsAreIgnored() {
        #expect(resolve([MixT.proc(1, pid: 60, "com.apple.audio.DriverHelper"), MixT.proc(2, pid: 61, "com.apple.coreaudiod")]).isEmpty)
    }

    @Test func runningAppPidGivesTheAppItself() {
        let r = resolve([MixT.proc(7, pid: 100, "com.apple.Safari")])
        #expect(r == [MixAppEntry(key: "com.apple.Safari", name: "Safari", processObjectIDs: [7], pids: [100], isOutputting: true)])
    }

    @Test func helperProcessMapsToTheParentApp() {
        let r = resolve([MixT.proc(9, pid: 999, "com.google.Chrome.helper.Renderer")])
        #expect(r.count == 1 && r[0].key == "com.google.Chrome" && r[0].name == "Google Chrome")
    }

    @Test func longestPrefixWins() {
        let apps = [MixRunningApp(pid: 1, bundleID: "com.foo", name: "Foo"), MixRunningApp(pid: 2, bundleID: "com.foo.bar", name: "Bar")]
        let r = resolve([MixT.proc(1, pid: 77, "com.foo.bar.helper")], apps: apps, pid: 0)
        #expect(r[0].key == "com.foo.bar" && r[0].name == "Bar")
    }

    @Test func similarBundleIdIsNotAParent() {
        let apps = [MixRunningApp(pid: 1, bundleID: "com.foo", name: "Foo")]
        let r = resolve([MixT.proc(1, pid: 77, "com.foobar.tool")], apps: apps, pid: 0)
        #expect(r[0].key == "com.foobar.tool")
    }

    @Test func accessoryAppsDoNotAdoptHelpers() {
        let apps = [MixRunningApp(pid: 1, bundleID: "com.foo", name: "Foo", isRegular: false)]
        let r = resolve([MixT.proc(1, pid: 77, "com.foo.helper")], apps: apps, pid: 0)
        #expect(r[0].key == "com.foo.helper")
    }

    @Test func executablePathInsideAppBundleFindsTheApp() {
        let apps = [MixRunningApp(pid: 5, bundleID: "com.vendor.Player", name: "Player", bundlePath: "/Applications/Player.app/")]
        let r = resolve([MixT.proc(3, pid: 321, "org.xpc.service", path: "/Applications/Player.app/Contents/XPCServices/Svc.xpc/Contents/MacOS/Svc")], apps: apps, pid: 0)
        #expect(r[0].key == "com.vendor.Player")
    }

    @Test func unknownBundleKeepsItsOwnKeyAndReadableName() {
        let r = resolve([MixT.proc(4, pid: 400, "com.example.Tool", path: "/Users/x/Tool.app/Contents/MacOS/Tool")])
        #expect(r[0].key == "com.example.Tool" && r[0].name == "Tool")
        let r2 = resolve([MixT.proc(5, pid: 401, "com.example.Daemon")])
        #expect(r2[0].name == "Daemon")
    }

    @Test func processWithoutBundleIdUsesTheExecutableName() {
        let r = resolve([MixT.proc(6, pid: 500, nil, path: "/usr/local/bin/mpv")])
        #expect(r[0].key == "exe.mpv" && r[0].name == "mpv")
    }

    @Test func processWithoutAnyIdentityIsSkipped() {
        #expect(resolve([MixT.proc(6, pid: 500, nil)]).isEmpty)
        #expect(resolve([MixT.proc(6, pid: 500, "")]).isEmpty)
    }

    @Test func helpersAreAggregatedIntoOneEntry() {
        let r = resolve([MixT.proc(30, pid: 301, "com.google.Chrome.helper", out: false), MixT.proc(10, pid: 300, "com.google.Chrome", out: false), MixT.proc(20, pid: 302, "com.google.Chrome.helper.Renderer", out: true), MixT.proc(10, pid: 300, "com.google.Chrome")])
        #expect(r.count == 1)
        #expect(r[0].processObjectIDs == [10, 20, 30] && r[0].pids == [300, 301, 302])
        #expect(r[0].isOutputting)
    }

    @Test func entriesKeepFirstSeenOrder() {
        let r = resolve([MixT.proc(1, pid: 200, "com.apple.Music"), MixT.proc(2, pid: 100, "com.apple.Safari"), MixT.proc(3, pid: 201, "com.apple.Music")])
        #expect(r.map(\.key) == ["com.apple.Music", "com.apple.Safari"])
    }

    @Test func appPidWithoutBundleIdFallsBackToProcessData() {
        let apps = [MixRunningApp(pid: 100, bundleID: nil, name: "Anon")]
        let r = resolve([MixT.proc(1, pid: 100, "com.x.y")], apps: apps, pid: 0)
        #expect(r[0].key == "com.x.y")
    }

    @Test func bundlePathHelpers() {
        #expect(MixAppIdentity.outermostBundlePath("/A/B.app/Contents/Frameworks/C.app/Contents/MacOS/c") == "/A/B.app")
        #expect(MixAppIdentity.outermostBundlePath("/A/B.app") == "/A/B.app")
        #expect(MixAppIdentity.outermostBundlePath("/usr/bin/say") == nil)
        #expect(MixAppIdentity.displayName(bundleID: nil, executablePath: nil) == "Процесс")
        #expect(MixAppIdentity.displayName(bundleID: "a.b.Cc", executablePath: nil) == "Cc")
    }
}

@Suite struct MixAppListTests {
    private func entry(_ key: String, name: String? = nil, ids: [UInt32] = [1], out: Bool = true) -> MixAppEntry {
        MixAppEntry(key: key, name: name ?? key, processObjectIDs: ids, pids: [1], isOutputting: out)
    }

    @Test func diffFindsAddedRemovedChanged() {
        let old = [entry("a"), entry("b"), entry("c")]
        let new = [entry("b", ids: [1, 2]), entry("c", out: false), entry("d"), entry("a", name: "A2")]
        let d = MixAppDiff.compute(old: old, new: new)
        #expect(d.added == ["d"])
        #expect(d.removed.isEmpty)
        #expect(Set(d.changed) == ["a", "b", "c"])
        let d2 = MixAppDiff.compute(old: old, new: [entry("b"), entry("c")])
        #expect(d2.removed == ["a"] && d2.added.isEmpty && d2.changed.isEmpty)
    }

    @Test func identicalListsGiveAnEmptyDiff() {
        let l = [entry("a"), entry("b")]
        #expect(MixAppDiff.compute(old: l, new: l).isEmpty)
        #expect(MixAppDiff().isEmpty)
    }

    @Test func updateReturnsTheDiffAndStoresEntries() {
        var m = MixAppListModel()
        let d = m.update([entry("a")], now: 0)
        #expect(d.added == ["a"] && m.entries.count == 1)
        #expect(m.update([entry("a")], now: 1).isEmpty)
    }

    @Test func idleAppsAreHiddenByDefault() {
        var m = MixAppListModel()
        m.update([entry("a", out: true), entry("b", out: false)], now: 100)
        let rows = m.rows(settings: MixSettings(), apps: [:], now: 100)
        #expect(rows.map(\.key) == ["a"])
    }

    @Test func justStoppedAppStaysForTheGracePeriod() {
        var m = MixAppListModel()
        m.update([entry("a", out: true)], now: 100)
        m.update([entry("a", out: false)], now: 103)
        #expect(m.rows(settings: MixSettings(), apps: [:], now: 105).map(\.key) == ["a"])
        #expect(m.rows(settings: MixSettings(), apps: [:], now: 100 + MixAppListModel.graceSeconds + 0.1).isEmpty)
        #expect(m.isRecentlyActive("a", now: 105))
    }

    @Test func showingInactiveListsEveryone() {
        var m = MixAppListModel()
        m.update([entry("a", out: false), entry("b", out: false)], now: 0)
        var s = MixSettings()
        s.hideInactive = false
        #expect(m.rows(settings: s, apps: [:], now: 0).count == 2)
    }

    @Test func pinnedAndConfiguredAppsStayVisibleWhenIdle() {
        var m = MixAppListModel()
        m.update([entry("a", out: false), entry("b", out: false), entry("c", out: false)], now: 0)
        let apps = ["a": MixAppSetting(pinned: true), "b": MixAppSetting(volume: 0.5)]
        #expect(Set(m.rows(settings: MixSettings(), apps: apps, now: 0).map(\.key)) == ["a", "b"])
    }

    @Test func pinnedAppThatIsNotRunningShowsFromMemory() {
        var m = MixAppListModel()
        m.update([], now: 0)
        let apps = ["x.y": MixAppSetting(pinned: true, name: "Игра"), "z.w": MixAppSetting(pinned: true)]
        let rows = m.rows(settings: MixSettings(), apps: apps, now: 0)
        #expect(rows.count == 2)
        #expect(rows.first { $0.key == "x.y" }?.name == "Игра" && rows.first { $0.key == "z.w" }?.name == "z.w")
        #expect(rows.allSatisfy { !$0.isRunning })
    }

    @Test func nonPinnedMemoryOfAMissingAppIsNotShown() {
        var m = MixAppListModel()
        m.update([], now: 0)
        #expect(m.rows(settings: MixSettings(), apps: ["x": MixAppSetting(volume: 0.3)], now: 0).isEmpty)
    }

    @Test func recentActivityIsForgottenWhenTheAppQuits() {
        var m = MixAppListModel()
        m.update([entry("a")], now: 10)
        m.update([], now: 11)
        m.update([entry("a", out: false)], now: 12)
        #expect(!m.isRecentlyActive("a", now: 12))
    }

    private func row(_ key: String, name: String? = nil, pinned: Bool = false, out: Bool = true) -> MixAppRow {
        MixAppRow(key: key, name: name ?? key, isRunning: true, isOutputting: out, setting: MixAppSetting(pinned: pinned))
    }

    @Test func pinnedRowsComeFirst() {
        let r = MixOrdering.sorted([row("a"), row("b", pinned: true), row("c")], order: [])
        #expect(r.map(\.key) == ["b", "a", "c"])
    }

    @Test func manualOrderBeatsAlphabet() {
        let r = MixOrdering.sorted([row("a"), row("b"), row("c")], order: ["c", "a"])
        #expect(r.map(\.key) == ["c", "a", "b"])
    }

    @Test func outputtingBeatsIdleThenNames() {
        let r = MixOrdering.sorted([row("x", name: "Zeta", out: false), row("y", name: "beta"), row("z", name: "Alpha")], order: [])
        #expect(r.map(\.name) == ["Alpha", "beta", "Zeta"])
    }

    @Test func equalNamesFallBackToKey() {
        let r = MixOrdering.sorted([row("b", name: "Same"), row("a", name: "Same")], order: [])
        #expect(r.map(\.key) == ["a", "b"])
    }

    @Test func moveBeforeTarget() {
        let o = MixOrdering.move([], visible: ["a", "b", "c", "d"], key: "d", before: "b")
        #expect(o == ["a", "d", "b", "c"])
    }

    @Test func moveKeepsHiddenKeysAtTheEnd() {
        let o = MixOrdering.move(["x", "a", "b"], visible: ["a", "b", "c"], key: "c", before: "a")
        #expect(o == ["c", "a", "b", "x"])
    }

    @Test func moveToSelfOrUnknownIsANoOp() {
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "a", before: "a") == ["a"])
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "q", before: "a") == ["a"])
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "a", before: "q") == ["a"])
    }

    @Test func nudgeSwapsNeighbours() {
        #expect(MixOrdering.move([], visible: ["a", "b", "c"], key: "b", by: -1) == ["b", "a", "c"])
        #expect(MixOrdering.move([], visible: ["a", "b", "c"], key: "b", by: 1) == ["a", "c", "b"])
    }

    @Test func nudgeStopsAtTheEdges() {
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "a", by: -1) == ["a"])
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "b", by: 1) == ["a"])
        #expect(MixOrdering.move(["a"], visible: ["a", "b"], key: "q", by: 1) == ["a"])
    }

    @Test func rowsFollowTheManualOrder() {
        var m = MixAppListModel()
        m.update([entry("a"), entry("b"), entry("c")], now: 0)
        var s = MixSettings()
        s.order = ["c", "b"]
        #expect(m.rows(settings: s, apps: [:], now: 0).map(\.key) == ["c", "b", "a"])
    }
}

@Suite struct MixSettingsStoreTests {
    @Test func emptyStoreGivesDefaults() {
        let st = MixSettingsStore(WndMemoryStore())
        #expect(st.loadSettings() == MixSettings())
        #expect(st.loadApps().isEmpty)
    }

    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        let st = MixSettingsStore(kv)
        st.saveSettings(MixSettings())
        st.saveApps([:])
        #expect(kv.values.isEmpty)
    }

    @Test func settingsRoundTrip() {
        let kv = WndMemoryStore()
        var s = MixSettings()
        s.maxBoost = 2
        s.hideInactive = false
        s.fineSteps = true
        s.showMeters = false
        s.headphoneGuard = true
        s.guardCapPercent = 45
        s.order = ["b", "a"]
        MixSettingsStore(kv).saveSettings(s)
        #expect(MixSettingsStore(kv).loadSettings() == s)
    }

    @Test func settingsAreClampedOnSaveAndLoad() {
        let kv = WndMemoryStore()
        var s = MixSettings()
        s.maxBoost = 99
        s.guardCapPercent = 1
        MixSettingsStore(kv).saveSettings(s)
        let back = MixSettingsStore(kv).loadSettings()
        #expect(back.maxBoost == 4 && back.guardCapPercent == 5)
        kv.set(0.1, forKey: "mixer.maxBoost")
        kv.set(5000, forKey: "mixer.guardCap")
        let bad = MixSettingsStore(kv).loadSettings()
        #expect(bad.maxBoost == 1 && bad.guardCapPercent == 100)
    }

    @Test func orderIsDeduplicatedAndCleaned() {
        #expect(MixSettingsStore.cleanOrder(["a", "", "b", "a", String(repeating: "x", count: 201)]) == ["a", "b"])
    }

    @Test func appPresetsPersistByBundleId() {
        let kv = WndMemoryStore()
        MixSettingsStore(kv).saveApps([
            "com.apple.Music": MixAppSetting(volume: 2.5, muted: false, outputUID: "airpods", pinned: true, name: "Музыка", lastUsed: 100),
            "com.apple.Safari": MixAppSetting(volume: 0.4, muted: true)
        ])
        let back = MixSettingsStore(kv).loadApps()
        #expect(back["com.apple.Music"] == MixAppSetting(volume: 2.5, muted: false, outputUID: "airpods", pinned: true, name: "Музыка", lastUsed: 100))
        #expect(back["com.apple.Safari"]?.volume == 0.4 && back["com.apple.Safari"]?.muted == true)
        #expect(back.count == 2)
    }

    @Test func neutralAppsAreNotStored() {
        let kv = WndMemoryStore()
        let st = MixSettingsStore(kv)
        st.saveApps(["a": MixAppSetting(), "b": MixAppSetting(name: "B", lastUsed: 5), "c": MixAppSetting(volume: 0.5)])
        #expect(Set(st.loadApps().keys) == ["c"])
    }

    @Test func emptyAppsRemoveTheKey() {
        let kv = WndMemoryStore()
        let st = MixSettingsStore(kv)
        st.saveApps(["a": MixAppSetting(volume: 0.5)])
        #expect(kv.values["mixer.apps"] != nil)
        st.saveApps([:])
        #expect(kv.values["mixer.apps"] == nil)
    }

    @Test func volumesAreClampedByTheBoostLimitOnLoad() {
        let kv = WndMemoryStore()
        MixSettingsStore(kv).saveApps(["a": MixAppSetting(volume: 3.5)])
        #expect(MixSettingsStore(kv).loadApps(maxBoost: 2)["a"]?.volume == 2)
        #expect(MixSettingsStore(kv).loadApps()["a"]?.volume == 3.5)
    }

    @Test func brokenRowsAreSkipped() {
        let kv = WndMemoryStore()
        kv.set([["v": 0.5], ["id": ""], ["id": 7], ["id": "ok", "v": 0.5, "t": Double.nan], ["id": String(repeating: "x", count: 300), "v": 0.5]] as [[String: Any]], forKey: "mixer.apps")
        let apps = MixSettingsStore(kv).loadApps()
        #expect(Set(apps.keys) == ["ok"] && apps["ok"]?.lastUsed == 0)
    }

    @Test func nonArrayGarbageIsIgnored() {
        let kv = WndMemoryStore()
        kv.set("garbage", forKey: "mixer.apps")
        kv.set(12, forKey: "mixer.order")
        let st = MixSettingsStore(kv)
        #expect(st.loadApps().isEmpty && st.loadSettings().order.isEmpty)
    }

    @Test func storedKeysAreAsciiAndPlistSafe() throws {
        let kv = WndMemoryStore()
        let st = MixSettingsStore(kv)
        st.saveApps(["com.apple.Music": MixAppSetting(volume: 2, muted: true, outputUID: "x", pinned: true, name: "Музыка", lastUsed: 3)])
        var s = MixSettings()
        s.maxBoost = 2
        s.order = ["com.apple.Music"]
        st.saveSettings(s)
        for k in kv.values.keys { #expect(k.allSatisfy { $0.isASCII }) }
        let rows = try #require(kv.values["mixer.apps"] as? [[String: Any]])
        for r in rows { for k in r.keys { #expect(k.allSatisfy { $0.isASCII }) } }
        let data = try PropertyListSerialization.data(fromPropertyList: kv.values, format: .xml, options: 0)
        #expect(!data.isEmpty)
    }

    @Test func pruneKeepsTheLimitDroppingOldestUnpinnedFirst() {
        var apps: [String: MixAppSetting] = [:]
        for i in 0..<10 { apps["k\(i)"] = MixAppSetting(volume: 0.5, lastUsed: Double(i)) }
        apps["k0"]?.pinned = true
        let kept = MixSettingsStore.prune(apps, limit: 6)
        #expect(kept.count == 6)
        #expect(kept["k0"] != nil)
        #expect(Set(kept.keys) == ["k0", "k5", "k6", "k7", "k8", "k9"])
    }

    @Test func pruneUnderTheLimitChangesNothing() {
        let apps = ["a": MixAppSetting(volume: 0.5), "b": MixAppSetting(muted: true)]
        #expect(MixSettingsStore.prune(apps, limit: 5) == apps)
    }

    @Test func savingTwiceIsIdempotent() {
        let kv = WndMemoryStore()
        let st = MixSettingsStore(kv)
        let apps = ["a": MixAppSetting(volume: 0.5, lastUsed: 4)]
        st.saveApps(apps)
        let first = kv.values.keys.sorted()
        st.saveApps(apps)
        #expect(kv.values.keys.sorted() == first)
        #expect(st.loadApps() == apps)
    }

    @Test func realDefaultsAreNeverTouchedByTheFakeStore() {
        let before = UserDefaults.standard.object(forKey: "mixer.apps")
        MixSettingsStore(WndMemoryStore()).saveApps(["probe.test": MixAppSetting(volume: 0.1)])
        let after = UserDefaults.standard.object(forKey: "mixer.apps")
        #expect((before == nil) == (after == nil))
    }
}

@Suite struct MixRoutingTests {
    private let devices = [Snd.speakers, Snd.airpods, Snd.usb, Snd.mic, Snd.hdmi, Snd.blackhole, MixT.airplayTV]

    @Test func onlinePreferredDeviceIsUsed() {
        #expect(MixRouting.resolve(preferred: "airpods", devices: devices, defaultUID: "speakers") == .device(uid: "airpods", usedFallback: false))
    }

    @Test func noPreferenceFollowsTheDefault() {
        #expect(MixRouting.resolve(preferred: nil, devices: devices, defaultUID: "usb-headset") == .device(uid: "usb-headset", usedFallback: false))
    }

    @Test func missingPreferredFallsBackToTheDefault() {
        #expect(MixRouting.resolve(preferred: "gone", devices: devices, defaultUID: "speakers") == .device(uid: "speakers", usedFallback: true))
    }

    @Test func missingDefaultFallsBackToTheFirstRealOutput() {
        let r = MixRouting.resolve(preferred: nil, devices: [Snd.blackhole, Snd.speakers], defaultUID: "gone")
        #expect(r == .device(uid: "speakers", usedFallback: false) || r == .device(uid: "speakers", usedFallback: true))
        #expect(r.uid == "speakers")
    }

    @Test func onlyVirtualDeviceIsStillBetterThanNothing() {
        #expect(MixRouting.resolve(preferred: nil, devices: [Snd.blackhole], defaultUID: nil).uid == "blackhole")
    }

    @Test func noOutputsMeansNone() {
        #expect(MixRouting.resolve(preferred: "x", devices: [Snd.mic], defaultUID: nil) == .none)
        #expect(MixRouting.resolve(preferred: nil, devices: [], defaultUID: nil).uid == nil)
    }

    @Test func hiddenAndInputOnlyDevicesAreNotTargets() {
        let c = MixRouting.candidates([Snd.hiddenTap, Snd.mic, Snd.speakers])
        #expect(c.map(\.uid) == ["speakers"])
        #expect(MixRouting.resolve(preferred: "tap", devices: [Snd.hiddenTap, Snd.speakers], defaultUID: "speakers").uid == "speakers")
    }

    @Test func ourOwnAggregatesAreNeverTargets() {
        let own = AudioDeviceInfo(uid: MixIdentity.aggregateUID(for: "abc"), name: "Multitul Mix x", transport: .aggregate, hasOutput: true)
        #expect(MixRouting.candidates([own, Snd.speakers]).map(\.uid) == ["speakers"])
        #expect(MixRouting.resolve(preferred: own.uid, devices: [own, Snd.speakers], defaultUID: "speakers").uid == "speakers")
    }

    @Test func defaultThatIsOurAggregateIsNotChosen() {
        let own = AudioDeviceInfo(uid: MixIdentity.aggregateUID(for: "z"), name: "x", transport: .aggregate, hasOutput: true)
        #expect(MixRouting.resolve(preferred: nil, devices: [own, Snd.usb], defaultUID: own.uid).uid == "usb-headset")
    }

    @Test func optionsStartWithTheSystemDefaultEntry() {
        let o = MixRouting.options(devices: devices, defaultUID: "speakers")
        #expect(o.first?.uid == nil && o.first?.name == "Как в системе")
        #expect(o.first { $0.uid == "speakers" }?.isDefault == true)
        #expect(o.filter { $0.isDefault }.count == 1)
    }

    @Test func airPlayDevicesAreListedAndSortedLast() {
        let o = MixRouting.options(devices: devices, defaultUID: nil)
        #expect(o.last?.uid == "airplay-tv" && o.last?.transport == .airplay)
        let virtualIndex = o.firstIndex { $0.uid == "blackhole" }!
        let realIndex = o.firstIndex { $0.uid == "speakers" }!
        #expect(realIndex < virtualIndex && virtualIndex < o.count - 1)
    }

    @Test func optionsExcludeInputsAndHidden() {
        let o = MixRouting.options(devices: [Snd.mic, Snd.hiddenTap, Snd.speakers], defaultUID: nil)
        #expect(o.map(\.uid) == [nil, "speakers"])
    }

    @Test func emptyDeviceListStillOffersTheDefault() {
        #expect(MixRouting.options(devices: [], defaultUID: nil).count == 1)
    }

    @Test func offlineCheck() {
        #expect(!MixRouting.isOffline(preferred: nil, devices: devices))
        #expect(!MixRouting.isOffline(preferred: "airpods", devices: devices))
        #expect(MixRouting.isOffline(preferred: "gone", devices: devices))
        #expect(MixRouting.isOffline(preferred: "tap", devices: [Snd.hiddenTap]))
    }

    @Test func backoffDoublesUpToTheCap() {
        var b = MixRetryBackoff()
        #expect(b.canTry("a", now: 0))
        b.fail("a", now: 100)
        #expect(!b.canTry("a", now: 100.5) && b.canTry("a", now: 101))
        b.fail("a", now: 101)
        #expect(!b.canTry("a", now: 102.9) && b.canTry("a", now: 103))
        for _ in 0..<10 { b.fail("a", now: 200) }
        #expect(!b.canTry("a", now: 229.9) && b.canTry("a", now: 230))
        #expect(b.failureCount("a") == 12)
    }

    @Test func backoffIsPerKeyAndResets() {
        var b = MixRetryBackoff()
        b.fail("a", now: 0)
        #expect(b.canTry("b", now: 0))
        b.succeed("a")
        #expect(b.canTry("a", now: 0) && b.failureCount("a") == 0)
    }
}
