import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class ShelfPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class ShelfPanelController {
    private(set) var panel: ShelfPanel?
    private(set) var reason: ShelfOpenReason?
    private var container: ShelfDropContainer?
    private var hideWork: DispatchWorkItem?
    private let model: ShelfViewModel
    private let intake: ShelfIntake
    var placement: () -> ShelfPlacementMode = { .nearCursor }
    var statusFrame: () -> CGRect? = { nil }
    var onHidden: (() -> Void)?

    init(model: ShelfViewModel, intake: ShelfIntake) {
        self.model = model
        self.intake = intake
    }

    var isShown: Bool { panel?.isVisible == true }

    var isHovered: Bool {
        guard let p = panel, p.isVisible else { return false }
        return p.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    static func screens() -> [ShelfScreen] { NSScreen.screens.map { ShelfScreen(frame: $0.frame, visible: $0.visibleFrame) } }

    private func build() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.onCancel = { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: ShelfView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.Radius.window
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.separatorColor.cgColor
        let c = ShelfDropContainer(content: host)
        c.intake = intake
        c.onTarget = { [weak self] on in self?.model.targeted = on }
        container = c
        p.contentView = c
        return p
    }

    func show(reason: ShelfOpenReason) {
        hideWork?.cancel()
        let p = panel ?? build()
        panel = p
        self.reason = reason
        let size = ShelfPlacement.size(itemCount: model.items.count)
        let screens = Self.screens()
        let origin: CGPoint
        if reason == .menuBarDrag || reason == .menuBarClick, let icon = statusFrame() {
            origin = ShelfPlacement.belowStatusItem(icon: icon, size: size, screens: screens)
        } else {
            origin = ShelfPlacement.origin(mode: placement(), cursor: NSEvent.mouseLocation, size: size, screens: screens)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        let wasVisible = p.isVisible
        if !wasVisible { p.alphaValue = 0 }
        if reason.isAutomatic { p.orderFrontRegardless() } else { p.makeKeyAndOrderFront(nil) }
        if !wasVisible { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 } }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let p = panel, p.isVisible else { reason = nil; return }
        reason = nil
        model.targeted = false
        p.orderOut(nil)
        onHidden?()
    }

    func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.isHovered == false || self?.model.items.isEmpty == true { self?.hide() } } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func cancelPendingHide() { hideWork?.cancel(); hideWork = nil }

    func resizeToFit() {
        guard let p = panel, p.isVisible else { return }
        let size = ShelfPlacement.size(itemCount: model.items.count)
        let top = p.frame.maxY
        let screens = Self.screens()
        let origin = CGPoint(x: p.frame.minX, y: top - size.height)
        let area = ShelfPlacement.screen(containing: CGPoint(x: p.frame.midX, y: p.frame.midY), in: screens)?.visible ?? p.frame
        p.setFrame(NSRect(origin: ShelfPlacement.clamp(origin, size: size, in: area), size: size), display: true, animate: true)
    }

    func destroy() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        container = nil
        reason = nil
    }
}
