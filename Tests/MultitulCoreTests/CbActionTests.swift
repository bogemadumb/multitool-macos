import Testing
import Foundation
@testable import MultitulCore

private struct Rig {
    let host = CbFakeHost()
    let exec = CbFakeExec()
    let fs = CbFakeFS()
    let snippets = CbFakeSnippets()
    let store = WndMemoryStore()
    let box = WndBox(CommandBarSettings())
    let router: CbActionRouter

    init() {
        let b = box
        router = CbActionRouter(fs: fs, launcher: exec, host: host, snippets: snippets, settings: { b.value }, now: { CbFix.now })
    }
}

@Suite struct CbRouterTests {
    @Test func simpleActionsGoToTheHost() {
        let r = Rig()
        #expect(r.router.perform(.openApp("/Applications/X.app")) == .done)
        #expect(r.router.perform(.openFile("/tmp/a.txt")) == .done)
        #expect(r.router.perform(.revealFile("/tmp/a.txt")) == .done)
        #expect(r.router.perform(.copyText("42")) == .done)
        #expect(r.router.perform(.pasteText("😀")) == .done)
        #expect(r.router.perform(.focusWindow(key: 3, pid: 9)) == .done)
        #expect(r.router.perform(.quitApp(pid: 5)) == .done)
        #expect(r.router.perform(.openSection("clean")) == .done)
        #expect(r.router.perform(.refreshRates) == .done)
        #expect(r.router.perform(.noop) == .done)
        #expect(r.host.log == ["open /Applications/X.app", "open /tmp/a.txt", "reveal /tmp/a.txt", "copy 42", "paste 😀", "focus 9:3", "quit 5", "section clean", "rates"])
    }

    @Test func hostFailuresBecomeMessages() {
        let r = Rig()
        r.host.openOK = false
        r.host.focusOK = false
        r.host.pasteClipOK = false
        r.host.menuOK = false
        #expect(r.router.perform(.openApp("/x")) == .failed("Не удалось открыть приложение"))
        #expect(r.router.perform(.openFile("/x")) == .failed("Не удалось открыть файл"))
        #expect(r.router.perform(.focusWindow(key: 1, pid: 1)) == .failed("Окно уже закрыто"))
        #expect(r.router.perform(.pasteClip(1)) == .failed("Запись истории не найдена"))
        #expect(r.router.perform(.menuItem(pid: 1, path: ["File", "New"])) == .failed("Пункт меню недоступен"))
    }

    @Test func clipboardEntriesPasteOrCopy() {
        let r = Rig()
        _ = r.router.perform(.pasteClip(5))
        _ = r.router.perform(.copyClip(5))
        #expect(r.host.log == ["clip 5 copyOnly=false", "clip 5 copyOnly=true"])
    }

    @Test func launcherTargetsGoThroughTheResolver() {
        let r = Rig()
        r.fs.files = ["/Applications/Notes.app", "/s/a.sh"]
        r.fs.bundles = ["com.apple.Notes": "/Applications/Notes.app"]
        #expect(r.router.perform(.launcher(.app("com.apple.Notes"))) == .done)
        #expect(r.router.perform(.launcher(.url("example.com"))) == .done)
        #expect(r.router.perform(.launcher(.script("/s/a.sh"))) == .done)
        #expect(r.router.perform(.launcher(.tool(.scratchpad))) == .done)
        #expect(r.router.perform(.launcher(.toggle(.darkMode))) == .done)
        #expect(r.exec.commands == [.openApp("/Applications/Notes.app"), .openURL(URL(string: "https://example.com")!), .run(executable: "/bin/zsh", arguments: ["/s/a.sh"]), .tool(.scratchpad), .toggle(.darkMode)])
    }

    @Test func launcherProblemsAreReportedWithoutRunning() {
        let r = Rig()
        #expect(r.router.perform(.launcher(.app("missing.bundle"))) == .failed("Приложение не найдено"))
        #expect(r.router.perform(.launcher(.script("relative.sh"))) == .failed("Нужен полный путь к скрипту"))
        #expect(r.router.perform(.launcher(.url("javascript:alert(1)"))) == .failed("Схема «javascript» запрещена"))
        #expect(r.exec.commands.isEmpty)
    }

    @Test func executorFailureIsPassedOn() {
        let r = Rig()
        r.exec.result = .failed("Модуль выключен")
        #expect(r.router.perform(.launcher(.tool(.colorPicker))) == .failed("Модуль выключен"))
        r.exec.result = .failed("")
        #expect(r.router.perform(.launcher(.tool(.colorPicker))) == .failed("Не удалось выполнить"))
    }

