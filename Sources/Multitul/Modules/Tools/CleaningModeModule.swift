import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CleaningOverlay: CleaningOverlayShowing {
    private var windows: [NSWindow] = []
    private var labels: [NSTextField] = []
    private var activity: NSObjectProtocol?

    nonisolated init() {}

    nonisolated func show(mode: CleaningScreenMode, needed: Int) {
        MainActor.assumeIsolated { build(mode, needed) }
    }

    nonisolated func update(presses: Int, needed: Int) {
        MainActor.assumeIsolated { for l in labels { l.stringValue = Self.text(presses, needed) } }
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { teardown() }
    }

    private static func text(_ presses: Int, _ needed: Int) -> String {
        presses == 0 ? "Режим уборки\nEsc × \(needed) — выйти" : "Режим уборки\nEsc: \(presses) из \(needed)"
    }

    private func build(_ mode: CleaningScreenMode, _ needed: Int) {
        teardown()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Режим уборки")
        switch mode {
        case .blackout:
            for screen in NSScreen.screens {
                let w = CleaningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
                w.backgroundColor = .black
                w.isOpaque = true
                w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                w.isReleasedWhenClosed = false
                w.ignoresMouseEvents = false
                let label = Self.label(size: 22, color: NSColor(white: 1, alpha: 0.55))
                label.stringValue = Self.text(0, needed)
                label.sizeToFit()
                label.frame.origin = NSPoint(x: (screen.frame.width - label.frame.width) / 2, y: (screen.frame.height - label.frame.height) / 2)
                w.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                w.contentView?.addSubview(label)
                label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
                labels.append(label)
                w.orderFrontRegardless()
                windows.append(w)
            }
        case .indicator:
            guard let screen = NSScreen.main else { return }
            let size = NSSize(width: 190, height: 60)
            let w = CleaningWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 14
            fx.layer?.masksToBounds = true
            let label = Self.label(size: 13, color: .labelColor)
            label.stringValue = Self.text(0, needed)
            label.frame = NSRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
            fx.addSubview(label)
            labels.append(label)
            w.contentView = fx
            w.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.maxY - size.height - 16))
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private static func label(size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: .medium)
        l.textColor = color
        l.alignment = .center
        l.maximumNumberOfLines = 2
        return l
    }

    private func teardown() {
        for w in windows { w.orderOut(nil); w.contentView = nil }
        windows = []
        labels = []
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }
}

@MainActor
final class CleaningController: ObservableObject {
    static let shared = CleaningController()

    @Published private(set) var settings = CleaningSettings()
    @Published private(set) var active = false
    @Published private(set) var lastNote = ""

    private let store = CleaningSettingsStore()
    private let overlay = CleaningOverlay()
    private var session: CleaningSession?
    private var timer: Timer?
    private var running = false
    let spec = ToolsHotkeys.cleaningToggle

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        HotkeyManager.shared.register(spec, owner: ModuleID.cleaningMode.rawValue) { [weak self] in self?.toggle() }
        ToolsRouter.shared.register(.cleaningMode) { [weak self] in self?.begin() }
    }

    func stop() {
        guard running else { return }
        running = false
        end()
        HotkeyManager.shared.unregisterAll(owner: ModuleID.cleaningMode.rawValue)
        ToolsRouter.shared.unregister(.cleaningMode)
    }

    func update(_ s: CleaningSettings) {
        settings = s.sanitized
        store.save(settings)
    }

    func toggle() { active ? end() : begin() }

    func begin() {
        guard running, !active else { return }
        guard Permissions.accessibilityTrusted else {
            lastNote = "Нужен «Универсальный доступ»: без него клавиатуру не заблокировать"
            HUD.show("Режим уборки: нужен доступ «Универсальный доступ»")
            return
        }
        let s = CleaningSession(hub: EventTapHub.shared, overlay: overlay, settings: settings)
        s.onFinish = { [weak self] reason in
            MainActor.assumeIsolated { self?.finished(reason) }
        }
        switch s.start() {
        case .started:
            session = s
            active = true
            lastNote = ""
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.session?.tick() }
            }
            Log.write("cleaningMode started mode=\(settings.screenMode.rawValue) mouse=\(settings.blockMouse)")
        case .noTap:
            lastNote = "Не удалось перехватить клавиатуру. Выдай «Универсальный доступ» и «Мониторинг ввода» и повтори"
            HUD.show("Режим уборки: не удалось перехватить клавиатуру")
        case .alreadyRunning:
            break
        }
    }

    func end() {
        session?.stop()
    }

    private func finished(_ reason: CleaningSession.FinishReason) {
        timer?.invalidate()
        timer = nil
        session = nil
        active = false
        Log.write("cleaningMode finished \(reason)")
        HUD.show(reason == .timeout ? "Режим уборки выключен по таймеру" : "Режим уборки выключен")
    }
}

@MainActor
final class CleaningModeModule: Module {
    let info = ModuleID.cleaningMode.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(CleaningTile()) }

    func start() { CleaningController.shared.start(); Log.write("module cleaningMode start") }
    func stop() { CleaningController.shared.stop(); Log.write("module cleaningMode stop") }
}

struct CleaningTile: View {
    @ObservedObject private var c = CleaningController.shared

    var body: some View {
        QuickTile(symbol: "sparkles", caption: "Уборка", active: c.active) { c.toggle() }
    }
}

struct CleaningModeSections: View {
    @ObservedObject private var c = CleaningController.shared

    private func binding<T>(_ kp: WritableKeyPath<CleaningSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .accessibility, text: "Нужен «Универсальный доступ»: без него перехват клавиатуры не работает.")
        Section {
            LabeledContent("Состояние", value: c.active ? "клавиатура заблокирована" : "выключен")
            Button(c.active ? "Выключить режим уборки" : "Включить режим уборки") { c.toggle() }
            if !c.lastNote.isEmpty { ToolWarning(text: c.lastNote) }
        } header: { Text("Уборка") } footer: {
            SectionFooter("Выход: \(c.settings.exitPresses) раз нажать Escape. Настройки применяются при следующем включении. Блокируются клавиши, медиа-клавиши и модификаторы.")
        }
        Section("Параметры уборки") {
            Picker(selection: binding(\.screenMode)) {
                ForEach(CleaningScreenMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Экран", "Чёрный экран закрывает все дисплеи; индикатор — маленькая плашка в углу") }
            StepperSetting("Нажатий Escape для выхода", value: binding(\.exitPresses), in: CleaningSettings.pressRange, unit: " раз")
            StepperSetting("Окно между нажатиями", "Нажатия вне окна не складываются",
                           value: Binding(get: { Int(c.settings.pressWindow) }, set: { v in var s = c.settings; s.pressWindow = Double(v); c.update(s) }),
                           in: Int(CleaningSettings.windowRange.lowerBound)...Int(CleaningSettings.windowRange.upperBound), unit: " с")
            StepperSetting("Автовыход через", "0 — не выключать само", value: binding(\.autoEndMinutes), in: CleaningSettings.autoEndRange, unit: " мин", zeroText: "не выключать")
            Toggle(isOn: binding(\.blockMouse)) { SettingLabel("Блокировать и мышь с тачпадом", "По умолчанию мышь работает, чтобы можно было нажать на экран; включи, если протираешь тачпад") }
        }
    }
}
