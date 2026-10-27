import Testing
import Foundation
@testable import MultitulCore

private func near(_ a: Double?, _ b: Double, _ e: Double = 1e-9) -> Bool { a.map { abs($0 - b) < e } ?? false }

@Suite struct RecTimelineTests {
    @Test func startsAsOneIdentitySegment() {
        let t = RecTimeline(sourceDuration: 20)
        #expect(t.segments.count == 1 && t.isIdentity && t.outputDuration == 20 && t.cutRanges.isEmpty)
    }

    @Test func invalidDurationGivesEmptyTimeline() {
        #expect(RecTimeline(sourceDuration: .nan).segments.isEmpty)
        #expect(RecTimeline(sourceDuration: -4).segments.isEmpty)
        #expect(RecTimeline(sourceDuration: 0).outputDuration == 0)
    }

    @Test func cutRemovesTheMiddle() {
        var t = RecTimeline(sourceDuration: 20)
        let h1 = t.cut(from: 5, to: 8)
        #expect(h1)
        #expect(t.segments.map(\.srcStart) == [0, 8] && t.segments.map(\.srcEnd) == [5, 20] && near(t.outputDuration, 17))
        #expect(t.cutRanges == [5...8])
    }

    @Test func cutWorksWithReversedArguments() {
        var t = RecTimeline(sourceDuration: 20)
        let h2 = t.cut(from: 8, to: 5)
        #expect(h2 && near(t.outputDuration, 17))
    }

    @Test func cutIsClampedToTheSource() {
        var t = RecTimeline(sourceDuration: 20)
        let h3 = t.cut(from: 15, to: 99)
        #expect(h3)
        #expect(near(t.outputDuration, 15) && t.segments.count == 1)
    }