    @Test func dangerousActionsAskFirst() {
        let r = Rig()
        #expect(r.router.perform(.system(.restart)) == .needsConfirmation("Перезагрузить Мак?"))
        #expect(r.router.perform(.system(.shutDown)) == .needsConfirmation("Выключить Мак?"))
        #expect(r.router.perform(.system(.logOut)) == .needsConfirmation("Выйти из учётной записи?"))
        #expect(r.router.perform(.killProcess(pid: 9, name: "zoom.us", tree: true)) == .needsConfirmation("Завершить «zoom.us» вместе с дочерними процессами?"))
        #expect(r.router.perform(.killProcess(pid: 9, name: "zoom.us", tree: false)) == .needsConfirmation("Завершить процесс «zoom.us»?"))
        #expect(r.host.log.isEmpty)
    }

    @Test func confirmedActionsRun() {
        let r = Rig()
        #expect(r.router.perform(.system(.restart), confirmed: true) == .done)
        #expect(r.router.perform(.killProcess(pid: 9, name: "zoom.us", tree: true), confirmed: true) == .done)
        #expect(r.host.log == ["system restart", "terminate 9 zoom.us tree=true"])
    }

    @Test func harmlessSystemCommandsDoNotAsk() {
        let r = Rig()
        #expect(r.router.perform(.system(.sleep)) == .done && r.router.perform(.system(.systemSettings)) == .done)
    }

    @Test func killErrorsComeBack() {
        let r = Rig()
        r.host.terminateError = "refused: untouchable"
        #expect(r.router.perform(.killProcess(pid: 1, name: "x", tree: false), confirmed: true) == .failed("refused: untouchable"))
    }

    @Test func systemFailure() {
        let r = Rig()
        r.host.systemOK = false
        #expect(r.router.perform(.system(.sleep)) == .failed("Команда не выполнилась"))
    }

    @Test func uninstallAndShelf() {
        let r = Rig()
        #expect(r.router.perform(.uninstallApp("/Applications/Slack.app")) == .done)
        r.host.uninstallOK = false
        #expect(r.router.perform(.uninstallApp("/x")) == .failed("Раздел удаления недоступен"))
        #expect(r.router.perform(.shelfAdd("/tmp/a")) == .done)
        r.host.shelfOK = false
        #expect(r.router.perform(.shelfAdd("/tmp/a")) == .failed("Полка недоступна"))
    }

    @Test func snippetIsRenderedAndPasted() {
        let r = Rig()
        r.snippets.list = [Snippet(id: 4, trigger: ";c", body: "buffer: {{clipboard}}")]
        r.host.clipboard = "hello"
        #expect(r.router.perform(.snippet(4)) == .done)
        #expect(r.host.log == ["paste buffer: hello"] && r.snippets.used == [4])
    }

    @Test func snippetCopiesWhenPastingIsOff() {
        let r = Rig()
        r.box.value.pasteResults = false
        r.snippets.list = [Snippet(id: 4, trigger: ";c", body: "plain")]
        _ = r.router.perform(.snippet(4))
        #expect(r.host.log == ["copy plain"])
    }

    @Test func missingSnippetFails() {
        #expect(Rig().router.perform(.snippet(1)) == .failed("Сниппет не найден"))
    }

    @Test func actionKeysAreStableAndMergeAppForms() {
        #expect(CbAction.launcher(.app("/A.app")).key == CbAction.openApp("/A.app").key)
        #expect(CbAction.launcher(.url("x")).key != CbAction.launcher(.script("x")).key)
        #expect(CbAction.menuItem(pid: 1, path: ["a", "b"]).key == "menuItem:1:a/b")
        let all: [CbAction] = [.openApp("a"), .focusWindow(key: 1, pid: 2), .openFile("a"), .revealFile("a"), .pasteClip(1), .copyClip(1), .copyText("a"), .pasteText("a"), .menuItem(pid: 1, path: ["a"]),
                               .launcher(.tool(.scratchpad)), .system(.sleep), .killProcess(pid: 1, name: "a", tree: true), .quitApp(pid: 1), .uninstallApp("a"), .snippet(1), .openSection("a"), .refreshRates, .shelfAdd("a"), .noop]
        #expect(Set(all.map(\.key)).count == all.count)
    }
}

