import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

enum ProcessGuardLists {
    // User-edited lists live in the shared database; built-in untouchables apply even when it is missing.
    static func load() -> StorozhLists {
        guard FileManager.default.fileExists(atPath: MultitulPaths.dbPath),
              let store = try? StorozhSchema.openStore(readOnly: true),
              let l = try? StorozhRepository(store: store).lists() else { return StorozhLists() }
        return l
    }

    static func service() -> KillProcessService {
        KillProcessService.live(lists: load(), privileged: PrivilegedCtl())
    }
}

enum PendingKill: Identifiable {
    case tree(CatalogProcess)
    case group(CatalogGroup)
    case port(ListeningPort)

    var id: String {
        switch self {
        case .tree(let p): "tree-\(p.pid)"
        case .group(let g): "group-\(g.key)"
        case .port(let p): "port-\(p.id)"
        }
    }

    var title: String {
        switch self {
        case .tree(let p): "Завершить «\(p.name)» вместе с дочерними?"
        case .group(let g): "Завершить «\(g.title)» целиком (\(g.processes.count))?"
        case .port(let p): "Остановить «\(p.command)» (pid \(p.pid)), порт \(p.port)?"
        }
    }
}

@MainActor
final class KillProcessModel: ObservableObject {
    @Published private(set) var groups: [CatalogGroup] = []
    @Published private(set) var busy = false
    @Published var toast: String?

    func refresh() {
        Task { groups = ProcessCatalog.group(await Task.detached { ProcessCatalog.live() }.value) }
    }

    func canTouch(_ p: CatalogProcess) -> Bool {
        KillProcessService(ops: SystemProcOps(), lists: lists).canTouch(p)
    }

    private var lists = ProcessGuardLists.load()

    func reloadLists() { lists = ProcessGuardLists.load() }

    func run(_ title: String, _ work: @escaping @Sendable (KillProcessService) -> [ActionOutcome]) {
        guard !busy else { return }
        busy = true
        Task {
            let outs = await Task.detached { work(ProcessGuardLists.service()) }.value
            let failed = outs.filter { $0.status != "done" }
            toast = failed.isEmpty ? "\(title): готово" : "\(title): не вышло (\(failed.first?.note ?? ""))"
            busy = false
            try? await Task.sleep(for: .seconds(1))
            refresh()
            Task {
                try? await Task.sleep(for: .seconds(4))
                toast = nil
            }
        }
    }

    func forceQuit(_ p: CatalogProcess) { run("«\(p.name)» завершён") { [$0.forceQuit(p)] } }
    func restart(_ p: CatalogProcess) { run("«\(p.name)» перезапущен") { [$0.restart(p)] } }
    func killTree(_ p: CatalogProcess) { run("«\(p.name)» с дочерними завершён") { [$0.killTree(p)] } }
    func quit(_ g: CatalogGroup) { run("«\(g.title)» завершён") { $0.quitGroup(g) } }
}

struct KillProcessView: View {
    @StateObject private var model = KillProcessModel()
    @State private var query = ""
    @State private var expanded = Set<String>()
    @State private var pending: PendingKill?