    @Test func cutOfTheWholeClipIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        let before = t
        let h4 = t.cut(from: 0, to: 20)
        #expect(!h4)
        #expect(t == before)
    }

    @Test func cutOfAnAlreadyCutRangeChangesNothing() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        let h5 = t.cut(from: 5.5, to: 7.5)
        #expect(!h5)
    }

    @Test func overlappingCutsMerge() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        t.cut(from: 7, to: 10)
        #expect(t.cutRanges == [5...10] && t.segments.count == 2)
    }

    @Test func degenerateCutIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        let h6 = t.cut(from: 5, to: 5)
        #expect(!h6)
    }

    @Test func trimKeepsOnlyTheRange() {
        var t = RecTimeline(sourceDuration: 20)
        let h7 = t.trim(from: 2, to: 12)
        #expect(h7)
        #expect(t.segments.count == 1 && near(t.outputDuration, 10) && t.cutRanges == [0...2, 12...20])
    }

    @Test func trimTooShortIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        let h8 = t.trim(from: 5, to: 5.01)
        #expect(!h8)
        #expect(t.isIdentity)
    }

    @Test func trimAfterCutKeepsTheGap() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        t.trim(from: 3, to: 15)
        #expect(t.segments.map(\.srcStart) == [3, 8] && t.segments.map(\.srcEnd) == [5, 15] && near(t.outputDuration, 9))
    }

    @Test func fullRangeTrimIsANoOp() {
        var t = RecTimeline(sourceDuration: 20)
        let h9 = t.trim(from: 0, to: 20)
        #expect(!h9)
    }

    @Test func speedSplitsAndRescalesOutput() {
        var t = RecTimeline(sourceDuration: 20)
        let h10 = t.setSpeed(from: 4, to: 8, speed: 2)
        #expect(h10)
        #expect(t.segments.count == 3 && t.segments[1].speed == 2 && near(t.outputDuration, 18) && t.hasSpeedChanges)
    }

    @Test func slowMotionLengthensOutput() {
        var t = RecTimeline(sourceDuration: 10)
        t.setSpeed(from: 0, to: 10, speed: 0.5)
        #expect(near(t.outputDuration, 20))
    }

    @Test func speedIsClamped() {
        var t = RecTimeline(sourceDuration: 10)
        t.setSpeed(from: 0, to: 5, speed: 500)
        #expect(t.segments[0].speed == 32)
        t.setSpeed(from: 0, to: 5, speed: 0.001)
        #expect(t.segments[0].speed == 0.1)
    }

    @Test func restoringSpeedMergesSegmentsBack() {
        var t = RecTimeline(sourceDuration: 20)
        t.setSpeed(from: 4, to: 8, speed: 2)
        t.setSpeed(from: 4, to: 8, speed: 1)
        #expect(t.isIdentity)
    }

    @Test func speedOverACutRangeAffectsOnlyKeptParts() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        let h11 = t.setSpeed(from: 4, to: 9, speed: 2)
        #expect(h11)
        #expect(near(t.outputDuration, 16))
        #expect(t.cutRanges == [5...8])
    }

    @Test func speedOverCutOnlyRangeIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        let h12 = t.setSpeed(from: 5.5, to: 7.5, speed: 2)
        #expect(!h12)
    }

    @Test func splitAddsABoundaryWithoutChangingLength() {
        var t = RecTimeline(sourceDuration: 20)
        let h13 = t.split(at: 10)
        #expect(h13)
        #expect(t.segments.count == 2 && t.outputDuration == 20)
    }

    @Test func splitNearEdgesIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        let h14 = t.split(at: 0.02)
        let h15 = t.split(at: 19.99)
        let h16 = t.split(at: 0)
        let h17 = t.split(at: 30)
        #expect(!h14 && !h15 && !h16 && !h17)
    }

    @Test func splitSegmentsHaveUniqueIDs() {
        var t = RecTimeline(sourceDuration: 20)
        for x in [3.0, 6, 9, 12] { t.split(at: x) }
        #expect(Set(t.segments.map(\.id)).count == t.segments.count)
    }

    @Test func splitThenSpeedOnOneHalf() {
        var t = RecTimeline(sourceDuration: 20)
        t.split(at: 10)
        let id = t.segments[1].id
        let h18 = t.setSpeed(segmentID: id, speed: 4)
        #expect(h18)
        #expect(near(t.outputDuration, 12.5))
    }

    @Test func removeSegmentByID() {
        var t = RecTimeline(sourceDuration: 20)
        t.split(at: 10)
        let id = t.segments[0].id
        let h19 = t.remove(segmentID: id)
        #expect(h19 && t.segments.count == 1 && t.cutRanges == [0...10])
    }

    @Test func removeLastSegmentIsRefused() {
        var t = RecTimeline(sourceDuration: 20)
        let h20 = t.remove(segmentID: t.segments[0].id)
        #expect(!h20)
        let h21 = t.remove(segmentID: 999)
        #expect(!h21)
    }

    @Test func sourceToOutputMapsKeptTimes() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        #expect(near(t.sourceToOutput(4), 4) && near(t.sourceToOutput(9), 6) && t.sourceToOutput(6) == nil)
        #expect(near(t.sourceToOutput(5), 5) && near(t.sourceToOutput(8), 5))
    }

    @Test func outputToSourceSkipsTheCut() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        #expect(near(t.outputToSource(4.5), 4.5) && near(t.outputToSource(5.5), 8.5) && near(t.outputToSource(17), 20))
        #expect(near(t.outputToSource(-3), 0) && near(t.outputToSource(99), 20))
    }

    @Test func speedMappingBothWays() {
        var t = RecTimeline(sourceDuration: 20)
        t.setSpeed(from: 4, to: 8, speed: 2)
        #expect(near(t.sourceToOutput(6), 5) && near(t.outputToSource(5), 6) && near(t.sourceToOutput(10), 4 + 2 + 2))
    }

    @Test func mappingRoundTripsOnAComplexTimeline() {
        var t = RecTimeline(sourceDuration: 60)
        t.cut(from: 10, to: 14)
        t.setSpeed(from: 20, to: 30, speed: 4)
        t.setSpeed(from: 40, to: 45, speed: 0.5)
        t.trim(from: 2, to: 55)
        let d = t.outputDuration
        for i in 0...200 {
            let o = d * Double(i) / 200
            #expect(near(t.sourceToOutput(t.outputToSource(o)), o, 1e-7))
        }
    }

    @Test func outputDurationEqualsSumOfSegments() {
        var t = RecTimeline(sourceDuration: 60)
        t.setSpeed(from: 0, to: 30, speed: 2)
        t.cut(from: 40, to: 50)
        #expect(near(t.outputDuration, 15 + 10 + 10))
        #expect(near(t.keptDuration, 50))
    }

    @Test func snapToKeptPicksTheNearerEdge() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        #expect(near(t.snapToKept(source: 6), 5) && near(t.snapToKept(source: 7.5), 8) && near(t.snapToKept(source: 12), 12))
    }

    @Test func segmentLookups() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        #expect(t.segmentIndex(atSource: 3) == 0 && t.segmentIndex(atSource: 10) == 1 && t.segmentIndex(atSource: 6) == nil)
        #expect(t.segmentIndex(atOutput: 2) == 0 && t.segmentIndex(atOutput: 6) == 1 && t.segmentIndex(atOutput: 17) == 1)
        #expect(t.isKept(source: 4) && !t.isKept(source: 6))
    }

    @Test func outputStartOfSegments() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        #expect(t.outputStart(ofIndex: 0) == 0 && near(t.outputStart(ofIndex: 1), 5) && near(t.outputStart(ofIndex: 9), 17))
    }

    @Test func resetRestoresIdentity() {
        var t = RecTimeline(sourceDuration: 20)
        t.cut(from: 5, to: 8)
        t.setSpeed(from: 0, to: 3, speed: 3)
        t.reset()
        #expect(t.isIdentity)
    }

    @Test func validationFindsNoIssuesAfterManyEdits() {
        var t = RecTimeline(sourceDuration: 100)
        for i in 0..<20 {
            let a = Double(i * 5)
            if i % 3 == 0 { t.cut(from: a, to: a + 2) } else if i % 3 == 1 { t.setSpeed(from: a, to: a + 3, speed: 1.5) } else { t.split(at: a + 1) }
        }
        #expect(t.validationIssues.isEmpty)
        for s in t.segments { #expect(s.srcEnd > s.srcStart) }
    }

    @Test func codableRoundTripKeepsEverything() throws {
        var t = RecTimeline(sourceDuration: 40)
        t.cut(from: 5, to: 8)
        t.setSpeed(from: 10, to: 20, speed: 2)
        let back = try JSONDecoder().decode(RecTimeline.self, from: try JSONEncoder().encode(t))
        #expect(back == t && near(back.outputDuration, t.outputDuration))
    }
}

