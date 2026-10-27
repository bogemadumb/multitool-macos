import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class PickCanvasView: NSView {
    let shot: ScreenCapture.Shot
    let session: ColorPickerSession
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    init?(shot: ScreenCapture.Shot, settings: ColorPickerSettings, clipboard: TextWriting, history: ColorHistoryStore) {
        guard let src = BitmapPixelSource(image: shot.image) else { return nil }
        self.shot = shot
        session = ColorPickerSession(source: src, settings: settings, clipboard: clipboard, history: history)
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func syncToMouse() {
        let p = window?.mouseLocationOutsideOfEventStream ?? .zero
        let v = convert(p, from: nil)
        session.moveTo(x: Int((v.x * shot.scale).rounded(.down)), y: Int(((bounds.height - v.y) * shot.scale).rounded(.down)))
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { syncToMouse(); onMoved?() }
    override func mouseDragged(with event: NSEvent) { syncToMouse(); onMoved?() }
    override func mouseDown(with event: NSEvent) { syncToMouse(); onClick?() }

    var cursorViewPoint: NSPoint {
        NSPoint(x: (CGFloat(session.x) + 0.5) / shot.scale, y: bounds.height - (CGFloat(session.y) + 0.5) / shot.scale)
    }

    var cursorGlobalCG: CGPoint {
        let b = CGDisplayBounds(shot.displayID)
        return CGPoint(x: b.minX + (CGFloat(session.x) + 0.5) / shot.scale, y: b.minY + (CGFloat(session.y) + 0.5) / shot.scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)
        let grid = session.loupe()
        let n = grid.count
        let cell: CGFloat = 11
        let side = CGFloat(n) * cell
        let labelH: CGFloat = 26
        let c = cursorViewPoint
        var origin = NSPoint(x: c.x + 22, y: c.y - 22 - side)
        if origin.x + side > bounds.maxX - 8 { origin.x = c.x - 22 - side }
        if origin.y < labelH + 8 { origin.y = c.y + 22 + labelH }
        if origin.y + side > bounds.maxY - 8 { origin.y = bounds.maxY - 8 - side }
        let box = NSRect(x: origin.x, y: origin.y, width: side, height: side)
        let frame = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.85).setFill()
        frame.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).addClip()
        for (row, line) in grid.enumerated() {
            for (col, color) in line.enumerated() {
                (color.map(nsColor) ?? NSColor.darkGray).setFill()
                NSRect(x: box.minX + CGFloat(col) * cell, y: box.maxY - CGFloat(row + 1) * cell, width: cell, height: cell).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let mid = n / 2
        let center = NSRect(x: box.minX + CGFloat(mid) * cell, y: box.maxY - CGFloat(mid + 1) * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        let ring = NSBezierPath(rect: center.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 2
        ring.stroke()
        NSColor.black.setStroke()
        let inner = NSBezierPath(rect: center.insetBy(dx: 1, dy: 1))
        inner.lineWidth = 1
        inner.stroke()
        if let text = session.currentText, let cur = session.current {
            let tag = NSRect(x: box.minX - 3, y: box.minY - labelH - 4, width: side + 6, height: labelH)
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
            nsColor(cur).setFill()
            NSBezierPath(roundedRect: NSRect(x: tag.minX + 5, y: tag.minY + 5, width: 16, height: 16), xRadius: 3, yRadius: 3).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            (text as NSString).draw(in: NSRect(x: tag.minX + 27, y: tag.minY + 5, width: tag.width - 30, height: 16), withAttributes: attrs)
        }
    }
}

@MainActor
final class ColorPickerController: ObservableObject {
    static let shared = ColorPickerController()

    @Published private(set) var settings = ColorPickerSettings()
    @Published private(set) var last: RGBAColor?
    @Published private(set) var history: [SavedColor] = []
    @Published private(set) var favorites: [SavedColor] = []
    @Published private(set) var picking = false
    @Published private(set) var note = ""

    private let settingsStore = ColorPickerSettingsStore()
    private var historyStore: ColorHistoryStore?
    private let clipboard = PasteboardTextWriter()
    private let capture = ScreenCapture()
    private var overlay = ScreenOverlaySet()
    private var views: [PickCanvasView] = []
    private var keyMonitor: Any?
    private var sampler: NSColorSampler?
    private var running = false
    let spec = ToolsHotkeys.colorPick

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        historyStore = ColorHistoryStore(UserDefaults.standard, limit: settings.historyLimit)
        reloadLists()
        HotkeyManager.shared.register(spec, owner: ModuleID.colorPicker.rawValue) { [weak self] in self?.pick() }
        ToolsRouter.shared.register(.colorPicker) { [weak self] in self?.pick() }
    }

    func stop() {
        guard running else { return }
        running = false
        finish()
        HotkeyManager.shared.unregisterAll(owner: ModuleID.colorPicker.rawValue)
        ToolsRouter.shared.unregister(.colorPicker)
    }

    func update(_ s: ColorPickerSettings) {
        settings = s.sanitized
        settingsStore.save(settings)
        historyStore?.limit = settings.historyLimit
        reloadLists()
    }

    private func reloadLists() {
        history = historyStore?.history ?? []
        favorites = historyStore?.favorites ?? []
    }

    func isFavorite(_ c: RGBAColor) -> Bool { historyStore?.isFavorite(c) ?? false }
    func toggleFavorite(_ c: RGBAColor) { historyStore?.toggleFavorite(c); reloadLists() }
    func removeHistory(at i: Int) { historyStore?.remove(historyAt: i); reloadLists() }
    func clearHistory() { historyStore?.clearHistory(); reloadLists() }

    func copy(_ c: RGBAColor, as f: ColorFormat? = nil) {
        let text = ColorFormatter.format(c.converted(to: settings.outputSpace), as: f ?? settings.format, options: settings.options)
        clipboard.write(text)
        last = c
        if settings.showHud { HUD.show("Скопировано: \(text)") }
    }

    func pick() {
        guard running, !picking else { return }
        guard ScreenCapture.hasPermission else {
            note = "Нет доступа к записи экрана: открыта обычная системная пипетка без лупы и стрелок"
            systemSampler()
            return
        }
        note = ""
        picking = true
        Task { @MainActor in
            let shots = await capture.captureAll()
            guard picking else { return }
            guard !shots.isEmpty else {
                note = "Не удалось снять экран. Проверь доступ к записи экрана"
                picking = false
                systemSampler()
                return
            }
            present(shots)
        }
    }

    private func systemSampler() {
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] color in
            MainActor.assumeIsolated {
                guard let self, let color, let c = rgbaColor(color) else { return }
                self.historyStore?.record(c)
                self.reloadLists()
                self.copy(c)
                self.sampler = nil
            }
        }
    }

    private func present(_ shots: [ScreenCapture.Shot]) {
        guard let store = historyStore else { picking = false; return }
        overlay = ScreenOverlaySet()
        views = []
        for shot in shots {
            guard let screen = NSScreen.screens.first(where: { $0.frame == shot.frame }),
                  let v = PickCanvasView(shot: shot, settings: settings, clipboard: clipboard, history: store) else { continue }
            v.onClick = { [weak self, weak v] in if let v { self?.apply(.copyAndClose, on: v) } }
            overlay.add(screen, content: v)
            views.append(v)
        }
        guard !views.isEmpty else { picking = false; return }
        overlay.showAll()
        overlay.hideCursor()
        views.forEach { $0.syncToMouse() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : e
        }
    }

    private func activeView() -> PickCanvasView? {
        let m = NSEvent.mouseLocation
        return views.first { $0.window?.frame.contains(m) == true } ?? views.first
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard picking, let action = PickerKeys.action(keyCode: UInt32(e.keyCode), shift: e.modifierFlags.contains(.shift)), let v = activeView() else { return false }
        apply(action, on: v)
        return true
    }

    private func apply(_ action: PickerAction, on v: PickCanvasView) {
        switch v.session.handle(action) {
        case .moved:
            CGWarpMouseCursorPosition(v.cursorGlobalCG)
            v.needsDisplay = true
        case .cancelled:
            finish()
        case .nothing:
            break
        case .copied(let text, let closes):
            last = v.session.current
            reloadLists()
            if settings.showHud { HUD.show("Скопировано: \(text)") }
            if closes { finish() }
        }
    }

    private func finish() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlay.closeAll()
        views = []
        picking = false
    }
}