@Suite struct CbModelTests {
    private func model(_ configure: (inout CbRig) -> Void = { _ in }) -> (CommandBarModel, CbWorld, Rig) {
        var rig = CbRig()
        configure(&rig)
        let w = CbWorld(rig)
        let r = Rig()
        r.box.value = w.box.value
        let m = CommandBarModel(engine: w.engine, router: r.router) { w.box.value }
        return (m, w, r)
    }

    private let apps = [CbFix.app("Telegram", bundle: "ru.keepcoder.Telegram"), CbFix.app("Terminal", bundle: "com.apple.Terminal"), CbFix.app("Notes", bundle: "com.apple.Notes")]

    @Test func typingFillsResultsAndSelectsTheFirst() {
        let (m, _, _) = model { $0.apps.list = [CbFix.app("Telegram"), CbFix.app("Terminal")] }
        m.setQuery("te")
        #expect(m.results.first?.title == "Telegram" && m.selection == 0 && m.selected?.title == "Telegram")
    }

    @Test func selectionWrapsAround() {
        let (m, _, _) = model { $0.apps.list = [CbFix.app("Alpha"), CbFix.app("Alps"), CbFix.app("Alto")] }
        m.setQuery("al")
        m.moveSelection(-1)
        #expect(m.selection == m.results.count - 1)
        m.moveSelection(1)
        #expect(m.selection == 0)
        m.select(2)
        #expect(m.selection == 2)
        m.select(99)
        #expect(m.selection == 2)
    }

    @Test func runningRecordsUsageOnSuccessOnly() {
        let (m, w, r) = model { $0.apps.list = [CbFix.app("Telegram", bundle: "ru.keepcoder.Telegram")] }
        m.setQuery("tele")
        r.host.openOK = false
        #expect(m.runSelected() == .failed("Не удалось открыть приложение") && m.message == "Не удалось открыть приложение")
        #expect(w.frecency.useCount("app:ru.keepcoder.Telegram") == 0)
        r.host.openOK = true
        #expect(m.runSelected() == .done && m.message.isEmpty)
        #expect(w.frecency.useCount("app:ru.keepcoder.Telegram") == 1)
        #expect(r.host.log.last == "open /Applications/Telegram.app")
    }

    @Test func numbersPickTheNthResult() {
        let (m, _, _) = model { $0.apps.list = [CbFix.app("Alpha"), CbFix.app("Alps")] }
        m.setQuery("al")
        #expect(m.result(number: 1)?.title == "Alps" && m.result(number: 2)?.title == "Alpha")
        #expect(m.result(number: 0) == nil && m.result(number: 10) == nil && m.result(number: 9) == nil)
    }

    @Test func secondaryActionRuns() {
        let (m, _, r) = model { $0.apps.list = [CbFix.app("Telegram", running: true, pid: 42)] }
        m.setQuery("tele")
        #expect(m.runSelected(secondary: 0) == .done)
        #expect(r.host.log == ["quit 42"])
        #expect(m.runSelected(secondary: 99) == nil)
    }

    @Test func confirmationFlow() {
        let (m, _, r) = model()
        m.setQuery("> restart")
        #expect(m.runSelected() == .needsConfirmation("Перезагрузить Мак?") && m.pendingConfirmation?.text == "Перезагрузить Мак?")
        #expect(r.host.log.isEmpty)
        #expect(m.confirmPending() == .done)
        #expect(r.host.log == ["system restart"] && m.pendingConfirmation == nil)
    }

    @Test func cancellingConfirmationDoesNothing() {
        let (m, _, r) = model()
        m.setQuery("> shut down")
        _ = m.runSelected()
        m.cancelPending()
        #expect(m.pendingConfirmation == nil && m.confirmPending() == nil && r.host.log.isEmpty)
    }

    @Test func typingClearsAPendingConfirmation() {
        let (m, _, _) = model()
        m.setQuery("> restart")
        _ = m.runSelected()
        m.setQuery("> restar")
        #expect(m.pendingConfirmation == nil)
    }

    @Test func slotRunsTheAssignedEntryWithoutTheBar() {
        let (m, w, r) = model()
        w.box.value.userEntries = [CbUserEntry(title: "Сайт", target: .url("https://example.com"), slot: 2)]
        #expect(m.runSlot(2) == .done)
        #expect(r.exec.commands == [.openURL(URL(string: "https://example.com")!)])
        #expect(m.runSlot(5) == .failed("Пункт 5 не назначен"))
        #expect(w.frecency.useCount("entry:url:https://example.com") == 1)
    }

