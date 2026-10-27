import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let windowModules: [ModuleID] = [.windowLayout, .windowMaximizer, .autoQuit, .spacesOrder, .dockClick]

@Suite struct WindowModuleInfoTests {
    @Test func fiveModulesLiveInTheWindowsGroup() {
        #expect(windowModules.allSatisfy { $0.info.group == .windows })
        #expect(ModuleID.allCases.filter { $0.info.group == .windows }.count == 8)
    }

    @Test func allAreOffByDefault() {
        #expect(windowModules.allSatisfy { !$0.info.enabledByDefault })
    }

    @Test func rawValuesAreAscii() {
        #expect(windowModules.allSatisfy { $0.rawValue.allSatisfy { $0.isASCII } && $0.enabledKey.allSatisfy { $0.isASCII } })
    }

    @Test func accessibilityIsDeclaredWhereItIsNeeded() {
        for id in [ModuleID.windowLayout, .windowMaximizer, .autoQuit, .dockClick] { #expect(id.info.permissions.contains(.accessibility)) }
        #expect(ModuleID.spacesOrder.info.permissions.isEmpty)
    }

    @Test func titlesAndSummariesAreRussian() {
        for id in windowModules {
            #expect(id.info.title.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) })
            #expect(!id.info.summary.isEmpty && !id.info.symbol.isEmpty)
        }
    }

    @Test func onlyTheLayoutModuleOwnsHotkeys() {
        #expect(ModuleID.windowLayout.info.hotkeys.count == WindowLayoutAction.allCases.count + 1)
        for id in [ModuleID.windowMaximizer, .autoQuit, .spacesOrder, .dockClick] { #expect(id.info.hotkeys.isEmpty) }
    }

    @Test func everyLayoutHotkeyShipsUnassigned() {
        #expect(ModuleID.windowLayout.info.hotkeys.allSatisfy { $0.defaultCombo.isNone })
    }

    @Test func hotkeyIdsAreUniqueAsciiAndPrefixed() {
        let ids = WindowHotkeys.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("windowLayout.") && $0.allSatisfy { $0.isASCII } })
    }

    @Test func hotkeyTitlesAreInRussianAndDistinct() {
        let titles = WindowHotkeys.all.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { $0.hasPrefix("Окна: ") })
    }

    @Test func actionRawValuesAreAsciiAndUnique() {
        let raw = WindowLayoutAction.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count && raw.allSatisfy { $0.allSatisfy { $0.isASCII } })
        #expect(WindowLayoutAction.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func customSlotsMapBothWays() {
        for slot in WindowLayoutAction.customSlots {
            let a = WindowLayoutAction.custom(slot: slot)
            #expect(a?.customSlot == slot && a?.group == .custom)
        }
        #expect(WindowLayoutAction.custom(slot: 9) == nil)
        #expect(WindowLayoutAction.leftHalf.customSlot == nil)
    }

    @Test func everyActionBelongsToAGroupAndFractionalOnesHaveAFraction() {
        for a in WindowLayoutAction.allCases {
            #expect(WindowLayoutGroup.allCases.contains(a.group))
            if a.group != .other && a.group != .custom { #expect(a.fraction != nil, "\(a)") }
        }
        #expect(WindowLayoutAction.restore.fraction == nil && WindowLayoutAction.center.fraction == nil)
    }

    @Test func fractionsStayInsideTheUnitSquare() {
        for a in WindowLayoutAction.allCases {
            guard let f = a.fraction else { continue }
            #expect(f.x >= 0 && f.y >= 0 && f.x + f.w <= 1 + 1e-9 && f.y + f.h <= 1 + 1e-9, "\(a)")
        }
    }

    @Test func movesBetweenDisplaysFlagCoversBothDirections() {
        #expect(WindowLayoutAction.nextDisplay.movesBetweenDisplays && WindowLayoutAction.previousDisplay.movesBetweenDisplays)
        #expect(!WindowLayoutAction.maximize.movesBetweenDisplays)
    }
}

@Suite struct WindowHintComboTests {
    private func display(_ a: WindowLayoutAction) -> String? { HotkeyHints.suggested[a.hotkeyID]?.display }

    @Test func halvesUseControlOptionArrows() {
        #expect(display(.leftHalf) == "⌃⌥←" && display(.rightHalf) == "⌃⌥→")
        #expect(display(.topHalf) == "⌃⌥↑" && display(.bottomHalf) == "⌃⌥↓")
    }

