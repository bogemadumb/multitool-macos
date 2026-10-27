import AppKit
import SwiftUI
import MultitulCore
import MultitulUI

private struct HeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

private struct FramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    func measureHeight(_ key: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightsKey.self, value: [key: g.size.height]) })
    }
}

private struct Jiggle: ViewModifier {
    var on: Bool
    var seed: Int
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on ? (phase ? 0.8 : -0.8) : 0))
            .animation(on ? .easeInOut(duration: 0.11 + Double(seed % 4) * 0.012).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { if on { phase = true } }
            .onChange(of: on) { _, v in phase = v }
    }
}

@MainActor
private struct PanelEntry {
    let id: String
    let module: Module
    let kind: PanelItemKind
    let view: AnyView
    let tile: AnyView?

    var allowed: [PanelItemSize] {
        kind == .tile ? [.small] : (tile != nil ? [.small, .medium] : [.medium])
    }
    var fallback: PanelItemSize { kind == .tile ? .small : .medium }
    var bare: Bool { module.id == .quickToggles }

    func section(size: PanelItemSize) -> PanelSection {
        PanelSection.of(module: module.id.rawValue, kind: kind, presentation: module.panelPresentation, small: kind == .card && size == .small)
    }
}

@MainActor
func panelItemIDs(_ runtime: ModuleRuntime) -> [String] {
    var ids: [String] = []
    for m in runtime.activeModules {
        let p = m.panelPresentation
        if p.emitsCard, m.panelCard != nil { ids.append(PanelItemID.make(m.id.rawValue, .card)) }
        if p.emitsTile, m.quickTile != nil { ids.append(PanelItemID.make(m.id.rawValue, .tile)) }
    }
    return ids
}

struct PanelView: View {
    @ObservedObject var runtime: ModuleRuntime
    @ObservedObject var layout: PanelLayoutStore
    var windowCombo: String
    var width: CGFloat
    var maxHeight: CGFloat
    var onHeight: (CGFloat) -> Void
    var openWindow: () -> Void

    @State private var editing = false
    @State private var contentH: CGFloat = 0
    @State private var topH: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var nameDraft = ""
    @State private var dragID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dropTarget: String?
    @State private var frames: [String: CGRect] = [:]

    private let inset: CGFloat = 12
    private let fade: CGFloat = 16
    private var chrome: CGFloat { inset * 2 + 10 }
    private var scrollH: CGFloat { max(0, min(contentH, maxHeight - chrome - topH)) }
    private var totalH: CGFloat { chrome + topH + scrollH }
    private var canScrollUp: Bool { scrollOffset > 1 }
    private var canScrollDown: Bool { contentH > scrollH + 1 && scrollOffset < contentH - scrollH - 1 }

