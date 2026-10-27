import AppKit
import MultitulCore

@MainActor
final class SnapPreviewOverlay: SnapPreviewing {
    private var panel: NSPanel?
    private var visible = false

    nonisolated init() {}

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 10
        v.layer?.cornerCurve = .continuous
        p.contentView = v
        return p
    }

    nonisolated func show(_ frame: CGRect, display: WndDisplay) {
        MainActor.assumeIsolated { present(frame) }
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { dismiss() }
    }

    private func present(_ topLeft: CGRect) {
        let target = LiveScreens.cocoaFrame(fromTopLeft: topLeft)
        let p = panel ?? make()
        panel = p
        if !visible {
            p.setFrame(target, display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
            visible = true
        } else {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().setFrame(target, display: true) }
        }
    }

    private func dismiss() {
        guard visible, let p = panel else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { if !self.visible { p.orderOut(nil) } }
        })
    }
}
