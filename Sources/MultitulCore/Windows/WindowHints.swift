import Foundation

public extension InputPriority {
    static let switcher = 445
    static let windowRing = 440
    static let windowGesture = 430
    static let dockClick = 340
    static let dockPreview = 330
    static let zoomButton = 335
    static let edgeSnap = 10
}

public enum WindowHintCombos {
    private static let ctrlOpt = KeyCombo.ctrl | KeyCombo.opt
    private static let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

    public static let all: [String: KeyCombo] = {
        func c(_ a: WindowLayoutAction, _ key: UInt32, _ mods: UInt32 = ctrlOpt) -> (String, KeyCombo) { (a.hotkeyID, KeyCombo(keyCode: key, modifiers: mods)) }
        let pairs: [(String, KeyCombo)] = [
            c(.leftHalf, Keys.left), c(.rightHalf, Keys.right), c(.topHalf, Keys.up), c(.bottomHalf, Keys.down),
            c(.topLeft, 32), c(.topRight, 34), c(.bottomLeft, 38), c(.bottomRight, 40),
            c(.maximize, Keys.returnKey), c(.center, 8), c(.restore, 15),
            c(.leftThird, 2), c(.centerThird, 3), c(.rightThird, 5),
            c(.leftTwoThirds, 14), c(.rightTwoThirds, 17),
            c(.nextDisplay, Keys.right, layer),
            (WindowHotkeys.cursorNextDisplay.id, KeyCombo(keyCode: 6, modifiers: layer))
        ]
        return Dictionary(uniqueKeysWithValues: pairs)
    }()
}
