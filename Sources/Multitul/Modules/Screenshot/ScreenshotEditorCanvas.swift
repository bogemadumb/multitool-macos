import SwiftUI
import AppKit
import MultitulCore

final class ShotEditorCanvas: NSView, NSTextFieldDelegate {
    let base: CGImage
    let editor: AnnotationEditor
    var onChange: (() -> Void)?
    var onCommand: ((String) -> Void)?
    private var rendered: CGImage?
    private var dirty = true
    private var textField: NSTextField?
    private var textPoint: CGPoint = .zero
    private var textEditing: Int?

    init(base: CGImage, editor: AnnotationEditor) {
        self.base = base
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func invalidate() {
        dirty = true
        needsDisplay = true
    }

    private var imageSize: CGSize { CGSize(width: base.width, height: base.height) }

    private var scale: CGFloat {
        let pad: CGFloat = 24
        let w = max(bounds.width - pad * 2, 50), h = max(bounds.height - pad * 2, 50)
        return min(w / imageSize.width, h / imageSize.height, 1)
    }

    private var imageRect: CGRect {
        let s = scale
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func toImage(_ p: NSPoint) -> CGPoint {
        let r = imageRect, s = scale
        return CGPoint(x: (p.x - r.minX) / s, y: (p.y - r.minY) / s)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = imageRect, s = scale
        return CGPoint(x: r.minX + p.x * s, y: r.minY + p.y * s)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let a = toView(rect.origin)
        return CGRect(x: a.x, y: a.y, width: rect.width * scale, height: rect.height * scale)
    }

    private func refreshRender() {
        guard dirty else { return }
        var doc = editor.document
        if var d = editor.draft {
            d.id = doc.nextID
            doc.items.append(d)
        }
        doc.crop = nil
        rendered = ShotRenderer.render(base: base, document: doc, applyCrop: false)
        dirty = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        refreshRender()
        let r = imageRect
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let flipped = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        if let img = rendered ?? Optional(base) {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: flipped)
        }
        ctx.restoreGState()
        let crop = editor.cropDraft ?? editor.document.effectiveCrop
        if let c = crop, c.width > 0, c.height > 0 {
            let cr = toView(c)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(cr.minY - r.minY, 0)))
            ctx.fill(CGRect(x: r.minX, y: cr.maxY, width: r.width, height: max(r.maxY - cr.maxY, 0)))
            ctx.fill(CGRect(x: r.minX, y: cr.minY, width: max(cr.minX - r.minX, 0), height: cr.height))
            ctx.fill(CGRect(x: cr.maxX, y: cr.minY, width: max(r.maxX - cr.maxX, 0), height: cr.height))
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(cr)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let it = editor.selectedItem, editor.tool == .select {
            let b = toView(it.bounds)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(b.insetBy(dx: -3, dy: -3))
            ctx.setLineDash(phase: 0, lengths: [])
            for h in AnnotationHit.handles(of: it) {
                let p = toView(h.position)
                let hr = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(hr)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                ctx.stroke(hr)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextIfNeeded()
        let p = toImage(convert(event.locationInWindow, from: nil))
        let ev = editor.pointerDown(p, shift: event.modifierFlags.contains(.shift))
        if case .requestText(let at, let editing) = ev { beginText(at: at, editing: editing) }
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        editor.pointerDragged(p, shift: event.modifierFlags.contains(.shift))
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        editor.pointerUp(p, shift: event.modifierFlags.contains(.shift))
        changed()
    }

    private func changed() {
        invalidate()
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch ch {
            case "z": editor.undo(); changed(); return
            case "c": onCommand?("copy"); return
            case "s": onCommand?("save"); return
            case "w": onCommand?("close"); return
            default: break
            }
        }
        if flags == [.command, .shift], ch == "z" { editor.redo(); changed(); return }
        if flags.isEmpty || flags == .shift {
            switch event.keyCode {
            case 51, 117: editor.deleteSelection(); changed(); return
            case 53:
                if editor.isDragging { editor.cancelDrag() } else if editor.selection != nil { editor.select(nil) } else { onCommand?("close") }
                changed()
                return
            case 123: editor.nudgeSelection(dx: flags.isEmpty ? -1 : -10, dy: 0); changed(); return
            case 124: editor.nudgeSelection(dx: flags.isEmpty ? 1 : 10, dy: 0); changed(); return
            case 126: editor.nudgeSelection(dx: 0, dy: flags.isEmpty ? -1 : -10); changed(); return
            case 125: editor.nudgeSelection(dx: 0, dy: flags.isEmpty ? 1 : 10); changed(); return
            default: break
            }
            if flags.isEmpty, let t = AnnotationTool.allCases.first(where: { $0.key == ch }) {
                editor.tool = t
                onCommand?("toolKey")
                changed()
                return
            }
        }
        super.keyDown(with: event)
    }

    private func beginText(at p: CGPoint, editing: Int?) {
        commitTextIfNeeded()
        textPoint = p
        textEditing = editing
        let existing = editing.flatMap { editor.document.item($0) }
        let size = CGFloat(existing?.style.fontSize ?? editor.style.fontSize) * scale
        let tf = NSTextField(frame: .zero)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.boldSystemFont(ofSize: max(size, 10))
        tf.textColor = NSColor(srgbRed: CGFloat((existing?.style.color ?? editor.style.color).r) / 255, green: CGFloat((existing?.style.color ?? editor.style.color).g) / 255,
                               blue: CGFloat((existing?.style.color ?? editor.style.color).b) / 255, alpha: 1)
        tf.stringValue = existing?.text ?? ""
        tf.placeholderString = "Текст"
        tf.delegate = self
        let o = toView(p)
        tf.frame = NSRect(x: o.x, y: o.y, width: max(240, bounds.width - o.x - 20), height: max(size * 1.4, 24))
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            removeTextField()
            return true
        }
        return false
    }

    private func removeTextField() {
        textField?.removeFromSuperview()
        textField = nil
        textEditing = nil
        window?.makeFirstResponder(self)
    }

    func commitTextIfNeeded() {
        guard let tf = textField else { return }
        let text = tf.stringValue
        let editing = textEditing
        removeTextField()
        if let id = editing { editor.editText(id, to: text) } else { editor.commitText(text, at: textPoint) }
        changed()
    }
}
