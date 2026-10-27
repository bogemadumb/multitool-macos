import SwiftUI

public struct SidebarEntry: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let symbol: String
    public let badge: Bool
    public let color: UInt32?

    public init(id: String, title: String, symbol: String, badge: Bool = false, color: UInt32? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.color = color
    }
}

public struct SidebarItem: View {
    var entry: SidebarEntry
    var selected: Bool

    public init(entry: SidebarEntry, selected: Bool) {
        self.entry = entry
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let c = entry.color {
                SettingsIcon(symbol: entry.symbol, color: Color(nsColor: NSColor(hex: c)))
            } else {
                IconTile(symbol: entry.symbol, active: selected)
            }
            Text(entry.title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if entry.badge {
                Circle().fill(selected ? Color.white : Theme.warn).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
    }
}

public struct SearchField: View {
    @Binding var text: String
    var prompt: String

    public init(text: Binding<String>, prompt: String = "Поиск") {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

public struct Sidebar<Brand: View>: View {
    var sections: [[SidebarEntry]]
    @Binding var selection: String
    @Binding var search: String
    var searchPrompt: String
    @ViewBuilder var brand: () -> Brand
    @FocusState private var focused: Bool

    public init(sections: [[SidebarEntry]], selection: Binding<String>, search: Binding<String>, searchPrompt: String = "Поиск", @ViewBuilder brand: @escaping () -> Brand) {
        self.sections = sections
        self._selection = selection
        self._search = search
        self.searchPrompt = searchPrompt
        self.brand = brand
    }

    private var visible: [[SidebarEntry]] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return sections }
        return sections.map { $0.filter { $0.title.lowercased().contains(q) } }.filter { !$0.isEmpty }
    }

    private func step(_ delta: Int) {
        let flat = visible.flatMap { $0 }
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : flat.count)
        selection = flat[min(max(i + delta, 0), flat.count - 1)].id
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                brand().padding(.horizontal, 10).padding(.bottom, 10)
                SearchField(text: $search, prompt: searchPrompt).padding(.horizontal, 4).padding(.bottom, 8)
                ForEach(Array(visible.enumerated()), id: \.offset) { idx, group in
                    if idx > 0 {
                        Divider().padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(group) { entry in
                        SidebarItem(entry: entry, selected: entry.id == selection)
                            .onTapGesture { selection = entry.id; focused = true }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .onKeyPress(.downArrow) { step(1); return .handled }
        }
        .onAppear { focused = true }
    }
}
