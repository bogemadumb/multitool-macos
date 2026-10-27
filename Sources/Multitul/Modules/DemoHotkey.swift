import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class DemoHotkeyModel: ObservableObject {
    @Published var count = 0
    var spec: HotkeySpec { ModuleID.demoHotkey.info.hotkeys[0] }

    func fire() {
        count += 1
        Log.write("demoHotkey fired count=\(count)")
        HUD.show("Сочетание сработало · \(count)")
        Notifier.shared.post(title: "Мультитул", body: "Демо-сочетание сработало (\(count))", id: "demoHotkey")
    }
}

@MainActor
final class DemoHotkeyModule: Module {
    let info = ModuleID.demoHotkey.info
    let model = DemoHotkeyModel()

    func start() {
        Notifier.shared.requestAuthorization()
        HotkeyManager.shared.register(model.spec, owner: info.id.rawValue) { [model] in model.fire() }
        Log.write("demoHotkey start")
    }

    func stop() {
        HotkeyManager.shared.unregisterAll(owner: info.id.rawValue)
        Log.write("demoHotkey stop")
    }

    var settingsView: AnyView { AnyView(DemoHotkeyCard(model: model)) }
}

struct DemoHotkeyCard: View {
    @ObservedObject var model: DemoHotkeyModel
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        let _ = hotkeys.overridesRevision
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сочетание").font(Theme.Fonts.body)
                Spacer()
                KeyCaps(hotkeys.combo(for: model.spec).display)
                switch hotkeys.state(of: model.spec.id) {
                case .active?: Pill("активно", style: .ok)
                case .conflict(let w)?: Pill("занято: \(w)", style: .warn)
                case .failed?: Pill("система не дала", style: .warn)
                case nil: Pill("не зарегистрировано")
                }
            }
            Divider()
            HStack {
                Text("Сработало раз: \(model.count)").font(Theme.Fonts.number).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Проверить") { model.fire() }
            }
        }
    }
}

@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var task: DispatchWorkItem?

    static func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.sizeToFit()
        let pad: CGFloat = 20
        let size = NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad)
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: pad, y: (size.height - label.frame.height) / 2)
        fx.addSubview(label)
        let p = panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        p.setContentSize(size)
        if let s = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY + s.frame.height * 0.22))
        }
        p.orderFrontRegardless()
        panel = p
        task?.cancel()
        let w = DispatchWorkItem { panel?.orderOut(nil) }
        task = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}
