import SwiftUI

public struct Card<Content: View>: View {
    var padding: CGFloat
    var fillHeight: Bool
    @ViewBuilder var content: () -> Content

    public init(padding: CGFloat = 14, fillHeight: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.fillHeight = fillHeight
        self.content = content
    }

    @Environment(\.flatCards) private var flat

    public var body: some View {
        if flat {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        } else {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
        }
    }
}

public struct ProgressBar: View {
    var value: Double
    var color: Color
    var height: CGFloat

    public init(value: Double, color: Color = Theme.accent, height: CGFloat = 5) {
        self.value = value
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

public struct MetricCard: View {
    var label: String
    var value: String
    var unit: String
    var progress: Double
    var color: Color
    var compact: Bool

    public init(label: String, value: String, unit: String = "", progress: Double, color: Color = Theme.accent, compact: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.progress = progress
        self.color = color
        self.compact = compact
    }

    public var body: some View {
        Card(padding: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(Theme.Fonts.label).foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(compact ? Theme.Fonts.midNumber : Theme.Fonts.bigNumber)
                    if !unit.isEmpty {
                        Text(unit).font(Theme.Fonts.unit).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 6)
                ProgressBar(value: progress, color: color).padding(.top, 10)
            }
        }
    }
}

public enum PillStyle {
    case ok, warn, neutral

    var color: Color {
        switch self {
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .neutral: Theme.muted
        }
    }
}

public struct Pill: View {
    var text: String
    var style: PillStyle

    public init(_ text: String, style: PillStyle = .neutral) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(Theme.Fonts.pill)
            .foregroundStyle(style.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.14), in: Capsule())
    }
}

public struct ListRow: View {
    var title: String
    var value: String
    var pill: Pill?

    public init(title: String, value: String, pill: Pill? = nil) {
        self.title = title
        self.value = value
        self.pill = pill
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.Fonts.body).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(Theme.Fonts.number).foregroundStyle(Theme.secondaryText)
            if let pill { pill }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }
}

public struct SectionLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(Theme.Fonts.label).foregroundStyle(Theme.muted)
    }
}
