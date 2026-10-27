import SwiftUI
import AppKit
import Combine
import MultitulCore
import MultitulUI

extension VpnState.Tone {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .grey: .secondary
        }
    }
}

enum VpnShieldIcon {
    @MainActor private static var cache: [VpnState.Tone: NSImage] = [:]

    @MainActor static func image(for tone: VpnState.Tone) -> NSImage {
        if let c = cache[tone] { return c }
        let img = draw(tone)
        cache[tone] = img
        return img
    }

    private static func dotColor(_ t: VpnState.Tone) -> NSColor? {
        switch t {
        case .green: NSColor(srgbRed: 0x3D / 255, green: 0xBA / 255, blue: 0x7E / 255, alpha: 1)
        case .yellow: NSColor(srgbRed: 0xE5 / 255, green: 0xA4 / 255, blue: 0x3B / 255, alpha: 1)
        case .red: NSColor(srgbRed: 0xF0 / 255, green: 0x55 / 255, blue: 0x3A / 255, alpha: 1)
        case .grey: nil
        }
    }

    static func draw(_ tone: VpnState.Tone) -> NSImage {
        let dot = dotColor(tone)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let k: CGFloat = 18.0 / 24.0
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 12, y: 2.6))
            shield.line(to: NSPoint(x: 4.6, y: 5.4))
            shield.line(to: NSPoint(x: 4.6, y: 11.5))
            shield.curve(to: NSPoint(x: 12, y: 21.4), controlPoint1: NSPoint(x: 4.6, y: 16.1), controlPoint2: NSPoint(x: 7.7, y: 19.6))
            shield.curve(to: NSPoint(x: 19.4, y: 11.5), controlPoint1: NSPoint(x: 16.3, y: 19.6), controlPoint2: NSPoint(x: 19.4, y: 16.1))
            shield.line(to: NSPoint(x: 19.4, y: 5.4))
            shield.close()
            shield.transform(using: AffineTransform(scaleByX: k, byY: k))
            shield.lineWidth = 1.8 * k
            shield.lineJoinStyle = .round
            shield.lineCapStyle = .round
            let center = NSPoint(x: 18.6 * k, y: 18.6 * k)
            NSGraphicsContext.saveGraphicsState()
            if dot != nil {
                let clip = NSBezierPath(rect: NSRect(x: -2, y: -2, width: 22, height: 22))
                clip.appendOval(in: NSRect(x: center.x - 4.4 * k, y: center.y - 4.4 * k, width: 8.8 * k, height: 8.8 * k))
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            (dot == nil ? NSColor.labelColor.withAlphaComponent(0.4) : NSColor.labelColor).setStroke()
            shield.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if let d = dot {
                d.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 3.1 * k, y: center.y - 3.1 * k, width: 6.2 * k, height: 6.2 * k)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

@MainActor
final class VpnStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onClick: () -> Void

    init(state: VpnState, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseDown])
        update(state)
    }

    @objc private func clicked() { onClick() }

    func update(_ state: VpnState) {
        item.button?.image = VpnShieldIcon.image(for: state.tone)
        item.button?.toolTip = "VPN: " + state.shortTitle
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

@MainActor
final class VpnModule: Module {
    let info = ModuleID.vpn.info
    let controller = VpnController()
    private var shield: VpnStatusItem?
    private var stateSink: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?

    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(VpnPage(controller: controller, traffic: controller.traffic)) }
    var quickTile: AnyView? { AnyView(VpnQuickTile(controller: controller)) }
    var panelPresentation: PanelPresentation { .module }

    static func openPage() { AppController.shared.openSection(ModuleGroup.net.rawValue) }

    func start() {
        Notifier.shared.requestAuthorization()
        HotkeyManager.shared.register(info.hotkeys[0], owner: info.id.rawValue) { VpnModule.openPage() }
        controller.start()
        stateSink = controller.$state.sink { [weak self] s in self?.shield?.update(s) }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncShield() }
        }
        syncShield()
        Log.write("vpn module start")
    }

    func stop() {
        stateSink = nil
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o); defaultsObserver = nil }
        shield?.remove()
        shield = nil
        HotkeyManager.shared.unregisterAll(owner: info.id.rawValue)
        controller.stop()
        Log.write("vpn module stop")
    }

    private func syncShield() {
        let want = (UserDefaults.standard.object(forKey: VpnKeys.showShield) as? Bool) ?? true
        if want && shield == nil {
            shield = VpnStatusItem(state: controller.state) { VpnModule.openPage() }
        } else if !want, let s = shield {
            s.remove()
            shield = nil
        }
    }
}

struct VpnQuickTile: View {
    @ObservedObject var controller: VpnController

    private var status: String {
        switch controller.state {
        case .off: return "Выключен"
        case .ok: return controller.delayMs.map { "\($0) мс" } ?? "Работает"
        case .slow, .degraded: return controller.delayMs.map { "Медленно · \($0) мс" } ?? "Медленно"
        case .connecting: return "Подключение…"
        case .down: return "Нет связи"
        }
    }

    var body: some View {
        ModuleTile(symbol: controller.daemonRunning ? "shield.lefthalf.filled" : "shield.slash.fill", title: "VPN", status: status, active: controller.state == .ok, action: {
            let wasRunning = controller.daemonRunning
            controller.toggle()
            if wasRunning { VpnModule.openPage() }
        }, options: { options })
        .contextMenu { options }
    }

    @ViewBuilder private var options: some View {
        ForEach(VpnMode.allCases, id: \.self) { m in
            Button((controller.currentMode == m ? "✓ " : "") + m.label) { controller.setMode(m) }
        }
        Divider()
        Button("Этот сайт — напрямую") { controller.rules.addCurrentSite() }
        Button("Открыть раздел «Сеть»") { VpnModule.openPage() }
    }
}
