import Testing
import Foundation
@testable import MultitulCore

@Suite struct IslShortcutListTests {
    private let fs = TlsFiles()

    @Test func defaultsAreUsable() {
        let l = IslShortcutList()
        #expect(l.items.count == IslShortcutDefaults.items.count && l.items.count <= IslShortcutList.maxItems)
        #expect(Set(l.items.map(\.id)).count == l.items.count)
        for i in l.items { #expect(!i.title.isEmpty && !i.symbol.isEmpty) }
    }

    @Test func defaultsPointAtRealTools() {
        for i in IslShortcutDefaults.items {
            switch i.target {
            case .tool(let t): #expect(ModuleID.allCases.contains(t.module))
            case .toggle: break
            default: Issue.record("unexpected default target")
            }
        }
    }

    @Test func addingAToolWorks() throws {
        var l = IslShortcutList(items: [])
        let item = try l.add(.tool(.scratchpad), fs: fs).get()
        #expect(l.items == [item] && item.title == "Блокнот")
    }

    @Test func addingWithACustomTitle() throws {
        var l = IslShortcutList(items: [])
        _ = try l.add(.tool(.scratchpad), title: "  Заметки ", fs: fs).get()
        #expect(l.items.first?.title == "Заметки")
    }

    @Test func urlsAreNormalisedAndValidated() throws {
        var l = IslShortcutList(items: [])
        let item = try l.add(.url("example.com"), fs: fs).get()
        #expect(item.target == .url("https://example.com"))
        #expect(l.add(.url("file:///etc/hosts"), fs: fs) == .failure(.blockedScheme("file")))
        #expect(l.items.count == 1)
    }

    @Test func missingAppsAndScriptsAreRejected() {
        var l = IslShortcutList(items: [])
        #expect(l.add(.app("com.nope"), fs: fs) == .failure(.appNotFound))
        #expect(l.add(.script("/nope.sh"), fs: fs) == .failure(.scriptNotFound))
        #expect(l.items.isEmpty)
    }

    @Test func installedAppsAndScriptsAreAccepted() throws {
        fs.bundles["com.apple.Safari"] = "/Applications/Safari.app"
        fs.files.insert("/Users/x/run.sh")
        fs.executables.insert("/Users/x/run.sh")
        var l = IslShortcutList(items: [])
        _ = try l.add(.app("com.apple.Safari"), fs: fs).get()
        _ = try l.add(.script("/Users/x/run.sh"), fs: fs).get()
        #expect(l.items.count == 2)
    }

    @Test func thereIsALimit() {
        var l = IslShortcutList(items: [])
        for _ in 0..<IslShortcutList.maxItems { _ = l.add(.tool(.scratchpad), fs: fs) }
        #expect(l.items.count == IslShortcutList.maxItems)
        #expect(l.add(.tool(.shelf), fs: fs) == .failure(.emptyValue))
        #expect(l.items.count == IslShortcutList.maxItems)
    }

    @Test func removeByIdOnly() {
        var l = IslShortcutList()
        let first = l.items[0].id
        l.remove(id: first)
        l.remove(id: "missing")
        #expect(!l.items.contains { $0.id == first } && l.items.count == IslShortcutDefaults.items.count - 1)
    }

    @Test func moveBefore() {
        var l = IslShortcutList(items: [IslShortcut(id: "a", target: .tool(.shelf)), IslShortcut(id: "b", target: .tool(.scratchpad)), IslShortcut(id: "c", target: .tool(.colorPicker))])
        l.move("c", before: "a")
        #expect(l.items.map(\.id) == ["c", "a", "b"])
        l.move("a", before: "a")
        l.move("a", before: "zzz")
        #expect(l.items.map(\.id) == ["c", "a", "b"])
    }

    @Test func nudgeStopsAtTheEdges() {
        var l = IslShortcutList(items: [IslShortcut(id: "a", target: .tool(.shelf)), IslShortcut(id: "b", target: .tool(.scratchpad))])
        l.nudge("a", by: -1)
        #expect(l.items.map(\.id) == ["a", "b"])
        l.nudge("a", by: 1)
        #expect(l.items.map(\.id) == ["b", "a"])
        l.nudge("a", by: 5)
        #expect(l.items.map(\.id) == ["b", "a"])
    }

    @Test func renameFallsBackToTheDefaultTitle() {
        var l = IslShortcutList(items: [IslShortcut(id: "a", title: "Мой", target: .tool(.shelf))])
        l.rename("a", to: "Новое")
        #expect(l.items[0].title == "Новое")
        l.rename("a", to: "   ")
        #expect(l.items[0].title == "Полка")
    }

    @Test func resetRestoresTheDefaults() {
        var l = IslShortcutList(items: [])
        l.reset()
        #expect(l == IslShortcutList())
    }

    @Test func sanitizingDropsDuplicatesAndTheOverflow() {
        let many = (0..<30).map { IslShortcut(id: "i\($0 % 20)", target: .tool(.shelf)) }
        let s = IslShortcutList(items: many).sanitized
        #expect(Set(s.items.map(\.id)).count == s.items.count && s.items.count <= IslShortcutList.maxItems)
    }
}

@Suite struct IslShortcutStoreTests {
    @Test func freshStoreGivesDefaults() {
        #expect(IslShortcutStore(WndMemoryStore()).load() == IslShortcutList())
    }

    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        IslShortcutStore(kv).save(IslShortcutList())
        #expect(kv.values.isEmpty)
    }

