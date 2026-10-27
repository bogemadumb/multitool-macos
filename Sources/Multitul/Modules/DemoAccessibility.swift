import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore
import MultitulUI

@MainActor
final class DemoAccessibilityModel: ObservableObject {
    @Published var appName = "—"
    @Published var windowTitle = "—"
    @Published var trusted = AXIsProcessTrusted()

    private var timer: Timer?
    private var lastForeignPID: pid_t?

    func begin() {
        poll()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        trusted = AXIsProcessTrusted()
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            lastForeignPID = app.processIdentifier
            appName = app.localizedName ?? "?"
        }
        guard trusted, let pid = lastForeignPID else {
            windowTitle = trusted ? "—" : "нет доступа"
            return
        }
        let el = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else {
            windowTitle = "(окна нет)"
            return
        }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
        windowTitle = (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(без заголовка)"
    }
}

@MainActor
final class DemoAccessibilityModule: Module {
    let info = ModuleID.demoAccessibility.info
    let model = DemoAccessibilityModel()

    func start() {
        model.begin()
        Log.write("demoAccessibility start trusted=\(AXIsProcessTrusted())")
    }

    func stop() {
        model.end()
        Log.write("demoAccessibility stop")
    }

    var settingsView: AnyView { AnyView(DemoAccessibilityCard(model: model)) }
}

struct DemoAccessibilityCard: View {
    @ObservedObject var model: DemoAccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.trusted {
                HStack {
                    Pill("нужен Универсальный доступ", style: .warn)
                    Spacer()
                    Button("Открыть настройки") { Permissions.shared.openSettings(.accessibility) }
                }
                Divider()
            }
            ListRow(title: "Приложение", value: model.appName)
            Divider()
            ListRow(title: "Окно", value: model.windowTitle)
        }
    }
}
