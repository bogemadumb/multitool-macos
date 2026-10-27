import SwiftUI
import AppKit
import Carbon.HIToolbox
import MultitulCore
import MultitulUI

@MainActor
struct HotkeyRecorder: View {
    let spec: HotkeySpec
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?
    var titles: [String: String]

    init(spec: HotkeySpec, titles: [String: String]) {
        self.spec = spec
        self.titles = titles
    }

    var body: some View {
        let _ = hotkeys.overridesRevision
        HStack(spacing: 8) {
            if let error { warn(error) }
            else if case .conflict(let w)? = hotkeys.state(of: spec.id) { warn("занято: \(hotkeys.reservedTitle(of: w) ?? titles[w] ?? w)") }
            else if case .failed? = hotkeys.state(of: spec.id) { warn("система не дала") }
            Button { recording ? stop() : begin() } label: {
                if recording {
                    Text("Нажмите сочетание…").font(.callout.weight(.medium)).padding(.horizontal, 6)
                } else {
                    KeyCaps(hotkeys.combo(for: spec).display)
                }
            }
            .buttonStyle(.plain)
            .help("Нажмите, чтобы записать новое сочетание. Esc — отмена, ⌫ — по умолчанию")
        }
        .onDisappear { stop() }
    }

    private func warn(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
    }

    private func begin() {
        error = nil
        recording = true
        hotkeys.suspendAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        hotkeys.resumeAll()
    }

    private func handle(_ e: NSEvent) {
        let key = UInt32(e.keyCode)
        if key == UInt32(kVK_Escape) { stop(); return }
        if key == UInt32(kVK_Delete) || key == UInt32(kVK_ForwardDelete) {
            stop()
            _ = hotkeys.resetCombo(spec)
            return
        }
        let mods = KeyCombo.carbonModifiers(from: e.modifierFlags)
        let hasMain = mods & (KeyCombo.cmd | KeyCombo.opt | KeyCombo.ctrl) != 0
        let isF = (96...122).contains(Int(key)) && KeyCombo.names[key]?.hasPrefix("F") == true
        guard hasMain || isF else { error = "нужен ⌘, ⌥ или ⌃"; return }
        stop()
        switch hotkeys.setCombo(spec, to: KeyCombo(keyCode: key, modifiers: mods)) {
        case .applied: error = nil
        case .conflict(let w): error = "занято: \(hotkeys.reservedTitle(of: w) ?? titles[w] ?? w)"
        case .failed: error = "система не дала"
        }
    }
}
