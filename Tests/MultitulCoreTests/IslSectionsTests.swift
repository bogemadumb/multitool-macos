import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import MultitulCore

private let known = [IslFix.descriptor("a", order: 10), IslFix.descriptor("b", order: 20), IslFix.descriptor("c", order: 30), IslFix.descriptor("d", order: 40)]

private func ids(_ l: IslLayout, _ k: [IslSectionDescriptor] = known) -> [String] { l.resolved(known: k).map(\.id.rawValue) }

@Suite struct IslLayoutTests {
    @Test func defaultsFollowTheDefaultOrder() {
        let l = IslLayout.defaults(for: [known[2], known[0], known[1]])
        #expect(l.order == ["a", "b", "c"] && l.hidden.isEmpty)
    }

    @Test func defaultHiddenSectionsStartHidden() {
        let l = IslLayout.defaults(for: [IslFix.descriptor("x", order: 1, hidden: true), known[0]])
        #expect(l.hidden == ["x"])
    }

    @Test func emptyOrderFallsBackToTheDefaults() {
        #expect(ids(IslLayout()) == ["a", "b", "c", "d"])
    }

    @Test func savedOrderWins() {
        #expect(ids(IslLayout(order: ["c", "a", "d", "b"])) == ["c", "a", "d", "b"])
    }

    @Test func unknownIdsAreDropped() {
        #expect(ids(IslLayout(order: ["zzz", "b", "a", "c", "d"])) == ["b", "a", "c", "d"])
    }

    @Test func duplicatesAreCollapsed() {
        #expect(ids(IslLayout(order: ["b", "b", "a", "a"])) == ["b", "a", "c", "d"])
    }

    @Test func newSectionsSlotInByDefaultOrder() {
        let withNew = known + [IslFix.descriptor("n", order: 25)]
        #expect(ids(IslLayout(order: ["a", "b", "c", "d"]), withNew) == ["a", "b", "n", "c", "d"])
    }

    @Test func newSectionBeforeEverythingGoesFirst() {
        let withNew = known + [IslFix.descriptor("z", order: 1)]
        #expect(ids(IslLayout(order: ["c", "b", "a", "d"]), withNew).first == "z")
    }

    @Test func newSectionAfterEverythingGoesLast() {
        let withNew = known + [IslFix.descriptor("z", order: 99)]
        #expect(ids(IslLayout(order: ["d", "c", "b", "a"]), withNew).last == "z")
    }

    @Test func userReorderingSurvivesANewSection() {
        let withNew = known + [IslFix.descriptor("n", order: 25)]
        let r = ids(IslLayout(order: ["d", "c", "b", "a"]), withNew)
        #expect(r.filter { $0 != "n" } == ["d", "c", "b", "a"])
        #expect(r.contains("n"))
    }

    @Test func visibleSkipsHidden() {
        let l = IslLayout(order: [], hidden: ["b", "d"])
        #expect(l.visible(known: known).map(\.id.rawValue) == ["a", "c"])
    }

    @Test func moveBeforeATarget() {
        var l = IslLayout()
        l.move("d", before: "b", known: known)
        #expect(l.order == ["a", "d", "b", "c"])
    }

    @Test func moveBeforeKeepsAllSections() {
        var l = IslLayout()
        l.move("d", before: "a", known: known)
        #expect(l.order == ["d", "a", "b", "c"])
    }

    @Test func moveOntoItselfOrUnknownDoesNothing() {
        var l = IslLayout()
        l.move("a", before: "a", known: known)
        l.move("a", before: "zzz", known: known)
        l.move("zzz", before: "a", known: known)
        #expect(l.order == ["a", "b", "c", "d"])
    }

    @Test func moveToIndexClamps() {
        var l = IslLayout()
        l.move("a", toIndex: 99, known: known)
        #expect(l.order.last == "a")
        l.move("a", toIndex: -5, known: known)
        #expect(l.order.first == "a")
    }

    @Test func nudgeMovesByOneAndStopsAtTheEdges() {
        var l = IslLayout()
        l.nudge("b", by: 1, known: known)
        #expect(l.order == ["a", "c", "b", "d"])
        l.nudge("a", by: -1, known: known)
        #expect(l.order.first == "a")
        l.nudge("d", by: 5, known: known)
        #expect(l.order.last == "d")
    }

    @Test func setHiddenToggles() {
        var l = IslLayout()
        l.setHidden("a", true)
        #expect(l.hidden == ["a"])
        l.setHidden("a", false)
        #expect(l.hidden.isEmpty)
    }