    @Test func selectionFollowsTheSameResultAcrossRefreshes() {
        let (m, w, _) = model { $0.apps.list = [CbFix.app("Alpha"), CbFix.app("Alps"), CbFix.app("Alto")] }
        m.setQuery("al")
        m.select(2)
        let chosen = m.selected?.id
        w.rig.apps.list.append(CbFix.app("Alamo"))
        m.refresh()
        #expect(m.selected?.id == chosen)
    }

    @Test func forcedProviderIsExposed() {
        let (m, _, _) = model()
        m.setQuery("win ")
        #expect(m.forced == .windows)
        m.setQuery("hello")
        #expect(m.forced == nil)
    }

    @Test func closeAfterRunReflectsTheSetting() {
        let (m, w, _) = model()
        #expect(m.shouldCloseAfterRun)
        w.box.value.closeAfterRun = false
        #expect(!m.shouldCloseAfterRun)
    }
}

@Suite struct CbSettingsStoreTests {
    @Test func defaultsWriteNothing() {
        let kv = WndMemoryStore()
        CommandBarSettingsStore(kv).save(CommandBarSettings())
        #expect(kv.values.isEmpty)
        #expect(CommandBarSettingsStore(kv).load() == CommandBarSettings())
    }

    @Test func everythingRoundTrips() {
        var s = CommandBarSettings()
        s.disabledProviders = [.emoji, .menu]
        s.excludedFromGlobal = [.files]
        s.maxResults = 12
        s.fileFolders = ["~/Documents", "/Volumes/Data"]
        s.fileLimit = 9
        s.scriptsFolder = "~/bin"
        s.userEntries = [CbUserEntry(id: "e1", title: "Бэкап", aliases: ["backup", "бекап"], target: .script("/s/b.sh"), slot: 4), CbUserEntry(id: "e2", title: "Сайт", target: .url("https://a.b"))]
        s.quicklinks = [CbQuicklink(id: "q1", name: "Мой", keyword: "my", template: "https://x.y/?q={query}", symbol: "star")]
        s.webFallback = false
        s.webEngineID = "q1"
        s.calcAngle = .degrees
        s.decimalComma = false
        s.grouping = false
        s.currencyOnline = false
        s.useFrecency = false
        s.closeAfterRun = false
        s.showNumbers = false
        s.pasteResults = false
        s.clipboardLimit = 8
        s.menuLimit = 3
        s.includeLauncherItems = false
        let kv = WndMemoryStore()
        CommandBarSettingsStore(kv).save(s)
        #expect(CommandBarSettingsStore(kv).load() == s)
    }

    @Test func storedKeysAreLatin() {
        var s = CommandBarSettings()
        s.userEntries = [CbUserEntry(title: "Привет", aliases: ["раз"], target: .url("https://a.b"))]
        s.maxResults = 7
        s.calcAngle = .degrees
        let kv = WndMemoryStore()
        CommandBarSettingsStore(kv).save(s)
        #expect(!kv.values.isEmpty && kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) && $0.hasPrefix("commandBar.") })
        let json = kv.values["commandBar.userEntries"] as? String ?? ""
        #expect(json.contains("\"title\"") && json.contains("\"target\""))
    }

    @Test func brokenStorageFallsBackToDefaults() {
        let kv = WndMemoryStore()
        kv.values["commandBar.userEntries"] = "{not json"
        kv.values["commandBar.quicklinks"] = "[1,2"
        kv.values["commandBar.calcAngle"] = "gradians"
        kv.values["commandBar.disabledProviders"] = ["apps", "nonsense"]
        let s = CommandBarSettingsStore(kv).load()
        #expect(s.userEntries.isEmpty && s.quicklinks == CbQuicklink.defaults && s.calcAngle == .radians && s.disabledProviders == [.apps])
    }

    @Test func outOfRangeValuesAreClamped() {
        let kv = WndMemoryStore()
        kv.values["commandBar.maxResults"] = 500
        kv.values["commandBar.fileLimit"] = -4
        kv.values["commandBar.clipboardLimit"] = 0
        let s = CommandBarSettingsStore(kv).load()
        #expect(s.maxResults == 20 && s.fileLimit == 1 && s.clipboardLimit == 1)
    }

    @Test func sanitizingFixesSlotsAndDuplicates() {
        var s = CommandBarSettings()
        s.userEntries = [CbUserEntry(id: "a", title: "A", target: .url("https://a.b"), slot: 1), CbUserEntry(id: "b", title: "B", target: .url("https://b.c"), slot: 1),
                         CbUserEntry(id: "c", title: "C", target: .url("https://c.d"), slot: 12), CbUserEntry(id: "a", title: "dup", target: .url("https://d.e"))]
        let t = s.sanitized
        #expect(t.userEntries.map(\.id) == ["a", "b", "c"] && t.userEntries.map(\.slot) == [1, nil, nil])
    }

