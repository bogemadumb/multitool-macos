import SwiftUI
import AppKit
import MultitulCore

final class ShotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ShotSelectSetup {
    var displays: [ShotDisplay]
    var windows: [ShotWindowInfo]
    var frozen: [UInt32: ShotSourceImage]
    var config: ShotSelectionConfig
    var hint: String
    var highlightWindows: Bool
}

@MainActor
final class ShotSelector {
    private(set) var session: ShotSelectionSession?
    private var setup: ShotSelectSetup?
    private var windows: [ShotOverlayWindow] = []
    private var views: [ShotSelectView] = []
    private var finish: ((ShotSelectionResult?) -> Void)?
    private var primaryHeight: CGFloat = 0
    private var flagsMonitor: Any?

    var isActive: Bool { session != nil }

    func begin(_ setup: ShotSelectSetup, onFinish: @escaping (ShotSelectionResult?) -> Void) {
        close()
        self.setup = setup
        finish = onFinish
        primaryHeight = ShotLiveScreens.primaryHeight()
        let mouse = NSEvent.mouseLocation
        let cursor = ShotSpace.cocoaToDesktop(mouse, primaryHeight: primaryHeight)
        session = ShotSelectionSession(displays: setup.displays, windows: setup.windows, config: setup.config, cursor: cursor)
        for d in setup.displays {
            guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.id }) else { continue }
            let w = ShotOverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = ShotSelectView(display: d, frozen: setup.frozen[d.id]?.image, selector: self)
            v.frame = NSRect(origin: .zero, size: screen.frame.size)
            w.contentView = v
            windows.append(w)
            views.append(v)
        }
        guard !windows.isEmpty else { close(); onFinish(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let key = windows.first { $0.frame.contains(mouse) } ?? windows[0]
        key.makeKeyAndOrderFront(nil)
        if let v = key.contentView { key.makeFirstResponder(v) }
        NSCursor.crosshair.set()
        redraw()
    }

    func close() {
        for w in windows { w.orderOut(nil); w.contentView = nil }
        windows = []
        views = []
        session = nil
        setup = nil
        finish = nil
    }

    func redraw() { for v in views { v.needsDisplay = true } }

    var hint: String { setup?.hint ?? "" }
    var highlightWindows: Bool { setup?.highlightWindows ?? false }
    var hasFrozen: Bool { !(setup?.frozen.isEmpty ?? true) }
    var allDisplays: [ShotDisplay] { setup?.displays ?? [] }

    func feed(_ input: ShotSelectionInput) {
        guard let s = session else { return }
        let outcome = s.handle(input)
        switch outcome {
        case .none, .changed:
            break
        case .warpCursor(let p):
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
        case .confirmed(let r):
            let cb = finish
            close()
            cb?(r)
            return
        case .cancelled:
            let cb = finish
            close()
            cb?(nil)
            return
        }
        redraw()
    }

    func desktopPoint(_ event: NSEvent) -> CGPoint {
        ShotSpace.cocoaToDesktop(NSEvent.mouseLocation, primaryHeight: primaryHeight)
    }

    static func modifiers(_ f: NSEvent.ModifierFlags) -> ShotModifiers {
        ShotModifiers(shift: f.contains(.shift), option: f.contains(.option), command: f.contains(.command), control: f.contains(.control))
    }
}

final class ShotSelectView: NSView {
    let display: ShotDisplay
    let frozen: CGImage?
    weak var selector: ShotSelector?

