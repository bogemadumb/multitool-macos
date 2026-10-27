import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func editor(_ tool: AnnotationTool = .rectangle) -> AnnotationEditor {
    let e = AnnotationEditor(document: AnnotationDocument(canvasWidth: 800, canvasHeight: 600))
    e.tool = tool
    e.measureText = { t, s in CGSize(width: Double(t.count) * s * 0.6, height: s * 1.2) }
    return e
}

private func draw(_ e: AnnotationEditor, _ a: CGPoint, _ b: CGPoint, shift: Bool = false) {
    e.pointerDown(a, shift: shift)
    e.pointerDragged(b, shift: shift)
    e.pointerUp(b, shift: shift)
}

@Suite struct AnnotationHistoryTests {
    private func snap(_ n: Int) -> AnnotationSnapshot { AnnotationSnapshot(items: [], crop: nil, nextID: n) }

    @Test func undoRedoWalkTheStack() {
        var h = AnnotationHistory()
        h.record(before: snap(1))
        h.record(before: snap(2))
        #expect(h.canUndo && !h.canRedo)
        let u = h.undo(current: snap(3))
        #expect(u == snap(2) && h.canRedo)
        #expect(h.redo(current: snap(2)) == snap(3))
    }

    @Test func recordingClearsRedo() {
        var h = AnnotationHistory()
        h.record(before: snap(1))
        _ = h.undo(current: snap(2))
        h.record(before: snap(5))
        #expect(!h.canRedo)
    }

    @Test func limitDropsTheOldest() {
        var h = AnnotationHistory(limit: 3)
        for i in 1...6 { h.record(before: snap(i)) }
        #expect(h.undoStack.count == 3 && h.undoStack.first == snap(4))
    }

    @Test func emptyHistoryReturnsNil() {
        var h = AnnotationHistory()
        #expect(h.undo(current: snap(1)) == nil && h.redo(current: snap(1)) == nil)
        h.record(before: snap(1))
        h.clear()
        #expect(!h.canUndo)
    }
}

