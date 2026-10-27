import SwiftUI
import MultitulCore
import MultitulUI

struct RazborView: View {
    @ObservedObject var model: RazborModel
    @State private var confirm = false
    @AppStorage(AnalysisEnv.rootsKey) private var rootsData = ""

    var body: some View {
        SettingsPage {
            controls
            if model.running {
                Section {
                    ProgressView(value: min(max(model.progress, 0), 1)) {
                        HStack {
                            Text(model.progressText).lineLimit(1)
                            Spacer()
                            Text("\(model.elapsed) с").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.report.isEmpty {
                Section("Результат") { ForEach(Array(model.report.enumerated()), id: \.offset) { _, l in Text(l) } }
            }
            if let r = model.result {
                if !r.notes.isEmpty {
                    Section { ForEach(r.notes, id: \.self) { ToolWarning(text: $0) } }
                }
                group("Брошенные диски VM", r.orphans)
                group("Рабочие папки", r.folders)
                group("Старые venv и node_modules (проект не трогали 14+ дней)", r.envs)
                group("Модели HuggingFace", r.models)
                if let uv = r.uv { group("Кэш uv", [uv]) }
                Section { EmptyView() } footer: {
                    SectionFooter("Разбор от \(SnapshotWriter.formatTime(Int64(r.stamp), "d MMM HH:mm")), \(Int(r.seconds)) с" + (r.remoteChecked ? ", с проверкой домашнего сервера" : ""))
                }
            } else if !model.running {
                Section {
                    ContentUnavailableView("Разбор ещё не запускался", systemImage: "chart.pie", description: Text("Он ничего не удаляет: сначала список с рекомендациями."))
                }
            }
            Section {
                TextField("Папки", text: Binding(
                    get: { AnalysisEnv.configuredRoots().joined(separator: ", ") },
                    set: { UserDefaults.standard.set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: AnalysisEnv.rootsKey); rootsData = $0 }),
                    prompt: Text("Относительно домашней папки, через запятую"))
            } header: { Text("Рабочие папки для разбора") } footer: {
                SectionFooter("По умолчанию Documents/Scratch. Сверка с домашним сервером идёт по ssh и только если в папке есть упоминание homeserver.")
            }
        }
        .confirmationDialog("Убрать выбранное (\(fmtBytes(model.pickedBytes)))?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Убрать", role: .destructive) { model.clean() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Выбранное уйдёт в Корзину, потом проверятся службы dev.multitool.*; если все живы, Корзина очистится от этих файлов. uv cache prune запускается отдельно.")
        }
    }

    private var controls: some View {
        Section {
            Button { model.run() } label: { Label(model.running ? "Разбираю…" : "Запустить разбор", systemImage: "chart.pie") }.disabled(model.running || model.cleaning)
            if model.running { Button("Остановить") { model.cancel() } }
            Button(role: .destructive) { confirm = true } label: { Label("Убрать выбранное · \(fmtBytes(model.pickedBytes))", systemImage: "trash") }
                .disabled(model.pickedItems.isEmpty || model.running || model.cleaning)
            if model.cleaning { ProgressView().controlSize(.small) }
        }
    }

    private func group(_ title: String, _ items: [AnalysisItem]) -> some View {
        Section {
            if items.isEmpty { EmptyHint(text: "Ничего", symbol: "checkmark.circle") }
            ForEach(items.prefix(25)) { it in
                row(it, depth: 0)
                if model.expanded.contains(it.id) { ForEach(it.children) { c in row(c, depth: 1) } }
            }
            if items.count > 25 { Text("…и ещё \(items.count - 25)").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("\(title): \(items.count), \(fmtBytes(items.reduce(0) { $0 + max($1.bytes, $1.logicalBytes) }))")
        }
    }

    private func row(_ it: AnalysisItem, depth: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(it.title, isOn: Binding(get: { model.picked.contains(it.id) }, set: { _ in model.toggle(it) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!it.selectable)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(it.title).fontWeight(depth == 0 ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                    recoLabel(it).font(.caption)
                    if it.remote == .copy { StatusLabel("копия на домашнем сервере", color: .green).font(.caption) }
                    if it.remote == .noCopy { StatusLabel("на домашнем сервере нет", color: .orange).font(.caption) }
                    if it.remote == .unreachable { StatusLabel("Домашний сервер не отвечает", color: .secondary).font(.caption) }
                }
                if !it.reason.isEmpty { caption(it.reason) }
                if !it.inUseBy.isEmpty { Text("работает: " + it.inUseBy.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
                if !it.note.isEmpty { caption(it.note).lineLimit(2) }
                if !it.remoteNote.isEmpty { caption(it.remoteNote).lineLimit(1) }
                if !it.symlinks.isEmpty { caption("ссылки внутрь: \(it.symlinks.count)") }
                if !it.heavy.isEmpty { caption(it.heavy.map { "\($0.name) \(fmtBytes($0.bytes))" }.joined(separator: " · ")).lineLimit(1) }
            }
            Spacer()
            if !it.children.isEmpty {
                Button { model.toggleExpand(it.id) } label: { Image(systemName: model.expanded.contains(it.id) ? "chevron.down" : "chevron.right") }.buttonStyle(.borderless)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(fmtBytes(it.bytes > 0 ? it.bytes : it.logicalBytes)).monospacedDigit().foregroundStyle(.secondary)
                if it.ageDays > 0 { caption("\(it.ageDays) дн.") }
            }
        }
        .padding(.leading, CGFloat(depth) * 22)
    }

    private func caption(_ t: String) -> Text { Text(t).font(.caption).foregroundStyle(.secondary) }

    private func recoLabel(_ it: AnalysisItem) -> StatusLabel {
        switch it.reco {
        case .can: StatusLabel("можно", color: .green)
        case .check: StatusLabel("проверь", color: .orange)
        case .keep: StatusLabel("оставить", color: .secondary)
        }
    }
}
