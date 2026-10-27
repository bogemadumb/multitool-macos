import SwiftUI

public struct QuickTileModel: Identifiable {
    public let id: String
    public let symbol: String
    public let caption: String
    public var active: Bool

    public init(id: String, symbol: String, caption: String, active: Bool = false) {
        self.id = id
        self.symbol = symbol
        self.caption = caption
        self.active = active
    }
}

public struct QuickTile: View {
    var symbol: String
    var caption: String
    var active: Bool
    var enabled: Bool
    var help: String?
    var action: () -> Void

    public init(symbol: String, caption: String, active: Bool = false, enabled: Bool = true, help: String? = nil, action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.caption = caption
        self.active = active
        self.enabled = enabled
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 5) {
                        SettingsIcon(symbol: symbol, color: IconPalette.color(for: symbol), size: 44, off: !active)
                        Text(caption).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 3)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: PanelMetrics.tileRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .help(help ?? caption)
    }
}

public struct QuickTileGrid: View {
    @Binding var tiles: [QuickTileModel]

    public init(tiles: Binding<[QuickTileModel]>) { self._tiles = tiles }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach($tiles) { $t in
                QuickTile(symbol: t.symbol, caption: t.caption, active: t.active) { t.active.toggle() }
            }
        }
    }
}

public struct MenuBarPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(width: 340)
            .background { panelBackground }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26, *) {
            Color.clear.glassSurface(radius: Theme.Radius.window)
        } else {
            VisualEffect(material: .popover)
        }
    }
}