    @Test func normalizeDropsStaleHiddenIds() {
        var l = IslLayout(order: ["a"], hidden: ["a", "gone"])
        l.normalize(known: known)
        #expect(l.hidden == ["a"] && l.order == ["a", "b", "c", "d"])
    }
}

@Suite struct IslLayoutStoreTests {
    @Test func freshStoreGivesDefaults() {
        let s = IslLayoutStore(WndMemoryStore())
        #expect(s.load(known: known) == IslLayout.defaults(for: known))
    }

    @Test func orderRoundTrips() {
        let kv = WndMemoryStore()
        let s = IslLayoutStore(kv)
        var l = IslLayout.defaults(for: known)
        l.move("c", before: "a", known: known)
        l.setHidden("b", true)
        s.save(l, known: known)
        let back = IslLayoutStore(kv).load(known: known)
        #expect(back.order == ["c", "a", "b", "d"] && back.hidden == ["b"])
    }

    @Test func defaultsAreNotWrittenDown() {
        let kv = WndMemoryStore()
        IslLayoutStore(kv).save(IslLayout.defaults(for: known), known: known)
        #expect(kv.values.isEmpty)
    }

    @Test func resettingToDefaultsClearsTheKeys() {
        let kv = WndMemoryStore()
        let s = IslLayoutStore(kv)
        var l = IslLayout.defaults(for: known)
        l.nudge("a", by: 2, known: known)
        s.save(l, known: known)
        #expect(!kv.values.isEmpty)
        s.save(IslLayout.defaults(for: known), known: known)
        #expect(kv.values.isEmpty)
    }

    @Test func explicitEmptyHiddenListBeatsDefaultHidden() {
        let k = [IslFix.descriptor("x", order: 1, hidden: true), IslFix.descriptor("y", order: 2)]
        let kv = WndMemoryStore()
        let s = IslLayoutStore(kv)
        var l = s.load(known: k)
        #expect(l.hidden == ["x"])
        l.setHidden("x", false)
        s.save(l, known: k)
        #expect(IslLayoutStore(kv).load(known: k).hidden.isEmpty)
    }

    @Test func garbageInTheStoreIsCleaned() {
        let kv = WndMemoryStore()
        kv.set(["b", "", "b", "a"], forKey: "notch.order")
        kv.set(["", "q"], forKey: "notch.hidden")
        let l = IslLayoutStore(kv).load(known: known)
        #expect(l.order == ["b", "a", "c", "d"] && l.hidden.isEmpty)
    }

    @Test func lastSectionRoundTrips() {
        let kv = WndMemoryStore()
        let s = IslLayoutStore(kv)
        #expect(s.loadLast() == nil)
        s.saveLast("shelf")
        #expect(s.loadLast() == "shelf")
        s.saveLast(nil)
        #expect(s.loadLast() == nil)
    }

    @Test func newSectionsAppearAfterAnUpdate() {
        let kv = WndMemoryStore()
        let s = IslLayoutStore(kv)
        var l = IslLayout.defaults(for: known)
        l.move("d", before: "a", known: known)
        s.save(l, known: known)
        let bigger = known + [IslFix.descriptor("n", order: 15)]
        let back = IslLayoutStore(kv).load(known: bigger)
        #expect(back.order.contains("n") && back.order.first == "d")
    }
}

@Suite struct IslNavigatorTests {
    private let list: [IslSectionID] = ["a", "b", "c"]

    @Test func nextAndPreviousWrap() {
        #expect(IslNavigator.next(after: "a", in: list) == "b")
        #expect(IslNavigator.next(after: "c", in: list) == "a")
        #expect(IslNavigator.previous(before: "a", in: list) == "c")
        #expect(IslNavigator.previous(before: "c", in: list) == "b")
    }

    @Test func noWrapStaysPut() {
        #expect(IslNavigator.next(after: "c", in: list, wrap: false) == "c")
        #expect(IslNavigator.previous(before: "a", in: list, wrap: false) == "a")
    }

    @Test func unknownCurrentStartsFromTheEdges() {
        #expect(IslNavigator.next(after: "zzz", in: list) == "a")
        #expect(IslNavigator.previous(before: nil, in: list) == "c")
    }

    @Test func emptyListHasNoTarget() {
        #expect(IslNavigator.next(after: "a", in: []) == nil)
        #expect(IslNavigator.start(choice: .last, last: "a", visible: [], activeSection: nil) == nil)
    }

    @Test func singleSectionStaysItself() {
        #expect(IslNavigator.next(after: "a", in: ["a"]) == "a")
    }

    @Test func startLastUsesTheRememberedSection() {
        #expect(IslNavigator.start(choice: .last, last: "c", visible: list, activeSection: "b") == "c")
    }

