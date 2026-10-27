import SwiftUI
import MultitulCore
import MultitulUI

private enum VpnJournalFilter: Int, CaseIterable {
    case all, drops, watchdog, leaks, speed

    var title: String {
        switch self {
        case .all: "Все"
        case .drops: "Обрывы"
        case .watchdog: "Сторож"
        case .leaks: "Утечки"
        case .speed: "Скорость"
        }
    }

    func matches(_ e: VpnEventGroup) -> Bool { matches(e.latest) }

    func matches(_ e: VpnEventRow) -> Bool {
        switch self {
        case .all: true
        case .drops: VpnEventKind.isDrop(e.kind)
        case .watchdog: e.kind == "watchdog"
        case .leaks: e.kind == "leak"
        case .speed: e.kind == "speed"
        }
    }
}

extension VpnEventRow {
    var kindTitle: String { VpnEventKind.title(kind) }
    var durationValue: Double { isOpen ? .infinity : (VpnEventKind.isDrop(kind) ? duration ?? 0 : 0) }
}

extension VpnEventGroup {
    var kindTitle: String { latest.kindTitle }
    var durationValue: Double { count > 1 ? 0 : latest.durationValue }
}

struct VpnJournalView: View {
    @ObservedObject var insights: VpnInsightsModel
    @State private var filter = VpnJournalFilter.all
    @State private var sortOrder = [KeyPathComparator(\VpnEventGroup.start, order: .reverse)]

    private func tone(_ kind: String) -> Color {
        switch kind {
        case "leak": .red
        case "watchdog": .blue
        case "speed": .secondary
        default: .orange
        }
    }

    var body: some View {
        let shown = VpnEventCollapse.collapse(insights.events.filter { filter.matches($0) }).sorted(using: sortOrder)
        Table(shown, sortOrder: $sortOrder) {
            TableColumn("Время", value: \.start) { e in
                Text(e.start, format: .dateTime.day().month(.abbreviated).hour().minute()).monospacedDigit()
            }
            .width(min: 90, ideal: 100)
            TableColumn("Тип", value: \.kindTitle) { e in
                StatusLabel(e.kindTitle, color: tone(e.kind))
            }
            .width(min: 90, ideal: 100)
            TableColumn("Событие", value: \.detail) { e in
                HStack(spacing: 6) {
                    Text(e.detail).lineLimit(2)
                    if e.count > 1 {
                        Text("×\(e.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                            .help("С \(e.earliest.formatted(.dateTime.day().month(.abbreviated).hour().minute())) по \(e.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    }
                }
            }
            .width(min: 200, ideal: 340)
            TableColumn("Длительность", value: \.durationValue) { e in
                let t = e.count > 1 ? "" : VpnEventLine(e: e.latest).durationText
                Text(t).foregroundStyle(e.latest.isOpen ? Color.red : Color.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 90)
        }
        .overlay {
            if !insights.available {
                ContentUnavailableView("История недоступна", systemImage: "externaldrive.badge.exclamationmark", description: Text("Не открылась база Мультитула"))
            } else if shown.isEmpty {
                if insights.loaded {
                    ContentUnavailableView("Событий нет", systemImage: "list.bullet.rectangle")
                } else {
                    ProgressView("Читаю журнал…")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Тип", selection: $filter) {
                    ForEach(VpnJournalFilter.allCases, id: \.self) { f in
                        Text("\(f.title) · \(insights.events.filter { f.matches($0) }.count)").tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("События хранятся год")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(8)
        }
    }
}
