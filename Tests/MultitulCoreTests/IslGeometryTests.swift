import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct IslNotchDetectionTests {
    @Test func hardwareNotchIsFoundFromTheAuxiliaryAreas() throws {
        let r = try #require(IslNotchDetector.hardwareNotchRect(IslFix.notchScreen))
        #expect(r.width == 185)
        #expect(r.height == 38)
        #expect(r.minX == 762.5)
        #expect(r.maxY == 1107)
    }

    @Test func noSafeAreaMeansNoHardwareNotch() {
        #expect(IslNotchDetector.hardwareNotchRect(IslFix.externalScreen) == nil)
        #expect(!IslNotchDetector.hasHardwareNotch(IslFix.leftScreen))
    }

    @Test func missingAuxAreaIsNotANotch() {
        var s = IslFix.notchScreen
        s.auxRightWidth = nil
        #expect(IslNotchDetector.hardwareNotchRect(s) == nil)
        s.auxRightWidth = 0
        #expect(IslNotchDetector.hardwareNotchRect(s) == nil)
    }

    @Test func absurdWidthsAreRejected() {
        var s = IslFix.notchScreen
        s.auxLeftWidth = 850
        s.auxRightWidth = 850
        #expect(IslNotchDetector.hardwareNotchRect(s) == nil)
        s.auxLeftWidth = 100
        s.auxRightWidth = 100
        #expect(IslNotchDetector.hardwareNotchRect(s) == nil)
    }

    @Test func notchOnASecondaryScreenKeepsItsOrigin() throws {
        var s = IslFix.notchScreen
        s.frame = CGRect(x: 2000, y: -300, width: 1710, height: 1107)
        let r = try #require(IslNotchDetector.hardwareNotchRect(s))
        #expect(r.minX == 2762.5)
        #expect(r.maxY == 807)
    }

    @Test func menuBarHeightPrefersTheSafeArea() {
        #expect(IslNotchDetector.menuBarHeight(IslFix.notchScreen) == 38)
    }

    @Test func menuBarHeightIsMeasuredFromTheVisibleFrame() {
        #expect(IslNotchDetector.menuBarHeight(IslFix.externalScreen) == 24)
    }

    @Test func menuBarHeightFallsBackWhenTheBarIsHidden() {
        var s = IslFix.externalScreen
        s.visibleFrame = s.frame
        #expect(IslNotchDetector.menuBarHeight(s) == IslNotchDetector.defaultMenuBarHeight)
        s.visibleFrame = CGRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: s.frame.height - 200)
        #expect(IslNotchDetector.menuBarHeight(s) == IslNotchDetector.defaultMenuBarHeight)
    }

    @Test func virtualPillSitsInTheTopCenter() {
        let n = IslNotchDetector.notch(for: IslFix.externalScreen)
        #expect(!n.isHardware)
        #expect(n.rect.midX == IslFix.externalScreen.frame.midX)
        #expect(n.rect.maxY == IslFix.externalScreen.frame.maxY)
        #expect(n.rect.width == IslNotchDetector.pillWidth)
        #expect(n.rect.height == 24)
    }

    @Test func virtualPillHeightIsClamped() {
        var s = IslFix.externalScreen
        s.visibleFrame = CGRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: s.frame.height - 50)
        #expect(IslNotchDetector.notch(for: s).rect.height == IslNotchDetector.pillHeightRange.upperBound)
    }

    @Test func hardwareNotchReportsItself() {
        let n = IslNotchDetector.notch(for: IslFix.notchScreen)
        #expect(n.isHardware)
        #expect(n.rect.height == 38)
    }

    @Test func pillOnANegativeOriginScreenIsCentered() {
        let n = IslNotchDetector.notch(for: IslFix.leftScreen)
        #expect(n.rect.midX == -960)
        #expect(n.rect.maxY == 1080)
    }
}

@Suite struct IslFramesTests {
    private func frames(_ s: IslScreenInfo, _ p: IslSizePreset = .standard, wings: IslWings = .zero) -> IslFrames {
        IslLayoutMath.frames(screen: s, notch: IslNotchDetector.notch(for: s), preset: p, wings: wings)
    }

    @Test func closedFrameIsTheNotchWithoutWings() {
        let f = frames(IslFix.notchScreen)
        #expect(f.closed == f.notch)
    }

