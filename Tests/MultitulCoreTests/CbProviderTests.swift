import Testing
import Foundation
@testable import MultitulCore

private func world(_ configure: (inout CbRig) -> Void = { _ in }) -> CbWorld {
    var rig = CbRig()
    configure(&rig)
    return CbWorld(rig)
}

@Suite struct CbAppsProviderTests {
    @Test func runningAppsShowAStateAndCanBeQuit() {
        let w = world { $0.apps.list = [CbFix.app("Telegram", running: true, pid: 42), CbFix.app("Notes")] }
        let r = w.search("telegram")[0]
        #expect(r.subtitle == "Запущено" && r.trailing == "●" && r.iconPath == "/Applications/Telegram.app")
        #expect(r.secondary.contains { $0.action == .quitApp(pid: 42) })
        let n = w.search("notes")[0]
        #expect(!n.secondary.contains { if case .quitApp = $0.action { true } else { false } })
    }

    @Test func uninstallActionNeedsTheModuleAndAnUnprotectedApp() {
        let w = world { $0.apps.list = [CbFix.app("Slack", bundle: "com.tinyspeck.slackmacgap"), CbFix.app("Safari", bundle: "com.apple.Safari")] }
        #expect(w.search("slack")[0].secondary.contains { $0.action == .uninstallApp("/Applications/Slack.app") })
        #expect(!w.search("safari")[0].secondary.contains { if case .uninstallApp = $0.action { true } else { false } })
        let off = world { $0.enabled = []; $0.apps.list = [CbFix.app("Slack")] }
        #expect(!off.search("slack")[0].secondary.contains { if case .uninstallApp = $0.action { true } else { false } })
    }

    @Test func userAliasesFindTheApp() {
        let w = world {
            $0.apps.list = [CbFix.app("Visual Studio Code", bundle: "com.microsoft.VSCode")]
            $0.settings.userEntries = [CbUserEntry(title: "Редактор", aliases: ["ed"], target: .app("/Applications/Visual Studio Code.app"))]
        }
        #expect(w.search("ed").first?.action.key == "openApp:/Applications/Visual Studio Code.app")
    }

    @Test func builtinAliasesAreUniqueAndLowercaseFriendly() {
        for (bundle, names) in CbAppAliases.byBundle { #expect(!bundle.isEmpty && !names.isEmpty && names.allSatisfy { !$0.isEmpty }) }
    }

    @Test func lastBundleComponentIsASearchKey() {
        let w = world { $0.apps.list = [CbFix.app("Код", bundle: "com.microsoft.VSCode")] }
        #expect(w.search("vscode").first?.title == "Код")
    }

    @Test func applicationFolderIsShownAsSubtitle() {
        let w = world { $0.apps.list = [CbFix.app("Notes", dir: "/System/Applications")] }
        #expect(w.search("notes")[0].subtitle == "/System/Applications")
    }
}

@Suite struct CbWindowsProviderTests {
    private func setup() -> CbWorld {
        world {
            $0.windows.list = [CbFix.window(1, app: "Safari", title: "Apple"), CbFix.window(2, app: "Safari", title: "Swift Forums", minimized: true), CbFix.window(3, app: "Notes", title: "Shopping", pid: 11),
                               SwitchEntry(app: SwitchApp(pid: 99, bundleID: "com.test.Idle", name: "Idle"))]
        }
    }

    @Test func windowsAreFoundByTitleAndByApp() {
        let w = setup()
        #expect(w.search("win swift").first?.title == "Swift Forums")
        #expect(w.search("win notes").first?.title == "Shopping")
        #expect(w.search("win safari").count == 2)
    }

    @Test func appOnlyEntriesAreNotWindows() {
        #expect(!setup().search("win idle").contains { $0.title == "Idle" })
    }

    @Test func minimizedStateIsShown() {
        let r = setup().search("win swift")[0]
        #expect(r.subtitle == "Safari · свёрнуто" && r.trailing == "▾")
        #expect(r.action == .focusWindow(key: 2, pid: 10))
    }

    @Test func emptyTitleFallsBackToTheAppName() {
        let w = world { $0.windows.list = [CbFix.window(1, app: "Finder", title: "")] }
        #expect(w.search("win fin").first?.title == "Finder")
    }

    @Test func listsAllWindowsForAnEmptyText() {
        #expect(setup().search("win ").count == 3)
    }

