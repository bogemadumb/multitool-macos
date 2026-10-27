import Testing
import Foundation
@testable import MultitulCore

private let managerModules: [ModuleID] = [.mediaTools, .homebrewManager, .appUpdates]

@Suite struct ManagersCatalogTests {
    @Test func theThreeModulesLiveInTheToolsGroup() {
        for id in managerModules { #expect(id.info.group == .tools && id.info.id == id, "\(id)") }
    }

    @Test func modulesAreOffByDefault() {
        for id in managerModules { #expect(!id.info.enabledByDefault, "\(id)") }
    }

    @Test func identifiersAndSettingKeysAreAscii() {
        for id in managerModules { #expect(id.rawValue.allSatisfy(\.isASCII) && id.enabledKey.allSatisfy(\.isASCII)) }
        let kv = WndMemoryStore()
        var m = MediaSettings(); m.quality = 90; m.outputFolder = "/x"
        MediaSettingsStore(kv).save(m)
        var b = BrewSettings(); b.includeGreedy = true; b.searchLimit = 77
        BrewSettingsStore(kv).save(b)
        var a = AppUpdateSettings(); a.notifyNew = false; a.storefront = "us"
        AppUpdateStore(kv).saveSettings(a)
        #expect(!kv.values.isEmpty && kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test func titlesSummariesAndSymbolsAreFilled() {
        for id in managerModules { #expect(!id.info.title.isEmpty && !id.info.summary.isEmpty && !id.info.symbol.isEmpty) }
    }

    @Test func permissionsFollowTheCatalog() {
        #expect(ModuleID.mediaTools.info.permissions.isEmpty)
        #expect(ModuleID.homebrewManager.info.permissions == [.automation])
        #expect(ModuleID.appUpdates.info.permissions == [.appManagement, .notifications])
    }

    @Test func noHotkeysAreRegistered() {
        for id in managerModules { #expect(id.info.hotkeys.isEmpty) }
    }

    @Test func brewSettingsRoundTrip() {
        let kv = WndMemoryStore()
        BrewSettingsStore(kv).save(BrewSettings())
        #expect(kv.values.isEmpty)
        var s = BrewSettings()
        s.includeGreedy = true
        s.autoUpdateIndex = false
        s.cleanupAfterUpgrade = true
        s.refreshOnOpen = false
        s.notifyOutdated = true
        s.preferTerminalForCasks = true
        s.searchWithDescriptions = false
        s.searchLimit = 99
        BrewSettingsStore(kv).save(s)
        #expect(BrewSettingsStore(kv).load() == s)
    }

    @Test func brewSettingsAreClamped() {
        let kv = WndMemoryStore()
        kv.set(100_000, forKey: "homebrew.searchLimit")
        #expect(BrewSettingsStore(kv).load().searchLimit == 200)
        kv.set(-4, forKey: "homebrew.searchLimit")
        #expect(BrewSettingsStore(kv).load().searchLimit == 10)
    }

    @Test func brewDefaultsKeepCasksInTheApp() {
        let s = BrewSettings()
        #expect(!s.preferTerminalForCasks && s.autoUpdateIndex && !s.includeGreedy && s.refreshOnOpen)
    }

    @Test func descriptionsMentionTheNeverSudoPolicy() {
        #expect(ModuleID.homebrewManager.info.summary.contains("Terminal"))
    }

    @Test func snapshotHelpers() {
        var s = BrewSnapshot()
        s.packages = [BrewPackage(name: "a", kind: .formula, pinned: true), BrewPackage(name: "b", kind: .formula), BrewPackage(name: "c", kind: .cask)]
        s.leaves = ["a"]
        s.outdated = [BrewOutdatedItem(name: "a", kind: .formula, installedVersions: ["1"], currentVersion: "2")]
        #expect(s.leafPackages.map(\.name) == ["a"] && s.dependencyPackages.map(\.name) == ["b"] && s.casks.map(\.name) == ["c"] && s.pinnedPackages.map(\.name) == ["a"])
        #expect(s.outdatedItem(for: s.packages[0])?.currentVersion == "2" && s.outdatedItem(for: s.packages[2]) == nil)
    }

    @Test func depNodeMath() {
        let n = BrewDepNode(name: "r", children: [BrewDepNode(name: "a", children: [BrewDepNode(name: "b")]), BrewDepNode(name: "c")])
        #expect(n.flattened == ["a", "b", "c"] && n.depth == 3)
    }

    @Test func appUpdateIdsAreStablePerVersion() {
        let a = mgrApp("Thing")
        let u = AppUpdate(app: a, source: .sparkle, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .sparkle(appPath: a.path, download: nil))
        #expect(u.id == "org.test.thing@2" && u.skipKey == u.id)
        #expect(UpdateSource.allCases.map(\.title).count == 3)
    }
}