    @Test func cornersUseUIJK() {
        #expect(display(.topLeft) == "⌃⌥U" && display(.topRight) == "⌃⌥I")
        #expect(display(.bottomLeft) == "⌃⌥J" && display(.bottomRight) == "⌃⌥K")
    }

    @Test func maximizeCenterRestore() {
        #expect(display(.maximize) == "⌃⌥↩" && display(.center) == "⌃⌥C" && display(.restore) == "⌃⌥R")
    }

    @Test func thirdsAndTwoThirds() {
        #expect(display(.leftThird) == "⌃⌥D" && display(.centerThird) == "⌃⌥F" && display(.rightThird) == "⌃⌥G")
        #expect(display(.leftTwoThirds) == "⌃⌥E" && display(.rightTwoThirds) == "⌃⌥T")
    }

    @Test func displayHintsUseTheTripleLayer() {
        #expect(display(.nextDisplay) == "⌃⌥⌘→")
        #expect(HotkeyHints.suggested[WindowHotkeys.cursorNextDisplay.id]?.display == "⌃⌥⌘Z")
    }

    @Test func eighteenHintsAndAllReferToRealSpecs() {
        #expect(WindowHintCombos.all.count == 18)
        let ids = Set(HotkeyHints.allSpecs.map(\.id))
        #expect(WindowHintCombos.all.keys.allSatisfy { ids.contains($0) })
    }

    @Test func hintsAreUniqueAmongThemselves() {
        let combos = Array(WindowHintCombos.all.values)
        #expect(Set(combos).count == combos.count)
    }

    @Test func hintsNeverCollideWithTheOtherModulesOrTheRing() {
        let others = HotkeyHints.suggested.filter { !WindowHintCombos.all.keys.contains($0.key) }.map(\.value)
        for c in WindowHintCombos.all.values {
            #expect(!others.contains(c))
            #expect(c != RingSettings.defaultTrigger)
        }
    }

    @Test func spaceIsNotUsedByAnyWindowHint() {
        #expect(!WindowHintCombos.all.values.contains { $0.keyCode == Keys.space })
    }

    @Test func effectiveComboFallsBackToTheHint() {
        #expect(HotkeyHints.effective(WindowHotkeys.spec(for: .leftHalf)).display == "⌃⌥←")
        #expect(HotkeyHints.effective(WindowHotkeys.spec(for: .leftQuarter)).isNone)
    }

    @Test func everyLayoutSpecRegistersWithoutConflictsAtItsHint() {
        var seen: [KeyCombo: String] = [:]
        for spec in WindowHotkeys.all {
            let c = HotkeyHints.effective(spec)
            guard !c.isNone else { continue }
            #expect(seen[c] == nil, "\(spec.id) vs \(seen[c] ?? "")")
            seen[c] = spec.id
        }
    }
}

@Suite struct WindowConflictTests {
    @Test func rectangleIsDetectedByBundleId() {
        let names = WindowConflicts.detect(running: [("com.knollsoft.Rectangle", "Rectangle"), ("com.apple.finder", "Finder")], for: .windowLayout)
        #expect(names == ["Rectangle"])
    }

    @Test func detectionAlsoWorksByName() {
        #expect(WindowConflicts.detect(running: [(nil, "Magnet Pro")], for: .windowLayout) == ["Magnet"])
    }

    @Test func conflictsAreModuleSpecific() {
        let running: [(bundleID: String?, name: String?)] = [("com.lwouis.alt-tab-macos", "AltTab")]
        #expect(WindowConflicts.detect(running: running, for: .dockClick) == ["AltTab"])
        #expect(WindowConflicts.detect(running: running, for: .windowLayout).isEmpty)
    }

    @Test func noRunningAppsNoConflicts() {
        #expect(WindowConflicts.detect(running: [], for: .windowLayout).isEmpty)
    }

    @Test func duplicatesAreReportedOnce() {
        let r: [(bundleID: String?, name: String?)] = [("com.knollsoft.Rectangle", "Rectangle"), ("com.knollsoft.Rectangle", "Rectangle")]
        #expect(WindowConflicts.detect(running: r, for: .windowLayout) == ["Rectangle"])
    }

    @Test func everyKnownEntryHasAnAsciiBundleIdAndAffectsSomething() {
        #expect(WindowConflicts.known.allSatisfy { $0.bundleID.allSatisfy { $0.isASCII } && !$0.affects.isEmpty })
    }
}
