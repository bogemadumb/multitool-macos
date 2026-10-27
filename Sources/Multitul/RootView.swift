import SwiftUI
import Combine
import MultitulCore
import MultitulUI

let modulesPageID = NavCatalog.modulesID

enum NavTarget {
    case today
    case group(ModuleGroup)
    case tool(ToolPageKind)
    case guardian
    case modules
    case hotkeys
    case permissions
    case general
}

struct NavItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: UInt32
    let target: NavTarget
}

struct NavGroup: Identifiable {
    let header: String?
    let items: [NavItem]
    var id: String { header ?? "top" }
}

private let navStyles: [String: (symbol: String, color: UInt32, target: NavTarget)] = [
    "today": ("sun.horizon.fill", 0xFF9500, .today),
    "net": ("globe.europe.africa.fill", 0x007AFF, .group(.net)),
    "system": ("cpu.fill", 0x8E8E93, .group(.system)),
    "guard": ("binoculars.fill", 0x34C759, .guardian),
    "storage": ("internaldrive.fill", 0x5856D6, .group(.clean)),
    "displays": ("photo.tv", 0x32ADE6, .group(.displays)),
    "windows": ("rectangle.split.2x2.fill", 0x30B0C7, .group(.windows)),
    "input": ("computermouse.fill", 0x7C7C82, .group(.input)),
    "sound": ("speaker.wave.3.fill", 0xFF2D55, .group(.sound)),
    "clip": ("doc.on.clipboard.fill", 0xFF6A2F, .group(.clip)),
    "energy": ("bolt.fill", 0x34C759, .group(.energy)),
    "shots": ("camera.viewfinder", 0xFF3B30, .tool(.shots)),
    "cmd": ("apple.terminal.fill", 0x3A3A3C, .tool(.command)),
    "ocr": ("text.viewfinder", 0x00C7BE, .tool(.ocr)),
    "pad": ("note.text", 0xFFC400, .tool(.pad)),
    "tidy": ("bubbles.and.sparkles.fill", 0x7A77FF, .tool(.tidy)),
    "brew": ("arrow.down.app.fill", 0xF5A100, .tool(.brew)),
    "pip": ("pip.fill", 0x3D5AFE, .tool(.pip)),
    "island": ("capsule.fill", 0x1C1C1E, .group(.island)),
    "keys": ("command", 0x8E8E93, .hotkeys),
    "modules": ("puzzlepiece.extension.fill", 0x00B8D9, .modules),
    "perm": ("lock.shield.fill", 0x007AFF, .permissions),
    "general": ("gearshape.fill", 0x8E8E93, .general)
]

let navGroups: [NavGroup] = {
    var heads: [String?] = []
    var buckets: [[NavItem]] = []
    for e in NavCatalog.entries {
        let st = navStyles[e.id] ?? ("questionmark", 0x8e8e93, .today)
        let item = NavItem(id: e.id, title: e.title, symbol: st.symbol, color: st.color, target: st.target)
        if !heads.isEmpty, heads[heads.count - 1] == e.header {
            buckets[buckets.count - 1].append(item)
        } else {
            heads.append(e.header)
            buckets.append([item])
        }
    }
    return zip(heads, buckets).map { NavGroup(header: $0, items: $1) }
}()

let navItems: [NavItem] = navGroups.flatMap(\.items)

struct RootView: View {
    @ObservedObject var nav: NavState
    @ObservedObject var runtime: ModuleRuntime
    @State private var search = ""
    @State private var guardOpen = 0

    private let resultPrefix = "result:"

    private var searching: Bool { !SettingsSearch.words(search).isEmpty }

    private var results: [SettingsIndexEntry] { SettingsSearch.search(search, in: SettingsIndex.all) }

    private var selection: Binding<String?> {
        Binding(get: { nav.selection }, set: { v in
            guard let v else { return }
            if v.hasPrefix(resultPrefix), let idx = Int(v.dropFirst(resultPrefix.count)), results.indices.contains(idx) {
                let entry = results[idx]
                nav.open(section: entry.section, subpage: entry.subpage, isEnabled: { runtime.isEnabled($0) }, pageRenders: pageRenders(entry.section))
                search = ""
            } else if !v.hasPrefix(resultPrefix) {
                nav.selection = v
            }
        })
    }

