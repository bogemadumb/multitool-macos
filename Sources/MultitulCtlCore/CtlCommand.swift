import Foundation

public enum CtlExit {
    public static let ok: Int32 = 0
    public static let failure: Int32 = 1
    public static let badStaged: Int32 = 2
    public static let noTempFile: Int32 = 3
    public static let badConfig: Int32 = 4
    public static let checkFailed: Int32 = 5
    public static let rolledBack: Int32 = 6
    public static let pfFailed: Int32 = 7
    public static let noFans: Int32 = 8
    public static let smcFailed: Int32 = 9
    public static let usage: Int32 = 64
    public static let unavailable: Int32 = 69
    public static let noPermission: Int32 = 77
}

public enum VpnAction: Equatable, Sendable {
    case on, off, restart, show
    case apply(path: String)
    case killswitch(KillSwitchAction)
    case rulesWrite(path: String)
}

public enum KillSwitchAction: String, Equatable, Sendable {
    case on, off, status
}

public enum FanSelector: Equatable, Sendable {
    case all
    case index(Int)
}

public enum CtlCommand: Equatable, Sendable {
    case selftest
    case vpn(VpnAction)
    case powerDisableSleep(Bool)
    case memPurge
    case procKill(pid: Int32, signal: Int32)
    case smcFanAuto(FanSelector)
    case smcFanSet(index: Int, rpm: Int)
    case smcFanMode(index: Int, manual: Bool)

    public var arguments: [String] {
        switch self {
        case .selftest: return ["selftest"]
        case .vpn(let a):
            switch a {
            case .on: return ["vpn", "on"]
            case .off: return ["vpn", "off"]
            case .restart: return ["vpn", "restart"]
            case .show: return ["vpn", "show"]
            case .apply(let p): return ["vpn", "apply", p]
            case .killswitch(let k): return ["vpn", "killswitch", k.rawValue]
            case .rulesWrite(let p): return ["vpn", "rules", "write", p]
            }
        case .powerDisableSleep(let on): return ["power", "disablesleep", on ? "on" : "off"]
        case .memPurge: return ["mem", "purge"]
        case .procKill(let pid, let sig): return ["proc", "kill", String(pid), String(sig)]
        case .smcFanAuto(let sel):
            switch sel {
            case .all: return ["smc", "fan-auto", "all"]
            case .index(let i): return ["smc", "fan-auto", String(i)]
            }
        case .smcFanSet(let i, let rpm): return ["smc", "fan-set", String(i), String(rpm)]
        case .smcFanMode(let i, let manual): return ["smc", "fan-mode", String(i), manual ? "manual" : "auto"]
        }
    }
}

public struct CtlParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public let ctlUsage = """
usage: multitul-ctl selftest
       multitul-ctl vpn on|off|restart|show
       multitul-ctl vpn apply <staged.json>
       multitul-ctl vpn killswitch on|off|status
       multitul-ctl vpn rules write <direct|proxy|block>.json
       multitul-ctl power disablesleep on|off
       multitul-ctl mem purge
       multitul-ctl proc kill <pid> [signal]
       multitul-ctl smc fan-auto <index>|all
       multitul-ctl smc fan-set <index> <rpm>
       multitul-ctl smc fan-mode <index> auto|manual
"""