    @Test func startLastFallsBackToTheFirst() {
        #expect(IslNavigator.start(choice: .last, last: "gone", visible: list, activeSection: nil) == "a")
        #expect(IslNavigator.start(choice: .last, last: nil, visible: list, activeSection: nil) == "a")
    }

    @Test func startAutoPrefersTheActiveSection() {
        #expect(IslNavigator.start(choice: .auto, last: "c", visible: list, activeSection: "b") == "b")
        #expect(IslNavigator.start(choice: .auto, last: "c", visible: list, activeSection: "gone") == "c")
    }

    @Test func startFixedIsHonoredWhenVisible() {
        #expect(IslNavigator.start(choice: .fixed("b"), last: "c", visible: list, activeSection: nil) == "b")
        #expect(IslNavigator.start(choice: .fixed("zzz"), last: "c", visible: list, activeSection: nil) == "c")
    }

    @Test func aDragOverridesEveryStartChoiceWhenTheTargetIsVisible() {
        for c in [IslStartChoice.last, .auto, .fixed("b")] {
            #expect(IslNavigator.start(choice: c, last: "a", visible: list, activeSection: "b", dropTarget: "c") == "c")
        }
    }

    @Test func aDragIgnoresAnInvisibleTarget() {
        #expect(IslNavigator.start(choice: .last, last: "b", visible: list, activeSection: nil, dropTarget: "zzz") == "b")
    }

    @Test func settleKeepsOrReplacesTheCurrent() {
        #expect(IslNavigator.settle(current: "b", visible: list) == "b")
        #expect(IslNavigator.settle(current: "q", visible: list) == "a")
        #expect(IslNavigator.settle(current: nil, visible: []) == nil)
    }
}

@Suite struct IslTabLayoutTests {
    @Test func everythingFitsOnTheLeft() {
        let s = IslTabLayout.split(count: 4, selected: 0, leftWidth: 200, rightWidth: 200, rightReserved: 60)
        #expect(s.left == [0, 1, 2, 3] && s.right.isEmpty && s.overflow.isEmpty)
    }

    @Test func spillsToTheRight() {
        let s = IslTabLayout.split(count: 8, selected: 0, leftWidth: 120, rightWidth: 260, rightReserved: 60)
        #expect(s.left == [0, 1, 2, 3] && s.right == [4, 5, 6, 7] && s.overflow.isEmpty)
    }

    @Test func overflowGoesIntoTheMenu() {
        let s = IslTabLayout.split(count: 9, selected: 0, leftWidth: 120, rightWidth: 150, rightReserved: 60)
        #expect(s.left == [0, 1, 2, 3])
        #expect(s.right == [4, 5])
        #expect(s.overflow == [6, 7, 8])
    }

    @Test func selectedTabInTheOverflowIsPulledForward() {
        let s = IslTabLayout.split(count: 9, selected: 8, leftWidth: 120, rightWidth: 150, rightReserved: 60)
        #expect(s.right.contains(8))
        #expect(!s.overflow.contains(8))
        #expect(Set(s.left + s.right + s.overflow) == Set(0..<9))
    }

    @Test func noRoomAtAllPutsEverythingInTheMenu() {
        let s = IslTabLayout.split(count: 3, selected: 1, leftWidth: 10, rightWidth: 50, rightReserved: 60)
        #expect(s.left.isEmpty && s.right.isEmpty)
        #expect(Set(s.overflow) == [0, 1, 2])
    }

    @Test func emptyInputIsEmpty() {
        let s = IslTabLayout.split(count: 0, selected: nil, leftWidth: 100, rightWidth: 100, rightReserved: 0)
        #expect(s.left.isEmpty && s.right.isEmpty && s.overflow.isEmpty)
    }

    @Test func partitionNeverLosesATab() {
        for count in 0...12 {
            for sel in [nil, 0, count / 2, max(count - 1, 0)] {
                let s = IslTabLayout.split(count: count, selected: sel, leftWidth: 95, rightWidth: 170, rightReserved: 66)
                let all = s.left + s.right + s.overflow
                #expect(Set(all) == Set(0..<count) && all.count == count, "count \(count) selected \(String(describing: sel))")
            }
        }
    }
}

