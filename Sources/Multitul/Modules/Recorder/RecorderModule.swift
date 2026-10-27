import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class RecorderModule: Module {
    let info = ModuleID.screenRecorder.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "record.circle.fill", caption: "Запись") { RecorderController.shared.toggle() }) }

    func start() { RecorderController.shared.start(); Log.write("module screenRecorder start") }
    func stop() { RecorderController.shared.stop(); Log.write("module screenRecorder stop") }
}


struct RecorderSections: View {
    @ObservedObject private var c = RecorderController.shared
    @State private var confirmClear = false
    @State private var micDevices: [AudioDeviceInfo] = []

    private func binding<T>(_ kp: WritableKeyPath<RecSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var sampleName: String {
        ShotNaming.baseName(template: c.settings.nameTemplate, context: ShotNameContext(date: Date(), mode: .area, appName: "Safari", windowTitle: nil, width: 1440, height: 900, counter: 7)) + "." + c.settings.container.fileExtension
    }

    private var estimateText: String {
        let s = c.settings
        let bitrate = RecEstimate.videoBitrate(width: 1920, height: 1080, fps: s.fps, quality: s.quality, codec: s.codec)
        let layout = RecTrackLayout.make(settings: s, micAvailable: true)
        let perMinute = RecEstimate.bytes(seconds: 60, videoBitrate: bitrate, layout: layout)
        return "Примерно \(RecTimeFormat.bytes(perMinute)) за минуту при 1920×1080"
    }

    var body: some View {
        Group {
            ToolsPermissionNote(permission: .screenRecording, text: "Нужен доступ «Запись экрана»: без него ничего не записать.")
            if c.settings.microphone { ToolsPermissionNote(permission: .microphone, text: "Для дорожки микрофона нужен доступ к микрофону.") }
            if !c.note.isEmpty || c.storeError != nil {
                Section {
                    if !c.note.isEmpty { ToolWarning(text: c.note) }
                    if let e = c.storeError { ToolWarning(text: "История недоступна: \(e)") }
                }
            }
            Section {
                if c.state.isActive {
                    LabeledContent("Состояние", value: c.state == .paused ? "пауза" : "идёт запись · \(RecTimeFormat.clock(c.elapsed))")
                    Button { c.stopRecording() } label: { Label("Остановить", systemImage: "stop.circle") }.disabled(!c.state.isCapturing)
                    Button { c.togglePause() } label: { Label(c.state == .paused ? "Продолжить" : "Пауза", systemImage: c.state == .paused ? "play.circle" : "pause.circle") }.disabled(!c.state.isCapturing)
                    Button(role: .destructive) { c.cancelRecording() } label: { Label("Отменить", systemImage: "xmark.circle") }
                } else {
                    ForEach(RecMode.allCases, id: \.self) { m in
                        Button { c.begin(m) } label: { Label(m.title, systemImage: m.symbol) }.disabled(!c.running || c.selecting)
                    }
                }
                Button { c.openHistory() } label: { Label("История", systemImage: "clock.arrow.circlepath") }
                Button { c.editLast() } label: { Label("Последняя запись в редакторе", systemImage: "pencil.and.outline") }
            } header: { Text("Запись экрана") } footer: {
                SectionFooter("Область, окно или весь экран с отдельными дорожками звука; редактор с автоприближением, GIF и временная ссылка.")
            }
            Section { HotkeysFooterLink() } header: { Text("Сочетания записи") }
            Section {
                Picker("Пресет", selection: Binding(get: { c.settings.presetID }, set: { id in if let p = RecPresets.capture.first(where: { $0.id == id }) { c.applyPreset(p) } })) {
                    if RecPresets.capturePreset(id: c.settings.presetID) == nil { Text("Свои параметры").tag(c.settings.presetID) }
                    ForEach(RecPresets.capture) { Text($0.title).tag($0.id) }
                }
            } header: { Text("Пресеты записи") } footer: {
                if let p = RecPresets.capturePreset(id: c.settings.presetID) { SectionFooter(p.summary) }
            }
            Section("Видео") {
                Picker("Частота кадров", selection: binding(\.fps)) { ForEach(RecSettings.fpsChoices, id: \.self) { Text("\($0) к/с").tag($0) } }
                Picker("Кодек", selection: binding(\.codec)) { ForEach(RecCodec.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Формат файла", selection: binding(\.container)) { ForEach(RecContainer.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker(selection: binding(\.quality)) { ForEach(RecQuality.allCases, id: \.self) { Text($0.title).tag($0) } } label: { SettingLabel("Качество", estimateText) }
                Picker("Размер кадра", selection: binding(\.resolution)) { ForEach(RecResolution.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Обратный отсчёт", selection: binding(\.countdownSeconds)) { ForEach(RecSettings.countdownChoices, id: \.self) { Text($0 == 0 ? "Нет" : "\($0) с").tag($0) } }
                Toggle(isOn: binding(\.showCursor)) { SettingLabel("Показывать курсор в записи", "Системный указатель попадает в видео") }
                Toggle(isOn: binding(\.highlightClicks)) { SettingLabel("Подсвечивать клики", "Клики запоминаются и рисуются кольцом при просмотре и экспорте; в редакторе подсветку можно выключить") }
                Toggle(isOn: binding(\.excludeOwnWindows)) { SettingLabel("Не записывать окна Мультитула", "Редактор, плашки и рамка записи не попадут в видео") }
                StepperSetting("Предел длительности", c.settings.maxMinutes == 0 ? "Без предела" : nil, value: binding(\.maxMinutes), in: 0...600, step: 5, unit: " мин", zeroText: "нет")
                StepperSetting("Остановить при малом месте", c.settings.minFreeMegabytes == 0 ? "Не следить" : "Запись остановится, когда свободно меньше", value: binding(\.minFreeMegabytes), in: 0...100_000, step: 250, unit: " МБ", zeroText: "нет")
            }
            Section("Звук") {
                Toggle(isOn: binding(\.systemAudio)) { SettingLabel("Звук системы отдельной дорожкой", "Всё, что играет на Маке, кроме самого Мультитула") }
                Toggle(isOn: binding(\.microphone)) { SettingLabel("Микрофон отдельной дорожкой", "В редакторе громкость и выключение у каждой дорожки свои") }
                if c.settings.microphone {
                    Picker("Микрофон", selection: binding(\.micDeviceUID)) {
                        Text("По умолчанию").tag("")
                        ForEach(micDevices) { Text($0.name).tag($0.uid) }
                    }
                }
            }
            Section {
                Picker("После записи", selection: binding(\.afterRecord)) { ForEach(RecAfterAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle(isOn: binding(\.addToShelf)) {
                    SettingLabel("Добавлять на полку", ShelfController.shared.service == nil ? "Модуль «Полка» выключен: пока записи на полку не попадают" : "Каждая запись появляется на полке")
                }
                LabeledContent {
                    HStack(spacing: 12) {
                        Button("Выбрать…") { chooseFolder() }
                        if !c.settings.saveDirectory.isEmpty { Button("По умолчанию") { var s = c.settings; s.saveDirectory = ""; c.update(s) } }
                    }
                } label: { SettingLabel("Папка", c.settings.resolvedDirectory()) }
                FieldSetting("Шаблон имени", "Пример: \(sampleName)", text: binding(\.nameTemplate))
            } header: { Text("Сохранение записи") } footer: {
                SectionFooter(ShotNaming.tokens.map { "\($0.token) — \($0.help)" }.joined(separator: "  ·  "))
            }
            Section {
                Toggle(isOn: binding(\.recordHistory)) { SettingLabel("Вести историю", "Миниатюра, монтаж и клики сохраняются внутри Мультитула; файлы лежат в твоей папке") }
                StepperSetting("Сколько хранить", "Закреплённое в истории не удаляется; файлы записей история не трогает", value: binding(\.historyLimit), in: 10...2000, step: 10, unit: " шт.")
                StepperSetting("Срок хранения", value: binding(\.historyKeepDays), in: 0...3650, step: 10, unit: " дн.", zeroText: "без срока")
                LabeledContent("Записей", value: "\(c.historyCount())")
                Button("Очистить историю", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Убрать всю историю записей? Файлы в твоей папке останутся.", isPresented: $confirmClear) {
                        Button("Очистить", role: .destructive) { c.clearHistory() }
                    }
            } header: { Text("История записей") }
            Section {
                NavigationLink(value: ToolRoute.recorderEditor) { Label("Редактор по умолчанию", systemImage: "wand.and.stars") }
            } header: { Text("Дополнительно") }
        }
        .onAppear { micDevices = AudioDeviceInfo.visible(CoreAudioHal().devices(), scope: .input) }
    }

    private func chooseFolder() {
        chooseFolderPath { path in
            var s = c.settings
            s.saveDirectory = path
            c.update(s)
        }
    }
}

struct RecorderEditorDefaultsPage: View {
    @ObservedObject private var c = RecorderController.shared

    private func binding<T>(_ kp: WritableKeyPath<RecSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: binding(\.autoZoom)) { SettingLabel("Автоприближение по кликам", "При первом открытии записи редактор сам расставляет приближения вокруг кликов") }
                SliderSetting("Сила приближения", String(format: "×%.1f", c.settings.zoomLevel), value: binding(\.zoomLevel), in: RecSettings.zoomLevelRange)
                Picker("Фон", selection: Binding(get: { c.settings.editorBackground.stored }, set: { var s = c.settings; s.editorBackground = ShotBackground(stored: $0); c.update(s) })) {
                    ForEach(ShotBackground.presets, id: \.title) { Text($0.title).tag($0.value.stored) }
                }
                SliderSetting("Поля вокруг записи", "\(c.settings.editorPadding) pt", value: Binding(get: { Double(c.settings.editorPadding) }, set: { var s = c.settings; s.editorPadding = Int($0); c.update(s) }), in: 0...160)
                SliderSetting("Скругление", "\(c.settings.editorCorner) pt", value: Binding(get: { Double(c.settings.editorCorner) }, set: { var s = c.settings; s.editorCorner = Int($0); c.update(s) }), in: 0...48)
            } footer: {
                SectionFooter("Ссылка на запись использует тот же сервис, что и скриншоты: адрес и ключ задаются в разделе «Ссылка на снимок».")
            }
        }
    }
}
