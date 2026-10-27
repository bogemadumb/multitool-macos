import Foundation

public enum CoreHotkeys {
    public static let panel = HotkeySpec(id: "core.panel", title: "Открыть панель", defaultCombo: KeyCombo(keyCode: 46, modifiers: KeyCombo.opt | KeyCombo.cmd))
    public static let window = HotkeySpec(id: "core.window", title: "Открыть окно", defaultCombo: KeyCombo(keyCode: 43, modifiers: KeyCombo.opt | KeyCombo.cmd))
    public static let all = [panel, window]
}

public struct InterceptedKey: Equatable, Sendable {
    public let id: String
    public let title: String
    public let combo: KeyCombo
}

public enum InterceptedKeys {
    public static let quit = KeyCombo(keyCode: Keys.q, modifiers: KeyCombo.cmd)
    public static let close = KeyCombo(keyCode: Keys.w, modifiers: KeyCombo.cmd)
    public static let finderCut = KeyCombo(keyCode: FinderKeys.keyX, modifiers: KeyCombo.cmd)
    public static let finderPaste = KeyCombo(keyCode: FinderKeys.keyV, modifiers: KeyCombo.cmd)
    public static let superKeyCaps = KeyCombo(keyCode: Keys.f18, modifiers: 0)
    public static let windowRing = RingSettings.defaultTrigger
    public static let switcherApps = SwitcherSettings.systemAppsTrigger
    public static let switcherWindows = SwitcherSettings.systemWindowsTrigger
    public static let radial = RadialTriggerConfig.defaultHotkey

    public static let quitID = "reserved.quit"
    public static let closeID = "reserved.close"
    public static let finderCutID = "reserved.finderCut"
    public static let finderPasteID = "reserved.finderPaste"
    public static let superKeyID = "reserved.superKey"
    public static let windowRingID = "reserved.windowRing"
    public static let switcherAppsID = "reserved.switcherApps"
    public static let switcherWindowsID = "reserved.switcherWindows"
    public static let radialID = "reserved.radial"

    public static let all: [InterceptedKey] = [
        InterceptedKey(id: quitID, title: "Защита ⌘Q", combo: quit),
        InterceptedKey(id: closeID, title: "Защита ⌘W", combo: close),
        InterceptedKey(id: finderCutID, title: "Finder: вырезать (⌘X)", combo: finderCut),
        InterceptedKey(id: finderPasteID, title: "Finder: вставить (⌘V)", combo: finderPaste),
        InterceptedKey(id: superKeyID, title: "Супер-клавиша (Caps Lock)", combo: superKeyCaps),
        InterceptedKey(id: windowRingID, title: "Кольцо раскладки окон (⌃⌥Space)", combo: windowRing),
        InterceptedKey(id: switcherAppsID, title: "Переключатель окон (⌘Tab)", combo: switcherApps),
        InterceptedKey(id: switcherWindowsID, title: "Переключатель окон текущего приложения (⌘`)", combo: switcherWindows),
        InterceptedKey(id: radialID, title: "Радиальное меню (⌃⌥⌘Space)", combo: radial)
    ]

    public static func title(of id: String) -> String? { all.first { $0.id == id }?.title }
}

public enum HotkeyHints {
    private static func combo(_ key: UInt32, _ mods: UInt32) -> KeyCombo { KeyCombo(keyCode: key, modifiers: mods) }
    private static let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

    public static let suggested: [String: KeyCombo] = [
        ClipHotkeys.picker.id: combo(9, layer),
        ClipHotkeys.pastePlain.id: combo(9, KeyCombo.shift | KeyCombo.opt | KeyCombo.cmd),
        ClipHotkeys.finderRename.id: combo(FinderKeys.keyF2, 0),
        ShelfHotkeys.toggle.id: combo(2, layer),
        SoundHotkeys.outputNext.id: combo(1, layer),
        SoundHotkeys.micToggle.id: combo(46, layer),
        KeepAwakeHotkeys.toggle.id: combo(40, layer),
        BrightnessHotkeys.displayDown.id: combo(27, KeyCombo.shift | KeyCombo.cmd),
        BrightnessHotkeys.displayUp.id: combo(24, KeyCombo.shift | KeyCombo.cmd),
        BrightnessHotkeys.keyboardDown.id: combo(27, KeyCombo.opt | KeyCombo.cmd),
        BrightnessHotkeys.keyboardUp.id: combo(24, KeyCombo.opt | KeyCombo.cmd),
        SnippetHotkeys.library.id: combo(37, layer)
    ].merging(WindowHintCombos.all) { a, _ in a }.merging(ToolsHintCombos.all) { a, _ in a }.merging(ShotHintCombos.all) { a, _ in a }.merging(RecHintCombos.all) { a, _ in a }.merging(IslHintCombos.all) { a, _ in a }

    public static func effective(_ spec: HotkeySpec) -> KeyCombo {
        spec.defaultCombo.isNone ? (suggested[spec.id] ?? spec.defaultCombo) : spec.defaultCombo
    }

    public static var allSpecs: [HotkeySpec] {
        CoreHotkeys.all + ModuleID.allCases.flatMap { $0.info.hotkeys }
    }
}
