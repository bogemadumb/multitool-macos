import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

enum StorozhIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ s: StorozhIconState) -> NSImage {
        let key = "\(s.level)-\(s.paused)"
        if let c = cache[key] { return c }
        let img = draw(s)
        cache[key] = img
        return img
    }

    private static func draw(_ s: StorozhIconState) -> NSImage {
        let color: NSColor? = s.level == .normal ? nil : (s.level == .warn ? .systemYellow : .systemRed)
        var cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: s.level == .normal ? .regular : .semibold)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        guard let base = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Сторож")?.withSymbolConfiguration(cfg) else { return NSImage() }
        if !s.paused {
            base.isTemplate = color == nil
            return base
        }
        let badgeBase = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let badgeCfg = color.map { badgeBase.applying(.init(paletteColors: [$0])) } ?? badgeBase
        let badge = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: "Пауза")?.withSymbolConfiguration(badgeCfg)
        let size = NSSize(width: base.size.width + 5, height: base.size.height + 2)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: rect.height - base.size.height, width: base.size.width, height: base.size.height))
            if let badge {
                let b = badge.size
                let clear = NSRect(x: rect.width - b.width - 1, y: 0, width: b.width + 1, height: b.height + 1)
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                NSBezierPath(ovalIn: clear.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                badge.draw(in: NSRect(x: rect.width - b.width, y: 0, width: b.width, height: b.height))
            }
            return true
        }
        img.isTemplate = color == nil
        return img
    }

    static func tooltip(_ s: StorozhIconState, open: Int) -> String {
        var t = "Сторож"
        switch s.level {
        case .normal: t += ": всё спокойно"
        case .warn: t += ": требуют внимания — \(open)"
        case .crit: t += ": критическое давление памяти"
        }
        return s.paused ? t + " (пауза)" : t
    }
}

@MainActor
final class StorozhStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseDown])
        update(StorozhIconState(level: .normal, paused: false), open: 0)
    }

    @objc private func clicked() { onClick() }

    func update(_ s: StorozhIconState, open: Int) {
        item.button?.image = StorozhIcon.image(s)
        item.button?.toolTip = StorozhIcon.tooltip(s, open: open)
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

@MainActor
final class StorozhModule: Module {
    static let showIconKey = "storozh.showIcon"
    let info = ModuleID.storozh.info
    private var statusItem: StorozhStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(StorozhQuickTile()) }

    static func openPage() {
        AppController.shared.openSection("guard")
    }

    func start() {
        let c = StorozhController.shared
        c.onIcon = { [weak self] s in self?.statusItem?.update(s, open: c.open.count) }
        c.start()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncItem() }
        }
        syncItem()
        Log.write("storozh module start")
    }

    func stop() {
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o); defaultsObserver = nil }
        statusItem?.remove()
        statusItem = nil
        StorozhController.shared.stop()
        Log.write("storozh module stop")
    }

    private func syncItem() {
        let want = (UserDefaults.standard.object(forKey: Self.showIconKey) as? Bool) ?? true
        if want && statusItem == nil {
            let item = StorozhStatusItem { StorozhModule.openPage() }
            let c = StorozhController.shared
            item.update(c.icon, open: c.open.count)
            statusItem = item
        } else if !want, let s = statusItem {
            s.remove()
            statusItem = nil
        }
    }
}

struct StorozhQuickTile: View {
    @ObservedObject private var c = StorozhController.shared

    var body: some View {
        QuickTile(symbol: c.icon.paused ? "bell.slash" : "gauge.with.dots.needle.33percent",
                  caption: c.open.isEmpty ? "Сторож" : "Сторож \(c.open.count)",
                  active: c.icon.level != .normal) { StorozhModule.openPage() }
    }
}
