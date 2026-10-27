import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
enum AppIcons {
    private static var cache: [Int32: NSImage] = [:]

    static func icon(pid: Int32) -> NSImage {
        if let i = cache[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        if cache.count > 200 { cache.removeAll() }
        cache[pid] = i
        return i
    }
}

struct PanelActions {
    var hover: (SwitchEntryID) -> Void = { _ in }
    var activate: (SwitchEntryID) -> Void = { _ in }
    var close: (SwitchEntryID) -> Void = { _ in }
    var quit: (Int32) -> Void = { _ in }
    var minimize: (SwitchEntryID) -> Void = { _ in }
    var place: (SwitchEntryID, WindowLayoutAction) -> Void = { _, _ in }
}

struct MiddleClickCatcher: NSViewRepresentable {
    var onMiddle: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onMiddle = onMiddle
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onMiddle = onMiddle }

    final class CatcherView: NSView {
        var onMiddle: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let t = NSApp.currentEvent?.type, t == .otherMouseDown || t == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseUp(with event: NSEvent) { onMiddle() }
    }
}

struct WindowCardView: View {
    let entry: SwitchEntry
    let selected: Bool
    let metrics: SwitcherGridMetrics
    let layout: SwitcherLayout
    let image: CGImage?
    let showTitle: Bool
    let revision: Int
    let actions: PanelActions
    var showQuit = false
    var contextMenu = false
    var middleCloses = false
    @State private var hover = false

    var body: some View {
        Group {
            switch layout {
            case .windows: windowCard
            case .icons: iconCard
            case .simple: simpleRow
            }
        }
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { actions.hover(entry.id) }
        }
        .onTapGesture { actions.activate(entry.id) }
        .overlay { if middleCloses { MiddleClickCatcher { actions.close(entry.id) } } }
        .contextMenu { if contextMenu { menu } }
    }

    @ViewBuilder private var menu: some View {
        Button(entry.isMinimized ? "Вернуть из Dock" : "Свернуть") { actions.minimize(entry.id) }
        Button("На другой дисплей") { actions.place(entry.id, .nextDisplay) }
        Button("Левая половина") { actions.place(entry.id, .leftHalf) }
        Button("Правая половина") { actions.place(entry.id, .rightHalf) }
        Button("На весь экран") { actions.place(entry.id, .maximize) }
        Divider()
        Button("Закрыть окно") { actions.close(entry.id) }
        Button("Выйти из приложения") { actions.quit(entry.pid) }
    }

    private var closeButton: some View {
        Button { entry.kind == .appOnly ? actions.quit(entry.pid) : actions.close(entry.id) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(Circle().fill(Color.black.opacity(0.62)))
        }
        .buttonStyle(.plain)
        .help(entry.kind == .appOnly ? "Выйти из приложения" : (showQuit ? "Выйти из приложения" : "Закрыть окно"))
    }

    private var windowCard: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tileFill)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).padding(2)
                } else {
                    Image(nsImage: AppIcons.icon(pid: entry.pid)).resizable().scaledToFit().frame(width: min(metrics.thumb.height * 0.5, 64)).opacity(entry.isMinimized ? 0.6 : 1)
                }
                if entry.isMinimized || entry.isAppHidden {
                    Image(systemName: entry.isMinimized ? "arrow.down.right.and.arrow.up.left" : "eye.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(4).background(.ultraThinMaterial, in: Circle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(5)
                }
                Image(nsImage: AppIcons.icon(pid: entry.pid)).resizable().frame(width: 22, height: 22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
                if hover || selected { closeButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5) }
                if entry.windowCount > 1 {
                    Text("\(entry.windowCount)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(5)
                }
            }
            .frame(width: metrics.thumb.width, height: metrics.thumb.height)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected || hover ? Theme.accent : Color.clear, lineWidth: 3))
            if showTitle {
                Text(entry.displayTitle).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail).frame(width: metrics.thumb.width)
            }
        }
        .frame(width: metrics.cell.width, height: metrics.cell.height, alignment: .top)
    }

    private var iconCard: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: AppIcons.icon(pid: entry.pid)).resizable().frame(width: metrics.thumb.width, height: metrics.thumb.height).opacity(entry.isMinimized ? 0.6 : 1)
                if hover || selected { closeButton }
            }
            Text(entry.appName).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1).frame(width: metrics.cell.width - 8)
        }
        .frame(width: metrics.cell.width, height: metrics.cell.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.28) : Color.clear))
    }

    private var simpleRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(pid: entry.pid)).resizable().frame(width: 24, height: 24)
            Text(entry.displayTitle).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            if entry.kind == .window, !entry.title.isEmpty { Text(entry.appName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            if entry.isMinimized { Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(.secondary) }
            if hover || selected { closeButton }
        }
        .padding(.horizontal, 10)
        .frame(width: metrics.cell.width, height: metrics.cell.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.28) : Color.clear))
    }
}

@MainActor
final class SwitcherPanelModel: ObservableObject {
    @Published var state: SwitcherViewState?
    @Published var revision = 0
    var cache: ThumbnailCache
    var actions = PanelActions()

    init(cache: ThumbnailCache) { self.cache = cache }
}

struct SwitcherPanelView: View {
    @ObservedObject var model: SwitcherPanelModel
    static let hintsHeight: CGFloat = 22

    var body: some View {
        if let s = model.state { content(s) }
    }

    private func rowsOf(_ s: SwitcherViewState) -> [[Int]] {
        let cols = max(s.metrics.columns, 1)
        return stride(from: 0, to: s.entries.count, by: cols).map { Array($0..<min($0 + cols, s.entries.count)) }
    }

    @ViewBuilder private func content(_ s: SwitcherViewState) -> some View {
        VStack(spacing: 0) {
            if s.searching { searchBar(s) }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: s.metrics.spacing) {
                        ForEach(Array(rowsOf(s).enumerated()), id: \.offset) { r, idxs in
                            HStack(spacing: s.metrics.spacing) {
                                ForEach(idxs, id: \.self) { i in cell(s, i) }
                            }
                            .id(r)
                        }
                        if s.entries.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60) }
                    }
                    .padding(s.metrics.padding)
                }
                .onChange(of: s.selected) { _, sel in
                    guard let sel else { return }
                    let r = s.metrics.row(of: sel)
                    if s.instant { proxy.scrollTo(r) } else { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(r) } }
                }
            }
            if s.showHints { hints(s) }
        }
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func cell(_ s: SwitcherViewState, _ i: Int) -> some View {
        let e = s.entries[i]
        let img = s.thumbnails && e.previewAllowed ? e.windowID.flatMap { model.cache.peek($0) } : nil
        return WindowCardView(entry: e, selected: s.selected == i, metrics: s.metrics, layout: s.layout, image: img, showTitle: !s.minimal, revision: model.revision, actions: model.actions)
    }

    private func searchBar(_ s: SwitcherViewState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(s.query.isEmpty ? "Начни печатать: название окна или приложения" : s.query).font(.system(size: 15)).foregroundStyle(s.query.isEmpty ? .secondary : .primary).lineLimit(1)
            Spacer()
            Text("↩ выбрать   esc очистить").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: SwitcherEngine.searchBarHeight)
    }

    private func hints(_ s: SwitcherViewState) -> some View {
        Text(s.searching ? "↩ открыть   ⇥ следующее   esc отмена" : "⇥ дальше   ⇧⇥ назад   W закрыть   Q выйти   M свернуть   H спрятать   S поиск   esc отмена")
            .font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: Self.hintsHeight)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
