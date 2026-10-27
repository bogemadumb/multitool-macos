import SwiftUI

public struct IconTile: View {
    var symbol: String
    var size: CGFloat
    var active: Bool
    var tint: Color

    public init(symbol: String, size: CGFloat = 22, active: Bool = false, tint: Color = Theme.accent) {
        self.symbol = symbol
        self.size = size
        self.active = active
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(active ? Color.white : tint)
            .frame(width: size, height: size)
            .background(active ? Color.white.opacity(0.22) : Theme.tileFill, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: active ? 0 : 1))
    }
}

public struct ToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool

    public init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Fonts.body)
                    if let subtitle {
                        Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .frame(minHeight: 34)
        }
    }
}

public struct SettingsRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    public init(symbol: String, title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.body)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 6)
    }
}

public struct SliderRow: View {
    var symbol: String
    @Binding var value: Double

    public init(symbol: String, value: Binding<Double>) {
        self.symbol = symbol
        self._value = value
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 16)
            Slider(value: $value, in: 0...100).tint(Theme.accent).controlSize(.small)
            Text("\(Int(value))")
                .font(Theme.Fonts.number)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

public struct KeyCaps: View {
    var keys: [String]

    public init(_ keys: [String]) { self.keys = keys }
    public init(_ combo: String) { self.keys = combo.map { String($0) } }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, k.count > 1 ? 5 : 0)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 1)
            }
        }
    }
}
