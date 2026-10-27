import SwiftUI
import AppKit
import MultitulCore

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScreenOverlaySet {
    private(set) var windows: [OverlayWindow] = []
    private var cursorHidden = false

    func add(_ screen: NSScreen, content: NSView) {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.level = .screenSaver
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        content.frame = NSRect(origin: .zero, size: screen.frame.size)
        w.contentView = content
        windows.append(w)
    }

    func showAll() {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        if let v = key?.contentView { key?.makeFirstResponder(v) }
    }

    func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    func closeAll() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        for w in windows { w.orderOut(nil); w.contentView = nil }
        windows = []
    }
}

func nsColor(_ c: RGBAColor) -> NSColor {
    let k = c.clamped
    return c.space == .displayP3
        ? NSColor(displayP3Red: k.r, green: k.g, blue: k.b, alpha: k.a)
        : NSColor(srgbRed: k.r, green: k.g, blue: k.b, alpha: k.a)
}

func rgbaColor(_ n: NSColor) -> RGBAColor? {
    if let c = n.usingColorSpace(.sRGB) { return RGBAColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent)) }
    return nil
}

final class RegionSelectView: NSView {
    let shot: ScreenCapture.Shot
    var onFinish: ((CGRect?, ScreenCapture.Shot) -> Void)?
    var hint = "Выдели область с текстом или QR-кодом · Esc — отмена"
    private var start: NSPoint?
    private var current: NSPoint?

    init(shot: ScreenCapture.Shot) {
        self.shot = shot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let sel = selection
        start = nil
        current = nil
        if let sel, sel.width >= 4, sel.height >= 4 { onFinish?(sel, shot) } else { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil, shot) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
        guard let sel = selection else {
            drawHint()
            return
        }
        ctx.saveGState()
        ctx.clip(to: sel)
        ctx.draw(shot.image, in: bounds)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
        let label = "\(Int(sel.width * shot.scale)) × \(Int(sel.height * shot.scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let bg = NSRect(x: sel.minX, y: max(sel.minY - size.height - 6, 2), width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }

    private func drawHint() {
        let text = hint as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80), withAttributes: attrs)
    }
}

extension ScreenCapture.Shot {
    func crop(viewRect r: NSRect, viewHeight: CGFloat) -> CGImage? {
        let px = CGRect(x: r.minX * scale, y: (viewHeight - r.maxY) * scale, width: r.width * scale, height: r.height * scale).integral
        return image.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }
}
