import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
private func makePanel(level: NSWindow.Level) -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = level
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

@MainActor
private func containsPoint(_ panel: NSPanel?, topLeft p: CGPoint) -> Bool {
    guard let panel, panel.isVisible else { return false }
    let h = ScreenSpace.primaryHeight(LiveScreens.current())
    return panel.frame.contains(ScreenSpace.flip(p, primaryHeight: h))
}

@MainActor
final class SwitcherPanelController: SwitcherPanelDriving {
    let model: SwitcherPanelModel
    private var panel: NSPanel?

    nonisolated init(model: SwitcherPanelModel) { self.model = model }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = makePanel(level: .popUpMenu)
        p.contentView = FirstMouseHostingView(rootView: SwitcherPanelView(model: model))
        panel = p
        return p
    }

    private func frame(for s: SwitcherViewState) -> NSRect {
        var size = s.metrics.panel
        if s.showHints { size.height += SwitcherPanelView.hintsHeight }
        let area = s.display.visible
        let w = min(size.width, area.width), h = min(size.height, area.height)
        let top = CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
        return LiveScreens.cocoaFrame(fromTopLeft: top)
    }

    nonisolated func present(_ state: SwitcherViewState) {
        MainActor.assumeIsolated {
            model.state = state
            let p = ensurePanel()
            p.setFrame(frame(for: state), display: false)
            p.alphaValue = state.instant ? 1 : 0
            p.orderFrontRegardless()
            if !state.instant { NSAnimationContext.runAnimationGroup { $0.duration = 0.08; p.animator().alphaValue = 1 } }
        }
    }

    nonisolated func update(_ state: SwitcherViewState) {
        MainActor.assumeIsolated {
            model.state = state
            guard let p = panel, p.isVisible else { return }
            let f = frame(for: state)
            if p.frame != f { p.setFrame(f, display: true) }
        }
    }

    nonisolated func thumbnailUpdated(windowID: UInt32) {
        MainActor.assumeIsolated { model.revision += 1 }
    }

    nonisolated func dismiss() {
        MainActor.assumeIsolated {
            panel?.orderOut(nil)
            model.state = nil
        }
    }

    nonisolated func contains(_ p: CGPoint) -> Bool {
        MainActor.assumeIsolated { containsPoint(panel, topLeft: p) }
    }
}

@MainActor
final class DockPreviewPanelModel: ObservableObject {
    @Published var state: DockPreviewViewState?
    @Published var revision = 0
    var cache: ThumbnailCache
    var actions = PanelActions()

    init(cache: ThumbnailCache) { self.cache = cache }
}

struct DockPreviewPanelView: View {
    @ObservedObject var model: DockPreviewPanelModel

    var body: some View {
        if let s = model.state { content(s) }
    }

    private func rows(_ s: DockPreviewViewState) -> [[Int]] {
        let cols = max(s.metrics.columns, 1)
        return stride(from: 0, to: s.entries.count, by: cols).map { Array($0..<min($0 + cols, s.entries.count)) }
    }

    @ViewBuilder private func content(_ s: DockPreviewViewState) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: s.metrics.spacing) {
                ForEach(Array(rows(s).enumerated()), id: \.offset) { _, idxs in
                    HStack(spacing: s.metrics.spacing) {
                        ForEach(idxs, id: \.self) { i in
                            let e = s.entries[i]
                            let img = s.thumbnails && e.previewAllowed ? e.windowID.flatMap { model.cache.peek($0) } : nil
                            WindowCardView(entry: e, selected: false, metrics: s.metrics, layout: .windows, image: img, showTitle: s.showTitles && !s.minimal, revision: model.revision,
                                           actions: model.actions, showQuit: s.closeQuitsApp, contextMenu: true, middleCloses: s.middleClickCloses)
                        }
                    }
                }
            }
            .padding(s.metrics.padding)
        }
        .background(VisualEffect(material: .hudWindow).opacity(s.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

@MainActor
final class DockPreviewPanelController: DockPreviewPanelDriving {
    let model: DockPreviewPanelModel
    private var panel: NSPanel?

    nonisolated init(model: DockPreviewPanelModel) { self.model = model }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = makePanel(level: .popUpMenu)
        p.contentView = FirstMouseHostingView(rootView: DockPreviewPanelView(model: model))
        panel = p
        return p
    }

    nonisolated func present(_ state: DockPreviewViewState) {
        MainActor.assumeIsolated {
            model.state = state
            let p = ensurePanel()
            p.setFrame(LiveScreens.cocoaFrame(fromTopLeft: state.frame), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; p.animator().alphaValue = 1 }
        }
    }

    nonisolated func update(_ state: DockPreviewViewState) {
        MainActor.assumeIsolated {
            model.state = state
            guard let p = panel, p.isVisible else { return }
            let f = LiveScreens.cocoaFrame(fromTopLeft: state.frame)
            if p.frame != f { p.setFrame(f, display: true) }
        }
    }

    nonisolated func thumbnailUpdated(windowID: UInt32) {
        MainActor.assumeIsolated { model.revision += 1 }
    }

    nonisolated func dismiss() {
        MainActor.assumeIsolated {
            panel?.orderOut(nil)
            model.state = nil
        }
    }

    nonisolated func contains(_ p: CGPoint) -> Bool {
        MainActor.assumeIsolated { containsPoint(panel, topLeft: p) }
    }
}
