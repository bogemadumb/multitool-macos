import SwiftUI

public struct SliderSetting: View {
    var title: String
    var subtitle: String?
    @Binding var value: Double
    var range: ClosedRange<Double>

    public init(_ title: String, _ subtitle: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
    }

    public var body: some View {
        LabeledContent {
            Slider(value: $value, in: range).frame(minWidth: 110, maxWidth: 220)
        } label: { SettingLabel(title, subtitle) }
    }
}

public struct StepperSetting: View {
    var title: String
    var subtitle: String?
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var unit: String
    var zeroText: String?

    public init(_ title: String, _ subtitle: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String = "", zeroText: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.zeroText = zeroText
    }

    public var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                SettingLabel(title, subtitle)
                Spacer()
                Text(value == 0 ? (zeroText ?? "0\(unit)") : "\(value)\(unit)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

public struct FieldSetting: View {
    var title: String
    var subtitle: String?
    @Binding var text: String
    var prompt: String
    var secure: Bool

    public init(_ title: String, _ subtitle: String? = nil, text: Binding<String>, prompt: String = "", secure: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        _text = text
        self.prompt = prompt
        self.secure = secure
    }

    public var body: some View {
        LabeledContent {
            Group {
                if secure { SecureField("", text: $text, prompt: Text(prompt)) } else { TextField("", text: $text, prompt: Text(prompt)) }
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 120, maxWidth: 280)
        } label: { SettingLabel(title, subtitle) }
    }
}

public struct ToolWarning: View {
    var text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

public struct IntSliderSetting: View {
    var title: String
    var subtitle: String?
    var unit: String
    var range: ClosedRange<Int>
    var step: Int
    @Binding var value: Int

    public init(_ title: String, _ subtitle: String? = nil, unit: String = "", value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        self.subtitle = subtitle
        self.unit = unit
        self.range = range
        self.step = step
        _value = value
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                    .frame(minWidth: 100, maxWidth: 200)
                Text("\(value)\(unit)").foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
        } label: { SettingLabel(title, subtitle) }
    }
}


public struct StatusLabel: View {
    var text: String
    var color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color)
        }
    }
}

public struct SpinnerOrIcon: View {
    var busy: Bool
    var symbol: String

    public init(busy: Bool, symbol: String) {
        self.busy = busy
        self.symbol = symbol
    }

    public var body: some View {
        if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
    }
}

public struct SymbolSlider: View {
    var title: String
    var symbol: String
    @Binding var value: Double

    public init(_ title: String, symbol: String, value: Binding<Double>) {
        self.title = title
        self.symbol = symbol
        _value = value
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: 0...100).frame(minWidth: 110, maxWidth: 220)
                Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
            }
        } label: { Label(title, systemImage: symbol) }
    }
}

public struct IntFieldSetting: View {
    var title: String
    var subtitle: String?
    @Binding var value: Int

    public init(_ title: String, _ subtitle: String? = nil, value: Binding<Int>) {
        self.title = title
        self.subtitle = subtitle
        _value = value
    }

    public var body: some View {
        LabeledContent {
            TextField("", value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 70, maxWidth: 120)
        } label: { SettingLabel(title, subtitle) }
    }
}