    @Test func windowsDoNotGetFrecency() {
        #expect(setup().search("win safari").allSatisfy { $0.frecencyKey == nil })
    }
}

@Suite struct CbClipboardProviderTests {
    private func setup(_ configure: (inout CommandBarSettings) -> Void = { _ in }) -> CbWorld {
        world {
            $0.clip.items = (1...12).map { (n: Int) -> ClipItem in
                let src: String? = n == 2 ? "Safari" : nil
                return CbFix.clip(Int64(n), "invoice \(n)", pinned: n == 1, source: src, age: Double(n) * 4000)
            }
            configure(&$0.settings)
        }
    }

    @Test func historyIsSearched() {
        let w = setup()
        let r = w.search("clip invoice")
        #expect(r.allSatisfy { $0.provider == .clipboard } && !r.isEmpty)
        #expect(w.rig.clip.searches == ["invoice"])
    }

    @Test func limitComesFromTheSettingAndDoublesWithAPrefix() {
        let w = setup { $0.clipboardLimit = 3; $0.maxResults = 20 }
        #expect(w.search("invoice").filter { $0.provider == .clipboard }.count == 3)
        #expect(w.search("clip invoice").count == 6)
    }

    @Test func globalSearchNeedsTwoCharacters() {
        let w = setup()
        #expect(w.search("i").allSatisfy { $0.provider != .clipboard })
        #expect(w.search("in").contains { $0.provider == .clipboard })
    }

    @Test func pasteIsThePrimaryActionAndCopyTheSecondary() {
        let r = setup().search("clip invoice 2")[0]
        #expect(r.action == .pasteClip(2) && r.secondary.first?.action == .copyClip(2))
    }

    @Test func copyOnlyModeSwapsThem() {
        let r = setup { $0.pasteResults = false }.search("clip invoice 2")[0]
        #expect(r.action == .copyClip(2) && r.secondary.first?.action == .pasteClip(2))
    }

    @Test func subtitleTellsKindAgeAndSource() {
        let r = setup().search("clip invoice 2")[0]
        #expect(r.subtitle.hasPrefix("Текст · ") && r.subtitle.contains("ч назад") && r.subtitle.hasSuffix("Safari"))
    }

    @Test func pinnedEntriesAreMarked() {
        let r = setup().search("clip invoice 1")
        #expect(r.first { $0.id == "clip:1" }?.trailing == "📌")
    }

    @Test func multilineTitlesAreFlattened() {
        let w = world { $0.clip.items = [CbFix.clip(1, "line one\n\n  line two\nline three")] }
        #expect(w.search("clip line").first?.title == "line one line two line three")
    }

    @Test func longTitlesAreTruncated() {
        let w = world { $0.clip.items = [CbFix.clip(1, String(repeating: "word ", count: 60))] }
        #expect(w.search("clip word").first?.title.count == 90)
    }

    @Test func recentItemsShowForAnEmptyPrefixedQuery() {
        let w = setup()
        #expect(w.search("clip ").count == 9)
        #expect(w.search("").isEmpty)
    }
}

@Suite struct CbFilesProviderTests {
    private func setup() -> CbWorld { world { $0.settings.fileFolders = ["~/Documents", "/tmp/data"] } }

    @Test func shortQueriesDoNotTouchSpotlight() {
        let w = setup()
        _ = w.search("re")
        #expect(w.rig.files.calls.isEmpty)
    }

    @Test func queryOfThreeStartsOneSearchWithExpandedFolders() {
        let w = setup()
        _ = w.search("rep")
        #expect(w.rig.files.calls.count == 1)
        #expect(w.rig.files.calls[0].folders == [NSHomeDirectory() + "/Documents", "/tmp/data"])
        #expect(w.rig.files.calls[0].limit == w.box.value.fileLimit * 3)
        _ = w.search("rep")
        #expect(w.rig.files.calls.count == 1)
    }

    @Test func resultsAppearAfterTheAnswerAndTriggerAnUpdate() {
        let w = setup()
        var updates = 0
        w.filesProvider.onUpdate = { updates += 1 }
        #expect(w.search("report").isEmpty || w.search("report").allSatisfy { $0.provider != .files })
        w.rig.files.answer([CbFileHit(path: "/tmp/data/report.pdf"), CbFileHit(path: "/tmp/data/Reports", isDirectory: true)])
        #expect(updates == 1)
        let r = w.search("report").filter { $0.provider == .files }
        #expect(r.map(\.title).sorted() == ["Reports", "report.pdf"])
        #expect(r.first { $0.title == "Reports" }?.symbol == "folder")
        #expect(r.first { $0.title == "report.pdf" }?.action == .openFile("/tmp/data/report.pdf"))
    }

