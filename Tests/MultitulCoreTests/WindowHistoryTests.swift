import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func r(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 100) }
private func record(_ pressed: WindowLayoutAction, _ effective: WindowLayoutAction, _ f: CGRect = r(0)) -> WindowRecord {
    WindowRecord(pressed: pressed, effective: effective, requested: f, actual: f, displayID: 1)
}

@Suite struct WindowHistoryTests {
    @Test func originalsAreRestoredNewestFirst() {
        var h = WindowHistory()
        h.pushOriginal(r(10), for: 1)
        h.pushOriginal(r(500), for: 1)
        #expect(h.popOriginal(for: 1) == r(500))
        #expect(h.popOriginal(for: 1) == r(10))
        #expect(h.popOriginal(for: 1) == nil)
    }

    @Test func pushingTheSameFrameTwiceKeepsOneEntry() {
        var h = WindowHistory()
        h.pushOriginal(r(10), for: 1)
        h.pushOriginal(r(10.4), for: 1)
        #expect(h.originalCount(for: 1) == 1)
    }

    @Test func historyIsPerWindow() {
        var h = WindowHistory()
        h.pushOriginal(r(10), for: 1)
        h.pushOriginal(r(20), for: 2)
        #expect(h.popOriginal(for: 2) == r(20))
        #expect(h.peekOriginal(for: 1) == r(10))
    }

    @Test func perWindowLimitDropsTheOldest() {
        var h = WindowHistory()
        for i in 0..<30 { h.pushOriginal(r(CGFloat(i) * 10), for: 1) }
        #expect(h.originalCount(for: 1) == WindowHistory.perWindowLimit)
        #expect(h.peekOriginal(for: 1) == r(290))
    }

    @Test func windowLimitEvictsTheLeastRecentlyUsed() {
        var h = WindowHistory()
        for k in 0..<(WindowHistory.windowLimit + 5) { h.pushOriginal(r(CGFloat(k)), for: k) }
        #expect(h.trackedWindows == WindowHistory.windowLimit)
        #expect(h.peekOriginal(for: 0) == nil)
        #expect(h.peekOriginal(for: WindowHistory.windowLimit + 4) != nil)
    }

    @Test func touchingAWindowKeepsItAlive() {
        var h = WindowHistory()
        h.pushOriginal(r(1), for: 0)
        for k in 1..<WindowHistory.windowLimit { h.pushOriginal(r(CGFloat(k) + 1), for: k) }
        h.setRecord(record(.leftHalf, .leftHalf), for: 0)
        h.pushOriginal(r(900), for: 999)
        #expect(h.peekOriginal(for: 0) != nil)
        #expect(h.peekOriginal(for: 1) == nil)
    }

    @Test func recordContinuesWhileTheWindowSitsWhereItWasLeft() {
        var h = WindowHistory()
        h.setRecord(record(.leftHalf, .leftHalf, r(0)), for: 1)
        #expect(h.continuing(r(0), for: 1) != nil)
        #expect(h.continuing(r(6), for: 1) != nil)
    }

    @Test func recordStopsWhenTheWindowWasMovedByHand() {
        var h = WindowHistory()
        h.setRecord(record(.leftHalf, .leftHalf, r(0)), for: 1)
        #expect(h.continuing(r(200), for: 1) == nil)
    }

    @Test func recordMatchesEitherTheRequestedOrTheActualFrame() {
        var h = WindowHistory()
        h.setRecord(WindowRecord(pressed: .leftHalf, effective: .leftHalf, requested: r(0), actual: r(300), displayID: 1), for: 1)
        #expect(h.continuing(r(0), for: 1) != nil)
        #expect(h.continuing(r(300), for: 1) != nil)
        #expect(h.continuing(r(150), for: 1) == nil)
    }

    @Test func forgetClearsEverything() {
        var h = WindowHistory()
        h.pushOriginal(r(1), for: 1)
        h.setRecord(record(.leftHalf, .leftHalf), for: 1)
        h.forget(1)
        #expect(h.record(for: 1) == nil && h.peekOriginal(for: 1) == nil && h.trackedWindows == 0)
    }

