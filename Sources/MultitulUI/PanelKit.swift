import SwiftUI
import AppKit

private struct FlatCardsKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    var flatCards: Bool {
        get { self[FlatCardsKey.self] }
        set { self[FlatCardsKey.self] = newValue }
    }
}

public enum PanelMetrics {
    public static let tileRadius: CGFloat = 16
    public static let windowRadius: CGFloat = 20
}

public extension View {
    func panelTile(radius: CGFloat = PanelMetrics.tileRadius) -> some View {
        background(.quaternary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

public struct ModuleTile<Options: View>: View {
    var symbol: String
    var title: String
    var status: String
    var active: Bool
    var enabled: Bool
    var action: () -> Void
    var options: Options?

    public init(symbol: String, title: String, status: String, active: Bool = false, enabled: Bool = true,
                action: @escaping () -> Void, @ViewBuilder options: () -> Options) {
        self.symbol = symbol
        self.title = title
        self.status = status
        self.active = active
        self.enabled = enabled
        self.action = action
        self.options = options()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    SettingsIcon(symbol: symbol, color: IconPalette.color(for: symbol), size: 38, off: !active)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, options == nil ? 10 : 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let options {
                Menu { options } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
        .panelTile()
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .help(status.isEmpty ? title : "\(title): \(status)")
    }
}

public extension ModuleTile where Options == EmptyView {
    init(symbol: String, title: String, status: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.status = status
        self.active = active
        self.enabled = enabled
        self.action = action
        self.options = nil
    }
}

public struct CapsuleSlider: View {
    var symbol: String
    @Binding var value: Double
    var enabled: Bool

    public init(symbol: String, value: Binding<Double>, enabled: Bool = true) {
        self.symbol = symbol
        self._value = value
        self.enabled = enabled
    }

    public var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = min(max(value / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color(light: NSColor.white, dark: NSColor(white: 0.9, alpha: 1))).frame(width: max(g.size.height, w * f))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(f > 0.08 ? Color(white: 0.33) : Color.secondary)
                    .frame(width: 30)
                    .padding(.leading, 4)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = min(max(v.location.x / max(w, 1), 0), 1) * 100
            })
        }
        .frame(height: 28)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement()
        .accessibilityValue("\(Int(value)) %")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(value + 5, 100)
            case .decrement: value = max(value - 5, 0)
            @unknown default: break
            }
        }
    }
}

public struct MiniRing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat

    public init(fraction: Double, color: Color, lineWidth: CGFloat = 4) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
