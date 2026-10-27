import Foundation
import CoreGraphics

public struct AnnotationSnapshot: Equatable, Sendable {
    public var items: [AnnotationItem]
    public var crop: CGRect?
    public var nextID: Int
}

public struct AnnotationHistory: Sendable {
    public static let defaultLimit = 100
    public private(set) var undoStack: [AnnotationSnapshot] = []
    public private(set) var redoStack: [AnnotationSnapshot] = []
    public let limit: Int

    public init(limit: Int = AnnotationHistory.defaultLimit) { self.limit = max(limit, 1) }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(before: AnnotationSnapshot) {
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: AnnotationSnapshot) -> AnnotationSnapshot? {
        guard let s = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return s
    }

    public mutating func redo(current: AnnotationSnapshot) -> AnnotationSnapshot? {
        guard let s = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return s
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

public enum AnnotationEvent: Equatable, Sendable {
    case none
    case changed
    case requestText(at: CGPoint, editing: Int?)
}

public final class AnnotationEditor {
    public static let minDraftSize: CGFloat = 3

    public private(set) var document: AnnotationDocument
    public private(set) var history: AnnotationHistory
    public private(set) var selection: Int?
    public private(set) var draft: AnnotationItem?
    public private(set) var cropDraft: CGRect?
    public var tool = AnnotationTool.arrow
    public var style = AnnotationStyle()
    public var measureText: (String, Double) -> CGSize = ShotTextMetrics.measure

    private enum Drag {
        case none
        case draft(origin: CGPoint)
        case move(original: AnnotationItem, origin: CGPoint)
        case resize(original: AnnotationItem, handle: AnnotationHandleKind)
        case crop(origin: CGPoint)
    }

    private var drag = Drag.none
    private var before: AnnotationSnapshot?

    public init(document: AnnotationDocument, historyLimit: Int = AnnotationHistory.defaultLimit) {
        self.document = document
        history = AnnotationHistory(limit: historyLimit)
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var selectedItem: AnnotationItem? { selection.flatMap { document.item($0) } }
    public var isDragging: Bool { if case .none = drag { false } else { true } }

    private var snapshot: AnnotationSnapshot { AnnotationSnapshot(items: document.items, crop: document.crop, nextID: document.nextID) }

    private func apply(_ s: AnnotationSnapshot) {
        document.items = s.items
        document.crop = s.crop
        document.nextID = s.nextID
        if let sel = selection, document.item(sel) == nil { selection = nil }
    }

    private func commitChange(from old: AnnotationSnapshot) {
        if old != snapshot { history.record(before: old) }
    }

    public func undo() {
        guard let s = history.undo(current: snapshot) else { return }
        apply(s)
    }

    public func redo() {
        guard let s = history.redo(current: snapshot) else { return }
        apply(s)
    }

    public func select(_ id: Int?) { selection = id.flatMap { document.item($0) != nil ? $0 : nil } }

    private func baseStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var s = style.sanitized
        if tool == .highlighter { s.color = s.color.withAlpha(0.4) }
        return s
    }

    @discardableResult
    public func pointerDown(_ p: CGPoint, shift: Bool = false) -> AnnotationEvent {
        before = snapshot
        switch tool {
        case .select:
            if let it = selectedItem, let h = AnnotationHit.hitHandle(of: it, at: p) {
                drag = .resize(original: it, handle: h.kind)
                return .changed
            }
            if let id = document.hitTest(p) {
                selection = id
                drag = .move(original: document.item(id)!, origin: p)
                return .changed
            }
            selection = nil
            drag = .none
            return .changed
        case .crop:
            drag = .crop(origin: p)
            cropDraft = CGRect(origin: p, size: .zero)
            return .changed
        case .text:
            if let id = document.hitTest(p), document.item(id)?.kind == .text {
                selection = id
                drag = .none
                return .requestText(at: document.item(id)!.points[0], editing: id)
            }
            drag = .none
            return .requestText(at: p, editing: nil)
        case .step:
            let id = document.add(.step, points: [p], style: baseStyle(for: .step))
            selection = id
            commitChange(from: before!)
            drag = .none
            return .changed
        default:
            guard let kind = tool.kind else { return .none }
            let pts: [CGPoint] = kind.isPath ? [p] : [p, p]
            draft = AnnotationItem(id: 0, kind: kind, points: pts, style: baseStyle(for: tool))
            drag = .draft(origin: p)
            return .changed
        }
    }

    @discardableResult
    public func pointerDragged(_ p: CGPoint, shift: Bool = false) -> AnnotationEvent {
        switch drag {
        case .none:
            return .none
        case .draft(let origin):
            guard var d = draft else { return .none }
            if d.kind.isPath {
                if let last = d.points.last, hypot(last.x - p.x, last.y - p.y) < 1 { return .none }
                d.points.append(p)
            } else {
                var end = p
                if shift {
                    if d.kind.isSegment { end = AnnotationHit.snapAngle(from: origin, to: p) } else {
                        let side = max(abs(p.x - origin.x), abs(p.y - origin.y))
                        end = CGPoint(x: origin.x + (p.x >= origin.x ? side : -side), y: origin.y + (p.y >= origin.y ? side : -side))
                    }
                }
                d.points = [origin, end]
            }
            draft = d
            return .changed
        case .move(let original, let origin):
            var moved = original.moved(by: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
            moved.id = original.id
            document.update(moved)
            return .changed
        case .resize(let original, let handle):
            document.update(AnnotationHit.resized(original, handle: handle, to: p, lockSquare: shift))
            return .changed
        case .crop(let origin):
            var end = p
            if shift {
                let side = max(abs(p.x - origin.x), abs(p.y - origin.y))
                end = CGPoint(x: origin.x + (p.x >= origin.x ? side : -side), y: origin.y + (p.y >= origin.y ? side : -side))
            }
            cropDraft = ShotSpace.rect(from: origin, to: end).intersection(CGRect(origin: .zero, size: document.canvasSize))
            return .changed
        }
    }

    @discardableResult
    public func pointerUp(_ p: CGPoint, shift: Bool = false) -> AnnotationEvent {
        defer { drag = .none; before = nil }
        switch drag {
        case .none:
            return .none
        case .draft:
            guard let d = draft, let old = before else { draft = nil; return .none }
            draft = nil
            let ok: Bool
            if d.kind.isPath {
                ok = d.points.count >= 2
            } else {
                let dw = abs(d.points[1].x - d.points[0].x), dh = abs(d.points[1].y - d.points[0].y)
                ok = d.kind.isSegment ? hypot(dw, dh) >= Self.minDraftSize : (dw >= Self.minDraftSize && dh >= Self.minDraftSize)
            }
            guard ok else { return .none }
            selection = document.add(d.kind, points: d.points, style: d.style)
            commitChange(from: old)
            return .changed
        case .move, .resize:
            if let old = before { commitChange(from: old) }
            return .changed
        case .crop:
            let r = cropDraft
            cropDraft = nil
            guard let old = before else { return .none }
            if let r, r.width >= 8, r.height >= 8 { document.crop = r.integral }
            commitChange(from: old)
            return .changed
        }
    }

    public func cancelDrag() {
        if let old = before { apply(old) }
        draft = nil
        cropDraft = nil
        drag = .none
        before = nil
    }

    public func commitText(_ text: String, at point: CGPoint) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let old = snapshot
        let s = baseStyle(for: .text)
        selection = document.add(.text, points: [point], style: s, text: t, boxSize: measureText(t, s.fontSize))
        commitChange(from: old)
    }

    public func editText(_ id: Int, to text: String) {
        guard var it = document.item(id), it.kind == .text else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = snapshot
        if t.isEmpty {
            document.remove([id])
            selection = nil
        } else {
            it.text = t
            it.boxSize = measureText(t, it.style.fontSize)
            document.update(it)
        }
        commitChange(from: old)
    }

    public func deleteSelection() {
        guard let id = selection else { return }
        let old = snapshot
        document.remove([id])
        selection = nil
        commitChange(from: old)
    }

    public func duplicateSelection(offset: CGFloat = 12) {
        guard let it = selectedItem else { return }
        let old = snapshot
        var c = it.moved(by: CGPoint(x: offset, y: offset))
        c.id = document.nextID
        document.nextID += 1
        if c.kind == .step { c.number = document.nextStepNumber }
        document.items.append(c)
        selection = c.id
        commitChange(from: old)
    }

    public func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let it = selectedItem else { return }
        let old = snapshot
        var m = it.moved(by: CGPoint(x: dx, y: dy))
        m.id = it.id
        document.update(m)
        commitChange(from: old)
    }

    public func bringSelectionToFront() {
        guard let id = selection else { return }
        let old = snapshot
        document.bringToFront(id)
        commitChange(from: old)
    }

    public func sendSelectionToBack() {
        guard let id = selection else { return }
        let old = snapshot
        document.sendToBack(id)
        commitChange(from: old)
    }

    public func setColor(_ c: ShotColor) {
        style.color = c
        applyToSelection { $0.style.color = $0.kind == .highlighter ? c.withAlpha(0.4) : c }
    }

    public func setStrokeWidth(_ w: Double) {
        style.strokeWidth = w
        style = style.sanitized
        applyToSelection { $0.style.strokeWidth = min(max(w, AnnotationStyle.strokeRange.lowerBound), AnnotationStyle.strokeRange.upperBound) }
    }

    public func setFontSize(_ s: Double) {
        style.fontSize = s
        style = style.sanitized
        let m = measureText
        applyToSelection {
            $0.style.fontSize = min(max(s, AnnotationStyle.fontRange.lowerBound), AnnotationStyle.fontRange.upperBound)
            if $0.kind == .text { $0.boxSize = m($0.text, $0.style.fontSize) }
        }
    }

    public func setFilled(_ f: Bool) {
        style.filled = f
        applyToSelection { $0.style.filled = f }
    }

    public func setStrength(_ s: Double) {
        style.strength = min(max(s, 0), 1)
        applyToSelection { $0.style.strength = min(max(s, 0), 1) }
    }

    private func applyToSelection(_ change: (inout AnnotationItem) -> Void) {
        guard var it = selectedItem else { return }
        let old = snapshot
        change(&it)
        document.update(it)
        commitChange(from: old)
    }

    public func setCrop(_ r: CGRect?) {
        let old = snapshot
        document.crop = r
        commitChange(from: old)
    }

    public func clearAll() {
        guard !document.isEmpty else { return }
        let old = snapshot
        document.items.removeAll()
        document.crop = nil
        selection = nil
        commitChange(from: old)
    }
}