    @Test func staleAnswersDoNotNotify() {
        let w = setup()
        var updates = 0
        w.filesProvider.onUpdate = { updates += 1 }
        _ = w.search("repo")
        let stale = w.rig.files.calls.count
        _ = w.search("report")
        #expect(w.rig.files.calls.count == stale + 1)
        w.rig.files.answer([])
        #expect(updates == 1)
    }

    @Test func hiddenAndBuildJunkIsFiltered() {
        let w = setup()
        _ = w.search("report")
        w.rig.files.answer([CbFileHit(path: "/tmp/data/.git/report"), CbFileHit(path: "/tmp/data/node_modules/report"), CbFileHit(path: "/tmp/data/App.app/Contents/report"),
                            CbFileHit(path: "/tmp/data/report.txt")])
        #expect(w.search("report").filter { $0.provider == .files }.map(\.title) == ["report.txt"])
    }

    @Test func fileFilterRules() {
        #expect(CbFileFilter.accept("/Users/x/Documents/a.txt"))
        #expect(!CbFileFilter.accept("/Users/x/.ssh/id_rsa"))
        #expect(!CbFileFilter.accept("/Users/x/proj/__pycache__/a.pyc"))
        #expect(!CbFileFilter.accept("/Applications/X.app/Contents/Info.plist"))
        #expect(!CbFileFilter.accept("/Users/x/Pictures/Photos.photoslibrary/a.jpg"))
    }

    @Test func filesCapAndSecondaryActions() {
        let w = world {
            $0.settings.fileFolders = ["/tmp/data"]
            $0.settings.fileLimit = 2
        }
        _ = w.search("report")
        w.rig.files.answer((1...6).map { CbFileHit(path: "/tmp/data/report\($0).txt") })
        let r = w.search("report").filter { $0.provider == .files }
        #expect(r.count == 2)
        #expect(r[0].secondary.map(\.action) == [.revealFile(r[0].action.key.replacingOccurrences(of: "openFile:", with: "")), .copyText("/tmp/data/report1.txt"), .shelfAdd("/tmp/data/report1.txt")])
    }

    @Test func shelfActionNeedsTheShelfModule() {
        let w = world { $0.settings.fileFolders = ["/tmp/data"]; $0.enabled = [] }
        _ = w.search("report")
        w.rig.files.answer([CbFileHit(path: "/tmp/data/report.txt")])
        #expect(!(w.search("report").first { $0.provider == .files }?.secondary.contains { if case .shelfAdd = $0.action { true } else { false } } ?? true))
    }

    @Test func noFoldersMeansNoSearch() {
        let w = world { $0.settings.fileFolders = [] }
        _ = w.search("report")
        #expect(w.rig.files.calls.isEmpty)
    }

    @Test func resetCancelsAndForgets() {
        let w = setup()
        _ = w.search("report")
        w.rig.files.answer([CbFileHit(path: "/tmp/data/report.txt")])
        w.filesProvider.reset()
        #expect(w.rig.files.cancelled >= 1)
        #expect(w.search("report").filter { $0.provider == .files }.isEmpty)
        #expect(w.rig.files.calls.count == 2)
    }

    @Test func prefixedFileSearchStartsFromOneCharacter() {
        let w = setup()
        _ = w.search("f r")
        #expect(w.rig.files.calls.count == 1)
    }

