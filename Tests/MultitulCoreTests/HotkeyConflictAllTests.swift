import Testing
import Foundation
import Carbon.HIToolbox
@testable import MultitulCore

private func fresh() -> InMemoryKeyValueStore { actDefaults() }

private func conflicts(_ pairs: [(String, KeyCombo)]) -> [String] {
    var out: [String] = []
    for i in pairs.indices {
        for j in pairs.indices where j > i && !pairs[i].1.isNone && pairs[i].1 == pairs[j].1 {
            out.append("\(pairs[i].0) == \(pairs[j].0) (\(pairs[i].1.display))")
        }
    }
    return out
}

private var defaultPairs: [(String, KeyCombo)] { HotkeyHints.allSpecs.map { ($0.id, $0.defaultCombo) } }
private var suggestedPairs: [(String, KeyCombo)] { HotkeyHints.allSpecs.map { ($0.id, HotkeyHints.effective($0)) } }

@Suite struct HotkeyCatalogTests {
    @Test func everySpecIdIsUniqueAndAscii() {
        let ids = HotkeyHints.allSpecs.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.allSatisfy { $0.isASCII } })
    }

    @Test func catalogCoversEveryModuleAndTheCore() {
        let ids = Set(HotkeyHints.allSpecs.map(\.id))
        for spec in CoreHotkeys.all { #expect(ids.contains(spec.id)) }
        for id in ModuleID.allCases { for spec in id.info.hotkeys { #expect(ids.contains(spec.id)) } }
        #expect(ids.contains(SnippetHotkeys.library.id) && ids.contains(ClipHotkeys.finderRename.id) && ids.contains(BrightnessHotkeys.keyboardUp.id))
    }

    @Test func defaultSetHasNoConflicts() {
        #expect(conflicts(defaultPairs).isEmpty)
    }

    @Test func newInputModulesShipWithoutAssignedCombos() {
        let specs = [ModuleID.mouseNavigation, .mouseButtonShortcuts, .middleClick, .superKey, .quitProtection, .textSnippets].flatMap { $0.info.hotkeys }
        #expect(specs.allSatisfy { $0.defaultCombo.isNone })
    }

    @Test func suggestedSetHasNoConflicts() {
        #expect(conflicts(suggestedPairs).isEmpty)
    }

    @Test func suggestedSetCoversEveryCatalogHint() {
        let ids = Set(HotkeyHints.allSpecs.map(\.id))
        for (id, combo) in HotkeyHints.suggested {
            #expect(ids.contains(id))
            #expect(!combo.isNone)
        }
        #expect(HotkeyHints.suggested.count == 44)
    }

    @Test func hintsNeverOverrideARealDefault() {
        for spec in HotkeyHints.allSpecs where !spec.defaultCombo.isNone { #expect(HotkeyHints.effective(spec) == spec.defaultCombo) }
    }

    @Test func everySuggestedComboIsRecordable() {
        for spec in HotkeyHints.allSpecs {
            let c = HotkeyHints.effective(spec)
            guard !c.isNone else { continue }
            let hasMain = c.modifiers & (KeyCombo.cmd | KeyCombo.opt | KeyCombo.ctrl) != 0
            let isF = KeyCombo.names[c.keyCode]?.hasPrefix("F") == true
            #expect(hasMain || isF, "\(spec.id) \(c.display)")
        }
    }

    @Test func suggestedCombosMatchTheCatalogText() {
        let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd
        #expect(HotkeyHints.suggested[ClipHotkeys.picker.id]?.display == KeyCombo(keyCode: 9, modifiers: layer).display)
        #expect(HotkeyHints.suggested[ClipHotkeys.picker.id]?.display == "⌃⌥⌘V")
        #expect(HotkeyHints.suggested[ClipHotkeys.pastePlain.id]?.display == "⌥⇧⌘V")
        #expect(HotkeyHints.suggested[ShelfHotkeys.toggle.id]?.display == "⌃⌥⌘D")
        #expect(HotkeyHints.suggested[SoundHotkeys.outputNext.id]?.display == "⌃⌥⌘S")
        #expect(HotkeyHints.suggested[SoundHotkeys.micToggle.id]?.display == "⌃⌥⌘M")
        #expect(HotkeyHints.suggested[KeepAwakeHotkeys.toggle.id]?.display == "⌃⌥⌘K")
        #expect(HotkeyHints.suggested[SnippetHotkeys.library.id]?.display == "⌃⌥⌘L")
        #expect(HotkeyHints.suggested[ClipHotkeys.finderRename.id]?.display == "F2")
    }
}

@Suite struct InterceptedKeyConflictTests {
    @Test func noDefaultOrSuggestedComboCollidesWithAnInterceptedKey() {
        let taken = InterceptedKeys.all
        for (id, combo) in defaultPairs + suggestedPairs where !combo.isNone {
            #expect(!taken.contains { $0.combo == combo }, "\(id) \(combo.display)")
        }
    }

    @Test func interceptedCatalogIsUniqueAndComplete() {
        #expect(Set(InterceptedKeys.all.map(\.id)).count == InterceptedKeys.all.count)
        #expect(conflicts(InterceptedKeys.all.map { ($0.id, $0.combo) }).isEmpty)
        let combos = InterceptedKeys.all.map(\.combo)
        #expect(combos.contains(KeyCombo(keyCode: Keys.q, modifiers: KeyCombo.cmd)))
        #expect(combos.contains(KeyCombo(keyCode: Keys.w, modifiers: KeyCombo.cmd)))
        #expect(combos.contains(InterceptedKeys.superKeyCaps))
    }

    @Test func snippetTerminatorKeysAreNeverHotkeys() {
        let terminators: Set<UInt32> = [Keys.space, Keys.tab, Keys.returnKey, Keys.enterKey, Keys.backspace]
        for (id, combo) in suggestedPairs where !combo.isNone && combo.modifiers == 0 { #expect(!terminators.contains(combo.keyCode), "\(id)") }
    }

    @Test func superKeySourceKeysAreNotHotkeyKeys() {
        let source = Set(SuperKeySource.allCases.map(\.keyCode))
        for (id, combo) in suggestedPairs where !combo.isNone && combo.modifiers == 0 { #expect(!source.contains(combo.keyCode), "\(id)") }
    }

    @Test func protectionReservationsMatchTheInterceptedCatalog() {
        var s = QuitProtectionSettings()
        s.close.mode = .hold
        #expect(Set(s.reservedCombos) == [InterceptedKeys.quit, InterceptedKeys.close])
        #expect(InterceptedKeys.title(of: InterceptedKeys.quitID) == "Защита ⌘Q")
    }
}

@MainActor
@Suite struct HotkeyManagerAllModulesTests {
    private func manager() -> (HotkeyManager, FakeHotkeyBackend) {
        let be = FakeHotkeyBackend()
        return (HotkeyManager(backend: be, defaults: fresh()), be)
    }

    @Test func registeringEverySpecAtItsDefaultActivatesAll() {
        let (hm, _) = manager()
        for spec in HotkeyHints.allSpecs { #expect(hm.register(spec, owner: spec.id) {} == .active, "\(spec.id)") }
        #expect(hm.states.values.allSatisfy { $0 == .active })
    }

    @Test func applyingEverySuggestedComboThroughTheManagerHasZeroConflicts() {
        let (hm, be) = manager()
        for spec in HotkeyHints.allSpecs { hm.register(spec, owner: spec.id) {} }
        var rejected: [String] = []
        for spec in HotkeyHints.allSpecs {
            let target = HotkeyHints.effective(spec)
            switch hm.setCombo(spec, to: target) {
            case .applied: break
            case .conflict(let w): rejected.append("\(spec.id) vs \(w)")
            case .failed: rejected.append("\(spec.id) failed")
            }
        }
        #expect(rejected.isEmpty)
        #expect(hm.states.values.allSatisfy { $0 == .active })
        let live = be.live.values.map { $0 }
        #expect(Set(live).count == live.count)
    }

    @Test func reservedKeyRefusesManualAssignment() {
        let (hm, _) = manager()
        hm.reserve(id: InterceptedKeys.quitID, title: "Защита ⌘Q", combo: InterceptedKeys.quit)
        #expect(hm.setCombo(SnippetHotkeys.library, to: InterceptedKeys.quit) == .conflict(with: InterceptedKeys.quitID))
        #expect(hm.holder(of: InterceptedKeys.quit, excluding: "x") == InterceptedKeys.quitID)
        #expect(hm.reservedTitle(of: InterceptedKeys.quitID) == "Защита ⌘Q")
    }

    @Test func reservedKeyBlocksRegistrationAndReleaseFreesIt() {
        let (hm, be) = manager()
        hm.reserve(id: InterceptedKeys.closeID, title: "Защита ⌘W", combo: InterceptedKeys.close)
        let spec = HotkeySpec(id: "test.close", title: "T", defaultCombo: InterceptedKeys.close)
        #expect(hm.register(spec, owner: "t") {} == .conflict(with: InterceptedKeys.closeID))
        #expect(be.live.isEmpty)
        hm.release(id: InterceptedKeys.closeID)
        #expect(hm.state(of: "test.close") == .active)
        #expect(be.live.values.contains(InterceptedKeys.close))
    }

    @Test func reservingAnAlreadyHeldComboDeactivatesTheHolder() {
        let (hm, be) = manager()
        let spec = HotkeySpec(id: "test.held", title: "T", defaultCombo: InterceptedKeys.quit)
        #expect(hm.register(spec, owner: "t") {} == .active)
        hm.reserve(id: InterceptedKeys.quitID, title: "Защита ⌘Q", combo: InterceptedKeys.quit)
        #expect(hm.state(of: "test.held") == .conflict(with: InterceptedKeys.quitID))
        #expect(be.live.isEmpty)
        hm.release(id: InterceptedKeys.quitID)
        #expect(hm.state(of: "test.held") == .active && be.live.count == 1)
    }

    @Test func reservationOfNoneComboChangesNothing() {
        let (hm, _) = manager()
        hm.reserve(id: "test.none", title: "x", combo: .none)
        #expect(hm.setCombo(SnippetHotkeys.library, to: .none) == .applied)
        #expect(hm.reservedIDs == ["test.none"])
    }

    @Test func snippetLibraryHintCanBeAppliedWhileProtectionsAreReserved() {
        let (hm, _) = manager()
        for key in InterceptedKeys.all { hm.reserve(id: key.id, title: key.title, combo: key.combo) }
        hm.register(SnippetHotkeys.library, owner: "s") {}
        #expect(hm.setCombo(SnippetHotkeys.library, to: HotkeyHints.effective(SnippetHotkeys.library)) == .applied)
    }
}
