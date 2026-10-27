import Foundation
@testable import MultitulCore

final class SndFakeHardware: AudioHardware, AudioInputControlling {
    var all: [AudioDeviceInfo] = []
    var outDefault: String?
    var inDefault: String?
    var sysOut: String?
    var failSet = false
    var setCalls: [(AudioScope, String)] = []
    var systemCalls: [String] = []

    var muteSwitches: [String: Bool] = [:]
    var volumes: [String: Float] = [:]
    var failMute: Set<String> = []
    var failVolume: Set<String> = []
    var mutePresent: Set<String> { Set(all.map(\.uid)) }

    func devices() -> [AudioDeviceInfo] { all }
    func defaultUID(_ scope: AudioScope) -> String? { scope == .output ? outDefault : inDefault }
    func systemOutputUID() -> String? { sysOut }

    func setDefault(_ scope: AudioScope, uid: String) -> Bool {
        setCalls.append((scope, uid))
        guard !failSet, all.contains(where: { $0.uid == uid && $0.supports(scope) }) else { return false }
        if scope == .output { outDefault = uid } else { inDefault = uid }
        return true
    }

    func setSystemOutput(uid: String) -> Bool {
        systemCalls.append(uid)
        guard !failSet else { return false }
        sysOut = uid
        return true
    }

    func plug(_ d: AudioDeviceInfo, systemSelects: Bool = false) {
        all.append(d)
        guard systemSelects else { return }
        if d.hasOutput { outDefault = d.uid }
        if d.hasInput { inDefault = d.uid }
    }

    // macOS falls back to the first remaining device of the kind.
    func unplug(_ uid: String) {
        all.removeAll { $0.uid == uid }
        if outDefault == uid { outDefault = all.first { $0.hasOutput && !$0.isHidden }?.uid }
        if inDefault == uid { inDefault = all.first { $0.hasInput && !$0.isHidden }?.uid }
    }

    func muteSwitch(uid: String) -> Bool? { mutePresent.contains(uid) ? muteSwitches[uid] : nil }

    func setMuteSwitch(uid: String, _ muted: Bool) -> Bool {
        guard mutePresent.contains(uid), muteSwitches[uid] != nil, !failMute.contains(uid) else { return false }
        muteSwitches[uid] = muted
        return true
    }

    func inputVolume(uid: String) -> Float? { mutePresent.contains(uid) ? volumes[uid] : nil }

    func setInputVolume(uid: String, _ value: Float) -> Bool {
        guard mutePresent.contains(uid), volumes[uid] != nil, !failVolume.contains(uid) else { return false }
        volumes[uid] = value
        return true
    }
}

final class SndFakeClaims: MicClaimStoring {
    var active = false
    var claims: [MicClaim] = []
}

enum Snd {
    static let speakers = AudioDeviceInfo(uid: "speakers", name: "Динамики MacBook", transport: .builtIn, hasOutput: true)
    static let mic = AudioDeviceInfo(uid: "builtin-mic", name: "Микрофон MacBook", transport: .builtIn, hasInput: true)
    static let airpods = AudioDeviceInfo(uid: "airpods", name: "AirPods", transport: .bluetooth, hasOutput: true, hasInput: true)
    static let usb = AudioDeviceInfo(uid: "usb-headset", name: "USB-гарнитура", transport: .usb, hasOutput: true, hasInput: true)
    static let hdmi = AudioDeviceInfo(uid: "hdmi", name: "Монитор", transport: .hdmi, hasOutput: true)
    static let blackhole = AudioDeviceInfo(uid: "blackhole", name: "BlackHole", transport: .virtual, hasOutput: true, hasInput: true)
    static let hiddenTap = AudioDeviceInfo(uid: "tap", name: "Tap", transport: .aggregate, hasOutput: true, isHidden: true)

    static func hardware(_ devices: [AudioDeviceInfo] = [speakers, mic], out: String? = "speakers", inp: String? = "builtin-mic") -> SndFakeHardware {
        let h = SndFakeHardware()
        h.all = devices
        h.outDefault = out
        h.inDefault = inp
        h.sysOut = out
        return h
    }
}
