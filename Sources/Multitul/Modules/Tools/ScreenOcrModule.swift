import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ScreenOcrController: ObservableObject {
    static let shared = ScreenOcrController()

    @Published private(set) var settings = OcrSettings()
    @Published private(set) var capturing = false
    @Published private(set) var lastText = ""
    @Published private(set) var note = ""

    private let store = OcrSettingsStore()
    private let capture = ScreenCapture()
    private let recognizer = VisionOcrRecognizer()
    private let clipboard = PasteboardTextWriter()
    private var overlay = ScreenOverlaySet()
    private var keyMonitor: Any?
    private var running = false
    let spec = ToolsHotkeys.ocrCapture

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        HotkeyManager.shared.register(spec, owner: ModuleID.screenOcr.rawValue) { [weak self] in self?.begin() }
        ToolsRouter.shared.register(.screenOcr) { [weak self] in self?.begin() }
    }

    func stop() {
        guard running else { return }
        running = false
        finishSelection()
        HotkeyManager.shared.unregisterAll(owner: ModuleID.screenOcr.rawValue)
        ToolsRouter.shared.unregister(.screenOcr)
    }

    func update(_ s: OcrSettings) {
        settings = s.sanitized
        store.save(settings)
    }

    func begin() {
        guard running, !capturing else { return }
        guard ScreenCapture.hasPermission else {
            note = "Нужен доступ «Запись экрана»"
            Permissions.shared.openSettings(.screenRecording)
            return
        }
        note = ""
        capturing = true
        Task { @MainActor in
            let shots = await capture.captureAll()
            guard capturing else { return }
            guard !shots.isEmpty else {
                note = "Не удалось снять экран"
                capturing = false
                return
            }
            present(shots)
        }
    }

    private func present(_ shots: [ScreenCapture.Shot]) {
        overlay = ScreenOverlaySet()
        for shot in shots {
            guard let screen = NSScreen.screens.first(where: { $0.frame == shot.frame }) else { continue }
            let v = RegionSelectView(shot: shot)
            v.onFinish = { [weak self, weak v] rect, shot in
                guard let self else { return }
                let h = v?.bounds.height ?? shot.frame.height
                self.finishSelection()
                if let rect, let img = shot.crop(viewRect: rect, viewHeight: h) { self.recognize(img) }
            }
            overlay.add(screen, content: v)
        }
        guard !overlay.windows.isEmpty else { capturing = false; return }
        overlay.showAll()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.finishSelection() }
            return nil
        }
    }

    private func finishSelection() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlay.closeAll()
        capturing = false
    }

    private func recognize(_ image: CGImage) {
        let settings = self.settings
        let rec = recognizer
        let cb = clipboard
        Task.detached(priority: .userInitiated) {
            let engine = ScreenOcrEngine(recognizer: rec, clipboard: cb, settings: settings)
            let outcome = engine.process(image)
            await MainActor.run { ScreenOcrController.shared.show(outcome) }
        }
    }

    private func show(_ outcome: OcrOutcome) {
        switch outcome {
        case .text(let t):
            lastText = t
            if settings.showHud { HUD.show("Текст скопирован (\(t.count) симв.)") }
            Log.write("screenOcr text chars=\(t.count)")
        case .nothing:
            HUD.show("Текст не найден")
        case .failed(let m):
            note = "Ошибка распознавания: \(m)"
            HUD.show("Не удалось распознать текст")
        case .codes(let list):
            presentCodes(list)
        }
    }

    private func presentCodes(_ list: [QrContent]) {
        NSApp.activate(ignoringOtherApps: true)
        for code in list {
            let alert = NSAlert()
            alert.messageText = "QR-код: \(code.title)"
            alert.informativeText = code.displayText
            alert.addButton(withTitle: "Скопировать")
            if code.openURL != nil { alert.addButton(withTitle: "Открыть") }
            alert.addButton(withTitle: "Закрыть")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                clipboard.write(code.copyText)
                lastText = code.copyText
                HUD.show("Скопировано")
            } else if r == .alertSecondButtonReturn, let u = code.openURL {
                NSWorkspace.shared.open(u)
            }
        }
    }
}

@MainActor
final class ScreenOcrModule: Module {
    let info = ModuleID.screenOcr.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "text.viewfinder", caption: "Текст", help: "Текст с экрана") { ScreenOcrController.shared.begin() }) }

    func start() { ScreenOcrController.shared.start(); Log.write("module screenOcr start") }
    func stop() { ScreenOcrController.shared.stop(); Log.write("module screenOcr stop") }
}

struct ScreenOcrSections: View {
    @ObservedObject private var c = ScreenOcrController.shared

    private func binding<T>(_ kp: WritableKeyPath<OcrSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var languagesText: Binding<String> {
        Binding(get: { c.settings.request.languages.joined(separator: ", ") }, set: { v in
            var s = c.settings
            s.request.languages = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            c.update(s)
        })
    }

    var body: some View {
        ToolsPermissionNote(permission: .screenRecording, text: "Нужен доступ «Запись экрана»: без него область не снять.")
        if !c.note.isEmpty { Section { ToolWarning(text: c.note) } }
        Section {
            Button("Выделить область") { c.begin() }.disabled(c.capturing)
        } header: { Text("Текст с экрана") } footer: {
            SectionFooter("Выдели область: текст распознаётся офлайн и копируется; QR-код показывается с кнопками «Скопировать» и «Открыть».")
        }
        Section("Распознавание") {
            Picker(selection: Binding(get: { c.settings.request.level }, set: { v in var s = c.settings; s.request.level = v; c.update(s) })) {
                ForEach(OcrLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Режим распознавания", "«Точно» медленнее, но лучше читает мелкий и стилизованный текст") }
            FieldSetting("Языки", "Коды через запятую, по порядку важности", text: languagesText, prompt: "ru-RU, en-US")
            Toggle(isOn: Binding(get: { c.settings.request.usesLanguageCorrection }, set: { v in var s = c.settings; s.request.usesLanguageCorrection = v; c.update(s) })) {
                SettingLabel("Исправлять по словарю", "Поправляет опечатки распознавания; выключи для кода и артикулов")
            }
            Toggle(isOn: binding(\.removeLineBreaks)) { SettingLabel("Убрать переносы строк", "Весь распознанный текст одной строкой; переносы слов по дефису склеиваются") }
            Toggle(isOn: binding(\.detectQr)) { SettingLabel("Искать QR-коды", "Если в области есть QR-код, показывается его содержимое вместо распознавания текста") }
            Toggle(isOn: binding(\.showHud)) { SettingLabel("Показывать плашку", "Короткая надпись «Текст скопирован»") }
        }
        if !c.lastText.isEmpty {
            Section("Последний результат") {
                Text(c.lastText).monospaced().textSelection(.enabled).lineLimit(8)
            }
        }
    }
}
