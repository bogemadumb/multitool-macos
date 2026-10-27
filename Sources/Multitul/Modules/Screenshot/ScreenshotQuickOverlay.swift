import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class ShotQuickPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShotQuickItem: ObservableObject, Identifiable {
    let id: Int64
    let outcome: ShotOutcome
    let thumbnail: NSImage
    @Published var timer: ShotOverlayTimer
    @Published var saved: Bool
    @Published var linkText: String?
    @Published var busy = false

    init(id: Int64, outcome: ShotOutcome, seconds: Int) {
        self.id = id
        self.outcome = outcome
        let size = ShotOverlayLogic.thumbnailSize(pixel: CGSize(width: outcome.image.width, height: outcome.image.height))
        thumbnail = NSImage(cgImage: outcome.image, size: size)
        timer = ShotOverlayTimer(seconds: seconds)
        saved = outcome.path != nil && !(outcome.record?.owned ?? false)
    }
}

struct ShotQuickView: View {
    @ObservedObject var item: ShotQuickItem
    let uploadConfigured: Bool
    let act: (ShotOverlayAction) -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let size = item.thumbnail.size
        ZStack(alignment: .bottom) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .onDrag { dragProvider() }
            if hovering || item.busy {
                VStack(spacing: 6) {
                    let actions = ShotOverlayLogic.actions(saved: item.saved, uploadConfigured: uploadConfigured).filter { $0 != .close }
                    HStack(spacing: 4) {
                        ForEach(actions.prefix(4), id: \.self) { a in button(a) }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(actions.dropFirst(4)), id: \.self) { a in button(a) }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
            if let t = item.linkText {
                Text(t).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.7), in: Capsule()).foregroundStyle(.white).padding(.bottom, 4)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { act(.close) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, .black.opacity(0.6)) }
                    .buttonStyle(.plain).padding(4)
            }
        }
        .overlay(alignment: .bottom) {
            if item.timer.total > 0 { ProgressView(value: item.timer.fraction).progressViewStyle(.linear).tint(.white).frame(height: 2).opacity(hovering ? 0 : 0.8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .onHover { h in hovering = h; hover(h) }
    }

    private func button(_ a: ShotOverlayAction) -> some View {
        Button { act(a) } label: {
            Image(systemName: a.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 24)
        }
        .buttonStyle(.bordered)
        .help(a.title)
        .controlSize(.small)
    }

    private func dragProvider() -> NSItemProvider {
        if let p = item.outcome.path { return NSItemProvider(object: URL(fileURLWithPath: p) as NSURL) }
        let name = item.outcome.fileName.isEmpty ? "screenshot.png" : item.outcome.fileName
        let path = MultitulPaths.shotCacheDir + "/drag-" + String(UUID().uuidString.prefix(8)) + "-" + name
        if let d = item.outcome.data, LiveShotFiles().write(d, to: path) { return NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
        return NSItemProvider(object: item.thumbnail)
    }
}

@MainActor
final class ShotQuickOverlay {
    private struct Entry {
        let item: ShotQuickItem
        let panel: ShotQuickPanel
    }

    private var entries: [Int64: Entry] = [:]
    private var stack = ShotOverlayStack()
    private var ticker: Timer?
    private var nextTemp: Int64 = -1
    weak var controller: ScreenshotController?

    func show(_ outcome: ShotOutcome, settings: ShotSettings, uploadConfigured: Bool) {
        let id = outcome.record?.id ?? { defer { nextTemp -= 1 }; return nextTemp }()
        let item = ShotQuickItem(id: id, outcome: outcome, seconds: settings.overlaySeconds)
        let view = ShotQuickView(item: item, uploadConfigured: uploadConfigured, act: { [weak self] a in self?.perform(a, id: id) },
                                 hover: { [weak item] h in item?.timer.setHover(h) })
        let host = NSHostingView(rootView: view)
        let size = item.thumbnail.size
        host.frame = NSRect(origin: .zero, size: size)
        let p = ShotQuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        if let evicted = stack.push(id) { dismiss(evicted) }
        entries[id] = Entry(item: item, panel: p)
        layout(corner: settings.overlayCorner)
        p.orderFrontRegardless()
        startTicker()
    }

    private func visibleFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private func layout(corner: ShotCorner) {
        let vis = visibleFrame()
        for id in stack.ids {
            guard let e = entries[id], let slot = stack.slot(of: id) else { continue }
            let f = ShotOverlayLogic.frame(slot: slot, corner: corner, visible: vis, size: e.item.thumbnail.size)
            e.panel.setFrame(f, display: true, animate: false)
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        for (id, e) in entries {
            var t = e.item.timer
            if t.tick(0.25) { dismiss(id) } else { e.item.timer = t }
        }
        if entries.isEmpty { ticker?.invalidate(); ticker = nil }
    }

    func dismiss(_ id: Int64) {
        guard let e = entries.removeValue(forKey: id) else { return }
        e.panel.orderOut(nil)
        e.panel.contentView = nil
        stack.remove(id)
        if let c = controller { layout(corner: c.settings.overlayCorner) }
    }

    func closeAll() {
        for id in Array(entries.keys) { dismiss(id) }
        ticker?.invalidate()
        ticker = nil
    }

    private func perform(_ a: ShotOverlayAction, id: Int64) {
        guard let e = entries[id], let c = controller else { return }
        let o = e.item.outcome
        switch a {
        case .copy:
            c.copy(o.image, data: o.data)
        case .save:
            let item = e.item
            c.saveFromOverlay(o) { saved in item.saved = saved }
        case .edit:
            c.openEditor(record: o.record, image: o.image)
            dismiss(id)
        case .pin:
            c.pin(image: o.image, record: o.record, title: o.record?.title ?? "Снимок")
            dismiss(id)
        case .link:
            let item = e.item
            item.busy = true
            c.makeLink(record: o.record, image: o.image) { text in
                item.busy = false
                item.linkText = text
            }
        case .share:
            c.share(o, from: e.panel)
        case .delete:
            c.delete(o)
            dismiss(id)
        case .close:
            dismiss(id)
        }
    }
}
