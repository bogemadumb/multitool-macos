import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

private func timeText(_ ts: Int64) -> String {
    SnapshotWriter.formatTime(ts, Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(ts))) ? "HH:mm" : "d MMM HH:mm")
}

private let actionNames = ["notify": "уведомление", "restart_useless": "перезапуск не помогает", "restart": "перезапущен", "kill": "убит",
                           "ignore": "игнор", "whitelist": "в белом списке", "skip": "неприкасаемый", "ignored": "в игноре", "dismiss": "закрыта"]

struct StorozhPage: View {
    @ObservedObject var c = StorozhController.shared

    var body: some View {
        SettingsPage {
            controls
            openSection
            detectorsSection
            ThresholdsEditor(c: c)
            offendersSection
            journalSection
            StorozhListsEditor(c: c)
            Section("Подробнее") {
                NavigationLink(value: StorozhRoute.sessions) { Text("Сессии Claude и Codex") }
            }
        }
        .navigationDestination(for: StorozhRoute.self) { _ in StorozhClaudeView().navigationTitle("Сессии") }
        .onAppear { c.refresh() }
    }

    private var paused: Bool { c.settings.isPaused(at: Date().timeIntervalSince1970) }

    private var controls: some View {
        Section {
            if let t = c.toast { Label(t, systemImage: "info.circle") }
            LabeledContent("Уведомления") {
                Menu {
                    Button("На час") { c.setPause(.hour) }
                    Button("До утра (9:00)") { c.setPause(.morning) }
                    if paused { Divider(); Button("Снять паузу") { c.setPause(.off) } }
                } label: {
                    Label(paused ? "Пауза до \(timeText(Int64(c.settings.pausedUntil)))" : "Пауза уведомлений", systemImage: c.icon.paused ? "bell.slash.fill" : "bell")
                }
                .fixedSize()
            }
            Button { c.snapshot(copyForClaude: false) } label: { Label("Снимок сейчас", systemImage: "camera") }.disabled(c.busy)
            Button { c.snapshot(copyForClaude: true) } label: { Label("Скопировать для Claude", systemImage: "doc.on.clipboard") }.disabled(c.busy)
            LabeledContent("Сборщик") {
                StatusLabel(c.health.summary, color: c.health.isHealthy ? .green : .orange)
            }
            if !c.health.isHealthy { Button("Перезапустить сборщик") { c.restartCollector() }.disabled(c.busy) }
        }
    }

    private var openSection: some View {
        Section {
            if c.open.isEmpty { EmptyHint(text: "Открытых аномалий нет", symbol: "checkmark.shield") }
            ForEach(c.open) { row in OpenAnomalyRow(row: row, c: c) }
        } header: { Text("Требуют внимания") }
    }

    private var detectorsSection: some View {
        Section {
            ForEach(DetectorKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(get: { c.settings.isEnabled(kind.rawValue) }, set: { c.setKind(kind, enabled: $0) })) {
                    SettingLabel(kind.title, kind.summary)
                }
            }
        } header: { Text("Детекторы") } footer: {
            SectionFooter("Повтор по одному и тому же не чаще раза в \(c.settings.thresholds.cooldownMin) минут. Выключенный детектор вообще не запускается.")
        }
    }

    private var offendersSection: some View {
        Section {
            if c.offenders.isEmpty { EmptyHint(text: "За неделю ничего", symbol: "checkmark.circle") }
            ForEach(Array(c.offenders.prefix(8).enumerated()), id: \.offset) { _, o in
                LabeledContent {
                    Text("×\(o.count)").monospacedDigit()
                } label: { SettingLabel(o.name, o.kinds.joined(separator: ", ")) }
            }
        } header: { Text("Нарушители недели") }
    }

    private var journalSection: some View {
        Section {
            if c.recent.isEmpty { EmptyHint(text: "Пока пусто", symbol: "list.bullet.rectangle") }
            ForEach(Array(c.recent.prefix(20)), id: \.id) { r in
                LabeledContent {
                    StatusLabel(actionNames[r.action ?? ""] ?? (r.action ?? r.status), color: r.status == "failed" ? .orange : .secondary)
                } label: { SettingLabel(StorozhReactions.notificationText(r).title, timeText(r.ts)) }
            }
        } header: { Text("Журнал") }
    }
}

struct OpenAnomalyRow: View {
    let row: AnomalyRow
    @ObservedObject var c: StorozhController

    var body: some View {
        let (title, text) = StorozhReactions.notificationText(row)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(timeText(row.ts)).font(.caption).foregroundStyle(.secondary)
            }
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if row.isProcessKind {
                    if row.action != "restart_useless" { Button("Перезапустить") { c.act(row, "restart") } }
                    Button("Убить", role: .destructive) { c.act(row, "kill") }
                    Button("Игнор") { c.act(row, "ignore") }
                    if row.action != "restart_useless" { Button("В белый список") { c.act(row, "whitelist") } }
                }
                Button("Закрыть") { c.act(row, "dismiss") }
                if let snap = SnapshotWriter.latestPath(kind: row.kind) {
                    Button("Снимок") { _ = NSWorkspace.shared.open(URL(fileURLWithPath: snap)) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(c.busy)
        }
        .padding(.vertical, 4)
    }
}

