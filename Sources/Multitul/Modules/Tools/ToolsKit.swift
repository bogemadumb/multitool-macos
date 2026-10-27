import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct HotkeyLine: View {
    var title: String
    var subtitle: String?
    var spec: HotkeySpec

    init(_ title: String, _ subtitle: String? = nil, spec: HotkeySpec) {
        self.title = title
        self.subtitle = subtitle
        self.spec = spec
    }

    var body: some View {
        LabeledContent {
            HotkeyRecorder(spec: spec, titles: [:])
        } label: { SettingLabel(title, subtitle) }
    }
}

struct HotkeysFooterLink: View {
    var body: some View {
        Button("Сочетание — в «Горячих клавишах»") { AppController.shared.openSection("keys") }
            .buttonStyle(.link)
            .font(.caption)
    }
}

struct ToolDisabledState: View {
    var title: String
    var symbol: String
    var openModules: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(title): модуль выключен", systemImage: symbol)
        } description: {
            Text("Включить его можно на странице «Модули».")
        } actions: {
            Button("Открыть «Модули»", action: openModules)
        }
    }
}

struct ToolsPermissionNote: View {
    let permission: Permission
    let text: String
    @ObservedObject private var perms = Permissions.shared

    var body: some View {
        if perms.state(permission) == .denied || perms.state(permission) == .undetermined {
            Section {
                ToolWarning(text: text)
                Button("Выдать доступ") { perms.openSettings(permission) }
            }
        }
    }
}

func chooseFolderPath(_ apply: (String) -> Void) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.prompt = "Выбрать"
    if p.runModal() == .OK, let u = p.url { apply(u.path) }
}

