import Testing
import Foundation
@testable import MultitulCore

@MainActor
@Suite struct PanelLayoutTests {
    private let valid: Set<String> = ["vpn", "keepAwake", "monitorCPU", "brightness"]
    private let ids = ["vpn.card", "vpn.tile", "keepAwake.card", "monitorCPU.card", "brightness.tile"]

    private func store(_ kv: KeyValueStoring = InMemoryKeyValueStore()) -> PanelLayoutStore {
        PanelLayoutStore(defaults: kv, validModules: valid)
    }

    @Test func noStoredLayoutMeansDefaultOrder() {
        let s = store()
        s.reconcile(available: ids)
        #expect(s.profiles.count == 1)
        #expect(s.active.name == "Основной")
        #expect(s.active.order == ids)
        #expect(s.active.visible(available: ids) == ids)
    }

    @Test func corruptStoredDataFallsBackToDefault() {
        let kv = InMemoryKeyValueStore([PanelLayoutStore.defaultsKey: Data("nope".utf8)])
        let s = store(kv)
        s.reconcile(available: ids)
        #expect(s.active.order == ids)
    }

    @Test func reorderMovesBeforeTargetOrToEnd() {
        let s = store()
        s.reconcile(available: ids)
        s.move("brightness.tile", before: "vpn.card")
        #expect(s.active.order.first == "brightness.tile")
        s.move("brightness.tile", before: nil)
        #expect(s.active.order.last == "brightness.tile")
        s.move("vpn.card", before: "vpn.card")
        #expect(s.active.order == ["vpn.card", "vpn.tile", "keepAwake.card", "monitorCPU.card", "brightness.tile"])
    }

    @Test func hideAndShowKeepsItemOutOfVisibleThenAppendsIt() {
        let s = store()
        s.reconcile(available: ids)
        s.hide("keepAwake.card")
        #expect(!s.active.visible(available: ids).contains("keepAwake.card"))
        #expect(s.active.hiddenItems(available: ids) == ["keepAwake.card"])
        s.show("keepAwake.card")
        #expect(s.active.visible(available: ids).last == "keepAwake.card")
        #expect(s.active.hiddenItems(available: ids).isEmpty)
    }

    @Test func sizeFallsBackToMediumWhenSmallNotAllowed() {
        #expect(PanelItemSize.resolve(.small, allowed: [.medium, .wide], fallback: .medium) == .medium)
        #expect(PanelItemSize.resolve(.wide, allowed: [.small], fallback: .small) == .small)
        #expect(PanelItemSize.resolve(nil, allowed: [.small, .medium, .wide], fallback: .medium) == .medium)
        #expect(PanelItemSize.resolve(.small, allowed: [.small, .medium], fallback: .medium) == .small)
        let s = store()
        s.reconcile(available: ids)
        s.setSize("vpn.card", .small)
        #expect(s.active.size(of: "vpn.card", allowed: [.medium, .wide], fallback: .medium) == .medium)
        s.setSize("vpn.card", .wide)
        #expect(s.active.size(of: "vpn.card", allowed: [.medium, .wide], fallback: .medium) == .wide)
    }

    @Test func collapseToggles() {
        let s = store()
        s.reconcile(available: ids)
        s.toggleCollapsed("vpn.card")
        #expect(s.active.isCollapsed("vpn.card"))
        s.toggleCollapsed("vpn.card")
        #expect(!s.active.isCollapsed("vpn.card"))
    }

    @Test func profileCrud() {
        let s = store()
        s.reconcile(available: ids)
        s.hide("vpn.tile")
        s.setSize("vpn.card", .wide)
        let dup = s.duplicateActive()
        #expect(s.profiles.count == 2 && s.activeID == dup)
        #expect(s.active.name == "Основной копия")
        #expect(s.active.hidden == ["vpn.tile"] && s.active.sizes["vpn.card"] == .wide)
        s.renameActive("  Работа ")
        #expect(s.active.name == "Работа")
        s.renameActive("   ")
        #expect(s.active.name == "Работа")
        s.show("vpn.tile")
        s.switchProfile(PanelLayoutStore.mainProfileID)
        #expect(s.active.hidden == ["vpn.tile"])
        let added = s.addProfile(name: "Пусто")
        #expect(s.activeID == added && s.active.order == ids && s.active.hidden.isEmpty)
        #expect(s.deleteActive())
        #expect(s.profiles.count == 2)
        #expect(s.profiles.contains(where: { $0.id == s.activeID }))
        s.switchProfile(dup)
        #expect(s.deleteActive())
        #expect(s.profiles.count == 1)
        #expect(!s.deleteActive())
        #expect(s.profiles.count == 1)
    }

    @Test func persistsAndRestores() {
        let kv = InMemoryKeyValueStore()
        let a = store(kv)
        a.reconcile(available: ids)
        a.move("brightness.tile", before: "vpn.card")
        a.hide("vpn.tile")
        a.toggleCollapsed("monitorCPU.card")
        a.addProfile(name: "Второй")
        let b = store(kv)
        #expect(b.profiles.count == 2)
        #expect(b.active.name == "Второй")
        b.switchProfile(PanelLayoutStore.mainProfileID)
        #expect(b.active.order.first == "brightness.tile")
        #expect(b.active.hidden == ["vpn.tile"])
        #expect(b.active.isCollapsed("monitorCPU.card"))
    }