    @Test func settingsResolveTildePaths() {
        var s = CommandBarSettings()
        s.fileFolders = ["~/Desktop", "/abs/path", "relative/path", "~"]
        #expect(s.resolvedFileFolders == [NSHomeDirectory() + "/Desktop", "/abs/path", NSHomeDirectory()])
    }
}

@Suite struct CbMenuTests {
    private func tree() -> [CbMenuNode] {
        [
            CbMenuNode(title: "Apple", children: [CbMenuNode(title: "About This Mac")]),
            CbMenuNode(title: "Safari", children: [CbMenuNode(title: "Settings…", cmdChar: ",", cmdModifiers: 0), CbMenuNode(title: "")]),
            CbMenuNode(title: "File", children: [
                CbMenuNode(title: "New Window", cmdChar: "n", cmdModifiers: 0),
                CbMenuNode(title: "New Private Window", cmdChar: "n", cmdModifiers: 1),
                CbMenuNode(title: "Close Tab", enabled: false, cmdChar: "w", cmdModifiers: 0),
                CbMenuNode(title: "Share", children: [CbMenuNode(title: "Mail"), CbMenuNode(title: "Messages", children: [CbMenuNode(title: "Deep", children: [CbMenuNode(title: "Deeper")])])]),
                CbMenuNode(title: "  "),
                CbMenuNode(title: "Print…", cmdChar: "p", cmdModifiers: 8)
            ]),
            CbMenuNode(title: "Window", children: [CbMenuNode(title: "Minimize")], enabled: false)
        ]
    }

    @Test func flattenSkipsAppleMenuAndSeparators() {
        let e = CbMenu.flatten(tree())
        #expect(!e.contains { $0.path.first == "Apple" })
        #expect(!e.contains { $0.title.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(e.contains { $0.path == ["Safari", "Settings…"] })
    }

    @Test func flattenKeepsLeavesWithTheirPath() {
        let e = CbMenu.flatten(tree())
        #expect(e.contains { $0.path == ["File", "Share", "Mail"] })
        #expect(!e.contains { $0.path == ["File", "Share"] })
    }

    @Test func depthIsLimited() {
        let e = CbMenu.flatten(tree())
        #expect(!e.contains { $0.title == "Deeper" })
        #expect(CbMenu.flatten(tree(), maxDepth: 5).contains { $0.title == "Deeper" })
    }

    @Test func disabledStateIsInherited() {
        let e = CbMenu.flatten(tree())
        #expect(e.first { $0.title == "Close Tab" }?.enabled == false)
        #expect(e.first { $0.title == "Minimize" }?.enabled == false)
        #expect(e.first { $0.title == "New Window" }?.enabled == true)
    }

    @Test func entryLimit() {
        let big = [CbMenuNode(title: "Big", children: (0..<100).map { CbMenuNode(title: "Item \($0)") })]
        #expect(CbMenu.flatten(big, limit: 10).count == 10)
    }

    @Test(arguments: [("n", 0, "⌘N"), ("n", 1, "⇧⌘N"), ("w", 2, "⌥⌘W"), ("t", 4, "⌃⌘T"), ("z", 7, "⌃⌥⇧⌘Z"), ("p", 8, "P"), ("q", 9, "⇧Q"), (",", 0, "⌘,")])
    func shortcutFormatting(_ ch: String, _ mods: Int, _ expected: String) {
        #expect(CbMenu.shortcut(char: ch, modifiers: mods) == expected)
    }

    @Test func noCharMeansNoShortcut() {
        #expect(CbMenu.shortcut(char: nil, modifiers: 0) == nil)
        #expect(CbMenu.shortcut(char: "", modifiers: 0) == nil)
    }

    @Test func providerListsOnlyEnabledItemsOfTheFrontApp() {
        let w = world {
            $0.menu.snap = CbMenuSnapshot(pid: 7, appName: "Safari", entries: CbMenu.flatten(self.tree()))
        }
        let r = w.search("menu new")
        #expect(r.map(\.title) == ["New Window", "New Private Window"])
        #expect(r[0].action == .menuItem(pid: 7, path: ["File", "New Window"]) && r[0].trailing == "⌘N" && r[0].subtitle == "Safari · File")
        #expect(w.search("menu close").isEmpty || !w.search("menu close").contains { $0.title == "Close Tab" })
    }

    @Test func noSnapshotNoMenuResults() {
        let w = world()
        #expect(w.search("menu new").allSatisfy { $0.provider != .menu })
    }

