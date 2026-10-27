import Testing
import Foundation
@testable import MultitulCore

@Suite struct LauncherTargetTests {
    @Test func storedFormRoundTrips() {
        let all: [LauncherTarget] = [.tool(.colorPicker), .toggle(.darkMode), .app("com.apple.Safari"), .url("https://example.com/a:b"), .script("/Users/x/run.sh")]
        for t in all { #expect(LauncherTarget(stored: t.stored) == t, "\(t.stored)") }
    }

    @Test func brokenStoredFormIsRejected() {
        for s in ["", "tool", "tool:nope", "toggle:x", "app:", "wat:1", "url:"] { #expect(LauncherTarget(stored: s) == nil, "\(s)") }
    }

    @Test func defaultTitles() {
        #expect(LauncherTarget.tool(.screenOcr).defaultTitle == "Текст с экрана")
        #expect(LauncherTarget.app("/Applications/Safari.app").defaultTitle == "Safari")
        #expect(LauncherTarget.url("https://example.com/path").defaultTitle == "example.com")
        #expect(LauncherTarget.script("/Users/x/run.sh").defaultTitle == "run.sh")
    }

    @Test func everyToolMapsToAnExistingModule() {
        for t in LauncherTool.allCases { #expect(ModuleID.allCases.contains(t.module) && !t.title.isEmpty && !t.symbol.isEmpty) }
        #expect(Set(LauncherTool.allCases.map(\.module)).count == LauncherTool.allCases.count)
    }

    @Test func itemTitleFallsBackToTheTarget() {
        #expect(LauncherItem(title: "", target: .tool(.scratchpad)).title == "Блокнот")
        #expect(LauncherItem(title: "Мой", target: .tool(.scratchpad)).title == "Мой")
    }
}

@Suite struct LauncherResolverTests {
    private let fs = TlsFiles()

    @Test func urlsGetHttpsWhenSchemeIsMissing() throws {
        #expect(try LauncherResolver.normalizeURL("example.com").get().absoluteString == "https://example.com")
        #expect(try LauncherResolver.normalizeURL(" example.com/path?q=1 ").get().absoluteString == "https://example.com/path?q=1")
        #expect(try LauncherResolver.normalizeURL("localhost:3000").get().absoluteString == "https://localhost:3000")
        #expect(try LauncherResolver.normalizeURL("http://example.com").get().absoluteString == "http://example.com")
    }

    @Test func appSchemesAreAllowed() throws {
        #expect(try LauncherResolver.normalizeURL("obsidian://open?vault=x").get().scheme == "obsidian")
        #expect(try LauncherResolver.normalizeURL("mailto:a@b.ru").get().scheme == "mailto")
        #expect(try LauncherResolver.normalizeURL("x-apple.systempreferences:com.apple.preference.security").get().scheme == "x-apple.systempreferences")
    }

    @Test func dangerousSchemesAreBlocked() {
        for s in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,x", "FILE:///x"] {
            if case .failure(let e) = LauncherResolver.normalizeURL(s), case .blockedScheme = e {} else { Issue.record("\(s) not blocked") }
        }
    }

    @Test func nonsenseUrlsAreRejected() {
        for s in ["", "   ", "two words", "http://nohost", "https://"] {
            if case .success = LauncherResolver.normalizeURL(s) { Issue.record("\(s) accepted") }
        }
    }

    @Test func scriptsRunThroughTheRightInterpreter() throws {
        for p in ["/a/x.sh", "/a/x.command", "/a/x.py", "/a/x.scpt", "/a/x.applescript"] { fs.files.insert(p) }
        #expect(try LauncherResolver.scriptCommand("/a/x.sh", fs: fs).get() == .run(executable: "/bin/zsh", arguments: ["/a/x.sh"]))
        #expect(try LauncherResolver.scriptCommand("/a/x.command", fs: fs).get() == .run(executable: "/bin/zsh", arguments: ["/a/x.command"]))
        #expect(try LauncherResolver.scriptCommand("/a/x.py", fs: fs).get() == .run(executable: "/usr/bin/python3", arguments: ["/a/x.py"]))
        #expect(try LauncherResolver.scriptCommand("/a/x.scpt", fs: fs).get() == .run(executable: "/usr/bin/osascript", arguments: ["/a/x.scpt"]))
        #expect(try LauncherResolver.scriptCommand("/a/x.applescript", fs: fs).get() == .run(executable: "/usr/bin/osascript", arguments: ["/a/x.applescript"]))
    }

    @Test func executableWithoutExtensionRunsDirectly() throws {
        fs.files.insert("/bin/tool"); fs.executables.insert("/bin/tool")
        #expect(try LauncherResolver.scriptCommand("/bin/tool", fs: fs).get() == .run(executable: "/bin/tool", arguments: []))
    }

    @Test func scriptProblems() {
        fs.files.insert("/a/data.txt")
        func issue(_ p: String) -> LauncherIssue? { if case .failure(let e) = LauncherResolver.scriptCommand(p, fs: fs) { return e } else { return nil } }
        #expect(issue("relative.sh") == .scriptNotAbsolute)
        #expect(issue("/a/missing.sh") == .scriptNotFound)
        #expect(issue("/a/data.txt") == .scriptUnsupported)
    }

    @Test func appsByBundleIDAndPath() throws {
        fs.bundles["com.apple.Safari"] = "/Applications/Safari.app"
        fs.files.insert("/Applications/Notes.app")
        #expect(try LauncherResolver.command(for: .app("com.apple.Safari"), fs: fs).get() == .openApp("/Applications/Safari.app"))
        #expect(try LauncherResolver.command(for: .app("/Applications/Notes.app"), fs: fs).get() == .openApp("/Applications/Notes.app"))
        if case .failure(let e) = LauncherResolver.command(for: .app("com.none"), fs: fs) { #expect(e == .appNotFound) } else { Issue.record("found") }
        if case .failure(let e) = LauncherResolver.command(for: .app("/Applications/Nope.app"), fs: fs) { #expect(e == .appNotFound) } else { Issue.record("found") }
        if case .failure(let e) = LauncherResolver.command(for: .app("  "), fs: fs) { #expect(e == .emptyValue) } else { Issue.record("found") }
    }

    @Test func toolsAndTogglesNeedNoFiles() throws {
        #expect(try LauncherResolver.command(for: .tool(.colorPicker), fs: fs).get() == .tool(.colorPicker))
        #expect(try LauncherResolver.command(for: .toggle(.lockScreen), fs: fs).get() == .toggle(.lockScreen))
    }
}

@Suite struct LauncherModelTests {
    private struct Rig {
        let model: LauncherModel
        let fs: TlsFiles
        let exec: TlsExecutor
        let saved: SavedBox
    }

    private final class SavedBox { var list: [QuickLauncherSettings] = [] }

    private func rig(_ s: QuickLauncherSettings = QuickLauncherSettings()) -> Rig {
        let fs = TlsFiles(), exec = TlsExecutor(), box = SavedBox()
        return Rig(model: LauncherModel(settings: s, fs: fs, executor: exec, save: { box.list.append($0) }), fs: fs, exec: exec, saved: box)
    }

    @Test func defaultsContainTheNewTools() {
        let r = rig()
        let targets = r.model.items.map(\.target)
        #expect(targets.contains(.tool(.colorPicker)) && targets.contains(.tool(.screenOcr)) && targets.contains(.tool(.scratchpad)) && targets.contains(.toggle(.darkMode)))
        #expect(Set(r.model.items.map(\.id)).count == r.model.items.count)
    }

    @Test func selectionWrapsAround() {
        let r = rig()
        let n = r.model.items.count
        r.model.moveSelection(-1)
        #expect(r.model.selection == n - 1)
        r.model.moveSelection(1)
        #expect(r.model.selection == 0)
        r.model.moveSelection(n * 3 + 2)
        #expect(r.model.selection == 2)
        r.model.select(99)
        #expect(r.model.selection == 2)
    }

    @Test func digitsMapToTheFirstNine() {
        var s = QuickLauncherSettings()
        s.items = (0..<12).map { LauncherItem(id: "i\($0)", title: "T\($0)", target: .tool(.scratchpad)) }
        let m = rig(s).model
        #expect(m.item(digit: 1)?.id == "i0" && m.item(digit: 9)?.id == "i8")
        #expect(m.item(digit: 0) == nil && m.item(digit: 10) == nil)
        #expect(rig().model.item(digit: 9) == nil)
    }

    @Test func runningATargetExecutesItsCommand() throws {
        let r = rig()
        try r.model.run(r.model.items[0]).get()
        #expect(r.exec.commands == [.tool(.colorPicker)])
        _ = r.model.runSlot(5)
        #expect(r.exec.commands.last == .toggle(.darkMode))
    }

    @Test func runSlotOutsideTheListDoesNothing() {
        let r = rig()
        #expect(r.model.runSlot(9) == nil)
        #expect(r.exec.commands.isEmpty)
    }

    @Test func runSelectedUsesTheCursor() throws {
        let r = rig()
        r.model.moveSelection(2)
        try #require(r.model.runSelected()).get()
        #expect(r.exec.commands == [.tool(.scratchpad)])
    }

    @Test func executorFailureSurfacesWithItsText() {
        let r = rig()
        r.exec.result = .failed("Модуль выключен")
        let out = r.model.run(r.model.items[0])
        if case .failure(let e) = out { #expect(e == .executionFailed("Модуль выключен") && e.message == "Модуль выключен") } else { Issue.record("expected failure") }
    }

    @Test func addingValidatedItems() throws {
        let r = rig()
        r.fs.bundles["com.apple.Notes"] = "/System/Applications/Notes.app"
        let before = r.model.items.count
        let app = try r.model.add(.app("com.apple.Notes")).get()
        #expect(app.title == "Notes" && app.target == .app("com.apple.Notes"))
        let url = try r.model.add(.url("example.com"), title: " Сайт ").get()
        #expect(url.title == "Сайт" && url.target == .url("https://example.com"))
        #expect(r.model.items.count == before + 2)
        #expect(r.saved.list.count == 2)
    }

    @Test func invalidItemsAreRejectedAndNotSaved() {
        let r = rig()
        let before = r.model.items.count
        for t: LauncherTarget in [.app("com.none"), .url("file:///x"), .script("/nope.sh"), .script("rel.sh")] {
            if case .success = r.model.add(t) { Issue.record("\(t.stored) accepted") }
        }
        #expect(r.model.items.count == before && r.saved.list.isEmpty)
    }

    @Test func removeKeepsSelectionInRange() {
        let r = rig()
        r.model.select(r.model.items.count - 1)
        r.model.remove(id: r.model.items.last!.id)
        #expect(r.model.selection == r.model.items.count - 1)
        for i in r.model.items { r.model.remove(id: i.id) }
        #expect(r.model.items.isEmpty && r.model.selection == 0)
        r.model.moveSelection(1)
        #expect(r.model.selection == 0)
        #expect(r.model.runSelected() == nil)
    }

    @Test func moveReordersAndFollowsTheSelection() {
        let r = rig()
        let ids = r.model.items.map(\.id)
        r.model.select(0)
        r.model.move(from: 0, to: 3)
        #expect(r.model.items.map(\.id) == [ids[1], ids[2], ids[3], ids[0]] + ids.dropFirst(4))
        #expect(r.model.selection == 3)
        r.model.move(from: 9, to: 0)
        r.model.move(from: 1, to: 1)
        #expect(r.model.items.count == ids.count)
    }

    @Test func renameAndReset() {
        let r = rig()
        let id = r.model.items[1].id
        r.model.rename(id: id, to: "  Скан ")
        #expect(r.model.items[1].title == "Скан")
        r.model.rename(id: id, to: "   ")
        #expect(r.model.items[1].title == "Текст с экрана")
        r.model.remove(id: id)
        r.model.resetToDefaults()
        #expect(r.model.items == LauncherDefaults.items)
    }

    @Test func listIsCapped() {
        var s = QuickLauncherSettings()
        s.items = (0..<40).map { LauncherItem(id: "i\($0)", target: .tool(.scratchpad)) }
        let r = rig(s)
        #expect(r.model.items.count == QuickLauncherSettings.maxItems)
        if case .success = r.model.add(.tool(.shelf)) { Issue.record("cap ignored") }
    }
}

@Suite struct LauncherSettingsStoreTests {
    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        QuickLauncherSettingsStore(kv).save(QuickLauncherSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func customListRoundTripsIncludingTitlesWithColons() {
        let kv = WndMemoryStore()
        let store = QuickLauncherSettingsStore(kv)
        var s = QuickLauncherSettings()
        s.items = [LauncherItem(id: "a", title: "Сайт: главный", target: .url("https://example.com/a:b")), LauncherItem(id: "b", title: "Скрипт", target: .script("/Users/x/run.sh")),
                   LauncherItem(id: "c", title: "", target: .toggle(.lockScreen))]
        s.closeAfterRun = false
        s.showNumbers = false
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("quickLauncher.") })
    }

    @Test func tabsInTitlesCannotBreakTheFormat() {
        let kv = WndMemoryStore()
        let store = QuickLauncherSettingsStore(kv)
        var s = QuickLauncherSettings()
        s.items = [LauncherItem(id: "a", title: "x\ty", target: .tool(.shelf))]
        store.save(s)
        #expect(store.load().items.first?.title == "x y")
    }

    @Test func garbageLinesAreSkipped() {
        let kv = WndMemoryStore()
        kv.set(["only-one-part", "a\tT\ttool:shelf", "b\tT\tbogus:1"], forKey: "quickLauncher.items")
        #expect(QuickLauncherSettingsStore(kv).load().items.map(\.id) == ["a"])
    }

    @Test func duplicateIdsAreCollapsed() {
        var s = QuickLauncherSettings()
        s.items = [LauncherItem(id: "a", target: .tool(.shelf)), LauncherItem(id: "a", target: .tool(.clipboard))]
        #expect(s.sanitized.items.count == 1)
    }
}

@Suite struct LauncherHotkeyTests {
    @Test func nineSlotsPlusToggle() {
        #expect(LauncherHotkeys.slots.count == 9 && LauncherHotkeys.all.count == 10)
        #expect(Set(LauncherHotkeys.all.map(\.id)).count == 10)
        #expect(LauncherHotkeys.all.allSatisfy { $0.defaultCombo.isNone && $0.id.allSatisfy { $0.isASCII } })
        #expect(LauncherHotkeys.slots.first?.id == "quickLauncher.slot1" && LauncherHotkeys.slots.last?.id == "quickLauncher.slot9")
    }

    @Test func slotsAreOwnedByTheModule() {
        #expect(ModuleID.quickLauncher.info.hotkeys == LauncherHotkeys.all)
    }

    @Test func registeringAllSlotsThroughTheManagerHasNoConflicts() async {
        await MainActor.run {
            let be = FakeHotkeyBackend()
            let hm = HotkeyManager(backend: be, defaults: actDefaults())
            for spec in LauncherHotkeys.all { #expect(hm.register(spec, owner: "quickLauncher") {} == .active) }
            hm.unregisterAll(owner: "quickLauncher")
            #expect(hm.states.isEmpty)
        }
    }
}
