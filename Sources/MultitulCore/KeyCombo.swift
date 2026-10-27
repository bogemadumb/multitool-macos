import Foundation
import AppKit

public struct KeyCombo: Hashable, Sendable {
    public static let cmd: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let opt: UInt32 = 2048
    public static let ctrl: UInt32 = 4096

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(stored: String) {
        let p = stored.split(separator: ":")
        guard p.count == 2, let k = UInt32(p[0]), let m = UInt32(p[1]) else { return nil }
        self.init(keyCode: k, modifiers: m)
    }

    public var stored: String { "\(keyCode):\(modifiers)" }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= opt }
        if flags.contains(.control) { m |= ctrl }
        return m
    }

    public static let none = KeyCombo(keyCode: 0xFFFF, modifiers: 0)
    public var isNone: Bool { keyCode == KeyCombo.none.keyCode }

    public var display: String {
        if isNone { return "—" }
        var s = ""
        if modifiers & KeyCombo.ctrl != 0 { s += "⌃" }
        if modifiers & KeyCombo.opt != 0 { s += "⌥" }
        if modifiers & KeyCombo.shift != 0 { s += "⇧" }
        if modifiers & KeyCombo.cmd != 0 { s += "⌘" }
        return s + (KeyCombo.names[keyCode] ?? "#\(keyCode)")
    }

    public static let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

public struct HotkeySpec: Hashable, Sendable {
    public let id: String
    public let title: String
    public let defaultCombo: KeyCombo

    public init(id: String, title: String, defaultCombo: KeyCombo) {
        self.id = id
        self.title = title
        self.defaultCombo = defaultCombo
    }
}
