import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let info = RecSourceInfo(width: 2880, height: 1800, duration: 60, fps: 30, scale: 2, hasSystemAudio: true, hasMicrophone: true)

private func doc() -> RecEditDocument { RecEditDocument(source: info) }

@Suite struct RecNormRectTests {
    @Test func sanitizeKeepsRectInsideUnitSquare() {
        let r = RecNormRect(x: 0.9, y: -1, w: 0.5, h: 2).sanitized
        #expect(r.x == 0.5 && r.y == 0 && r.w == 0.5 && r.h == 1)
    }

    @Test func sanitizeEnforcesMinimumSide() {
        let r = RecNormRect(x: 0.5, y: 0.5, w: 0, h: 0.001).sanitized
        #expect(r.w == RecNormRect.minSide && r.h == RecNormRect.minSide)
    }

    @Test func nonFiniteFallsBackToFull() {
        let r = RecNormRect(x: .nan, y: .infinity, w: .nan, h: .nan).sanitized
        #expect(r.w == 1 && r.h == 1 && r.x == 0)
    }

    @Test func fullDetection() {
        #expect(RecNormRect.full.isFull && !RecNormRect(x: 0.1, y: 0, w: 0.9, h: 1).isFull)
    }
}

@Suite struct RecAudioMixTests {
    @Test func defaultGainIsUnity() {
        let a = RecAudioMix()
        #expect(a.gain(.systemAudio) == 1 && a.gain(.microphone) == 1 && a.gain(.video) == 0)
    }

    @Test func muteZeroesGain() {
        var a = RecAudioMix()
        a.micMuted = true
        #expect(a.gain(.microphone) == 0 && a.gain(.systemAudio) == 1)
    }

    @Test func gainIsClamped() {
        var a = RecAudioMix()
        a.systemVolume = 9
        a.micVolume = -3
        #expect(a.gain(.systemAudio) == 2 && a.gain(.microphone) == 0)
    }
}

@Suite struct RecEditDocumentTests {
    @Test func freshDocumentIsUntouched() {
        #expect(doc().isUntouched && doc().timeline.outputDuration == 60)
    }

    @Test func anyEditMakesItTouched() {
        var d = doc()
        d.timeline.cut(from: 1, to: 2)
        #expect(!d.isUntouched)
        var e = doc()
        e.audio.micMuted = true
        #expect(!e.isUntouched)
    }

    @Test func blurRegionsGetIncreasingIDs() {
        var d = doc()
        let a = d.addBlur(rect: RecNormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1), from: 2, to: 8)
        let b = d.addBlur(rect: RecNormRect(x: 0.5, y: 0.5, w: 0.2, h: 0.1), from: 4, to: 6)
        #expect(a == 1 && b == 2 && d.blurs.count == 2)
        d.removeBlur(id: a)
        #expect(d.blurs.map(\.id) == [2])
    }

    @Test func blurTimesAreNormalized() {
        var d = doc()
        _ = d.addBlur(rect: .full, from: 90, to: -5)
        #expect(d.blurs[0].srcStart == 0 && d.blurs[0].srcEnd == 60)
        _ = d.addBlur(rect: .full, from: 10, to: 10)
        #expect(d.blurs[1].srcEnd >= 10.1)
    }

    @Test func blurActivity() {
        let b = RecBlurRegion(id: 1, rect: .full, srcStart: 2, srcEnd: 4)
        #expect(!b.isActive(at: 1.9) && b.isActive(at: 2) && b.isActive(at: 4) && !b.isActive(at: 4.1))
    }

    @Test func regenerateZoomUsesTheLog() {
        var d = doc()
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.5, y: 0.5), RecInputEvent(t: 40, kind: .down, x: 0.2, y: 0.2)], duration: 60)
        d.regenerateZoom(log: log)
        #expect(d.zoom.spans.count == 2)
        d.zoomEnabled = false
        d.regenerateZoom(log: log)
        #expect(d.zoom.spans.isEmpty)
    }

    @Test func serializationRoundTrip() throws {
        var d = doc()
        d.timeline.cut(from: 5, to: 8)
        d.crop = RecNormRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        d.style.padding = 32
        d.style.background = "gradient:#FF7E5F:#FEB47B:135"
        d.audio.micVolume = 0.4
        _ = d.addBlur(rect: RecNormRect(x: 0.2, y: 0.2, w: 0.1, h: 0.1), from: 1, to: 2)
        let back = try RecEditDocument.decode(try d.encoded())
        #expect(back == d)
    }

    @Test func decodeRejectsNewerVersions() throws {
        var d = doc()
        d.version = 99
        let data = try d.encoded()
        #expect((try? RecEditDocument.decode(data)) == nil)
    }

    @Test func decodeRejectsGarbage() {
        #expect((try? RecEditDocument.decode(Data("{}".utf8))) == nil)
        #expect((try? RecEditDocument.decode(Data())) == nil)
    }

    @Test func decodeSanitizesCropAndStyle() throws {
        var d = doc()
        d.crop = RecNormRect(x: 2, y: 2, w: 9, h: 9)
        d.style.padding = 100_000
        let back = try RecEditDocument.decode(try d.encoded())
        #expect(back.crop.w <= 1 && back.style.padding == 400)
    }

    @Test func encodedKeysAreAscii() throws {
        let data = try doc().encoded()
        let ascii = data.allSatisfy { $0 < 128 }
        #expect(ascii)
    }

    @Test func styleSanitizeFixesBadColorAndRanges() {
        var s = RecFrameStyle()
        s.clickColor = "red"
        s.corner = -5
        s.clickRadius = 9
        let c = s.sanitized
        #expect(c.clickColor == "#FFD60A" && c.corner == 0 && c.clickRadius == 0.15)
    }

    @Test func plainStyleDetection() {
        var s = RecFrameStyle()
        #expect(s.isPlain)
        s.corner = 8
        #expect(!s.isPlain)
    }
}

