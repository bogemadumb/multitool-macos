import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ScreenshotModule: Module {
    let info = ModuleID.screenshot.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "camera.viewfinder", caption: "Скриншот") { ScreenshotController.shared.begin(.area) }) }

    func start() { ScreenshotController.shared.start(); Log.write("module screenshot start") }
    func stop() { ScreenshotController.shared.stop(); Log.write("module screenshot stop") }
}


struct ScreenshotSections: View {
    @ObservedObject private var c = ScreenshotController.shared
    @ObservedObject private var pins = ScreenshotController.shared.pins
    @State private var confirmClear = false

    private func binding<T>(_ kp: WritableKeyPath<ShotSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var sampleName: String {
        ShotNaming.baseName(template: c.settings.nameTemplate, context: ShotNameContext(date: Date(), mode: .area, appName: "Safari", windowTitle: "Новости", width: 1440, height: 900, counter: 7)) + "." + c.settings.format.fileExtension
    }

    var body: some View {
        ToolsPermissionNote(permission: .screenRecording, text: "Нужен доступ «Запись экрана»: без него ничего не снять.")
        if !c.note.isEmpty || c.storeError != nil {
            Section {
                if !c.note.isEmpty { ToolWarning(text: c.note) }
                if let e = c.storeError { ToolWarning(text: "История недоступна: \(e)") }
            }
        }
        Section {
            ForEach(ShotMode.allCases, id: \.self) { m in
                Button { c.begin(m) } label: { Label(m.title, systemImage: m.symbol) }.disabled(c.busy || !c.running)
            }
            Button { c.openHistory() } label: { Label("История", systemImage: "clock.arrow.circlepath") }
            Button { c.editLast() } label: { Label("Последний в редакторе", systemImage: "pencil.and.outline") }
            Button { c.editFromClipboard() } label: { Label("Редактор из буфера", systemImage: "doc.on.clipboard") }
        } header: { Text("Скриншоты") } footer: {
            SectionFooter("Область, окно, экран, все экраны, прокручиваемая страница; редактор, закрепление, история и временная ссылка.")
        }
        Section {
            Toggle(isOn: binding(\.takeOverSystemKeys)) {
                SettingLabel("Заменить системные ⇧⌘3, ⇧⌘4, ⇧⌘5", "Отключает системные сочетания съёмки (с записью в журнал, при выключении модуля они возвращаются) и отдаёт эти же клавиши Мультитулу. ⌃⇧⌘3 и ⌃⇧⌘4 копируют только в буфер")
            }
            if let n = c.takeoverNote { ToolWarning(text: n) }
            if c.holdingNative { Label("Системные сочетания отключены", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        } header: { Text("Сочетания скриншотов") } footer: { HotkeysFooterLink() }
        Section("Съёмка") {
            Toggle(isOn: binding(\.freezeScreen)) { SettingLabel("Замораживать экран при выборе области", "Картинка замирает, выбираешь область по неподвижному кадру; с таймером заморозка выключается") }
            Toggle(isOn: binding(\.confirmOnRelease)) { SettingLabel("Снимать сразу при отпускании кнопки мыши", "Иначе после выделения можно сдвинуть область стрелками (⌥ меняет размер) и подтвердить Return") }
            Toggle(isOn: binding(\.includeCursor)) { SettingLabel("Захватывать курсор", "Указатель мыши попадает на снимок") }
            Picker(selection: binding(\.timerSeconds)) {
                ForEach(ShotSettings.timerChoices, id: \.self) { Text($0 == 0 ? "Нет" : "\($0) с").tag($0) }
            } label: { SettingLabel("Таймер", "Задержка перед съёмкой, чтобы успеть открыть меню") }
            Toggle(isOn: binding(\.downscaleRetina)) { SettingLabel("Уменьшать Retina-снимки до 1×", "Файл вдвое меньше по каждой стороне") }
            StepperSetting("Предел высоты длинного снимка", "Прокручиваемая съёмка останавливается на этой высоте в пикселях", value: binding(\.scrollMaxHeight), in: 2000...100_000, step: 2000)
        }
        ToolsPermissionNote(permission: .accessibility, text: "Съёмка прокручиваемой страницы посылает колесо мыши; для этого может понадобиться «Универсальный доступ».")
        Section("После съёмки") {
            Picker("Действие по умолчанию", selection: binding(\.afterCapture)) {
                ForEach(ShotAfterAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle(isOn: binding(\.openEditorImmediately)) { SettingLabel("Сразу открывать редактор", "Перекрывает действие по умолчанию") }
            Toggle(isOn: binding(\.copyToClipboard)) { SettingLabel("Копировать в буфер", "Каждый снимок автоматически попадает в буфер обмена") }
            Toggle(isOn: binding(\.saveToDisk)) { SettingLabel("Сохранять файл", "Если выключить, снимки остаются только в истории (внутри Мультитула) и в буфере") }
            Toggle(isOn: binding(\.addToShelf)) {
                SettingLabel("Добавлять на полку", ShelfController.shared.service == nil ? "Модуль «Полка» выключен: пока снимки на полку не попадают" : "Каждый снимок появляется на полке, откуда его можно перетащить в любое приложение")
            }
        }
        Section {
            LabeledContent {
                HStack(spacing: 12) {
                    Button("Выбрать…") { chooseFolder() }
                    if !c.settings.saveDirectory.isEmpty { Button("По умолчанию") { var s = c.settings; s.saveDirectory = ""; c.update(s) } }
                }
            } label: { SettingLabel("Папка", c.settings.resolvedDirectory()) }
            FieldSetting("Шаблон имени", "Пример: \(sampleName)", text: binding(\.nameTemplate))
            Picker(selection: binding(\.format)) {
                ForEach(ShotFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Формат", c.settings.format.usesQuality ? "Качество \(Int(c.settings.quality * 100))%" : "Без потерь, с прозрачностью") }
            if c.settings.format.usesQuality {
                SliderSetting("Качество", value: binding(\.quality), in: ShotSettings.qualityRange)
            }
        } header: { Text("Файл") } footer: {
            SectionFooter(ShotNaming.tokens.map { "\($0.token) — \($0.help)" }.joined(separator: "  ·  "))
        }
        Section("Снимок окна") {
            Toggle(isOn: binding(\.windowShadow)) { SettingLabel("С тенью окна", "Системная тень вокруг окна попадает на снимок") }
            SliderSetting("Поля вокруг окна", "\(c.settings.windowPadding) pt; с фоном получается красивая карточка",
                          value: Binding(get: { Double(c.settings.windowPadding) }, set: { var s = c.settings; s.windowPadding = Int($0); c.update(s) }), in: 0...160)
            Picker("Фон", selection: Binding(get: { c.settings.background.stored }, set: { var s = c.settings; s.background = ShotBackground(stored: $0); c.update(s) })) {
                ForEach(ShotBackground.presets, id: \.title) { Text($0.title).tag($0.value.stored) }
            }
            SliderSetting("Скругление окна на фоне", "\(c.settings.backgroundCorner) pt",
                          value: Binding(get: { Double(c.settings.backgroundCorner) }, set: { var s = c.settings; s.backgroundCorner = Int($0); c.update(s) }), in: 0...48)
        }
        Section("Плашка после съёмки") {
            StepperSetting("Сколько висит", c.settings.overlaySeconds == 0 ? "Пока не закроешь" : "Пока наведён курсор, не исчезает", value: binding(\.overlaySeconds), in: ShotSettings.overlaySecondsRange, unit: " с", zeroText: "пока не закроешь")
            Picker("Угол экрана", selection: binding(\.overlayCorner)) { ForEach(ShotCorner.allCases, id: \.self) { Text($0.title).tag($0) } }
        }
        Section {
            Toggle(isOn: binding(\.recordHistory)) { SettingLabel("Вести историю", "Миниатюры и поиск; если файл не сохраняется, копия лежит внутри Мультитула") }
            Toggle(isOn: binding(\.indexText)) { SettingLabel("Искать по тексту на снимках", "Текст распознаётся офлайн (Vision) и попадает в поиск") }
            StepperSetting("Сколько хранить", "Закреплённое в истории не удаляется", value: binding(\.historyLimit), in: ShotSettings.historyLimitRange, step: 50, unit: " шт.")
            StepperSetting("Срок хранения", value: binding(\.historyKeepDays), in: 0...3650, step: 10, unit: " дн.", zeroText: "без срока")
            LabeledContent("Записей", value: "\(c.historyCount())")
            Button("Очистить историю", role: .destructive) { confirmClear = true }
                .confirmationDialog("Убрать всю историю скриншотов? Файлы в твоей папке останутся, внутренние копии удалятся.", isPresented: $confirmClear) {
                    Button("Очистить", role: .destructive) { c.clearHistory() }
                }
        } header: { Text("История скриншотов") }
        .id("shots.history")
        Section {
            NavigationLink(value: ToolRoute.shotLink) { Label("Ссылка на снимок", systemImage: "link") }
            NavigationLink(value: ToolRoute.shotWatermark) { Label("Водяной знак", systemImage: "textformat") }
            NavigationLink(value: ToolRoute.shotPins) {
                LabeledContent {
                    Text("\(pins.count)").foregroundStyle(.secondary)
                } label: { Label("Закреплённые снимки", systemImage: "pin") }
            }
        } header: { Text("Дополнительно") }
    }

    private func chooseFolder() {
        chooseFolderPath { path in
            var s = c.settings
            s.saveDirectory = path
            c.update(s)
        }
    }
}

struct ScreenshotLinkPage: View {
    @ObservedObject private var c = ScreenshotController.shared
    @State private var token = ""
    @State private var tokenNote = ""

    private func binding<T>(_ kp: WritableKeyPath<ShotSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private func uploadBinding<T>(_ kp: WritableKeyPath<ShotUploadSettings, T>) -> Binding<T> {
        Binding(get: { c.upload[keyPath: kp] }, set: { v in var s = c.upload; s[keyPath: kp] = v; c.updateUpload(s) })
    }

    var body: some View {
        SettingsPage {
            Section {
                FieldSetting("Адрес загрузки", "Только https (http допускается для localhost)", text: uploadBinding(\.endpoint), prompt: "https://…")
                FieldSetting("Поле файла", text: uploadBinding(\.fileField), prompt: "file")
                Picker(selection: binding(\.linkTTL)) {
                    ForEach(ShotLinkTTL.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Срок жизни ссылки", "Уходит в поле запроса; пустое имя поля — не отправлять") }
                FieldSetting("Поле срока", text: uploadBinding(\.ttlField), prompt: "ttl")
                Toggle("Срок в секундах", isOn: uploadBinding(\.ttlInSeconds))
            } header: { Text("Сервис") } footer: {
                SectionFooter("Снимок загружается на твой сервис multipart-запросом, в ответе ищется адрес. Пока адрес не задан, кнопка «Ссылка» не работает; ничего никуда не отправляется.")
            }
            Section {
                FieldSetting("Заголовок", text: uploadBinding(\.authHeader), prompt: "Authorization")
                FieldSetting("Префикс", text: uploadBinding(\.authPrefix), prompt: "Bearer ")
                FieldSetting("Ключ сервиса", tokenNote.isEmpty ? "Сохраняется в связку ключей Мультитула" : tokenNote, text: $token, prompt: "ключ", secure: true)
                Button("Сохранить ключ") { saveToken() }.disabled(token.isEmpty)
            } header: { Text("Авторизация") } footer: {
                SectionFooter("Ключ берётся из связки ключей; в настройках он не хранится.")
            }
            Section {
                FieldSetting("Где в ответе ссылка", "Путь через точку, например data.url; для простого текста оставь пустым", text: uploadBinding(\.responsePath), prompt: "url")
            } header: { Text("Ответ") }
        }
    }

    private func saveToken() {
        let ok = AppKeychain().write(ShotUploadSettings.keychainService, ["token": token])
        tokenNote = ok ? "Ключ сохранён в связке ключей" : "Не удалось сохранить ключ"
        if ok { token = "" }
    }
}

struct ScreenshotWatermarkPage: View {
    @ObservedObject private var c = ScreenshotController.shared

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: Binding(get: { c.settings.watermark.enabled }, set: { var s = c.settings; s.watermark.enabled = $0; c.update(s) })) {
                    SettingLabel("Ставить водяной знак", "Текст в углу каждого снимка и при экспорте из редактора")
                }
                FieldSetting("Текст", text: Binding(get: { c.settings.watermark.text }, set: { var s = c.settings; s.watermark.text = $0; c.update(s) }))
                Picker("Угол", selection: Binding(get: { c.settings.watermark.corner }, set: { var s = c.settings; s.watermark.corner = $0; c.update(s) })) {
                    ForEach(ShotCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SliderSetting("Прозрачность", value: Binding(get: { c.settings.watermark.opacity }, set: { var s = c.settings; s.watermark.opacity = $0; c.update(s) }), in: 0.1...1)
            }
        }
    }
}

struct ScreenshotPinsPage: View {
    @ObservedObject private var pins = ScreenshotController.shared.pins

    var body: some View {
        SettingsPage {
            Section {
                if pins.states.isEmpty {
                    ContentUnavailableView("Нет закреплённых снимков", systemImage: "pin", description: Text("Закрепить снимок можно в плашке после съёмки или в редакторе"))
                }
                ForEach(pins.states) { p in
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text("\(Int(p.zoom * 100))%").foregroundStyle(.secondary).monospacedDigit()
                            Slider(value: Binding(get: { p.opacity }, set: { pins.setOpacity(p.id, $0) }), in: ShotPinMath.opacityRange).frame(minWidth: 80, maxWidth: 140)
                            Toggle("Насквозь", isOn: Binding(get: { p.clickThrough }, set: { _ in pins.toggleClickThrough(p.id) }))
                            Button("Закрыть") { pins.close(p.id) }
                        }
                    } label: { Text(p.title).lineLimit(1) }
                }
            } header: { Text("Закреплённые снимки") } footer: {
                SectionFooter("Колесо мыши над закрепом меняет размер, ⌥ + колесо или [ и ] — прозрачность, углы тянут размер, правая кнопка открывает меню, Esc закрывает.")
            }
            Section {
                Button("Скрыть или показать все") { pins.toggleAllHidden() }
                Button("Вернуть клики всем") { pins.restoreClicks() }
                Button("Закрыть все", role: .destructive) { pins.closeAll() }
            }
            .disabled(pins.count == 0)
        }
    }
}
