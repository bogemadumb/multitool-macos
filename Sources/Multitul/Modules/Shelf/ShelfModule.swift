import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ShelfModule: Module {
    let info = ModuleID.shelf.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "tray.and.arrow.down", caption: "Полка") { ShelfController.shared.toggle(reason: .tile) }) }

    func start() {
        ShelfController.shared.start()
        ToolsRouter.shared.register(.shelf) { ShelfController.shared.toggle(reason: .tile) }
    }

    func stop() {
        ShelfController.shared.stop()
        ToolsRouter.shared.unregister(.shelf)
    }
}

struct ShelfSections: View {
    @ObservedObject private var c = ShelfController.shared
    @State private var confirmClear = false

    private func binding<T>(_ kp: WritableKeyPath<ShelfSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent("Предметов на полке", value: "\(c.count)")
            LabeledContent("Показать полку") {
                HStack(spacing: 12) {
                    Button("Показать") { c.show(reason: .tile) }
                    HotkeyRecorder(spec: c.spec, titles: [:])
                }
            }
            Toggle(isOn: binding(\.shakeEnabled)) { SettingLabel("Открывать встряхиванием при перетаскивании", "Потряси файл, текст или ссылку из любого приложения: полка появится рядом. Права не нужны") }
            Picker(selection: binding(\.shakeSensitivity)) {
                ForEach(ShakeSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Чувствительность встряхивания", "Выше — срабатывает на более короткие и редкие движения") }
            Picker(selection: binding(\.placement)) {
                ForEach(ShelfPlacementMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Где появляется полка", "При встряхивании и по сочетанию") }
            NavigationLink {
                BundleListPage(footer: "Если тянешь из этих приложений, встряхивание полку не открывает (по сочетанию и из строки меню она работает). Перетаскивание значков из Dock не учитывается никогда.", apps: binding(\.excludedApps))
                    .navigationTitle("Исключения для встряхивания")
            } label: {
                LabeledContent("Исключения для встряхивания", value: "\(c.settings.excludedApps.count)")
            }
        } header: { Text("Полка") } footer: {
            SectionFooter(c.storeError.map { "Хранилище недоступно: \($0)" } ?? "Файлы хранятся ссылками на место, текст и картинки внутри базы Мультитула; закреплённое переживает перезапуск.")
        }
        Section("Полка: строка меню и поведение") {
            Toggle(isOn: binding(\.menuBarIcon)) { SettingLabel("Значок полки в строке меню", "Бросай файлы на значок; клик открывает список, справа от значка — число предметов") }
            Toggle(isOn: binding(\.menuBarDrop)) { SettingLabel("Показывать полку под значком, когда что-то тянешь", "Как только началось перетаскивание, список раскрывается под значком в строке меню") }
            Toggle(isOn: binding(\.closeAfterDrop)) { SettingLabel("Закрывать полку после броска", "После того как предмет вытащен в другое приложение или добавлен на полку") }
            Toggle(isOn: binding(\.deleteAfterDrop)) { SettingLabel("Убирать предметы после броска", "Вытащенное удаляется с полки; закреплённое остаётся") }
            Toggle(isOn: binding(\.autoHideEmpty)) { SettingLabel("Прятать пустую полку", "Открытая автоматически полка закрывается, когда на ней ничего нет") }
        }
        Section {
            Button("Очистить полку, закреплённое останется") { c.clearAll() }
            Button("Очистить всё…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Убрать с полки всё, включая закреплённое?", isPresented: $confirmClear) {
                    Button("Убрать всё", role: .destructive) { c.service?.clear(keepPinned: false) }
                }
        }
    }
}