    @Test func menuJoinsTheGlobalSearchOnlyForGoodMatches() {
        let w = world { $0.menu.snap = CbMenuSnapshot(pid: 7, appName: "Safari", entries: CbMenu.flatten(self.tree())) }
        #expect(w.search("print").contains { $0.provider == .menu })
        #expect(!w.search("rnt").contains { $0.provider == .menu })
    }
}

@Suite struct CbOtherProvidersTests {
    @Test func snippetsAreFoundByTriggerTitleAndBody() {
        let w = world {
            $0.snippets.list = [Snippet(id: 1, trigger: ";sig", title: "Подпись", body: "С уважением,\nИван"), Snippet(id: 2, trigger: ";addr", title: "Адрес", body: "Санкт-Петербург")]
        }
        #expect(w.search("snip подп").first?.action == .snippet(1))
        #expect(w.search("snip addr").first?.action == .snippet(2))
        #expect(w.search("snip петербург").first?.action == .snippet(2))
        #expect(w.search("snip подп").first?.trailing == ";sig")
    }

    @Test func processesNeedTheKillModule() {
        let procs = [CbFix.proc(100, "zoom.us", ppid: 1, path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"), CbFix.proc(101, "ZoomHelper", ppid: 100, path: "/Applications/zoom.us.app/Contents/Frameworks/ZoomHelper"),
                     CbFix.proc(1, "launchd", uid: 0), CbFix.proc(200, "node", rssMB: 300)]
        let on = world { $0.procs.list = procs }
        let r = on.search("kill zoom")
        #expect(r.count == 1 && r[0].action == .killProcess(pid: 100, name: "zoom.us", tree: true) && r[0].subtitle.contains("Процессов: 2"))
        #expect(r[0].secondary.first?.action == .killProcess(pid: 100, name: "zoom.us", tree: false))
        let off = world { $0.procs.list = procs; $0.enabled = [] }
        #expect(off.search("kill zoom").isEmpty)
    }

    @Test func rootProcessesAreNeverOffered() {
        let w = world { $0.procs.list = [CbFix.proc(1, "launchd", uid: 0), CbFix.proc(2, "kernel_task", uid: 0)] }
        #expect(w.search("kill launchd").isEmpty && w.search("kill kernel").isEmpty)
    }

    @Test func processesJoinTheGlobalSearchOnlyForStrongMatches() {
        let w = world { $0.procs.list = [CbFix.proc(200, "postgres")] }
        #expect(w.search("postgres").contains { $0.provider == .processes })
        #expect(!w.search("pgs").contains { $0.provider == .processes })
    }

    @Test func uninstallListsOnlyRemovableApps() {
        let w = world { $0.apps.list = [CbFix.app("Slack", bundle: "com.tinyspeck.slackmacgap"), CbFix.app("Safari", bundle: "com.apple.Safari"), CbFix.app("Multitul", bundle: "dev.multitool.app")] }
        let r = w.search("rm s")
        #expect(r.map(\.title) == ["Удалить «Slack»…"])
        #expect(r[0].action == .uninstallApp("/Applications/Slack.app"))
        #expect(w.search("удалить multitul").isEmpty && w.search("uninstall safari").isEmpty)
    }

    @Test func uninstallModuleOffExplainsItself() {
        let w = world { $0.enabled = []; $0.apps.list = [CbFix.app("Slack")] }
        let r = w.search("rm slack")
        #expect(r.count == 1 && r[0].id == "uninstall:off" && r[0].action == .noop)
    }

    @Test func uninstallNeverAppearsWithoutItsPrefix() {
        let w = world { $0.apps.list = [CbFix.app("Slack", bundle: "com.tinyspeck.slackmacgap")] }
        #expect(w.search("slack").allSatisfy { $0.provider != .uninstall })
    }

    @Test func commandsRespectEnabledModules() {
        let off = world { $0.enabled = [] }
        let on = world()
        #expect(!off.titles("> блокнот").contains("Блокнот") && on.titles("> блокнот").contains("Блокнот"))
        #expect(!off.titles("> тёмная").contains("Тёмная тема") && on.titles("> тёмная").contains("Тёмная тема"))
        #expect(off.titles("> сон").contains("Сон"))
    }

    @Test func commandsAreFoundByEnglishAndRussianNames() {
        let w = world()
        #expect(w.search("> lock screen").first?.action == .launcher(.toggle(.lockScreen)))
        #expect(w.search("> заблокировать").first?.action == .launcher(.toggle(.lockScreen)))
        #expect(w.search("> restart").first?.action == .system(.restart))
        #expect(w.search("> перезагрузить").first?.action == .system(.restart))
        #expect(w.search("> dark mode").first?.action == .launcher(.toggle(.darkMode)))
        #expect(w.search("> eyedropper").first?.action == .launcher(.tool(.colorPicker)))
    }

    @Test func sectionCommandsOpenTheWindow() {
        let w = world()
        let r = w.search("> очистка").first { $0.id == "cmd:section:clean" }
        #expect(r?.action == .openSection("clean"))
        #expect(w.search("> права").contains { $0.action == .openSection("modules") })
    }

    @Test func destructiveSystemCommandsNeedConfirmation() {
        for c in CbSystemCommand.allCases { #expect(c.needsConfirmation == [.restart, .shutDown, .logOut].contains(c)) }
        #expect(CbAction.system(.shutDown).needsConfirmation && !CbAction.system(.sleep).needsConfirmation)
        #expect(CbAction.killProcess(pid: 1, name: "x", tree: true).needsConfirmation)
    }

    @Test func systemCommandsHaveKeywordsAndSymbols() {
        for c in CbSystemCommand.allCases { #expect(!c.title.isEmpty && !c.symbol.isEmpty && !c.keywords.isEmpty && c.rawValue.allSatisfy(\.isASCII)) }
    }

    @Test func commandBarItselfIsNotListedAsATool() {
        #expect(!world().titles("> командная").contains("Командная строка"))
    }

    @Test func userEntriesAreSearchableByAliasAndShowTheirSlot() {
        let w = world {
            $0.settings.userEntries = [CbUserEntry(title: "Бэкап", aliases: ["backup", "бекап"], target: .script("/Users/me/backup.sh"), slot: 3), CbUserEntry(title: "Сайт", target: .url("https://example.com"))]
        }
        let r = w.search("bekap")
        #expect(w.search("backup").first?.title == "Бэкап")
        #expect(w.search("бекап").first?.trailing == "#3")
        #expect(w.search("сайт").first?.action == .launcher(.url("https://example.com")))
        #expect(r.isEmpty || r.first?.title != "Сайт")
    }

    @Test func quickLauncherItemsJoinTheSearchUnlessSwitchedOff() {
        let w = world { $0.launcher.list = [LauncherItem(title: "Мой пункт", target: .url("https://example.org"))] }
        #expect(w.search("мой пункт").first?.action == .launcher(.url("https://example.org")))
        w.box.value.includeLauncherItems = false
        #expect(w.search("мой пункт").allSatisfy { $0.provider != .entries })
    }

    @Test func userEntryWinsOverTheSameLauncherItem() {
        let w = world {
            $0.settings.userEntries = [CbUserEntry(title: "Свой", target: .url("https://example.org"))]
            $0.launcher.list = [LauncherItem(title: "Чужой", target: .url("https://example.org"))]
        }
        #expect(w.search("свой").first?.title == "Свой")
        #expect(w.search("чужой").allSatisfy { $0.title != "Чужой" })
    }

    @Test func scriptsFromTheFolderAreListed() {
        let w = world { $0.scripts.files = ["/s/backup.sh", "/s/notes.txt", "/s/clean.py", "/s/hi.scpt", "/s/.hidden.sh"] }
        let r = w.search("run ")
        #expect(r.map(\.title).sorted() == [".hidden", "backup", "clean", "hi"].sorted())
        #expect(w.rig.scripts.asked.first == MultitulPaths.home + "/scripts")
        #expect(w.search("backup").first?.action == .launcher(.script("/s/backup.sh")))
    }

    @Test func customScriptsFolderIsUsed() {
        let w = world { $0.settings.scriptsFolder = "~/bin/mine" }
        _ = w.search("run x")
        #expect(w.rig.scripts.asked.last == NSHomeDirectory() + "/bin/mine")
    }

    @Test func emojiNeedsAStrongMatchInTheGlobalSearch() {
        let w = world()
        #expect(w.search("огонь").contains { $0.provider == .emoji })
        #expect(!w.search("ог").contains { $0.provider == .emoji })
        #expect(w.search(":ог").contains { $0.provider == .emoji })
    }

    @Test func emojiActionFollowsThePasteSetting() {
        let w = world()
        #expect(w.search(":fire").first?.action == .pasteText("🔥"))
        w.box.value.pasteResults = false
        #expect(w.search(":fire").first?.action == .copyText("🔥"))
    }

    @Test func emojiNeverOutranksAnApp() {
        let w = world { $0.apps.list = [CbFix.app("Notes")] }
        #expect(w.search("note").first?.title == "Notes")
    }
}
