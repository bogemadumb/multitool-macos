import SwiftUI
import AppKit
import MultitulCore

final class ShotPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShotPinContentView: NSView {
    var image: CGImage?
    var onScroll: ((NSEvent) -> Void)?
    var onResize: ((ShotPinCorner, NSPoint) -> Void)?
    var onMenu: (() -> NSMenu)?
    var onKey: ((NSEvent) -> Bool)?
    private var activeCorner: ShotPinCorner?
    private let grip: CGFloat = 16

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let i = image { ctx.draw(i, in: bounds) }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    private func corner(at p: NSPoint) -> ShotPinCorner? {
        let l = p.x <= grip, r = p.x >= bounds.width - grip, b = p.y <= grip, t = p.y >= bounds.height - grip
        if l && t { return .topLeft }
        if r && t { return .topRight }
        if l && b { return .bottomLeft }
        if r && b { return .bottomRight }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        activeCorner = corner(at: convert(event.locationInWindow, from: nil))
        if activeCorner == nil { window?.performDrag(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = activeCorner else { return }
        onResize?(c, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) { activeCorner = nil }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        let g = grip
        addCursorRect(NSRect(x: 0, y: 0, width: g, height: g), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - g, y: 0, width: g, height: g), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: bounds.height - g, width: g, height: g), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - g, y: bounds.height - g, width: g, height: g), cursor: .crosshair)
    }
}

@MainActor
final class ShotPins: ObservableObject {
    let board = ShotPinBoard()
    @Published private(set) var revision = 0
    private var panels: [Int: ShotPinPanel] = [:]
    private var images: [Int: CGImage] = [:]
    weak var controller: ScreenshotController?

    var count: Int { board.count }
    var states: [ShotPinState] { board.pins }