    private var entries: [PanelEntry] {
        var out: [PanelEntry] = []
        for m in runtime.activeModules {
            let p = m.panelPresentation
            let tile = p.emitsTile ? m.quickTile : nil
            if p.emitsCard, let c = m.panelCard { out.append(PanelEntry(id: PanelItemID.make(m.id.rawValue, .card), module: m, kind: .card, view: c, tile: tile)) }
            if let t = tile { out.append(PanelEntry(id: PanelItemID.make(m.id.rawValue, .tile), module: m, kind: .tile, view: t, tile: nil)) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if editing { profileBar }
            }
            .measureHeight("top")
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .measureHeight("content")
                    .background(GeometryReader { g in Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("scroll")).minY) })
            }
            .coordinateSpace(name: "scroll")
            .frame(height: scrollH)
            .mask(fadeMask)
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
        }
        .padding(inset)
        .frame(width: width, height: totalH, alignment: .top)
        .background { VisualEffect(material: .popover) }
        .onPreferenceChange(HeightsKey.self) { v in
            if let c = v["content"], abs(c - contentH) > 0.5 { contentH = c }
            if let t = v["top"], abs(t - topH) > 0.5 { topH = t }
        }
        .onPreferenceChange(FramesKey.self) { frames = $0 }
        .onChange(of: totalH) { _, v in if contentH > 0 { onHeight(v) } }
        .onChange(of: runtime.revision) { _, _ in layout.reconcile(available: panelItemIDs(runtime)) }
        .onChange(of: layout.activeID) { _, _ in nameDraft = layout.active.name }
        .onChange(of: nameDraft) { _, v in if !v.trimmingCharacters(in: .whitespaces).isEmpty && v != layout.active.name { layout.renameActive(v) } }
        .onAppear { nameDraft = layout.active.name }
    }

    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [canScrollUp ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, canScrollDown ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Мультитул").font(.headline)
            if !editing && layout.profiles.count > 1 { profileMenu }
            Spacer(minLength: 4)
            if editing {
                Button("Готово") { editing = false; dragID = nil }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                headerButton("pencil", "Изменить панель") { editing = true }
            }
            headerButton("gearshape", "Открыть окно  \(windowCombo)", action: openWindow)
        }
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var profileMenu: some View {
        Menu {
            ForEach(layout.profiles) { p in
                Button { layout.switchProfile(p.id) } label: {
                    if p.id == layout.activeID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(layout.active.name).font(.caption).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var profileBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(layout.profiles) { p in
                        Button { layout.switchProfile(p.id) } label: {
                            Text(p.name).font(.caption).lineLimit(1)
                                .foregroundStyle(p.id == layout.activeID ? Color.white : Color.primary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(p.id == layout.activeID ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    barButton("plus", "Новый набор") { layout.addProfile(name: "Набор \(layout.profiles.count + 1)"); nameDraft = layout.active.name }
                }
            }
            HStack(spacing: 6) {
                TextField("Название набора", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                barButton("doc.on.doc", "Дублировать набор") { layout.duplicateActive(); nameDraft = layout.active.name }
                barButton("trash", "Удалить набор") { layout.deleteActive(); nameDraft = layout.active.name }
                    .opacity(layout.profiles.count > 1 ? 1 : 0.3)
                    .disabled(layout.profiles.count < 2)
            }
        }
    }

    private func barButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var content: some View {
        let all = entries
        let allIDs = all.map(\.id)
        let profile = layout.active
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = profile.visible(available: allIDs).compactMap { byID[$0] }
        var bySection: [PanelSection: [PanelEntry]] = [:]
        for e in visible {
            let size = profile.size(of: e.id, allowed: e.allowed, fallback: e.fallback)
            bySection[e.section(size: size), default: []].append(e)
        }
        let hiddenEntries = profile.hiddenItems(available: allIDs).compactMap { byID[$0] }
        let cardSections: [PanelSection] = [.sliders, .metrics, .cards]
        return VStack(alignment: .leading, spacing: 8) {
            if let list = bySection[.modules] { grid(list, columns: 2, spacing: 8, profile: profile) }
            ForEach(cardSections, id: \.self) { sec in
                ForEach(bySection[sec] ?? [], id: \.id) { e in cardCell(e, profile: profile) }
            }
            if let list = bySection[.quick] { grid(list, columns: 4, spacing: 8, profile: profile) }
            if visible.isEmpty && !editing {
                Text("Нет включённых модулей с быстрыми действиями")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            if editing { addSection(hiddenEntries) }
        }
        .environment(\.flatCards, true)
        .padding(editing ? 6 : 0)
        .coordinateSpace(name: "pc")
        .animation(.snappy(duration: 0.22), value: profile.order)
        .animation(.snappy(duration: 0.22), value: profile.hidden)
    }

    private func grid(_ list: [PanelEntry], columns n: Int, spacing: CGFloat, profile: PanelProfile) -> some View {
        let rows = stride(from: 0, to: list.count, by: n).map { Array(list[$0..<min($0 + n, list.count)]) }
        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.id) { e in
                        gridCell(e, profile: profile).frame(maxWidth: .infinity)
                    }
                    ForEach(0..<(n - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func gridCell(_ e: PanelEntry, profile: PanelProfile) -> some View {
        let base: AnyView = e.kind == .tile ? e.view : (e.tile ?? e.view)
        return decorated(e, base: base, profile: profile)
            .contextMenu {
                if !editing {
                    if e.kind == .card { sizeMenu(e, profile: profile) }
                    Button("Скрыть с панели") { layout.hide(e.id) }
                    Button("Изменить панель") { editing = true }
                }
            }
    }

    private func cardCell(_ e: PanelEntry, profile: PanelProfile) -> some View {
        let collapsed = profile.isCollapsed(e.id) && !editing
        let base: AnyView = collapsed
            ? AnyView(collapsedRow(e))
            : AnyView(e.bare ? AnyView(e.view) : AnyView(e.view.panelTile()))
        return decorated(e, base: base, profile: profile)
            .contextMenu {
                if !editing {
                    Button(profile.isCollapsed(e.id) ? "Развернуть" : "Свернуть") { layout.toggleCollapsed(e.id) }
                    sizeMenu(e, profile: profile)
                    Button("Скрыть с панели") { layout.hide(e.id) }
                    Button("Изменить панель") { editing = true }
                }
            }
    }

    @ViewBuilder
    private func sizeMenu(_ e: PanelEntry, profile: PanelProfile) -> some View {
        if e.allowed.count > 1 {
            let cur = profile.size(of: e.id, allowed: e.allowed, fallback: e.fallback)
            Menu("Вид") {
                ForEach(e.allowed, id: \.self) { s in
                    Button { layout.setSize(e.id, s) } label: {
                        if s == cur { Label(sizeTitle(s), systemImage: "checkmark") } else { Text(sizeTitle(s)) }
                    }
                }
            }
        }
    }

    private func sizeTitle(_ s: PanelItemSize) -> String {
        switch s {
        case .small: "Плитка"
        case .medium, .wide: "Карточка"
        }
    }

    private func collapsedRow(_ e: PanelEntry) -> some View {
        Button { layout.toggleCollapsed(e.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: e.module.info.symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(e.module.info.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .panelTile()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Развернуть")
    }

    @ViewBuilder
    private func decorated(_ e: PanelEntry, base: AnyView, profile: PanelProfile) -> some View {
        if editing {
            let dragging = dragID == e.id
            base
                .allowsHitTesting(false)
                .overlay { Color.clear.contentShape(Rectangle()).gesture(dragGesture(e.id)) }
                .overlay(alignment: .topLeading) { minusBadge(e.id) }
                .overlay(alignment: .topTrailing) { if e.kind == .card && e.allowed.count > 1 { sizePicker(e, profile: profile) } }
                .overlay {
                    if dropTarget == e.id {
                        RoundedRectangle(cornerRadius: PanelMetrics.tileRadius, style: .continuous).stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: FramesKey.self, value: [e.id: g.frame(in: .named("pc"))]) })
                .modifier(Jiggle(on: !dragging, seed: abs(e.id.hashValue)))
                .scaleEffect(dragging ? 1.04 : 1)
                .opacity(dragging ? 0.85 : 1)
                .offset(dragging ? dragOffset : .zero)
                .zIndex(dragging ? 10 : 0)
        } else {
            base
        }
    }

    private func minusBadge(_ id: String) -> some View {
        Button { layout.hide(id) } label: {
            Image(systemName: "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color(nsColor: .systemGray), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -6, y: -6)
        .help("Убрать с панели")
    }

    private func sizePicker(_ e: PanelEntry, profile: PanelProfile) -> some View {
        let cur = profile.size(of: e.id, allowed: e.allowed, fallback: e.fallback)
        return HStack(spacing: 2) {
            ForEach(e.allowed, id: \.self) { s in
                Button { layout.setSize(e.id, s) } label: {
                    Image(systemName: s == .small ? "square.fill" : "rectangle.fill").font(.system(size: 9))
                        .foregroundStyle(s == cur ? Color.white : Color.secondary)
                        .frame(width: 20, height: 16)
                        .background(s == cur ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sizeTitle(s))
            }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
    }

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("pc"))
            .onChanged { v in
                dragID = id
                dragOffset = v.translation
                dropTarget = frames.first(where: { $0.key != id && $0.value.contains(v.location) })?.key
            }
            .onEnded { _ in
                if let t = dropTarget { drop(id, onto: t) }
                dragID = nil
                dragOffset = .zero
                dropTarget = nil
            }
    }

    private func drop(_ id: String, onto target: String) {
        let order = layout.active.order
        guard let a = order.firstIndex(of: id), let b = order.firstIndex(of: target) else { return }
        if a < b { layout.move(id, before: order.dropFirst(b + 1).first) } else { layout.move(id, before: target) }
    }

    private func addSection(_ list: [PanelEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Добавить").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if list.isEmpty {
                Text("Всё включённое уже на панели").font(.caption).foregroundStyle(.secondary)
            } else {
                let rows = stride(from: 0, to: list.count, by: 2).map { Array(list[$0..<min($0 + 2, list.count)]) }
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.id) { e in addChip(e).frame(maxWidth: .infinity) }
                            ForEach(0..<(2 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func addChip(_ e: PanelEntry) -> some View {
        Button { layout.show(e.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.module.info.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text(e.kind == .card ? "карточка" : "плитка").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .panelTile(radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.module.info.title)
    }
}
