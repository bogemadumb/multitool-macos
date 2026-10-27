import SwiftUI
import MultitulCore
import MultitulUI

struct HotkeysPage: View {
    @ObservedObject var runtime: ModuleRuntime
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var query = ""
    @State private var filter = HotkeyFilter.all

    private static let titles: [String: String] = Dictionary(uniqueKeysWithValues: HotkeyRegistry.rows.map { ($0.id, $0.spec.title) })

    private func isActive(_ r: HotkeyRow) -> Bool { r.module.map { runtime.isEnabled($0) } ?? true }

    private var conflicts: [String: String] {
        let _ = hotkeys.overridesRevision
        var out: [String: String] = [:]
        let active = HotkeyRegistry.rows.filter(isActive)
        let dup = HotkeyRegistry.duplicates(active.map { (id: $0.id, title: $0.spec.title, combo: hotkeys.combo(for: $0.spec)) })
        for (id, others) in dup { out[id] = "Та же комбинация: " + others.joined(separator: ", ") }
        for r in active {
            switch hotkeys.state(of: r.id) {
            case .conflict(let w)?: out[r.id] = "Занято: " + (hotkeys.reservedTitle(of: w) ?? Self.titles[w] ?? w)
            case .failed?: out[r.id] = "Система не дала зарегистрировать"
            default: break
            }
        }
        return out
    }

    var body: some View {
        let _ = runtime.revision
        let conflicts = self.conflicts
        let sections = HotkeyRegistry.sections(query: query, filter: filter, combo: { hotkeys.combo(for: $0) }, conflicting: Set(conflicts.keys))
        SettingsPage {
            Section {
                TextField("Поиск по сочетаниям", text: $query, prompt: Text("Название, модуль или клавиши"))
                Picker("Показывать", selection: $filter) {
                    ForEach(HotkeyFilter.allCases) { f in
                        Text(f == .conflicts && !conflicts.isEmpty ? "Конфликты (\(conflicts.count))" : f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                SectionFooter("Нажми на сочетание и введи новое. Esc отменяет запись, ⌫ возвращает сочетание по умолчанию.")
            }
            if sections.isEmpty {
                Section {
                    ContentUnavailableView(filter == .conflicts && query.isEmpty ? "Конфликтов нет" : "Ничего не найдено",
                                           systemImage: filter == .conflicts && query.isEmpty ? "checkmark.shield" : "magnifyingglass")
                }
            }
            ForEach(sections) { s in
                Section {
                    ForEach(s.rows) { r in
                        HotkeyRegistryRow(row: r, active: isActive(r), conflict: conflicts[r.id], titles: Self.titles)
                    }
                } header: { Text(s.title) }
            }
        }
    }
}

private struct HotkeyRegistryRow: View {
    let row: HotkeyRow
    let active: Bool
    let conflict: String?
    let titles: [String: String]
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        let _ = hotkeys.overridesRevision
        let changed = hotkeys.combo(for: row.spec) != row.spec.defaultCombo
        LabeledContent {
            HStack(spacing: 10) {
                if changed {
                    Button { _ = hotkeys.resetCombo(row.spec) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Вернуть по умолчанию: " + row.spec.defaultCombo.display)
                }
                HotkeyRecorder(spec: row.spec, titles: titles)
            }
        } label: {
            Label {
                SettingLabel(row.spec.title, subtitle)
            } icon: {
                Image(systemName: conflict != nil ? "exclamationmark.triangle.fill" : "keyboard")
                    .foregroundStyle(conflict != nil ? Color.orange : Color.secondary)
                    .frame(width: 20)
            }
        }
        .help(conflict ?? "")
    }

    private var subtitle: String? {
        var parts: [String] = []
        if row.module != nil { parts.append(row.owner) }
        if !active { parts.append("модуль выключен") }
        if let c = conflict { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
