import SwiftUI

public struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Fonts.pageTitle)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.subtitle).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

public extension PageHeader where Trailing == SegmentedControl {
    init(title: String, subtitle: String? = nil, segments: [String], selection: Binding<Int>) {
        self.init(title: title, subtitle: subtitle) { SegmentedControl(segments: segments, selection: selection) }
    }
}

public struct SegmentedControl: View {
    var segments: [String]
    @Binding var selection: Int

    public init(segments: [String], selection: Binding<Int>) {
        self.segments = segments
        self._selection = selection
    }

    public var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in Text(s).tag(i) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

public struct AdaptiveSegmentedControl: View {
    var segments: [String]
    @Binding var selection: Int

    public init(segments: [String], selection: Binding<Int>) {
        self.segments = segments
        self._selection = selection
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            SegmentedControl(segments: segments, selection: $selection)
            Picker("", selection: $selection) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, s in Text(s).tag(i) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}
