import SwiftUI
import MultitulCore
import MultitulUI

struct VpnToast: View {
    @ObservedObject var rules: VpnRulesModel

    var body: some View {
        if let s = rules.toast {
            Text(s)
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .transition(.opacity)
        }
    }
}

struct VpnConnectionsView: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var model: VpnConnectionsModel
    @ObservedObject var rules: VpnRulesModel
    @State private var sortOrder: [KeyPathComparator<VpnConnRow>] = []
    @State private var selection = Set<VpnConnRow.ID>()

    private var rows: [VpnConnRow] {
        let list = model.visible
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private func picked(_ ids: Set<VpnConnRow.ID>) -> [VpnConnRow] { model.rows.filter { ids.contains($0.id) } }

    var body: some View {
        let list = rows
        Table(list, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Приложение", value: \.app) { r in
                Text(r.app).fontWeight(.semibold).lineLimit(1)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Куда", value: \.host) { r in
                Text(r.host).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 110, ideal: 170)
            TableColumn("Путь", value: \.routeLabel) { r in
                VpnRouteLabel(route: r.route)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Правило", value: \.ruleText) { r in
                Text(r.ruleText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Скорость", value: \.speed) { r in
                Text(VpnFormat.speed(r.speed)).monospacedDigit().foregroundStyle(r.speed > 0 ? Color.primary : Color.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 75)
            TableColumn("Длится", value: \.startedStamp) { r in
                Text(r.started.map { VpnFormat.age(Date().timeIntervalSince($0)) } ?? "—").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 60)
        }
        .contextMenu(forSelectionType: VpnConnRow.ID.self) { ids in
            let sel = picked(ids)
            Button("Оборвать") { sel.forEach { model.drop($0) } }
            Divider()
            Button("Этот сайт, всегда напрямую") { sel.forEach { model.ruleForSite($0, .direct) } }
            Button("Этот сайт, всегда через VPS") { sel.forEach { model.ruleForSite($0, .proxy) } }
            Divider()
            Button("Это приложение, напрямую") { sel.forEach { model.ruleForApp($0, .direct) } }.disabled(sel.contains { $0.app == "—" })
            Button("Это приложение, через VPS") { sel.forEach { model.ruleForApp($0, .proxy) } }.disabled(sel.contains { $0.app == "—" })
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView(model.failed ? "Ядро не отвечает" : "Нет соединений", systemImage: model.failed ? "exclamationmark.triangle.fill" : "network")
            }
        }
        .overlay(alignment: .bottom) { VpnToast(rules: rules).padding(.bottom, 8) }
        .animation(.easeOut(duration: 0.2), value: rules.toast)
        .searchable(text: $model.search, prompt: "Приложение или сайт")
        .toolbar {
            ToolbarItem {
                Picker("Путь", selection: $model.filter) {
                    ForEach(VpnConnFilter.allCases, id: \.self) { f in Text("\(f.label) · \(model.count(f))").tag(f) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task { await model.run() }
        .onAppear { controller.traffic.setVisible("conns", true) }
        .onDisappear { controller.traffic.setVisible("conns", false) }
    }
}