    @Test func everyFrameHangsFromTheTopEdge() {
        for s in IslFix.all {
            let f = frames(s)
            for st in IslState.allCases { #expect(f.frame(for: st).maxY == s.frame.maxY, "\(s.name) \(st)") }
        }
    }

    @Test func openAndPeekAreCenteredOnTheNotch() {
        let f = frames(IslFix.notchScreen)
        #expect(f.open.midX == f.notch.midX)
        #expect(f.peek.midX == f.notch.midX)
    }

    @Test func sizesGrowFromClosedToPeekToOpen() {
        for s in IslFix.all {
            let f = frames(s)
            #expect(f.closed.width < f.peek.width)
            #expect(f.peek.width <= f.open.width)
            #expect(f.closed.height < f.peek.height)
            #expect(f.peek.height < f.open.height)
        }
    }

    @Test func presetsChangeTheOpenSize() {
        let c = frames(IslFix.notchScreen, .compact).open.size
        let s = frames(IslFix.notchScreen, .standard).open.size
        let x = frames(IslFix.notchScreen, .spacious).open.size
        #expect(c.width < s.width && s.width < x.width)
        #expect(c.height < s.height && s.height < x.height)
    }

    @Test func standardOpenSizeMatchesThePreset() {
        let f = frames(IslFix.notchScreen)
        #expect(f.open.size == IslSizePreset.standard.openSize)
    }

    @Test func peekHeightAddsTheExtraStripToTheNotch() {
        let f = frames(IslFix.notchScreen)
        #expect(f.peek.height == 38 + IslLayoutMath.peekExtraHeight)
    }

    @Test func wingsWidenTheClosedFrameAroundTheNotch() {
        let f = frames(IslFix.notchScreen, wings: IslWings(left: 54, right: 30))
        #expect(f.closed.minX == f.notch.minX - 54)
        #expect(f.closed.maxX == f.notch.maxX + 30)
        #expect(f.closed.height == f.notch.height)
    }

    @Test func negativeWingsAreIgnored() {
        let f = frames(IslFix.notchScreen, wings: IslWings(left: -10, right: -3))
        #expect(f.closed == f.notch)
    }

    @Test func openNeverLeavesTheScreen() {
        var s = IslFix.externalScreen
        s.frame = CGRect(x: 0, y: 0, width: 500, height: 800)
        s.visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 776)
        let f = frames(s, .spacious)
        #expect(f.open.minX >= s.frame.minX && f.open.maxX <= s.frame.maxX)
    }

    @Test func screenOnTheLeftKeepsNegativeCoordinates() {
        let f = frames(IslFix.leftScreen)
        #expect(f.open.minX >= -1920 && f.open.maxX <= 0)
        #expect(f.closed.midX == -960)
    }

    @Test func wingsAreClampedInsideTheScreen() {
        var s = IslFix.notchScreen
        s.auxLeftWidth = 90
        s.auxRightWidth = 1435
        let f = frames(s, wings: IslWings(left: 400, right: 0))
        #expect(f.closed.minX >= s.frame.minX)
    }

    @Test func frameForStateReturnsTheMatchingRect() {
        let f = frames(IslFix.notchScreen)
        #expect(f.frame(for: .closed) == f.closed)
        #expect(f.frame(for: .peek) == f.peek)
        #expect(f.frame(for: .open) == f.open)
    }

    @Test func menuBarHeightDoesNotChangeTheOpenFrame() {
        let a = frames(IslFix.externalScreen)
        var s = IslFix.externalScreen
        s.visibleFrame = CGRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: s.frame.height - 30)
        let b = frames(s)
        #expect(a.open.width == b.open.width)
        #expect(b.closed.height >= a.closed.height)
    }

    @Test func scaleDoesNotAffectPointGeometry() {
        var s = IslFix.notchScreen
        let a = frames(s)
        s.scale = 1
        #expect(frames(s) == a)
    }
}

@Suite struct IslMenuClearanceTests {
    private let notch = CGRect(x: 762.5, y: 1069, width: 185, height: 38)

    @Test func unknownClearanceGivesFullWings() {
        let w = IslMenuClearance.unknown.wings(notch: notch)
        #expect(w == IslWings(left: IslLayoutMath.desiredWing, right: IslLayoutMath.desiredWing))
    }

    @Test func plentyOfRoomKeepsTheDesiredWing() {
        let w = IslMenuClearance(appMenuMaxX: 300, statusItemsMinX: 1300).wings(notch: notch)
        #expect(w.left == IslLayoutMath.desiredWing && w.right == IslLayoutMath.desiredWing)
    }

