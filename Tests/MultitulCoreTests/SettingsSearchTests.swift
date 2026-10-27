import Testing
import Foundation
@testable import MultitulCore

private func entry(_ title: String, _ kw: String = "", _ section: String = "keys", _ sub: String? = nil) -> SettingsIndexEntry {
    SettingsIndexEntry(title: title, keywords: kw, section: section, subpage: sub)
}

@Suite struct SettingsSearchMatchTests {
    @Test func caseInsensitive() {
        let e = [entry("Kill switch", "VPN")]
        #expect(SettingsSearch.search("KILL", in: e).count == 1)
        #expect(SettingsSearch.search("vpn", in: e).count == 1)
        #expect(SettingsSearch.search("Vpn", in: [entry("впн", "VPN")]).count == 1)
    }

    @Test func yoEqualsYe() {
        let e = [entry("Ещё один параметр"), entry("Ёлка")]
        #expect(SettingsSearch.search("еще", in: e).map(\.title) == ["Ещё один параметр"])
        #expect(SettingsSearch.search("ёлка", in: e).map(\.title) == ["Ёлка"])
        #expect(SettingsSearch.search("елка", in: e).map(\.title) == ["Ёлка"])
        #expect(SettingsSearch.normalize("ЁЖ") == "еж")
    }

    @Test func prefixMatchesWordStart() {
        let e = [entry("Скриншоты и запись")]
        #expect(SettingsSearch.search("скри", in: e).count == 1)
        #expect(SettingsSearch.search("зап", in: e).count == 1)
        #expect(SettingsSearch.search("к", in: e).isEmpty == false)
    }

    @Test func substringNeedsThreeChars() {
        let e = [entry("Скриншоты")]
        #expect(SettingsSearch.search("шот", in: e).count == 1)
        #expect(SettingsSearch.search("шо", in: e).isEmpty)
    }

    @Test func multiWordRequiresEveryWordInAnyOrder() {
        let e = [entry("Яркость клавиатуры"), entry("Яркость выше максимума"), entry("Клавиши яркости")]
        #expect(SettingsSearch.search("яркость клав", in: e).map(\.title).contains("Яркость клавиатуры"))
        #expect(SettingsSearch.search("клав яркость", in: e).map(\.title).contains("Яркость клавиатуры"))
        #expect(SettingsSearch.search("яркость макс", in: e).map(\.title) == ["Яркость выше максимума"])
        #expect(SettingsSearch.search("яркость банан", in: e).isEmpty)
    }

    @Test func keywordsAndSectionTitleAreSearched() {
        let e = [entry("Режим", "умный напрямую", "net")]
        #expect(SettingsSearch.search("напр", in: e).count == 1)
        #expect(SettingsSearch.search("сеть режим", in: e).count == 1)
    }

    @Test func subpageIsSearchedAndShownInPath() {
        let e = [entry("Новое правило", "", "net", "Правила")]
        #expect(SettingsSearch.search("правила", in: e).count == 1)
        #expect(e[0].path == "Сеть › Правила")
        #expect(entry("X", "", "keys").path == "Горячие клавиши")
    }

    @Test func exactTitleOutranksKeywordHit() {
        let e = [entry("Прочее", "микшер"), entry("Микшер"), entry("Микшер громкости")]
        #expect(SettingsSearch.search("микшер", in: e).map(\.title) == ["Микшер", "Микшер громкости", "Прочее"])
    }

    @Test func emptyOrSymbolOnlyQueryGivesNothing() {
        let e = [entry("Что угодно")]
        #expect(SettingsSearch.search("", in: e).isEmpty)
        #expect(SettingsSearch.search("   ", in: e).isEmpty)
        #expect(SettingsSearch.search("⌘", in: e).isEmpty)
    }

    @Test func limitAndDeduplication() {
        let many = (0..<100).map { entry("Параметр \($0)", "", "keys") }
        #expect(SettingsSearch.search("параметр", in: many, limit: 10).count == 10)
        let dup = [entry("Один"), entry("Один")]
        #expect(SettingsSearch.search("один", in: dup).count == 1)
    }

    @Test func scoreIsNilWhenAnyTokenMissing() {
        #expect(SettingsSearch.score(query: "диск батарея", title: "Диск", keywords: "место") == nil)
        #expect(SettingsSearch.score(query: "диск", title: "Диск") != nil)
    }
}