@Suite struct RecUndoStackTests {
    @Test func undoAndRedo() {
        var u = RecUndoStack<Int>()
        u.record(before: 1)
        u.record(before: 2)
        let h22 = u.undo(current: 3)
        let h23 = u.undo(current: 2)
        let h24 = u.undo(current: 1)
        #expect(h22 == 2 && h23 == 1 && h24 == nil)
        let h25 = u.redo(current: 1)
        let h26 = u.redo(current: 2)
        let h27 = u.redo(current: 3)
        #expect(h25 == 2 && h26 == 3 && h27 == nil)
    }

    @Test func newEditClearsRedo() {
        var u = RecUndoStack<Int>()
        u.record(before: 1)
        _ = u.undo(current: 2)
        #expect(u.canRedo)
        u.record(before: 5)
        #expect(!u.canRedo)
    }

    @Test func identicalStatesAreNotRecordedTwice() {
        var u = RecUndoStack<Int>()
        u.record(before: 1)
        u.record(before: 1)
        #expect(u.undoStates.count == 1)
    }

    @Test func limitDropsTheOldest() {
        var u = RecUndoStack<Int>(limit: 3)
        for i in 0..<10 { u.record(before: i) }
        #expect(u.undoStates == [7, 8, 9])
    }

    @Test func clearEmptiesBothStacks() {
        var u = RecUndoStack<Int>()
        u.record(before: 1)
        _ = u.undo(current: 2)
        u.clear()
        #expect(!u.canUndo && !u.canRedo)
    }
}