    @Test func clearRecordKeepsOriginals() {
        var h = WindowHistory()
        h.pushOriginal(r(1), for: 1)
        h.setRecord(record(.leftHalf, .leftHalf), for: 1)
        h.clearRecord(for: 1)
        #expect(h.record(for: 1) == nil && h.originalCount(for: 1) == 1)
    }
}

@Suite struct WindowLayoutPlannerTests {
    @Test func firstPressPlacesTheRequestedAction() {
        #expect(WindowLayoutPlanner.resolve(.leftHalf, record: nil, mode: .cycleSizes) == .place(.leftHalf))
    }

    @Test func cycleGoesHalfTwoThirdsThirdHalf() {
        var effective = WindowLayoutAction.leftHalf
        var seen = [effective]
        for _ in 0..<3 {
            guard case .place(let next) = WindowLayoutPlanner.resolve(.leftHalf, record: record(.leftHalf, effective), mode: .cycleSizes) else { Issue.record("not place"); return }
            effective = next
            seen.append(next)
        }
        #expect(seen == [.leftHalf, .leftTwoThirds, .leftThird, .leftHalf])
    }

    @Test func rightTopAndBottomCycleToo() {
        #expect(WindowLayoutPlanner.resolve(.rightHalf, record: record(.rightHalf, .rightHalf), mode: .cycleSizes) == .place(.rightTwoThirds))
        #expect(WindowLayoutPlanner.resolve(.topHalf, record: record(.topHalf, .topTwoThirds), mode: .cycleSizes) == .place(.topThird))
        #expect(WindowLayoutPlanner.resolve(.bottomHalf, record: record(.bottomHalf, .bottomThird), mode: .cycleSizes) == .place(.bottomHalf))
    }

    @Test func aDifferentKeyStartsOver() {
        #expect(WindowLayoutPlanner.resolve(.rightHalf, record: record(.leftHalf, .leftTwoThirds), mode: .cycleSizes) == .place(.rightHalf))
    }

    @Test func nonCyclingActionsAreNotCycled() {
        #expect(WindowLayoutPlanner.resolve(.maximize, record: record(.maximize, .maximize), mode: .cycleSizes) == .place(.maximize))
        #expect(WindowLayoutPlanner.resolve(.topLeft, record: record(.topLeft, .topLeft), mode: .cycleSizes) == .place(.topLeft))
    }

    @Test func modeNoneNeverChangesTheAction() {
        #expect(WindowLayoutPlanner.resolve(.leftHalf, record: record(.leftHalf, .leftHalf), mode: .none) == .place(.leftHalf))
    }

    @Test func crossDisplayMirrorsTheHalf() {
        #expect(WindowLayoutPlanner.resolve(.leftHalf, record: record(.leftHalf, .leftHalf), mode: .crossDisplay) == .cross(.rightHalf, .left))
        #expect(WindowLayoutPlanner.resolve(.rightHalf, record: record(.rightHalf, .rightHalf), mode: .crossDisplay) == .cross(.leftHalf, .right))
        #expect(WindowLayoutPlanner.resolve(.topHalf, record: record(.topHalf, .topHalf), mode: .crossDisplay) == .cross(.bottomHalf, .up))
        #expect(WindowLayoutPlanner.resolve(.bottomHalf, record: record(.bottomHalf, .bottomHalf), mode: .crossDisplay) == .cross(.topHalf, .down))
    }

    @Test func crossDisplayIgnoresOtherActions() {
        #expect(WindowLayoutPlanner.resolve(.topLeft, record: record(.topLeft, .topLeft), mode: .crossDisplay) == .place(.topLeft))
    }

    @Test func effectiveOutsideTheChainRestartsAtTheFirstStep() {
        #expect(WindowLayoutPlanner.resolve(.leftHalf, record: record(.leftHalf, .maximize), mode: .cycleSizes) == .place(.leftHalf))
    }
}