    @Test func tightMenuShrinksTheLeftWing() {
        let w = IslMenuClearance(appMenuMaxX: 710).wings(notch: notch)
        #expect(w.left > 0 && w.left < IslLayoutMath.desiredWing)
        #expect(w.left == 762.5 - (710 + IslLayoutMath.wingPadding))
    }

    @Test func menuReachingTheNotchRemovesTheWing() {
        let w = IslMenuClearance(appMenuMaxX: 750).wings(notch: notch)
        #expect(w.left == 0)
        #expect(w.right == IslLayoutMath.desiredWing)
    }

    @Test func wingsBelowTheUsefulMinimumCollapse() {
        let w = IslMenuClearance(appMenuMaxX: 762.5 - 8 - 20).wings(notch: notch)
        #expect(w.left == 0)
    }

    @Test func rightSideIsLimitedByTheStatusItems() {
        let w = IslMenuClearance(appMenuMaxX: nil, statusItemsMinX: 947.5 + 8 + 40).wings(notch: notch)
        #expect(w.right == 40)
    }

    @Test func disablingAvoidanceIgnoresTheMeasurements() {
        let w = IslMenuClearance(appMenuMaxX: 760, statusItemsMinX: 950).wings(notch: notch, enabled: false)
        #expect(w.left == IslLayoutMath.desiredWing && w.right == IslLayoutMath.desiredWing)
    }

    @Test func measurementsFromAnotherScreenAreDropped() {
        let c = IslMenuClearance(appMenuMaxX: 300, statusItemsMinX: 2000)
        let local = c.localized(to: CGRect(x: 0, y: 0, width: 1710, height: 1107))
        #expect(local.appMenuMaxX == 300 && local.statusItemsMinX == nil)
        let other = c.localized(to: CGRect(x: 1710, y: 0, width: 2560, height: 1440))
        #expect(other.appMenuMaxX == nil && other.statusItemsMinX == 2000)
    }

    @Test func droppedMeasurementsFallBackToFullWings() {
        let w = IslMenuClearance(appMenuMaxX: 300).localized(to: CGRect(x: 1710, y: 0, width: 2560, height: 1440)).wings(notch: notch)
        #expect(w.left == IslLayoutMath.desiredWing)
    }

    @Test func menuBeyondTheNotchNeverGivesNegativeWings() {
        let w = IslMenuClearance(appMenuMaxX: 1500, statusItemsMinX: 100).wings(notch: notch)
        #expect(w == .zero)
        #expect(w.isEmpty)
    }
}

@Suite struct IslHoverZoneTests {
    private let f = IslLayoutMath.frames(screen: IslFix.notchScreen, notch: IslNotchDetector.notch(for: IslFix.notchScreen), preset: .standard)

    @Test func closedTriggerCoversTheNotchAndTheTopEdge() {
        #expect(IslHoverZone.contains(CGPoint(x: f.notch.midX, y: f.notch.midY), state: .closed, frames: f))
        #expect(IslHoverZone.contains(CGPoint(x: f.notch.midX, y: 1107), state: .closed, frames: f))
    }

    @Test func closedTriggerIsTight() {
        #expect(!IslHoverZone.contains(CGPoint(x: f.notch.minX - 20, y: f.notch.midY), state: .closed, frames: f))
        #expect(!IslHoverZone.contains(CGPoint(x: f.notch.midX, y: f.notch.minY - 20), state: .closed, frames: f))
    }

    @Test func closedTriggerHasASmallSlop() {
        #expect(IslHoverZone.contains(CGPoint(x: f.notch.minX - 2, y: f.notch.midY), state: .closed, frames: f))
    }

    @Test func openZoneIsTheOpenFrameWithTolerance() {
        #expect(IslHoverZone.contains(CGPoint(x: f.open.minX + 5, y: f.open.minY + 5), state: .open, frames: f))
        #expect(IslHoverZone.contains(CGPoint(x: f.open.minX - 4, y: f.open.midY), state: .open, frames: f))
        #expect(!IslHoverZone.contains(CGPoint(x: f.open.minX - 30, y: f.open.midY), state: .open, frames: f))
        #expect(!IslHoverZone.contains(CGPoint(x: f.open.midX, y: f.open.minY - 30), state: .open, frames: f))
    }

    @Test func peekZoneIsNarrowerThanOpen() {
        let p = CGPoint(x: f.open.minX + 10, y: f.open.maxY - 10)
        #expect(IslHoverZone.contains(p, state: .open, frames: f))
        #expect(!IslHoverZone.contains(p, state: .peek, frames: f))
    }

