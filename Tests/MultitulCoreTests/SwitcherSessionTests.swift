import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func named(_ items: [(String, String)]) -> [SwitchEntry] {
    items.enumerated().map { i, p in SwitchEntry(window: SwcFix.win(i + 1, pid: Int32(10 + i), app: p.0, title: p.1)) }
}

@Suite struct SwitcherSessionTests {
    @Test func firstSelectionIsThePreviousWindow() {
        #expect(SwitcherSession(entries: SwcFix.entries(5)).selected == 1)
        #expect(SwitcherSession(entries: SwcFix.entries(1)).selected == 0)
        #expect(SwitcherSession(entries: []).selected == nil)
        #expect(SwitcherSession(entries: SwcFix.entries(5), backward: true).selected == 4)
    }

    @Test func movingWrapsInBothDirections() {
        var s = SwitcherSession(entries: SwcFix.entries(4))
        s.move(1); s.move(1)
        #expect(s.selected == 3)
        s.move(1)
        #expect(s.selected == 0)
        s.move(-1)
        #expect(s.selected == 3)
        s.move(-5)
        #expect(s.selected == 2)
    }

    @Test func movingWithoutWrapClamps() {
        var s = SwitcherSession(entries: SwcFix.entries(3))
        s.move(10, wrap: false)
        #expect(s.selected == 2)
        s.move(-10, wrap: false)
        #expect(s.selected == 0)
    }

    @Test func movingOnAnEmptyListKeepsNoSelection() {
        var s = SwitcherSession(entries: [])
        s.move(1)
        s.moveVertical(1, columns: 3)
        #expect(s.selected == nil && s.selectedEntry == nil)
    }

    @Test func verticalMoveStepsByRowsAndWrapsToTheSameColumn() {
        var s = SwitcherSession(entries: SwcFix.entries(8))
        s.select(index: 1)
        s.moveVertical(1, columns: 3)
        #expect(s.selected == 4)
        s.moveVertical(1, columns: 3)
        #expect(s.selected == 7)
        s.moveVertical(1, columns: 3)
        #expect(s.selected == 1)
        s.moveVertical(-1, columns: 3)
        #expect(s.selected == 7)
    }

    @Test func verticalMoveIntoAShortLastRowLandsOnTheLastItem() {
        var s = SwitcherSession(entries: SwcFix.entries(8))
        s.select(index: 2)
        s.moveVertical(1, columns: 3)
        s.moveVertical(1, columns: 3)
        #expect(s.selected == 7)
        s.select(index: 2)
        s.moveVertical(-1, columns: 3)
        #expect(s.selected == 5)
    }

    @Test func selectingByIdAndIndexIsValidated() {
        var s = SwitcherSession(entries: SwcFix.entries(4))
        #expect(s.select(id: .window(3)) && s.selected == 2)
        #expect(!s.select(id: .window(99)) && s.selected == 2)
        s.select(index: 99)
        #expect(s.selected == 2)
    }

    @Test func removingBeforeTheSelectionShiftsIt() {
        var s = SwitcherSession(entries: SwcFix.entries(5))
        s.select(index: 3)
        s.remove(id: .window(1))
        #expect(s.selected == 2 && s.selectedID == .window(4))
    }

    @Test func removingTheSelectedLastItemClamps() {
        var s = SwitcherSession(entries: SwcFix.entries(3))
        s.select(index: 2)
        s.remove(id: .window(3))
        #expect(s.selected == 1 && s.count == 2)
        s.remove(id: .window(1)); s.remove(id: .window(2))
        #expect(s.isEmpty && s.selected == nil)
    }

    @Test func replacingAnEntryKeepsItsPlace() {
        var s = SwitcherSession(entries: SwcFix.entries(3))
        var e = s.visible[1]
        e.isMinimized = true
        s.replace(e)
        #expect(s.visible[1].isMinimized && s.all[1].isMinimized)
    }

    @Test func searchFiltersRanksAndSelectsTheBestMatch() {
        var s = SwitcherSession(entries: named([("Safari", "Новости"), ("Telegram", "Чат"), ("Terminal", "zsh"), ("Xcode", "Multitul")]))
        s.beginSearch()
        s.appendQuery("te")
        #expect(s.visible.map(\.appName) == ["Telegram", "Terminal"] && s.selected == 0)
        s.appendQuery("r")
        #expect(s.visible.first?.appName == "Terminal")
        s.deleteLastQueryCharacter()
        #expect(s.visible.count == 2)
    }

    @Test func clearingTheQueryKeepsTheChosenEntry() {
        var s = SwitcherSession(entries: named([("Safari", "A"), ("Telegram", "B"), ("Terminal", "C")]))
        s.setQuery("term")
        #expect(s.selectedEntry?.appName == "Terminal")
        s.setQuery("")
        #expect(s.count == 3 && s.selectedEntry?.appName == "Terminal")
    }

    @Test func aQueryWithNoMatchesLeavesNothingSelected() {
        var s = SwitcherSession(entries: SwcFix.entries(3))
        s.setQuery("zzzzqq")
        #expect(s.isEmpty && s.selected == nil)
        s.deleteLastQueryCharacter()
        #expect(s.query == "zzzzq")
    }