@MainActor
final class ColorPickerModule: Module {
    let info = ModuleID.colorPicker.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "eyedropper.full", caption: "Пипетка") { ColorPickerController.shared.pick() }) }

    func start() { ColorPickerController.shared.start(); Log.write("module colorPicker start") }
    func stop() { ColorPickerController.shared.stop(); Log.write("module colorPicker stop") }
}

struct Swatch: View {
    let color: RGBAColor
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor(color)))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct ColorPickerSections: View {
    @ObservedObject private var c = ColorPickerController.shared

    private func binding<T>(_ kp: WritableKeyPath<ColorPickerSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .screenRecording, text: "Без записи экрана открывается обычная системная пипетка: нет лупы и стрелок.")
        if !c.note.isEmpty { Section { ToolWarning(text: c.note) } }
        Section {
            Button("Взять цвет") { c.pick() }.disabled(c.picking)
        } header: { Text("Пипетка") } footer: {
            SectionFooter("Стрелки двигают пиксель (⇧ — на 10), Return копирует и закрывает, C копирует и оставляет, Esc — отмена.")
        }
        Section("Копирование цвета") {
            Picker(selection: binding(\.format)) {
                ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
            } label: { SettingLabel("Что копировать", "Формат по умолчанию для Return и C") }
            Picker(selection: binding(\.outputSpace)) {
                ForEach(ColorSpaceKind.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Цветовое пространство", "Экран Мака может отдавать Display P3; HEX и RGB в P3 не существуют, их считаем в sRGB") }
            Toggle(isOn: binding(\.withoutHash)) { SettingLabel("HEX без решётки", "FF8800 вместо #FF8800") }
            Toggle(isOn: binding(\.uppercaseHex)) { SettingLabel("HEX заглавными буквами", "Выключено — строчными") }
            Toggle(isOn: binding(\.showHud)) { SettingLabel("Показывать плашку", "Короткая надпись «Скопировано» после выбора цвета") }
        }
        Section("Лупа и история") {
            IntSliderSetting("Размер лупы", "Клеток от центра", unit: " кл.", value: binding(\.loupeRadius), in: ColorPickerSettings.loupeRange)
            Toggle(isOn: binding(\.recordHistory)) { SettingLabel("Запоминать в истории", "Каждый скопированный цвет попадает в историю") }
            IntSliderSetting("Глубина истории", unit: " цв.", value: binding(\.historyLimit), in: ColorHistoryStore.limitRange)
        }
        Section {
            NavigationLink(value: ToolRoute.colorConverter) {
                LabeledContent("Конвертер и палитра", value: "\(c.favorites.count) в избранном")
            }
            NavigationLink(value: ToolRoute.colorContrast) { Text("Контраст WCAG") }
        } header: { Text("Инструменты цвета") }
    }
}

struct ColorConverterPage: View {
    @ObservedObject private var c = ColorPickerController.shared
    @State private var input = ""

    private var shown: RGBAColor? { ColorParser.parse(input) ?? c.last }

    var body: some View {
        SettingsPage {
            Section {
                TextField("Цвет", text: $input, prompt: Text("#FF8800, rgb(255 136 0), hsl(32 100% 50%), oklch(0.75 0.17 60)"))
                if let col = shown {
                    LabeledContent {
                        Button(c.isFavorite(col) ? "Убрать из избранного" : "В избранное") { c.toggleFavorite(col) }
                    } label: {
                        Label {
                            Text(input.isEmpty ? "Последний выбранный" : "Разобрано")
                        } icon: { Swatch(color: col, size: 24) }
                    }
                    ForEach(ColorFormatter.formatAll(col.converted(to: c.settings.outputSpace), options: c.settings.options), id: \.format) { row in
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text(row.text).monospaced().textSelection(.enabled)
                                Button("Копировать") { c.copy(col, as: row.format) }
                            }
                        } label: { Text(row.format.title).foregroundStyle(.secondary) }
                    }
                } else if !input.isEmpty {
                    ToolWarning(text: "Не получилось разобрать цвет")
                } else {
                    Text("Возьми цвет с экрана или вставь значение выше").foregroundStyle(.secondary)
                }
            } header: { Text("Все форматы") }
            Section("Избранное") {
                swatches(c.favorites, empty: "Избранное пусто") { _, col in
                    Button("Копировать") { c.copy(col) }
                    Button("Убрать из избранного") { c.toggleFavorite(col) }
                }
            }
            Section {
                swatches(c.history, empty: "История пуста") { item, col in
                    Button("Копировать") { c.copy(col) }
                    Button(c.isFavorite(col) ? "Убрать из избранного" : "В избранное") { c.toggleFavorite(col) }
                    if let i = c.history.firstIndex(of: item) { Button("Удалить из истории") { c.removeHistory(at: i) } }
                }
                Button("Очистить историю", role: .destructive) { c.clearHistory() }.disabled(c.history.isEmpty)
            } header: { Text("История") } footer: {
                SectionFooter("Клик по цвету подставляет его в поле; правая кнопка открывает меню.")
            }
        }
    }

    @ViewBuilder
    private func swatches<M: View>(_ list: [SavedColor], empty: String, @ViewBuilder menu: @escaping (SavedColor, RGBAColor) -> M) -> some View {
        if list.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(list, id: \.self) { item in
                    if let col = item.color {
                        Swatch(color: col, size: 30)
                            .onTapGesture { input = ColorFormatter.hex(col) }
                            .help(ColorFormatter.hex(col))
                            .contextMenu { menu(item, col) }
                    }
                }
            }
        }
    }
}