    @Test func wingsExtendTheTriggerZone() {
        let w = IslLayoutMath.frames(screen: IslFix.notchScreen, notch: IslNotchDetector.notch(for: IslFix.notchScreen), preset: .standard, wings: IslWings(left: 54, right: 54))
        #expect(IslHoverZone.contains(CGPoint(x: w.notch.minX - 40, y: w.notch.midY), state: .closed, frames: w))
    }

    @Test func zoneClassifiesTheTopRowOfAnOpenIsland() {
        let top = CGPoint(x: f.open.minX + 30, y: f.open.maxY - 10)
        let body = CGPoint(x: f.open.minX + 30, y: f.open.minY + 40)
        #expect(IslGestureZone.zone(for: top, state: .open, frames: f) == .topRow)
        #expect(IslGestureZone.zone(for: body, state: .open, frames: f) == .body)
        #expect(IslGestureZone.zone(for: top, state: .closed, frames: f) == .notch)
    }
}

@Suite struct IslDisplaySelectionTests {
    @Test func allModeKeepsNotchAndPillScreens() {
        let r = IslDisplaySelector.select(IslFix.all, mode: .all, selected: [], virtualPill: true)
        #expect(r.map(\.id) == [1, 2, 3])
    }

    @Test func pillOffDropsScreensWithoutANotch() {
        let r = IslDisplaySelector.select(IslFix.all, mode: .all, selected: [], virtualPill: false)
        #expect(r.map(\.id) == [1])
    }

    @Test func builtinMode() {
        #expect(IslDisplaySelector.select(IslFix.all, mode: .builtin, selected: [], virtualPill: true).map(\.id) == [1])
    }

    @Test func mainMode() {
        #expect(IslDisplaySelector.select(IslFix.all, mode: .main, selected: [], virtualPill: true).map(\.id) == [1])
    }

    @Test func selectedModeUsesStableKeys() {
        let r = IslDisplaySelector.select(IslFix.all, mode: .selected, selected: ["0610-a001-00000001"], virtualPill: true)
        #expect(r.map(\.id) == [2])
    }

    @Test func selectedModeWithNothingSelectedIsEmpty() {
        #expect(IslDisplaySelector.select(IslFix.all, mode: .selected, selected: [], virtualPill: true).isEmpty)
    }

    @Test func selectedPillScreenNeedsThePillOption() {
        #expect(IslDisplaySelector.select(IslFix.all, mode: .selected, selected: ["left"], virtualPill: false).isEmpty)
    }

    @Test func modeTitlesAreFilled() {
        for m in IslDisplayMode.allCases { #expect(!m.title.isEmpty) }
    }
}

@Suite struct IslConflictTests {
    private typealias App = (bundleID: String, name: String, pid: Int32)

    @Test func atollIsFoundByBundleOrName() {
        let r = IslConflictDetector.find(running: [("com.ebullioscopic.Atoll", "Atoll", 10), ("com.apple.finder", "Finder", 11)])
        #expect(r == [IslConflict(app: .atoll, bundleID: "com.ebullioscopic.Atoll", pid: 10)])
    }

    @Test func nameAloneIsEnough() {
        let r = IslConflictDetector.find(running: [("org.example.x", "Atoll", 5)])
        #expect(r.first?.app == .atoll)
    }

    @Test func otherNotchAppsAreRecognised() {
        let r = IslConflictDetector.find(running: [("com.theboringteam.boringnotch", "boringNotch", 1), ("lo.cafe.NotchNook", "NotchNook", 2), ("com.example.notchapp", "Example", 3)], extraBundleIDs: ["com.example.notchapp"])
        #expect(Set(r.map(\.app)) == [.boringNotch, .notchNook, .custom])
    }

    @Test func ownBundleIsIgnored() {
        #expect(IslConflictDetector.find(running: [("dev.multitool.app", "Мультитул", 1)]).isEmpty)
    }

    @Test func unrelatedAppsAreIgnored() {
        #expect(IslConflictDetector.find(running: [("com.apple.Safari", "Safari", 1), ("com.google.Chrome", "Chrome", 2)]).isEmpty)
    }

    @Test func noticeNamesEachAppOnce() throws {
        let c = [IslConflict(app: .atoll, bundleID: "a", pid: 1), IslConflict(app: .atoll, bundleID: "a2", pid: 2)]
        let n = try #require(IslConflictDetector.notice(c))
        #expect(n.contains("Atoll"))
        #expect(n.components(separatedBy: "Atoll").count == 2)
        #expect(IslConflictDetector.notice([]) == nil)
    }
}