    private func pageRenders(_ section: String) -> Bool {
        guard let item = navItems.first(where: { $0.id == section }) else { return false }
        switch item.target {
        case .group(let g): return !runtime.modules(in: g).isEmpty
        case .tool: return true
        default: return false
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                if searching {
                    let found = results
                    if found.isEmpty {
                        Text("Ничего не найдено").foregroundStyle(.secondary)
                    } else {
                        Section("Результаты") {
                            ForEach(Array(found.enumerated()), id: \.element.id) { idx, entry in
                                resultRow(entry).tag(resultPrefix + String(idx))
                            }
                        }
                    }
                } else {
                    ForEach(navGroups) { g in
                        if let h = g.header {
                            Section(h) { rows(g.items) }
                        } else {
                            Section { rows(g.items) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            let item = navItems.first { $0.id == nav.selection } ?? navItems[0]
            NavigationStack(path: $nav.path) {
                page(for: item)
                    .navigationTitle(item.title)
            }
            .id(item.id)
            .environment(\.scrollAnchor, nav.anchor)
        }
        .onReceive(StorozhController.shared.$open.map(\.count).removeDuplicates()) { guardOpen = $0 }
        .searchable(text: $search, placement: .sidebar, prompt: "Поиск по настройкам")
        .frame(minWidth: 780, minHeight: 520)
    }

    private func rows(_ items: [NavItem]) -> some View {
        ForEach(items) { item in
            Label {
                Text(item.title)
            } icon: {
                SettingsIcon(symbol: item.symbol, color: Color(nsColor: NSColor(hex: item.color)))
            }
            .badge(item.id == "guard" ? guardOpen : 0)
            .tag(item.id)
        }
    }

    private func resultRow(_ entry: SettingsIndexEntry) -> some View {
        let item = navItems.first { $0.id == entry.section }
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            SettingsIcon(symbol: item?.symbol ?? "gearshape", color: Color(nsColor: NSColor(hex: item?.color ?? 0x8e8e93)))
        }
    }

    @ViewBuilder
    private func page(for item: NavItem) -> some View {
        let enabled = Set(runtime.enabledIDs)
        switch item.target {
        case .today:
            TodayPage(runtime: runtime) { nav.selection = $0 }
        case .modules:
            ModulesPage(runtime: runtime)
        case .hotkeys:
            HotkeysPage(runtime: runtime)
        case .permissions:
            PermissionsPage(runtime: runtime)
        case .general:
            GeneralPage()
        case .group(let g):
            groupPage(g, enabled: enabled)
        case .tool(let k):
            ToolPage(kind: k, enabled: enabled, extras: runtime.modules(in: .tools).filter { $0.info.id == .demoClock }, openModules: { nav.selection = modulesPageID })
        case .guardian:
            if enabled.contains(.storozh) {
                StorozhPage()
            } else {
                ToolDisabledState(title: "Сторож", symbol: "shield.fill", openModules: { nav.selection = modulesPageID })
            }
        }
    }

    @ViewBuilder
    private func groupPage(_ group: ModuleGroup, enabled: Set<ModuleID>) -> some View {
        let modules = runtime.modules(in: group)
        if modules.isEmpty {
            EmptyState(group: group) { nav.selection = modulesPageID }
        } else {
            switch group {
            case .net: ForEach(modules, id: \.info.id) { m in m.settingsView }
            case .system: SystemPage(enabled: enabled)
            case .clean: CleanPage(enabled: enabled)
            case .displays: DisplaysPage(enabled: enabled)
            case .windows: WindowsPage(enabled: enabled, extras: modules.filter { $0.info.id == .demoAccessibility })
            case .input: InputPage(enabled: enabled, extras: modules.filter { $0.info.id == .demoHotkey })
            case .sound: SoundPage(enabled: enabled)
            case .clip: ClipPage(enabled: enabled)
            case .energy: EnergyPage(enabled: enabled)
            case .island: IslandPage(enabled: enabled)
            case .tools: EmptyView()
            }
        }
    }
}

struct EmptyState: View {
    let group: ModuleGroup
    var openModules: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Нет включённых модулей", systemImage: group.symbol)
        } description: {
            Text("В разделе «\(group.title)» ничего не включено. Включить модули можно на странице «Модули».")
        } actions: {
            Button("Открыть «Модули»", action: openModules)
        }
    }
}