@Suite struct SettingsIndexTests {
    @Test func everySectionIsAKnownSidebarID() {
        for e in SettingsIndex.all { #expect(NavCatalog.contains(e.section), "\(e.title) -> \(e.section)") }
    }

    @Test func coversEverySidebarItem() {
        let ids = Set(SettingsIndex.nav.map(\.section))
        #expect(ids == Set(NavCatalog.entries.map(\.id)))
    }

    @Test func coversEveryModule() {
        let titles = Set(SettingsIndex.all.map(\.title))
        for id in ModuleID.allCases { #expect(titles.contains(id.info.title), "\(id)") }
    }

    @Test func entriesAreUniqueAndNonEmpty() {
        let ids = SettingsIndex.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let cur = SettingsIndex.curated.map(\.id)
        #expect(Set(cur).count == cur.count)
        #expect(SettingsIndex.all.allSatisfy { !$0.title.isEmpty })
    }

    @Test func hasGoodCoverage() {
        #expect(SettingsIndex.curated.count >= 450)
        #expect(SettingsIndex.all.count >= 480)
        for sec in NavCatalog.entries.map(\.id) {
            #expect(SettingsIndex.all.contains { $0.section == sec })
        }
    }

    @Test func realQueriesLandOnTheRightSection() {
        func top(_ q: String) -> String? { SettingsSearch.search(q, in: SettingsIndex.all).first?.section }
        #expect(top("автозапуск") == "general")
        #expect(top("kill switch") == "net")
        #expect(top("яркость") == "displays")
        #expect(top("сочетания") == "keys")
        #expect(top("универсальный доступ") == "perm")
        #expect(top("keep awake") == "energy")
        #expect(top("помодоро") == "island")
        #expect(top("история буфера") == "clip")
        #expect(top("скриншот") == "shots")
        #expect(top("сторож") == "guard")
        #expect(top("ёмкость") == "system")
    }

    @Test func sectionKeywordsFindSubpageEntries() {
        let hits = SettingsSearch.search("правила", in: SettingsIndex.all)
        #expect(hits.contains { $0.section == "net" && $0.subpage == "Правила" })
    }
}

@Suite struct NavCatalogTests {
    @Test func idsAreUniqueAsciiAndDefaultExists() {
        let ids = NavCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.allSatisfy(\.isASCII) })
        #expect(NavCatalog.contains(NavCatalog.defaultID))
        #expect(NavCatalog.defaultID == "today")
        #expect(NavCatalog.entries.first?.id == "today")
    }

    @Test func oldSectionIDsAreMapped() {
        #expect(NavCatalog.sidebarID(forSection: "clean") == "storage")
        #expect(NavCatalog.sidebarID(forSection: "tools") == "shots")
        #expect(NavCatalog.sidebarID(forSection: "modules") == "modules")
        #expect(NavCatalog.sidebarID(forSection: "permissions") == "perm")
        #expect(NavCatalog.sidebarID(forSection: "hotkeys") == "keys")
        #expect(NavCatalog.sidebarID(forSection: "guard") == "guard")
        #expect(NavCatalog.sidebarID(forSection: "keys") == "keys")
        #expect(NavCatalog.sidebarID(forSection: "nonsense") == "today")
        #expect(NavCatalog.sidebarID(forSection: "") == "today")
    }

    @Test func everyModuleGroupRawValueResolves() {
        for g in ModuleGroup.allCases { #expect(NavCatalog.contains(NavCatalog.sidebarID(forSection: g.rawValue))) }
    }

    @Test func everyModuleHasAPageAndToolsAreNotLumped() {
        for id in ModuleID.allCases {
            let s = NavCatalog.sidebarID(for: id)
            #expect(NavCatalog.contains(s))
            if id.info.group == .tools { #expect(["shots", "cmd", "ocr", "pad", "tidy", "brew", "pip"].contains(s), "\(id)") }
        }
        #expect(NavCatalog.sidebarID(for: .storozh) == "guard")
        #expect(NavCatalog.sidebarID(for: .diskClean) == "storage")
        #expect(NavCatalog.sidebarID(for: .vpn) == "net")
    }
}