    func add(image: CGImage, record: ShotRecord?, title: String, scale: CGFloat, origin: CGPoint?) {
        let size = CGSize(width: CGFloat(image.width) / max(scale, 1), height: CGFloat(image.height) / max(scale, 1))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = board.add(title: title, recordID: record?.id, imagePointSize: size, visible: visible, preferredOrigin: origin)
        if let ev = r.evicted { close(panelOnly: ev) }
        images[r.id] = image
        guard let st = board.pin(r.id) else { return }
        let panel = ShotPinPanel(contentRect: st.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let id = r.id
        let v = ShotPinContentView(frame: NSRect(origin: .zero, size: st.frame.size))
        v.image = image
        v.autoresizingMask = [.width, .height]
        v.onScroll = { [weak self, weak panel] e in
            MainActor.assumeIsolated { if let panel { self?.scroll(id, panel: panel, event: e) } }
        }
        v.onResize = { [weak self] corner, p in MainActor.assumeIsolated { self?.resize(id, corner: corner, to: p) } }
        v.onMenu = { [weak self] in MainActor.assumeIsolated { self?.menu(id) ?? NSMenu() } }
        v.onKey = { [weak self] e in MainActor.assumeIsolated { self?.key(id, event: e) ?? false } }
        panel.contentView = v
        panels[id] = panel
        apply(id)
        panel.orderFrontRegardless()
        revision += 1
    }

    private func visibleArea(for frame: CGRect) -> CGRect {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return (NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main)?.visibleFrame ?? frame
    }

    private func apply(_ id: Int) {
        guard let st = board.pin(id), let p = panels[id] else { return }
        p.setFrame(st.frame, display: true)
        p.alphaValue = CGFloat(st.opacity)
        p.ignoresMouseEvents = st.clickThrough
        if board.allHidden || st.hidden { p.orderOut(nil) } else { p.orderFrontRegardless() }
        revision += 1
    }

    private func scroll(_ id: Int, panel: NSPanel, event: NSEvent) {
        guard let st = board.pin(id) else { return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        if event.modifierFlags.contains(.option) {
            board.stepOpacity(id, up: dy > 0)
        } else {
            let factor: CGFloat = dy > 0 ? 1.06 : 1 / 1.06
            let anchor = NSEvent.mouseLocation
            let area = visibleArea(for: st.frame)
            let f = ShotPinMath.zoomed(st.frame, factor: factor, around: anchor, imagePointSize: st.imagePointSize, maxSize: CGSize(width: area.width, height: area.height))
            board.setFrame(id, ShotPinMath.keepReachable(f, in: area))
        }
        apply(id)
    }

    private func resize(_ id: Int, corner: ShotPinCorner, to p: NSPoint) {
        guard let st = board.pin(id) else { return }
        let area = visibleArea(for: st.frame)
        let r = ShotPinMath.resized(st.frame, corner: corner, to: p, aspect: st.aspect, lockAspect: !NSEvent.modifierFlags.contains(.shift), maxSize: CGSize(width: area.width, height: area.height))
        board.setFrame(id, r)
        apply(id)
    }

    private func key(_ id: Int, event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            close(id)
            return true
        case 30:
            board.stepOpacity(id, up: true)
            apply(id)
            return true
        case 33:
            board.stepOpacity(id, up: false)
            apply(id)
            return true
        default:
            return false
        }
    }

    private func menu(_ id: Int) -> NSMenu {
        let m = NSMenu()
        let st = board.pin(id)
        func add(_ title: String, _ action: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, action: action)
            m.addItem(it)
        }
        add("Копировать") { [weak self] in if let i = self?.images[id] { self?.controller?.copy(i, data: nil) } }
        add("Открыть в редакторе") { [weak self] in
            guard let self, let i = self.images[id] else { return }
            self.controller?.openEditor(record: self.recordFor(id), image: i)
        }
        m.addItem(.separator())
        let o = NSMenuItem(title: "Прозрачность", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in stride(from: 1.0, through: 0.2, by: -0.2) {
            let it = ClosureMenuItem(title: "\(Int((v * 100).rounded()))%") { [weak self] in
                self?.board.setOpacity(id, v)
                self?.apply(id)
            }
            if let st, abs(st.opacity - v) < 0.05 { it.state = .on }
            sub.addItem(it)
        }
        o.submenu = sub
        m.addItem(o)
        add(st?.clickThrough == true ? "Принимать клики" : "Пропускать клики насквозь") { [weak self] in
            self?.board.toggleClickThrough(id)
            self?.apply(id)
        }
        add("Исходный размер") { [weak self] in
            guard let self, let st = self.board.pin(id) else { return }
            let f = CGRect(x: st.frame.minX, y: st.frame.maxY - st.imagePointSize.height, width: st.imagePointSize.width, height: st.imagePointSize.height)
            self.board.setFrame(id, ShotPinMath.keepReachable(f, in: self.visibleArea(for: f)))
            self.apply(id)
        }
        m.addItem(.separator())
        add("Закрыть") { [weak self] in self?.close(id) }
        add("Закрыть все закрепы") { [weak self] in self?.closeAll() }
        return m
    }

    private func recordFor(_ id: Int) -> ShotRecord? {
        guard let rid = board.pin(id)?.recordID else { return nil }
        return try? controller?.history?.record(id: rid)
    }

    private func close(panelOnly id: Int) {
        panels[id]?.orderOut(nil)
        panels[id]?.contentView = nil
        panels[id] = nil
        images[id] = nil
    }

    func close(_ id: Int) {
        close(panelOnly: id)
        board.remove(id)
        revision += 1
    }

    func closeAll() {
        for id in Array(panels.keys) { close(panelOnly: id) }
        board.removeAll()
        revision += 1
    }

    func toggleAllHidden() {
        board.toggleAllHidden()
        for id in panels.keys { apply(id) }
    }

    func restoreClicks() {
        board.setAllClickThrough(false)
        for id in panels.keys { apply(id) }
    }

    func setOpacity(_ id: Int, _ v: Double) {
        board.setOpacity(id, v)
        apply(id)
    }

    func toggleClickThrough(_ id: Int) {
        board.toggleClickThrough(id)
        apply(id)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