    @Test func newModulesAppendToEveryProfileAndUnknownIdsDrop() {
        let kv = InMemoryKeyValueStore()
        let s = store(kv)
        s.reconcile(available: ["vpn.card"])
        s.addProfile(name: "Второй")
        s.reconcile(available: ["vpn.card", "keepAwake.card"])
        for p in s.profiles { #expect(p.order == ["vpn.card", "keepAwake.card"]) }

        var p = PanelProfile(name: "x", order: ["ghost.card", "vpn.card", "vpn.card", "bad", "keepAwake.zzz"])
        p.hidden = ["ghost.tile", "vpn.tile"]
        p.sizes = ["ghost.card": .wide, "vpn.card": .wide]
        p.collapsed = ["ghost.card"]
        p.reconcile(available: ["vpn.card", "monitorCPU.card"], validModules: valid)
        #expect(p.order == ["vpn.card", "monitorCPU.card"])
        #expect(p.hidden == ["vpn.tile"])
        #expect(p.sizes == ["vpn.card": .wide])
        #expect(p.collapsed.isEmpty)
    }

    @Test func disabledModuleKeepsItsPlaceUntilReenabled() {
        let s = store()
        s.reconcile(available: ids)
        s.move("brightness.tile", before: "vpn.card")
        s.reconcile(available: ids.filter { $0 != "brightness.tile" })
        #expect(s.active.visible(available: ids.filter { $0 != "brightness.tile" }).first == "vpn.card")
        s.reconcile(available: ids)
        #expect(s.active.order.first == "brightness.tile")
    }

    private let legacyBlob = """
    {"profiles":[{"id":"main","name":"Основной","order":["vpn.card","vpn.tile","keepAwake.card","monitorCPU.card","brightness.tile"],"hidden":["vpn.card"],"sizes":{"keepAwake.card":"wide","brightness.tile":"small"},"collapsed":["monitorCPU.card"]},{"id":"games","name":"Игры","order":["brightness.tile"],"hidden":[],"sizes":{},"collapsed":[]}],"activeID":"games"}
    """

    @Test func legacyStoredLayoutStillDecodes() {
        let kv = InMemoryKeyValueStore([PanelLayoutStore.defaultsKey: Data(legacyBlob.utf8)])
        let s = store(kv)
        #expect(s.profiles.map(\.id) == ["main", "games"])
        #expect(s.activeID == "games")
        s.switchProfile("main")
        let p = s.active
        #expect(p.order.count == 5)
        #expect(p.hidden == ["vpn.card"])
        #expect(p.sizes["keepAwake.card"] == .wide)
        #expect(p.isCollapsed("monitorCPU.card"))
    }

    @Test func itemsFoldedIntoModuleTilesKeepStoredStateAndSizesStillResolve() {
        let kv = InMemoryKeyValueStore([PanelLayoutStore.defaultsKey: Data(legacyBlob.utf8)])
        let s = store(kv)
        s.switchProfile("main")
        let now = ["vpn.tile", "keepAwake.tile", "monitorCPU.card", "brightness.tile"]
        s.reconcile(available: now)
        #expect(s.active.order.contains("keepAwake.card"))
        #expect(s.active.visible(available: now) == ["vpn.tile", "monitorCPU.card", "brightness.tile", "keepAwake.tile"])
        #expect(s.active.size(of: "keepAwake.card", allowed: [.small, .medium], fallback: .medium) == .medium)
        #expect(s.active.size(of: "brightness.tile", allowed: [.small], fallback: .small) == .small)
        let reloaded = store(kv)
        #expect(reloaded.profiles.count == 2 && reloaded.activeID == "main")
    }

    @Test func presentationDecidesWhichItemsAreEmitted() {
        #expect(PanelPresentation.quick.emitsCard && PanelPresentation.quick.emitsTile)
        #expect(!PanelPresentation.module.emitsCard && PanelPresentation.module.emitsTile)
        #expect(PanelPresentation.cardOnly.emitsCard && !PanelPresentation.cardOnly.emitsTile)
    }

    @Test func sectionsFollowControlCenterOrder() {
        func sec(_ m: String, _ k: PanelItemKind, _ p: PanelPresentation = .quick, small: Bool = false) -> PanelSection {
            PanelSection.of(module: m, kind: k, presentation: p, small: small)
        }
        #expect(sec("vpn", .tile, .module) == .modules)
        #expect(sec("screenshot", .tile) == .quick)
        #expect(sec("brightness", .card) == .sliders)
        #expect(sec("soundOutputSwitcher", .card) == .sliders)
        #expect(sec("monitorCPU", .card) == .metrics)
        #expect(sec("monitorToggle", .tile, .module) == .modules)
        #expect(sec("keepAwake", .card, .cardOnly) == .cards)
        #expect(sec("soundOutputSwitcher", .card, small: true) == .quick)
        #expect(PanelSection.allCases == [.modules, .sliders, .metrics, .cards, .quick])
    }

    @Test func groupingKeepsProfileOrderInsideEachSection() {
        let order = ["screenshot.tile", "vpn.tile", "brightness.card", "colorPicker.tile", "keepAwake.tile"]
        let g = PanelSection.group(order) { id in
            let p = PanelItemID.parse(id)!
            let module = p.module == "vpn" || p.module == "keepAwake"
            return PanelSection.of(module: p.module, kind: p.kind, presentation: module ? .module : .quick)
        }
        #expect(g[.modules] == ["vpn.tile", "keepAwake.tile"])
        #expect(g[.sliders] == ["brightness.card"])
        #expect(g[.quick] == ["screenshot.tile", "colorPicker.tile"])
        #expect(g[.cards] == nil)
    }
}
