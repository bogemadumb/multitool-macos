import SwiftUI
import MultitulCore
import MultitulUI

struct ToggleSetting: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingLabel(title, subtitle) }
    }
}

struct ModuleSection<Rows: View>: View {
    var title: String
    var subtitle: String?
    var ready: Bool?
    var readyText = "работает"
    var onAppear: (() -> Void)?
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        Section {
            if let ready {
                LabeledContent("Состояние") {
                    StatusLabel(ready ? readyText : "нет доступа", color: ready ? .green : .orange)
                }
            }
            rows()
        } header: {
            Text(title).onAppear { onAppear?() }
        } footer: {
            if let subtitle { SectionFooter(subtitle) }
        }
    }
}

struct ChoiceSetting<T: Hashable>: View {
    var title: String
    var subtitle: String?
    var options: [T]
    var label: (T) -> String
    @Binding var value: T

    var body: some View {
        Picker(selection: $value) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        } label: { SettingLabel(title, subtitle) }
    }
}