    var body: some View {
        let groups = ProcessCatalog.search(model.groups, query: query)
        SettingsPage {
            Section {
                if groups.isEmpty { EmptyHint(text: "Ничего не найдено", symbol: "magnifyingglass") }
                ForEach(groups.prefix(80)) { g in
                    groupRow(g, forceOpen: !query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Процессы") } footer: {
                SectionFooter("Системные и неприкасаемые процессы (замок) не завершаются. Для процессов root нужен установленный root-слой (sudoers).")
            }
        }
        .searchable(text: $query, prompt: "Поиск по имени или pid")
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let t = model.toast { Label(t, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        }
        .onAppear { model.reloadLists(); model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.refresh()
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Завершить", role: .destructive) {
                switch pending {
                case .tree(let p): model.killTree(p)
                case .group(let g): model.quit(g)
                default: break
                }
                pending = nil
            }
            Button("Отмена", role: .cancel) { pending = nil }
        }
    }

    @ViewBuilder private func groupRow(_ g: CatalogGroup, forceOpen: Bool) -> some View {
        let open = forceOpen || expanded.contains(g.key)
        LabeledContent {
            HStack(spacing: 12) {
                Text(String(format: "%.1f%%", g.cpu)).monospacedDigit()
                Text(SysFormat.bytes(Double(g.rssBytes))).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                if g.bundlePath != nil, g.processes.contains(where: model.canTouch) {
                    Button("Завершить всё") { pending = .group(g) }.controlSize(.small)
                }
            }
        } label: {
            Button { if expanded.contains(g.key) { expanded.remove(g.key) } else { expanded.insert(g.key) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12)
                    Text(g.title).lineLimit(1)
                    if g.processes.count > 1 { Text("×\(g.processes.count)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
        }
        if open {
            ForEach(g.processes) { p in processRow(p) }
        }
    }

    private func processRow(_ p: CatalogProcess) -> some View {
        let ok = model.canTouch(p)
        return LabeledContent {
            HStack(spacing: 12) {
                Text(String(p.pid)).foregroundStyle(.secondary).monospacedDigit()
                Text(String(format: "%.1f%%", p.cpu)).monospacedDigit()
                Text(SysFormat.bytes(Double(p.rssBytes))).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                if ok {
                    Menu {
                        Button("Завершить (SIGTERM, затем SIGKILL)") { model.forceQuit(p) }
                        if p.bundlePath != nil && p.path.contains(".app/Contents/MacOS/") { Button("Перезапустить") { model.restart(p) } }
                        Button("Завершить с дочерними…") { pending = .tree(p) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(p.name, systemImage: ok ? (p.isRoot ? "shield.lefthalf.filled" : "circle.fill") : "lock.fill").lineLimit(1)
                .padding(.leading, 18)
        }
        .help(p.path)
    }
}

@MainActor
final class PortManagerModel: ObservableObject {
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var busy = false
    @Published var toast: String?

    func refresh() {
        Task { ports = await Task.detached { PortScanner.scan() }.value }
    }

    func stop(_ port: ListeningPort) {
        guard !busy else { return }
        busy = true
        Task {
            let out: ActionOutcome = await Task.detached {
                guard let proc = ProcessCatalog.live().first(where: { $0.pid == port.pid }) else {
                    return ActionOutcome(action: "kill", status: "failed", note: "process gone")
                }
                return ProcessGuardLists.service().forceQuit(proc)
            }.value
            toast = out.status == "done" ? "Порт \(port.port): «\(port.command)» остановлен" : "Порт \(port.port): не вышло (\(out.note))"
            busy = false
            try? await Task.sleep(for: .seconds(1))
            refresh()
            try? await Task.sleep(for: .seconds(4))
            toast = nil
        }
    }
}

extension ListeningPort {
    var protoName: String { proto.rawValue }
    var exposure: Int { isLocalOnly ? 0 : 1 }
}

struct PortManagerView: View {
    @StateObject private var model = PortManagerModel()
    @State private var query = ""
    @State private var showUDP = true
    @State private var pending: ListeningPort?
    @State private var sortOrder = [KeyPathComparator(\ListeningPort.port)]

    private var rows: [ListeningPort] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.ports.filter { p in
            (showUDP || p.proto == .tcp) && (q.isEmpty || String(p.port).contains(q) || p.command.lowercased().contains(q) || String(p.pid) == q)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        let list = rows
        Table(list, sortOrder: $sortOrder) {
            TableColumn("Порт", value: \.port) { p in Text(String(p.port)).monospacedDigit() }
                .width(min: 56, ideal: 70)
            TableColumn("Протокол", value: \.protoName) { p in Text(p.protoName).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
            TableColumn("Процесс", value: \.command) { p in Text(p.command).lineLimit(1) }
            TableColumn("pid", value: \.pid) { p in Text(String(p.pid)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 64)
            TableColumn("Адрес", value: \.exposure) { p in
                StatusLabel(p.isLocalOnly ? "только localhost" : "все интерфейсы", color: p.isLocalOnly ? .secondary : .orange)
            }
            .width(min: 120, ideal: 150)
            TableColumn("") { p in
                Button("Остановить", role: .destructive) { pending = p }.controlSize(.small)
            }
            .width(min: 90, ideal: 100)
        }
        .overlay {
            if list.isEmpty { ContentUnavailableView("Слушающих портов не видно", systemImage: "network") }
        }
        .searchable(text: $query, prompt: "Порт, процесс или pid")
        .toolbar {
            ToolbarItemGroup {
                Toggle("UDP", isOn: $showUDP)
                Button { model.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let t = model.toast { Label(t, systemImage: "info.circle") }
                Text("Видны сокеты текущего пользователя (lsof -nP). Остановка идёт через ту же защиту, что и «Завершение процессов».").foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                model.refresh()
            }
        }
        .confirmationDialog(pending.map { PendingKill.port($0).title } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Остановить", role: .destructive) {
                if let p = pending { model.stop(p) }
                pending = nil
            }
            Button("Отмена", role: .cancel) { pending = nil }
        }
    }
}

@MainActor
final class SimpleModule: Module {
    let info: ModuleInfo
    init(id: ModuleID) { info = id.info }
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    func start() { Log.write("module \(info.id.rawValue) start") }
    func stop() { Log.write("module \(info.id.rawValue) stop") }
}