    @Test func endingTheSearchRestoresTheFullList() {
        var s = SwitcherSession(entries: SwcFix.entries(4))
        s.beginSearch()
        s.setQuery("окно 3")
        #expect(s.count == 1 && s.searching)
        s.endSearch()
        #expect(s.count == 4 && !s.searching && s.query.isEmpty)
    }

    @Test func mergingFreshEntriesKeepsTheSelectionById() {
        var s = SwitcherSession(entries: SwcFix.entries(4))
        s.select(index: 2)
        let fresh = Array(SwcFix.entries(5).reversed())
        s.merge(fresh: fresh)
        #expect(s.selectedID == .window(3) && s.count == 5)
    }

    @Test func mergingDropsAVanishedSelectionToTheNearestIndex() {
        var s = SwitcherSession(entries: SwcFix.entries(4))
        s.select(index: 3)
        s.merge(fresh: SwcFix.entries(2))
        #expect(s.selected == 1)
    }

    @Test func mergingRespectsTheActiveQuery() {
        var s = SwitcherSession(entries: named([("Safari", "A"), ("Terminal", "B")]))
        s.setQuery("saf")
        s.merge(fresh: named([("Safari", "A"), ("Terminal", "B"), ("Safari Technology", "C")]))
        #expect(s.visible.count == 2 && s.visible.allSatisfy { $0.appName.hasPrefix("Safari") })
    }
}

@Suite struct SwitcherSearchTests {
    private let list = named([("Safari", "Apple — Главная"), ("Telegram", "Семья"), ("Terminal", "ssh vps"), ("Code", "SwitcherSearch.swift"), ("Slack", "Рабочий чат"), ("Chrome", "Заказ на сайте")])

    @Test func emptyQueryKeepsTheOrder() {
        #expect(SwitcherSearch.rank(list, query: "  ").map(\.appName) == list.map(\.appName))
    }

    @Test func appNamePrefixBeatsATitleMatch() {
        let r = SwitcherSearch.rank(list, query: "sa")
        #expect(r.first?.appName == "Safari")
    }

    @Test func titleWordsAreSearchable() {
        #expect(SwitcherSearch.rank(list, query: "семья").map(\.appName) == ["Telegram"])
        #expect(SwitcherSearch.rank(list, query: "vps").map(\.appName) == ["Terminal"])
    }

    @Test func allTokensMustMatch() {
        #expect(SwitcherSearch.rank(list, query: "term vps").map(\.appName) == ["Terminal"])
        #expect(SwitcherSearch.rank(list, query: "safari vps").isEmpty)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(SwitcherSearch.rank(list, query: "SAFARI").count == 1)
        let e = named([("Éditeur", "Naïve café")])
        #expect(SwitcherSearch.rank(e, query: "editeur cafe").count == 1)
    }

    @Test func aWrongKeyboardLayoutStillFindsTheApp() {
        #expect(SwitcherSearch.rank(list, query: "ыфафкш").map(\.appName) == ["Safari"])
    }

    @Test func layoutSwapMapsBothWays() {
        #expect(KeyboardLayoutSwap.swapped("ыфафкш") == "safari")
        #expect(KeyboardLayoutSwap.swapped("цфдд") == "wall")
        #expect(KeyboardLayoutSwap.swapped("wall") == "цфдд")
        #expect(KeyboardLayoutSwap.swapped("123") == nil)
    }

    @Test func aLatinQueryFindsACyrillicNameTypedOnTheEnglishLayout() {
        let e = named([("Телеграм", "x"), ("Почта", "y")])
        #expect(SwitcherSearch.rank(e, query: "ntktuhfv").map(\.appName) == ["Телеграм"])
    }

    @Test func fuzzySubsequenceIsAWeakFallback() {
        let r = SwitcherSearch.rank(list, query: "tlgrm")
        #expect(r.first?.appName == "Telegram")
        #expect(SwitcherSearch.rank(list, query: "zq").isEmpty)
    }

    @Test func equalScoresKeepTheRecencyOrder() {
        let e = named([("Notes", "a"), ("Notes", "b"), ("Notes", "c")])
        #expect(SwitcherSearch.rank(e, query: "notes").map(\.title) == ["a", "b", "c"])
    }

    @Test func appOnlyEntriesAreMatchedByNameOnly() {
        let e = [SwitchEntry(app: SwcFix.app(5, "Finder"))]
        #expect(SwitcherSearch.rank(e, query: "find").count == 1)
        #expect(SwitcherSearch.rank(e, query: "zzz").isEmpty)
    }

    @Test func textInputRulesRejectControlsAndArrows() {
        #expect(SwitcherKeyMachine.isSearchText("a") && SwitcherKeyMachine.isSearchText("ё") && SwitcherKeyMachine.isSearchText(" "))
        #expect(!SwitcherKeyMachine.isSearchText("\u{7F}") && !SwitcherKeyMachine.isSearchText("\r") && !SwitcherKeyMachine.isSearchText("\u{F700}") && !SwitcherKeyMachine.isSearchText(""))
    }
}
