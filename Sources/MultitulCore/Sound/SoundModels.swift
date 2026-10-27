import Foundation

public enum AudioScope: String, CaseIterable, Sendable {
    case output, input

    public var title: String { self == .output ? "Вывод" : "Ввод" }
}

public enum AudioTransport: String, Sendable {
    case builtIn, usb, bluetooth, airplay, hdmi, virtual, aggregate, other

    public var title: String {
        switch self {
        case .builtIn: "встроенное"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .airplay: "AirPlay"
        case .hdmi: "HDMI / DisplayPort"
        case .virtual: "виртуальное"
        case .aggregate: "агрегатное"
        case .other: "другое"
        }
    }

    public var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "cable.connector"
        case .bluetooth: "headphones"
        case .airplay: "airplayaudio"
        case .hdmi: "display"
        case .virtual, .aggregate: "waveform.path"
        case .other: "speaker.wave.2"
        }
    }

    public var isSynthetic: Bool { self == .virtual || self == .aggregate }
}

public struct AudioDeviceInfo: Equatable, Hashable, Identifiable, Sendable {
    public var uid: String
    public var name: String
    public var transport: AudioTransport
    public var hasOutput: Bool
    public var hasInput: Bool
    public var isHidden: Bool

    public var id: String { uid }

    public init(uid: String, name: String, transport: AudioTransport = .other, hasOutput: Bool = false, hasInput: Bool = false, isHidden: Bool = false) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasOutput = hasOutput
        self.hasInput = hasInput
        self.isHidden = isHidden
    }

    public func supports(_ scope: AudioScope) -> Bool { scope == .output ? hasOutput : hasInput }

    public static func visible(_ all: [AudioDeviceInfo], scope: AudioScope) -> [AudioDeviceInfo] {
        all.filter { !$0.isHidden && $0.supports(scope) }
    }
}

public enum AudioHardwareEvent: Equatable, Sendable {
    case devicesChanged
    case defaultChanged(AudioScope)
    case systemOutputChanged
}

public protocol AudioHardware: AnyObject {
    func devices() -> [AudioDeviceInfo]
    func defaultUID(_ scope: AudioScope) -> String?
    func systemOutputUID() -> String?
    @discardableResult func setDefault(_ scope: AudioScope, uid: String) -> Bool
    @discardableResult func setSystemOutput(uid: String) -> Bool
}

public protocol AudioInputControlling: AnyObject {
    func muteSwitch(uid: String) -> Bool?
    func setMuteSwitch(uid: String, _ muted: Bool) -> Bool
    func inputVolume(uid: String) -> Float?
    func setInputVolume(uid: String, _ value: Float) -> Bool
}

public enum SoundHotkeys {
    public static let outputNext = HotkeySpec(id: "soundOutput.next", title: "Звук: следующее устройство вывода", defaultCombo: .none)
    public static let micToggle = HotkeySpec(id: "micMute.toggle", title: "Микрофон: заглушить / включить", defaultCombo: .none)
}
