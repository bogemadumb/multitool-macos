import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ProcessCardModel: ObservableObject {
    @Published var detail: ProcessDetail?
    @Published var cpu: [Double] = []
    @Published var rss: [Double] = []
    @Published var alive = true
    private var name = ""

    func load(group: ProcGroup) {
        name = group.name
        let pid = group.pids.min() ?? 0
        let n = group.name
        Task {
            let d = await Task.detached { ProcessDetailReader.read(pid: pid) }.value
            let hist = await Task.detached { () -> [ProcHistPoint] in
                guard let store = SystemHub.openHistoryStore() else { return [] }
                return SystemHistory.processHistory(store, name: n, range: 3600)
            }.value
            guard self.name == n else { return }
            self.detail = d
            self.alive = d != nil
            self.cpu = hist.map(\.cpu)
            self.rss = hist.map(\.rssMb)
        }
    }
}

struct SystemProcesses: View {
    @ObservedObject var hub: SystemHub
    @State private var sortOrder = [KeyPathComparator(\ProcGroup.cpu, order: .reverse)]
    @State private var search = ""
    @State private var selection: ProcGroup.ID?
    @State private var showInspector = false
    @StateObject private var card = ProcessCardModel()

    private var groups: [ProcGroup] {
        var g = SystemParsers.groupProcesses(hub.processes)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { g = g.filter { $0.name.lowercased().contains(q) } }
        g.sort(using: sortOrder)
        return Array(g.prefix(60))
    }

    var body: some View {
        let rows = groups
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Процесс", value: \.name) { g in
                HStack(spacing: 6) {
                    Text(g.name).lineLimit(1)
                    if g.pids.count > 1 { Text("×\(g.pids.count)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TableColumn("ЦП", value: \.cpu) { g in
                Text(String(format: "%.1f%%", g.cpu)).monospacedDigit().foregroundStyle(g.cpu > 80 ? Color.red : Color.primary)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Память", value: \.rssBytes) { g in
                Text(SysFormat.bytes(Double(g.rssBytes))).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Сеть", value: \.netBps) { g in
                Text(g.netBps > 0 ? SysFormat.rate(g.netBps) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(hub.enabled.isDisjoint(with: [.cpu, .memory, .network]) ? "Монитор выключен" : "Ждём первый замер…", systemImage: "list.bullet.rectangle",
                                       description: hub.enabled.isDisjoint(with: [.cpu, .memory, .network]) ? Text("Включите монитор процессора, памяти или сети на странице «Модули».") : nil)
            }
        }
        .searchable(text: $search, prompt: "Поиск по имени")
        .onChange(of: selection) { _, new in
            if let name = new, let g = SystemParsers.groupProcesses(hub.processes).first(where: { $0.name == name }) {
                card.load(group: g)
                showInspector = true
            } else {
                showInspector = false
            }
        }
        .inspector(isPresented: $showInspector) {
            if let name = selection, let g = SystemParsers.groupProcesses(hub.processes).first(where: { $0.name == name }) {
                ProcessCard(group: g, model: card) { selection = nil }
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            }
        }
        .onAppear { hub.pageAppeared() }
        .onDisappear { hub.pageDisappeared() }
    }
}

struct ProcessCard: View {
    var group: ProcGroup
    @ObservedObject var model: ProcessCardModel
    var close: () -> Void

    var body: some View {
        SettingsPage {
            Section {
                if let d = model.detail {
                    info("Путь", d.path ?? "—")
                    info("Родитель", d.parentName.map { "\($0) (pid \(d.ppid))" } ?? "pid \(d.ppid)")
                    info("Работает", d.uptime.map(SysFormat.duration) ?? "—")
                    info("PID", group.pids.prefix(6).map(String.init).joined(separator: ", ") + (group.pids.count > 6 ? "…" : ""))
                    if !d.args.isEmpty { info("Аргументы", d.args.dropFirst().joined(separator: " ").prefix(160).description) }
                } else if !model.alive {
                    ToolWarning(text: "Процесс уже завершился или нет доступа к его данным")
                }
                if let path = model.detail?.bundlePath ?? model.detail?.path {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            } header: {
                HStack {
                    Text(group.name).lineLimit(2)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
            Section {
                ChartBlock(title: "ЦП за час", current: String(format: "%.1f%%", group.cpu),
                           series: [ChartSeries(values: model.cpu, color: .accentColor, filled: true)],
                           range: autoRange(model.cpu + [0, 5], floor: 0), height: 70)
                ChartBlock(title: "Память за час", current: SysFormat.bytes(Double(group.rssBytes)),
                           series: [ChartSeries(values: model.rss, color: .green, filled: true)],
                           range: autoRange(model.rss + [0], floor: 0), height: 70)
            }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }
}