@Suite struct AnnotationEditorTests {
    @Test func dragCreatesAShapeAndSelectsIt() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(110, 90))
        #expect(e.document.items.count == 1 && e.document.items[0].points == [pt(10, 10), pt(110, 90)])
        #expect(e.selection == e.document.items[0].id && e.canUndo)
    }

    @Test func tinyDragCreatesNothing() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(11, 11))
        draw(e, pt(10, 10), pt(200, 11))
        #expect(e.document.items.isEmpty && !e.canUndo)
        let line = editor(.line)
        draw(line, pt(10, 10), pt(11, 10))
        #expect(line.document.items.isEmpty)
    }

    @Test func draftIsVisibleWhileDragging() {
        let e = editor(.arrow)
        e.pointerDown(pt(0, 0))
        e.pointerDragged(pt(50, 50))
        #expect(e.draft?.kind == .arrow && e.draft?.points == [pt(0, 0), pt(50, 50)] && e.document.items.isEmpty && e.isDragging)
        e.pointerUp(pt(50, 50))
        #expect(e.draft == nil && !e.isDragging)
    }

    @Test func penCollectsPoints() {
        let e = editor(.pen)
        e.pointerDown(pt(0, 0))
        for i in 1...5 { e.pointerDragged(pt(CGFloat(i) * 5, CGFloat(i * i))) }
        e.pointerUp(pt(25, 25))
        #expect(e.document.items[0].points.count == 6)
    }

    @Test func penClickWithoutMovementCreatesNothing() {
        let e = editor(.pen)
        e.pointerDown(pt(5, 5))
        e.pointerUp(pt(5, 5))
        #expect(e.document.items.isEmpty)
    }

    @Test func highlighterUsesAHalfTransparentColour() {
        let e = editor(.highlighter)
        e.style.color = .yellow
        draw(e, pt(0, 0), pt(100, 0))
        #expect(e.document.items[0].style.color.a == 102)
    }

    @Test func shiftMakesSquaresAndStraightLines() {
        let sq = editor(.rectangle)
        draw(sq, pt(10, 10), pt(110, 60), shift: true)
        #expect(sq.document.items[0].points == [pt(10, 10), pt(110, 110)])
        let ln = editor(.line)
        draw(ln, pt(0, 0), pt(100, 12), shift: true)
        let p = ln.document.items[0].points[1]
        #expect(abs(p.y) < 0.001 && p.x > 99)
    }

    @Test func stepToolPlacesNumberedBadgesOnClick() {
        let e = editor(.step)
        for x in [20, 60, 100] { e.pointerDown(pt(CGFloat(x), 20)); e.pointerUp(pt(CGFloat(x), 20)) }
        #expect(e.document.items.map(\.number) == [1, 2, 3])
        e.undo()
        #expect(e.document.items.count == 2)
    }

    @Test func textToolAsksForTextThenCommits() {
        let e = editor(.text)
        let ev = e.pointerDown(pt(30, 40))
        #expect(ev == .requestText(at: pt(30, 40), editing: nil))
        e.pointerUp(pt(30, 40))
        e.commitText("  Привет  ", at: pt(30, 40))
        let t = e.document.items[0]
        #expect(t.kind == .text && t.text == "Привет" && t.boxSize.width == Double("Привет".count) * 28 * 0.6)
        #expect(e.selection == t.id)
    }

    @Test func emptyTextIsIgnored() {
        let e = editor(.text)
        e.commitText("   ", at: pt(0, 0))
        #expect(e.document.items.isEmpty && !e.canUndo)
    }

    @Test func clickingExistingTextAsksToEditIt() {
        let e = editor(.text)
        e.commitText("abc", at: pt(100, 100))
        let id = e.document.items[0].id
        #expect(e.pointerDown(pt(105, 105)) == .requestText(at: pt(100, 100), editing: id))
        e.editText(id, to: "abcdef")
        #expect(e.document.item(id)?.text == "abcdef" && e.document.item(id)!.boxSize.width > 0)
        e.editText(id, to: "  ")
        #expect(e.document.items.isEmpty)
    }

    @Test func selectToolPicksAndMoves() {
        let e = editor(.rectangle)
        draw(e, pt(100, 100), pt(200, 200))
        e.tool = .select
        e.select(nil)
        e.pointerDown(pt(100, 150))
        e.pointerDragged(pt(130, 170))
        e.pointerUp(pt(130, 170))
        #expect(e.document.items[0].points == [pt(130, 120), pt(230, 220)])
    }

    @Test func aWholeMoveIsOneUndoStep() {
        let e = editor(.rectangle)
        draw(e, pt(100, 100), pt(200, 200))
        e.tool = .select
        e.pointerDown(pt(100, 150))
        for i in 1...10 { e.pointerDragged(pt(100 + CGFloat(i) * 3, 150)) }
        e.pointerUp(pt(130, 150))
        e.undo()
        #expect(e.document.items[0].points == [pt(100, 100), pt(200, 200)])
        e.undo()
        #expect(e.document.items.isEmpty)
        e.redo()
        e.redo()
        #expect(e.document.items[0].points == [pt(130, 100), pt(230, 200)])
    }

    @Test func clickOnEmptySpaceDeselects() {
        let e = editor(.rectangle)
        draw(e, pt(100, 100), pt(200, 200))
        e.tool = .select
        e.pointerDown(pt(700, 500))
        e.pointerUp(pt(700, 500))
        #expect(e.selection == nil && !e.isDragging)
    }

    @Test func handlesResizeTheSelectedShape() {
        let e = editor(.rectangle)
        draw(e, pt(100, 100), pt(200, 200))
        e.tool = .select
        e.pointerDown(pt(200, 200))
        e.pointerDragged(pt(300, 260))
        e.pointerUp(pt(300, 260))
        #expect(AnnotationItem.rect(e.document.items[0].points[0], e.document.items[0].points[1]) == CGRect(x: 100, y: 100, width: 200, height: 160))
        #expect(e.history.undoStack.count == 2)
    }

    @Test func deleteSelectionIsUndoable() {
        let e = editor(.ellipse)
        draw(e, pt(10, 10), pt(80, 80))
        e.deleteSelection()
        #expect(e.document.items.isEmpty && e.selection == nil)
        e.undo()
        #expect(e.document.items.count == 1)
        e.deleteSelection()
        #expect(e.history.undoStack.count == 1)
        e.select(e.document.items[0].id)
        e.deleteSelection()
        e.deleteSelection()
        #expect(e.document.items.isEmpty && e.history.undoStack.count == 2)
    }

    @Test func duplicateOffsetsAndSelectsTheCopy() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(80, 80))
        let first = e.document.items[0].id
        e.duplicateSelection()
        #expect(e.document.items.count == 2 && e.selection != first && e.document.items[1].points[0] == pt(22, 22))
    }

    @Test func duplicatedStepGetsTheNextNumber() {
        let e = editor(.step)
        e.pointerDown(pt(20, 20)); e.pointerUp(pt(20, 20))
        e.duplicateSelection()
        #expect(e.document.items.map(\.number) == [1, 2])
    }

    @Test func nudgeMovesTheSelection() {
        let e = editor(.line)
        draw(e, pt(10, 10), pt(80, 80))
        e.nudgeSelection(dx: 1, dy: -2)
        #expect(e.document.items[0].points == [pt(11, 8), pt(81, 78)])
        e.tool = .select
        e.select(nil)
        e.nudgeSelection(dx: 5, dy: 5)
        #expect(e.document.items[0].points[0] == pt(11, 8))
    }

    @Test func stackingCommandsChangeTheOrder() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(50, 50))
        let a = e.document.items[0].id
        draw(e, pt(20, 20), pt(60, 60))
        e.select(a)
        e.bringSelectionToFront()
        #expect(e.document.items.last?.id == a)
        e.sendSelectionToBack()
        #expect(e.document.items.first?.id == a)
    }

    @Test func styleChangesApplyToTheSelectionAndTheDefault() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(80, 80))
        e.setColor(.green)
        e.setStrokeWidth(12)
        e.setFilled(true)
        e.setStrength(0.2)
        let s = e.document.items[0].style
        #expect(s.color == .green && s.strokeWidth == 12 && s.filled && s.strength == 0.2)
        #expect(e.style.color == .green && e.style.strokeWidth == 12)
        draw(e, pt(100, 100), pt(150, 150))
        #expect(e.document.items[1].style.color == .green)
    }

    @Test func fontSizeRemeasuresSelectedText() {
        let e = editor(.text)
        e.commitText("abcd", at: pt(0, 0))
        let before = e.selectedItem!.boxSize.width
        e.setFontSize(56)
        #expect(e.selectedItem!.style.fontSize == 56 && e.selectedItem!.boxSize.width > before)
    }

    @Test func styleChangeWithoutSelectionOnlyChangesDefaults() {
        let e = editor(.rectangle)
        e.setColor(.purple)
        #expect(e.style.color == .purple && !e.canUndo)
    }

    @Test func cropToolSetsTheCropRect() {
        let e = editor(.crop)
        draw(e, pt(100, 100), pt(500, 400))
        #expect(e.document.crop == CGRect(x: 100, y: 100, width: 400, height: 300) && e.canUndo)
        e.undo()
        #expect(e.document.crop == nil)
    }

    @Test func cropIsClampedToTheCanvas() {
        let e = editor(.crop)
        draw(e, pt(-50, -50), pt(900, 700))
        #expect(e.document.crop == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(e.document.effectiveCrop == nil)
    }

    @Test func tinyCropIsIgnored() {
        let e = editor(.crop)
        draw(e, pt(100, 100), pt(104, 104))
        #expect(e.document.crop == nil && !e.canUndo)
    }

    @Test func shiftCropIsSquare() {
        let e = editor(.crop)
        draw(e, pt(100, 100), pt(400, 200), shift: true)
        #expect(e.document.crop?.width == e.document.crop?.height)
    }

    @Test func cancelDragDiscardsTheDraft() {
        let e = editor(.rectangle)
        e.pointerDown(pt(10, 10))
        e.pointerDragged(pt(100, 100))
        e.cancelDrag()
        #expect(e.draft == nil && e.document.items.isEmpty && !e.isDragging)
        e.pointerUp(pt(100, 100))
        #expect(e.document.items.isEmpty)
    }

    @Test func clearAllRemovesEverythingAndCrop() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(80, 80))
        e.setCrop(CGRect(x: 0, y: 0, width: 100, height: 100))
        e.clearAll()
        #expect(e.document.isEmpty)
        e.undo()
        #expect(e.document.items.count == 1 && e.document.crop != nil)
        let blank = editor()
        blank.clearAll()
        #expect(!blank.canUndo)
    }

    @Test func undoDropsASelectionThatNoLongerExists() {
        let e = editor(.rectangle)
        draw(e, pt(10, 10), pt(80, 80))
        e.undo()
        #expect(e.selection == nil && e.selectedItem == nil)
        e.redo()
        #expect(e.document.items.count == 1)
    }

    @Test func blurAndPixelateAreCreatedAsEffects() {
        let b = editor(.blur), p = editor(.pixelate)
        draw(b, pt(10, 10), pt(100, 100))
        draw(p, pt(10, 10), pt(100, 100))
        #expect(b.document.items[0].kind == .blur && p.document.items[0].kind == .pixelate && b.document.items[0].kind.isEffect)
    }

    @Test func everyDrawingToolMapsToAKind() {
        for t in AnnotationTool.allCases { #expect((t.kind != nil) == (t != .select && t != .crop), "\(t)") }
        #expect(Set(AnnotationTool.allCases.compactMap(\.key)).count == AnnotationTool.allCases.count)
    }
}