    @Test func sanitizingKeepsQuicklinksUsable() {
        var s = CommandBarSettings()
        s.quicklinks = [CbQuicklink(id: "1", name: "A", keyword: " G ", template: "https://a/{query}"), CbQuicklink(id: "2", name: "B", keyword: "g", template: "https://b/{query}"),
                        CbQuicklink(id: "3", name: "", keyword: "x", template: "https://c"), CbQuicklink(id: "4", name: "D", keyword: "two words", template: "https://d")]
        #expect(s.sanitized.quicklinks.map(\.id) == ["1"] && s.sanitized.quicklinks[0].keyword == "g")
    }

    @Test func entryCountIsLimited() {
        var s = CommandBarSettings()
        s.userEntries = (0..<100).map { CbUserEntry(id: "\($0)", title: "e\($0)", target: .url("https://a.b/\($0)")) }
        #expect(s.sanitized.userEntries.count == CommandBarSettings.maxEntries)
    }

    @Test func aliasesAreTrimmed() {
        var s = CommandBarSettings()
        s.userEntries = [CbUserEntry(title: "x", aliases: [" a ", "", "  "], target: .url("https://a.b"))]
        #expect(s.sanitized.userEntries[0].aliases == ["a"])
    }

    @Test func webEngineFallsBackToTheFirstSearchLink() {
        var s = CommandBarSettings()
        s.webEngineID = "nope"
        #expect(s.webEngine?.id == "google")
        s.quicklinks = [CbQuicklink(id: "plain", name: "P", keyword: "p", template: "https://p.q")]
        #expect(s.webEngine == nil)
    }

    @Test func providerFlags() {
        var s = CommandBarSettings()
        #expect(s.isEnabled(.apps) && s.inGlobal(.apps) && !s.inGlobal(.uninstall))
        s.disabledProviders = [.apps]
        #expect(!s.isEnabled(.apps) && !s.inGlobal(.apps))
        s.excludedFromGlobal = [.files]
        #expect(s.isEnabled(.files) && !s.inGlobal(.files))
    }
}

@Suite struct CbHotkeyTests {
    @Test func specsAreLatinAndUnique() {
        let ids = CommandBarHotkeys.all.map(\.id)
        #expect(ids.count == 10 && Set(ids).count == 10 && ids.allSatisfy { $0.allSatisfy(\.isASCII) && $0.hasPrefix("commandBar.") })
    }

    @Test func noDefaultComboIsAssigned() {
        #expect(CommandBarHotkeys.all.allSatisfy { $0.defaultCombo.isNone })
    }

    @Test func catalogHintIsOptionSpace() {
        #expect(HotkeyHints.suggested[CommandBarHotkeys.toggle.id]?.display == "⌥Space")
        #expect(HotkeyHints.effective(CommandBarHotkeys.toggle).display == "⌥Space")
        #expect(HotkeyHints.suggested[CommandBarHotkeys.slots[0].id] == nil)
    }

    @Test func moduleExposesTheSpecs() {
        #expect(ModuleID.commandBar.info.hotkeys.map(\.id) == CommandBarHotkeys.all.map(\.id))
        #expect(HotkeyHints.allSpecs.contains { $0.id == CommandBarHotkeys.toggle.id })
    }

    @Test func optionSpaceCollidesWithNoOtherHint() {
        let combo = HotkeyHints.effective(CommandBarHotkeys.toggle)
        let others = HotkeyHints.allSpecs.filter { $0.id != CommandBarHotkeys.toggle.id }.map { HotkeyHints.effective($0) }
        #expect(!others.contains(combo))
        #expect(!InterceptedKeys.all.contains { $0.combo == combo })
    }

    @Test func moduleCatalogEntries() {
        for id in [ModuleID.commandBar, .radialMenu] {
            let i = id.info
            #expect(i.group == .tools && !i.enabledByDefault && !i.title.isEmpty && !i.summary.isEmpty && !i.symbol.isEmpty && i.permissions == [.accessibility])
            #expect(id.rawValue.allSatisfy(\.isASCII) && id.enabledKey == "module.\(id.rawValue).enabled")
        }
    }

    @Test func commandBarIsAnAvailableLauncherTool() {
        #expect(LauncherTool.commandBar.module == .commandBar && LauncherTool.commandBar.title == "Командная строка")
        #expect(LauncherTarget(stored: "tool:commandBar") == .tool(.commandBar))
    }
}