@MainActor
private final class StubSection: IslSection {
    let descriptor: IslSectionDescriptor
    var availability: IslAvailability
    var activities: [IslActivity]
    var onChange: (() -> Void)?
    init(_ id: String, order: Int, available: Bool = true, activities: [IslActivity] = []) {
        descriptor = IslFix.descriptor(id, order: order)
        availability = available ? .available : .unavailable("off")
        self.activities = activities
    }
    func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Suite struct IslRegistryTests {
    @Test func registeringReplacesTheSameId() {
        let r = IslSectionRegistry()
        r.register(StubSection("a", order: 1))
        r.register(StubSection("a", order: 2))
        #expect(r.sections.count == 1 && r.descriptors.first?.defaultOrder == 2)
    }

    @Test func unregisterRemoves() {
        let r = IslSectionRegistry()
        r.register(StubSection("a", order: 1))
        r.unregister("a")
        #expect(r.sections.isEmpty && r.section("a") == nil)
    }

    @Test func orderedFollowsTheLayoutAndHidden() {
        let r = IslSectionRegistry()
        r.register(StubSection("a", order: 1))
        r.register(StubSection("b", order: 2))
        r.register(StubSection("c", order: 3))
        let l = IslLayout(order: ["c", "a", "b"], hidden: ["a"])
        #expect(r.ordered(l).map(\.descriptor.id.rawValue) == ["c", "b"])
    }

    @Test func availableSkipsUnavailableSections() {
        let r = IslSectionRegistry()
        r.register(StubSection("a", order: 1))
        r.register(StubSection("b", order: 2, available: false))
        #expect(r.available(IslLayout()).map(\.descriptor.id.rawValue) == ["a"])
    }

    @Test func activitiesSkipMutedAndUnavailable() {
        let r = IslSectionRegistry()
        r.register(StubSection("a", order: 1, activities: [IslFix.activity("x", "a")]))
        r.register(StubSection("b", order: 2, available: false, activities: [IslFix.activity("y", "b")]))
        r.register(StubSection("c", order: 3, activities: [IslFix.activity("z", "c")]))
        #expect(r.activities(muted: ["c"]).map(\.id) == ["x"])
        #expect(Set(r.activities(muted: []).map(\.id)) == ["x", "z"])
    }

    @Test func protocolDefaultsAreInert() {
        let s = StubSection("a", order: 1)
        #expect(s.id == "a")
        #expect(s.compactLeading(IslFix.activity("x")) == nil && s.compactTrailing(IslFix.activity("x")) == nil && s.peekView(IslFix.activity("x")) == nil)
        #expect(!s.handle(.swipeNext) && s.settingsView == nil)
    }

    @Test func accessoriesAreFilteredBySlotAndActivity() {
        let reg = IslAccessoryRegistry()
        reg.register(IslAccessory(id: "lyrics", slot: .musicBelow, order: 2) { AnyView(EmptyView()) })
        reg.register(IslAccessory(id: "queue", slot: .musicBelow, order: 1, isActive: { false }) { AnyView(EmptyView()) })
        reg.register(IslAccessory(id: "eq", slot: .wingTrailing) { AnyView(EmptyView()) })
        #expect(reg.active(in: .musicBelow).map(\.id) == ["lyrics"])
        #expect(reg.active(in: .wingTrailing).map(\.id) == ["eq"])
        reg.unregister("lyrics")
        #expect(reg.active(in: .musicBelow).isEmpty)
    }

    @Test func accessoriesAreOrdered() {
        let reg = IslAccessoryRegistry()
        reg.register(IslAccessory(id: "b", slot: .musicSide, order: 2) { AnyView(EmptyView()) })
        reg.register(IslAccessory(id: "a", slot: .musicSide, order: 1) { AnyView(EmptyView()) })
        #expect(reg.active(in: .musicSide).map(\.id) == ["a", "b"])
    }

    @Test func coreCatalogIsComplete() {
        let ids = IslCoreSections.descriptors.map(\.id.rawValue)
        #expect(Array(ids.prefix(9)) == ["music", "levels", "shortcuts", "mixer", "clipboard", "shots", "shelf", "stats", "tools"])
        #expect(Array(ids.dropFirst(9)) == IslExtModules.descriptors.map(\.id.rawValue))
        #expect(Set(ids).count == ids.count)
        #expect(IslCoreSections.descriptors.map(\.defaultOrder) == IslCoreSections.descriptors.map(\.defaultOrder).sorted())
        for d in IslCoreSections.descriptors {
            #expect(!d.title.isEmpty && !d.symbol.isEmpty && !d.summary.isEmpty)
            #expect(d.id.rawValue.allSatisfy { $0.isASCII })
        }
    }

    @Test func moduleDependentSectionsPointAtExistingModules() {
        for d in IslCoreSections.descriptors { if let m = d.module { #expect(ModuleID.allCases.contains(m)) } }
        #expect(IslCoreSections.descriptors.first { $0.id == IslSectionIDs.mixer }?.module == .mixer)
    }
}