    @Test func customListRoundTrips() {
        let list = IslShortcutList(items: [
            IslShortcut(id: "a", title: "Блокнот", target: .tool(.scratchpad)),
            IslShortcut(id: "b", title: "Сайт", target: .url("https://example.com/a:b")),
            IslShortcut(id: "c", title: "Скрипт", target: .script("/Users/x/run.sh")),
            IslShortcut(id: "d", title: "Тема", target: .toggle(.darkMode))
        ])
        let kv = WndMemoryStore()
        IslShortcutStore(kv).save(list)
        #expect(IslShortcutStore(kv).load() == list)
    }

    @Test func emptyListIsRemembered() {
        let kv = WndMemoryStore()
        IslShortcutStore(kv).save(IslShortcutList(items: []))
        #expect(IslShortcutStore(kv).load().items.isEmpty)
    }

    @Test func tabsInTitlesDoNotBreakTheFormat() {
        let list = IslShortcutList(items: [IslShortcut(id: "a", title: "a\tb", target: .tool(.shelf))])
        let kv = WndMemoryStore()
        IslShortcutStore(kv).save(list)
        #expect(IslShortcutStore(kv).load().items.first?.title == "a b")
    }

    @Test func brokenLinesAreSkipped() {
        let kv = WndMemoryStore()
        kv.set(["a\tOk\ttool:shelf", "broken", "b\tNo\ttool:nope", "c\tTwo\ttoggle:darkMode"], forKey: "notch.shortcuts")
        let l = IslShortcutStore(kv).load()
        #expect(l.items.map(\.id) == ["a", "c"])
    }
}

private func failure<T>(_ r: Result<T, LauncherIssue>) -> LauncherIssue? { if case .failure(let e) = r { return e }; return nil }
private func succeeded<T>(_ r: Result<T, LauncherIssue>) -> Bool { if case .success = r { return true }; return false }

@Suite struct IslShortcutRunnerTests {
    private func runner() -> (IslShortcutRunner, TlsFiles, TlsExecutor) {
        let fs = TlsFiles()
        let ex = TlsExecutor()
        return (IslShortcutRunner(fs: fs, executor: ex), fs, ex)
    }

    @Test func toolsAreExecuted() {
        let (r, _, ex) = runner()
        #expect(succeeded(r.run(IslShortcut(target: .tool(.shelf)))))
        #expect(ex.commands == [.tool(.shelf)])
    }

    @Test func togglesAreExecuted() {
        let (r, _, ex) = runner()
        _ = r.run(IslShortcut(target: .toggle(.darkMode)))
        #expect(ex.commands == [.toggle(.darkMode)])
    }

    @Test func missingTargetsFailBeforeExecution() {
        let (r, _, ex) = runner()
        #expect(failure(r.run(IslShortcut(target: .app("com.nope")))) == .appNotFound)
        #expect(ex.commands.isEmpty)
    }

    @Test func executorFailuresAreReported() {
        let (r, _, ex) = runner()
        ex.result = .failed("Модуль выключен")
        #expect(failure(r.run(IslShortcut(target: .tool(.shelf)))) == .executionFailed("Модуль выключен"))
    }

    @Test func urlsAreOpened() {
        let (r, _, ex) = runner()
        _ = r.run(IslShortcut(target: .url("example.com")))
        #expect(ex.commands == [.openURL(URL(string: "https://example.com")!)])
    }

    @Test func dangerousSchemesNeverReachTheExecutor() {
        let (r, _, ex) = runner()
        _ = r.run(IslShortcut(target: .url("javascript:alert(1)")))
        #expect(ex.commands.isEmpty)
    }

    @Test func toolsCatalogFollowsAvailability() {
        #expect(IslToolsCatalog.tools { $0 == .shelf || $0 == .clipboard } == [.shelf, .clipboard])
        #expect(IslToolsCatalog.tools { _ in false }.isEmpty)
        #expect(IslToolsCatalog.toggles.allSatisfy { !$0.needsConfirmation })
        #expect(!IslToolsCatalog.toggles.contains(.emptyTrash))
    }
}
