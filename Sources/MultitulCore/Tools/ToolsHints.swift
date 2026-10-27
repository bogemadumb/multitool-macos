import Foundation

public enum ToolsHotkeys {
    public static let colorPick = HotkeySpec(id: "colorPicker.pick", title: "Пипетка: взять цвет", defaultCombo: .none)
    public static let ocrCapture = HotkeySpec(id: "screenOcr.capture", title: "Текст с экрана: выделить область", defaultCombo: .none)
    public static let cleaningToggle = HotkeySpec(id: "cleaningMode.toggle", title: "Режим уборки: включить", defaultCombo: .none)
}

public enum ToolsHintCombos {
    private static let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

    public static let all: [String: KeyCombo] = [
        LauncherHotkeys.toggle.id: KeyCombo(keyCode: Keys.v, modifiers: KeyCombo.ctrl | KeyCombo.cmd),
        ToolsHotkeys.colorPick.id: KeyCombo(keyCode: 8, modifiers: layer),
        ToolsHotkeys.ocrCapture.id: KeyCombo(keyCode: 17, modifiers: layer),
        CameraHotkeys.toggle.id: KeyCombo(keyCode: Keys.w, modifiers: layer),
        ScratchpadHotkeys.toggle.id: KeyCombo(keyCode: 45, modifiers: layer),
        CommandBarHotkeys.toggle.id: KeyCombo(keyCode: Keys.space, modifiers: KeyCombo.opt)
    ]
}