struct ColorContrastPage: View {
    @ObservedObject private var c = ColorPickerController.shared
    @State private var fg = "#1A1A1A"
    @State private var bg = "#FFFFFF"

    private func level(_ r: Double, large: Bool) -> String {
        ColorContrast.passes(ratio: r, level: .aaa, largeText: large) ? "AAA" : ColorContrast.passes(ratio: r, level: .aa, largeText: large) ? "AA" : "нет"
    }

    var body: some View {
        SettingsPage {
            Section {
                TextField("Текст", text: $fg)
                TextField("Фон", text: $bg)
                if let l = c.last {
                    Button("Текст = последний выбранный") { fg = ColorFormatter.hex(l) }
                    Button("Фон = последний выбранный") { bg = ColorFormatter.hex(l) }
                }
            } header: { Text("Цвета") }
            Section {
                if let a = ColorParser.parse(fg), let b = ColorParser.parse(bg) {
                    let r = ColorContrast.ratio(a, b)
                    LabeledContent {
                        Text("Aa").font(.title3.bold()).foregroundStyle(Color(nsColor(a)))
                            .frame(width: 54, height: 34).background(Color(nsColor(b)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } label: { Text(ColorContrast.describe(r)).monospacedDigit() }
                    LabeledContent("Обычный текст") {
                        Text(level(r, large: false)).foregroundStyle(ColorContrast.passes(ratio: r, level: .aa, largeText: false) ? Color.green : Color.orange)
                    }
                    LabeledContent("Крупный текст") {
                        Text(level(r, large: true)).foregroundStyle(ColorContrast.passes(ratio: r, level: .aa, largeText: true) ? Color.green : Color.orange)
                    }
                } else {
                    Text("Введи два цвета в любом формате").foregroundStyle(.secondary)
                }
            } header: { Text("Результат") }
        }
    }
}
