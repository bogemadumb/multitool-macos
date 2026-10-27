import SwiftUI
import MultitulCore
import MultitulUI

struct VpnRulesView: View {
    @ObservedObject var rules: VpnRulesModel
    @State private var text = ""
    @State private var target = VpnRuleTarget.direct

    private var parsed: (kind: VpnRuleKind, value: String)? { VpnRuleDetect.parse(text) }

    var body: some View {
        let items = VpnRuleList.items(user: rules.user, alwaysVps: rules.alwaysVps)
        SettingsPage {
            Section {
                TextField("Сайт, адрес или приложение", text: $text, prompt: Text("example.com"))
                    .onSubmit { submit() }
                Picker("Куда пускать", selection: $target) {
                    ForEach(VpnRuleTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Добавить, без перезапуска") { submit() }
                    .disabled(parsed == nil || rules.busyWrite)
            } header: { Text("Новое правило") } footer: {
                SectionFooter(parsed.map { "\($0.kind.label): \($0.value)" } ?? "Применяется без перезапуска ядра.")
            }
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    LabeledContent {
                        HStack(spacing: 12) {
                            VpnRouteLabel(route: it.route)
                            if let u = it.user {
                                Button { Task { await rules.remove(u) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .disabled(rules.busyWrite)
                                    .help("Удалить правило")
                            } else {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                    .help("Встроенное правило, не редактируется")
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i + 1). \(it.what)").lineLimit(1).truncationMode(.middle)
                            Text(it.note).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            } header: { Text("Правила") } footer: {
                SectionFooter("Сверху вниз, срабатывает первое подходящее.")
            }
        }
        .overlay(alignment: .bottom) { VpnToast(rules: rules).padding(.bottom, 8) }
        .animation(.easeOut(duration: 0.2), value: rules.toast)
        .task { await rules.reload() }
    }

    private func submit() {
        guard let p = parsed, !rules.busyWrite else { return }
        let t = target
        Task {
            if await rules.add(kind: p.kind, value: p.value, target: t) {
                rules.say("\(p.value) — \(t.label)")
                text = ""
            }
        }
    }
}