@Suite struct RecEditSessionTests {
    @Test func editRecordsUndo() {
        var s = RecEditSession(document: doc())
        let ok = s.cut(from: 5, to: 8)
        #expect(ok && s.canUndo && !s.canRedo && s.revision == 1)
    }

    @Test func failedEditIsNotRecorded() {
        var s = RecEditSession(document: doc())
        let ok = s.cut(from: 5, to: 5)
        #expect(!ok && !s.canUndo && s.revision == 0)
    }

    @Test func noOpEditIsNotRecorded() {
        var s = RecEditSession(document: doc())
        let ok = s.setCrop(.full)
        #expect(!ok && !s.canUndo)
    }

    @Test func undoRestoresAndRedoReapplies() {
        var s = RecEditSession(document: doc())
        s.cut(from: 5, to: 8)
        s.setSpeed(from: 10, to: 20, speed: 2)
        let after = s.document
        let h1 = s.undo()
        #expect(h1)
        #expect(s.document.timeline.hasSpeedChanges == false && s.document.timeline.cutRanges == [5...8])
        let h2 = s.undo()
        #expect(h2)
        #expect(s.document.isUntouched)
        let h3 = s.redo()
        let h4 = s.redo()
        #expect(h3 && h4)
        #expect(s.document == after)
    }

    @Test func editAfterUndoDropsRedo() {
        var s = RecEditSession(document: doc())
        s.cut(from: 5, to: 8)
        s.undo()
        s.trim(from: 1, to: 9)
        #expect(!s.canRedo)
    }

    @Test func undoWithNothingToUndo() {
        var s = RecEditSession(document: doc())
        let a = s.undo()
        let b = s.redo()
        #expect(!a && !b)
    }

    @Test func styleAndAudioEditsAreUndoable() {
        var s = RecEditSession(document: doc())
        var st = RecFrameStyle()
        st.padding = 40
        s.setStyle(st)
        var au = RecAudioMix()
        au.systemMuted = true
        s.setAudio(au)
        s.undo()
        #expect(!s.document.audio.systemMuted && s.document.style.padding == 40)
        s.undo()
        #expect(s.document.style.padding == 0)
    }

    @Test func setCropIsSanitized() {
        var s = RecEditSession(document: doc())
        s.setCrop(RecNormRect(x: 0.9, y: 0.9, w: 0.9, h: 0.9))
        #expect(s.document.crop.x + s.document.crop.w <= 1.0000001)
    }

    @Test func hundredEditsStayWithinTheUndoLimit() {
        var s = RecEditSession(document: doc())
        for i in 0..<130 { s.split(at: Double(i) * 0.4 + 0.2) }
        #expect(s.undoStack.undoStates.count <= 100)
    }
}