struct StorozhListsEditor: View {
    @ObservedObject var c: StorozhController
    @State private var drafts: [StorozhList: String] = [:]

    var body: some View {
        ForEach(StorozhList.allCases, id: \.self) { list in listSection(list) }
    }

    private func entries(_ list: StorozhList) -> [String] {
        list == .untouchable ? c.lists.effectiveUntouchable : c.lists.entries(list)
    }

    private func listSection(_ list: StorozhList) -> some View {
        Section {
            let items = entries(list)
            if items.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { e in
                LabeledContent {
                    if list != .untouchable || !StorozhLists.isBuiltin(e) {
                        Button { c.remove(e, from: list) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    } else {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                } label: { Text(e).lineLimit(1).truncationMode(.middle) }
            }
            TextField("Добавить", text: Binding(get: { drafts[list] ?? "" }, set: { drafts[list] = $0 }), prompt: Text("Имя, шаблон Code Helper*, pid<200, path:/префикс, pathhas:часть"))
                .onSubmit { add(list) }
            Button("Добавить") { add(list) }.disabled((drafts[list] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        } header: { Text(list.title) } footer: { SectionFooter(list.subtitle) }
    }

    private func add(_ list: StorozhList) {
        guard let v = drafts[list]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return }
        c.add(v, to: list)
        drafts[list] = ""
    }
}

struct StorozhClaudeView: View {
    @ObservedObject var c = StorozhController.shared
    @State private var sortOrder = [KeyPathComparator(\ClaudeSession.cpu, order: .reverse)]

    var body: some View {
        Table(c.sessions.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Сессия", value: \.name) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(s.name) \u{b7} \(String(s.pid))").fontWeight(.semibold)
                    if let cwd = s.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
            }
            TableColumn("ЦП", value: \.cpu) { s in Text(String(format: "%.1f%%", s.cpu)).monospacedDigit() }
                .width(min: 56, ideal: 70)
            TableColumn("Память", value: \.rssMb) { s in Text(SysFormat.bytes(s.rssMb * 1_048_576)).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Работает", value: \.uptimeValue) { s in Text(s.uptime.map(SysFormat.duration) ?? "—").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90)
        }
        .overlay {
            if c.sessions.isEmpty { ContentUnavailableView("Запущенных сессий нет", systemImage: "terminal") }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { c.snapshot(copyForClaude: true) } label: { Label("Снимок и копия для Claude", systemImage: "doc.on.clipboard") }.disabled(c.busy)
                Button { c.loadSessions() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let t = c.toast { Label(t, systemImage: "info.circle") }
                Text("Снимок пишется в Documents/Scratch/storozh-snimki, в буфер уходит готовый текст с путём к нему. Только чтение: сессии отсюда не закрываются, Claude и Codex в списке неприкасаемых.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { c.loadSessions() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                c.loadSessions()
            }
        }
    }
}

extension ClaudeSession {
    var uptimeValue: Double { uptime ?? 0 }
}

struct ThresholdsEditor: View {
    @ObservedObject var c: StorozhController

    private func valueText(_ f: ThresholdField) -> String {
        let v = f.value(in: c.settings.thresholds)
        let s = f.isInteger ? String(Int(v)) : String(format: "%g", v).replacingOccurrences(of: ".", with: ",")
        return "\(s) \(f.unit)"
    }

    private func field(_ f: ThresholdField) -> some View {
        Stepper(value: Binding(get: { f.value(in: c.settings.thresholds) }, set: { c.setThreshold(f, $0) }), in: f.range, step: f.step) {
            HStack {
                Text(f.title)
                Spacer()
                Text(valueText(f)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        Section {
            DisclosureGroup("Пороги детекторов") {
                ForEach(DetectorKind.allCases, id: \.self) { kind in
                    let fields = ThresholdField.allCases.filter { $0.detector == kind }
                    if !fields.isEmpty {
                        Text(kind.title).font(.subheadline).foregroundStyle(.secondary)
                        ForEach(fields, id: \.self) { field($0) }
                    }
                }
                Text("Общие").font(.subheadline).foregroundStyle(.secondary)
                ForEach(ThresholdField.allCases.filter { $0.detector == nil }, id: \.self) { field($0) }
                Button("Сбросить к умолчаниям") { c.resetThresholds() }
            }
        } footer: { SectionFooter("Изменения действуют со следующего замера, перезапуск не нужен.") }
    }
}