    init(display: ShotDisplay, frozen: CGImage?, selector: ShotSelector) {
        self.display = display
        self.frozen = frozen
        self.selector = selector
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func mods(_ e: NSEvent) -> ShotModifiers { ShotSelector.modifiers(e.modifierFlags) }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = selector else { return }
            s.feed(.mouseMoved(s.desktopPoint(event), mods(event)))
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = selector else { return }
            s.feed(.mouseDown(s.desktopPoint(event), mods(event)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = selector else { return }
            s.feed(.mouseDragged(s.desktopPoint(event), mods(event)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = selector else { return }
            s.feed(.mouseUp(s.desktopPoint(event), mods(event)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { selector?.feed(.keyDown(Keys.escape, .none)) }
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = selector else { return }
            s.feed(.keyDown(UInt32(event.keyCode), mods(event)))
        }
    }

    override func keyUp(with event: NSEvent) {
        MainActor.assumeIsolated { selector?.feed(.keyUp(UInt32(event.keyCode))) }
    }

    private func viewRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX - display.frame.minX, y: bounds.height - (r.maxY - display.frame.minY), width: r.width, height: r.height)
    }

    private func viewPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x - display.frame.minX, y: bounds.height - (p.y - display.frame.minY))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sel = MainActor.assumeIsolated { selector }
        guard let s = sel, let session = MainActor.assumeIsolated({ s.session }) else { return }
        let (hint, highlight, hasFrozen) = MainActor.assumeIsolated { (s.hint, s.highlightWindows, s.hasFrozen) }
        if let f = frozen { ctx.draw(f, in: bounds) }
        let selection = session.rect.map(viewRect)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.fill(bounds)
        if let r = selection, r.width > 0, r.height > 0 {
            if let f = frozen {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.draw(f, in: bounds)
                ctx.restoreGState()
            } else {
                ctx.setBlendMode(.clear)
                ctx.fill(r)
                ctx.setBlendMode(.normal)
            }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
            drawLabel(ShotMagnifier.sizeLabel(session.rect!, scale: display.scale), near: r)
        } else if highlight, session.state == .idle, let w = session.hoverWindow {
            let r = viewRect(w.frame)
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r.insetBy(dx: 1, dy: 1))
            drawLabel(ShotWindowFilter.label(w), near: r, inside: true)
        }
        if session.state != .adjusting, display.frame.contains(session.cursor) {
            drawCrosshair(ctx, session: session, hasFrozen: hasFrozen)
        }
        if let gx = session.guideX, gx >= display.frame.minX, gx <= display.frame.maxX {
            ctx.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: gx - display.frame.minX, y: 0))
            ctx.addLine(to: CGPoint(x: gx - display.frame.minX, y: bounds.height))
            ctx.strokePath()
        }
        if let gy = session.guideY, gy >= display.frame.minY, gy <= display.frame.maxY {
            let y = bounds.height - (gy - display.frame.minY)
            ctx.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            ctx.strokePath()
        }
        if session.state == .idle, !hint.isEmpty, display.frame.contains(session.cursor) { drawHint(hint) }
    }

    private func drawCrosshair(_ ctx: CGContext, session: ShotSelectionSession, hasFrozen: Bool) {
        let p = viewPoint(session.cursor)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: p.y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: 0))
        ctx.addLine(to: CGPoint(x: p.x, y: bounds.height))
        ctx.strokePath()
        guard let m = ShotMagnifier.model(cursor: session.cursor, displays: [display]) else { return }
        let box = viewRect(m.loupeFrame)
        guard frozen != nil else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let text = "\(m.pointText)  ·  \(m.pixelText)" as NSString
            let size = text.size(withAttributes: attrs)
            let tag = NSRect(x: box.minX, y: box.minY, width: size.width + 14, height: size.height + 8)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: tag.minX + 7, y: tag.minY + 4), withAttributes: attrs)
            return
        }
        let bg = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.85).setFill()
        bg.fill()
        if let f = frozen {
            let src = m.sourcePixelRect.intersection(CGRect(x: 0, y: 0, width: f.width, height: f.height))
            if !src.isNull, let piece = f.cropping(to: src.integral) {
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.clip()
                ctx.interpolationQuality = .none
                let cell = box.width / CGFloat(m.gridSize)
                let dest = NSRect(x: box.minX + (src.minX - m.sourcePixelRect.minX) * cell, y: box.maxY - (src.maxY - m.sourcePixelRect.minY) * cell,
                                  width: src.width * cell, height: src.height * cell)
                ctx.draw(piece, in: dest)
                ctx.restoreGState()
            }
        }
        let cell = box.width / CGFloat(m.gridSize)
        let mid = m.gridSize / 2
        let center = NSRect(x: box.minX + CGFloat(mid) * cell, y: box.maxY - CGFloat(mid + 1) * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        let ring = NSBezierPath(rect: center.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 1.5
        ring.stroke()
        let tag = NSRect(x: box.minX - 3, y: box.minY - 40, width: box.width + 6, height: 36)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        (m.pointText as NSString).draw(at: NSPoint(x: tag.minX + 8, y: tag.minY + 19), withAttributes: attrs)
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.65)]
        (m.pixelText as NSString).draw(at: NSPoint(x: tag.minX + 8, y: tag.minY + 5), withAttributes: dim)
    }

    private func drawLabel(_ text: String, near r: NSRect, inside: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var bg = NSRect(x: r.minX, y: r.minY - size.height - 8, width: size.width + 12, height: size.height + 4)
        if inside || bg.minY < 2 { bg.origin.y = min(r.maxY - size.height - 8, bounds.maxY - bg.height - 2) }
        bg.origin.x = min(max(bg.origin.x, 2), bounds.maxX - bg.width - 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 6, y: bg.minY + 2), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let bg = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 74, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 14, y: bg.minY + 7), withAttributes: attrs)
    }
}
