import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct ShelfView: View {
    @ObservedObject var model: ShelfViewModel
    var showClose = true
    var embedded = false
    @State private var thumbTick = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.items.isEmpty { emptyState } else { list }
        }
        .overlay {
            if model.targeted {
                RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .background { if !embedded { VisualEffect(material: .hudWindow) } }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { model.actions?.quickLook(model.selectedOrAll.prefix(1).map { $0 }); return .handled }
        .onKeyPress(.delete) { model.actions?.remove(model.orderedSelection); return .handled }
        .onKeyPress(.deleteForward) { model.actions?.remove(model.orderedSelection); return .handled }
        .onKeyPress(.return) { model.actions?.open(model.orderedSelection); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "ac"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.characters == "a" { model.selectAll() } else { model.actions?.copy(model.selectedOrAll) }
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("Полка").font(.system(size: 13, weight: .bold))
            if !model.items.isEmpty { Pill("\(model.items.count)", style: .neutral) }
            if let busy = model.busy { Text(busy).font(Theme.Fonts.caption).foregroundStyle(Theme.muted) }
            Spacer()
            if !model.items.isEmpty {
                headerButton("square.and.arrow.up", help: "Поделиться") { model.actions?.share(model.selectedOrAll) }
                headerButton("doc.zipper", help: "Сжать в zip") { model.actions?.compress(model.selectedOrAll) }
                headerButton("trash", help: "Очистить всё (закреплённое останется)") { model.actions?.clearAll() }
            }
            if showClose { headerButton("xmark", help: "Закрыть полку") { model.actions?.closeShelf() } }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.muted)
            Text("Брось сюда файлы, ссылки, текст или картинки").font(Theme.Fonts.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { item in
                    ShelfRow(model: model, item: item, tick: thumbTick) { thumbTick += 1 }
                }
            }
            .padding(6)
        }
    }
}

struct ShelfRow: View {
    @ObservedObject var model: ShelfViewModel
    let item: ShelfItem
    let tick: Int
    var thumbReady: () -> Void
    @State private var hover = false

    private var state: ShelfFileState? { model.states[item.id] }
    private var selected: Bool { model.selection.contains(item.id) }
    private var missing: Bool { state?.isMissing == true }

    var body: some View {
        let _ = tick
        ZStack {
            HStack(spacing: 10) {
                Image(nsImage: ShelfThumbs.shared.image(for: item, state: state, payload: model.service.payload(of: item.id)?.data, ready: thumbReady))
                    .resizable().scaledToFit().frame(width: 32, height: 32)
                    .opacity(missing ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(missing ? Theme.warn : Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            ShelfRowInteraction(
                onDown: { cmd, shift, clicks in
                    model.pointerDown(item.id, command: cmd, shift: shift)
                    if clicks == 2 && !cmd && !shift { model.actions?.open([item.id]) }
                },
                onUp: { cmd, shift in model.pointerUp(item.id, command: cmd, shift: shift) },
                dragSetup: { dragSetup() },
                menu: { contextMenu() })
            if hover {
                HStack(spacing: 2) {
                    Spacer()
                    rowButton("eye", "Быстрый просмотр") { model.actions?.quickLook([item.id]) }
                    if item.kind.isPath { rowButton("magnifyingglass", "Показать в Finder") { model.actions?.reveal([item.id]) } }
                    rowButton(item.pinned ? "pin.slash" : "pin", item.pinned ? "Открепить" : "Закрепить") { model.service.togglePin(item.id); model.refresh() }
                    rowButton("xmark", "Убрать с полки") { model.actions?.remove([item.id]) }
                }
                .padding(.trailing, 6)
            }
        }
        .background(selected ? Theme.accent.opacity(0.22) : (hover ? Theme.field : Color.clear), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        if missing { return "Файл не найден: был " + (item.path.map { ShelfPaths.displayDirectory($0) } ?? "—") }
        switch item.kind {
        case .file: return [item.detail, item.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file) : nil].compactMap { $0 }.joined(separator: " · ")
        case .folder: return item.detail
        case .text, .url: return item.detail
        case .image: return [item.detail, ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private func rowButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).background(Theme.cardFill, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .help(help)
    }

    @MainActor
    private func dragSetup() -> ShelfDragSetup? {
        guard let actions = model.actions else { return nil }
        let ids = model.selection.contains(item.id) ? model.orderedSelection : [item.id]
        let writers = actions.writers(for: ids)
        let preview = ShelfThumbs.shared.image(for: item, state: state, payload: nil, ready: {})
        return ShelfDragSetup(writers: writers, preview: preview, ids: ids) { accepted in actions.dragEnded(ids: ids, accepted: accepted) }
    }

    @MainActor
    private func contextMenu() -> NSMenu? {
        let ids = model.idsForContext(item.id)
        return ShelfMenuBuilder.menu(for: ids, model: model)
    }
}

@MainActor
enum ShelfMenuBuilder {
    private final class Target: NSObject {
        var handlers: [Int: () -> Void] = [:]
        @objc func fire(_ sender: NSMenuItem) { handlers[sender.tag]?() }
    }

    nonisolated(unsafe) private static var live: [Target] = []

    static func menu(for ids: [Int64], model: ShelfViewModel) -> NSMenu {
        let target = Target()
        live = [target]
        let menu = NSMenu()
        var tag = 0
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            tag += 1
            let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: "")
            item.target = target
            item.tag = tag
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            target.handlers[tag] = action
            menu.addItem(item)
        }
        let items = model.items.filter { ids.contains($0.id) }
        let hasPath = items.contains { $0.kind.isPath }
        let allPinned = !items.isEmpty && items.allSatisfy(\.pinned)
        add("Быстрый просмотр", "eye") { model.actions?.quickLook(Array(ids.prefix(1))) }
        add("Открыть", "arrow.up.forward.app") { model.actions?.open(ids) }
        if hasPath { add("Показать в Finder", "magnifyingglass") { model.actions?.reveal(ids) } }
        menu.addItem(.separator())
        add("Скопировать", "doc.on.doc") { model.actions?.copy(ids) }
        add("Поделиться…", "square.and.arrow.up") { model.actions?.share(ids) }
        add("AirDrop", "airplayaudio") { model.actions?.airDrop(ids) }
        add("Сжать в zip", "doc.zipper") { model.actions?.compress(ids) }
        menu.addItem(.separator())
        add(allPinned ? "Открепить" : "Закрепить", allPinned ? "pin.slash" : "pin") { model.service.setPinned(ids, !allPinned); model.refresh() }
        add("Убрать с полки", "xmark") { model.actions?.remove(ids) }
        add("Очистить всё", "trash") { model.actions?.clearAll() }
        return menu
    }
}
