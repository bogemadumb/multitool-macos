import Foundation

public struct CtlContext: Sendable {
    public var ownPid: Int32
    public var parentPid: Int32
    public var allowedApplyDirs: [String]

    public init(ownPid: Int32 = getpid(), parentPid: Int32 = getppid(), allowedApplyDirs: [String]) {
        self.ownPid = ownPid
        self.parentPid = parentPid
        self.allowedApplyDirs = allowedApplyDirs
    }
}

public enum CtlPathGuard {
    // Lexical check: absolute, no "." or ".." components, strictly inside one of the allowed directories.
    public static func validate(_ path: String, allowedDirs: [String]) throws -> String {
        guard !path.isEmpty, path.hasPrefix("/") else { throw CtlParseError("apply: path must be absolute") }
        guard !path.contains("\0") else { throw CtlParseError("apply: bad path") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw CtlParseError("apply: bad path") }
        if parts.contains("..") || parts.contains(".") { throw CtlParseError("apply: path must not contain . or ..") }
        let normalized = "/" + parts.joined(separator: "/")
        for dir in allowedDirs {
            let d = "/" + dir.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
            if d != "/", normalized.hasPrefix(d + "/"), normalized.count > d.count + 1 { return normalized }
        }
        throw CtlParseError("apply: path is outside the allowed directories")
    }
}

public enum CtlParser {
    public static let allowedSignals: [String: Int32] = [
        "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT, "KILL": SIGKILL, "TERM": SIGTERM,
        "STOP": SIGSTOP, "CONT": SIGCONT, "USR1": SIGUSR1, "USR2": SIGUSR2
    ]

    public static func parse(_ args: [String], context: CtlContext) throws -> CtlCommand {
        guard let head = args.first else { throw CtlParseError("missing subcommand") }
        let rest = Array(args.dropFirst())
        switch head {
        case "selftest":
            try expect(rest.isEmpty, "selftest takes no arguments")
            return .selftest
        case "vpn": return try parseVpn(rest, context)
        case "power":
            try expect(rest.count == 2 && rest[0] == "disablesleep", "usage: power disablesleep on|off")
            return .powerDisableSleep(try onOff(rest[1], "power disablesleep"))
        case "mem":
            try expect(rest == ["purge"], "usage: mem purge")
            return .memPurge
        case "proc": return try parseProc(rest, context)
        case "smc": return try parseSmc(rest)
        default: throw CtlParseError("unknown subcommand: \(head)")
        }
    }

    private static func expect(_ cond: Bool, _ msg: String) throws {
        if !cond { throw CtlParseError(msg) }
    }

    private static func onOff(_ s: String, _ what: String) throws -> Bool {
        switch s {
        case "on": return true
        case "off": return false
        default: throw CtlParseError("\(what): expected on|off, got \(s)")
        }
    }

    private static func parseVpn(_ a: [String], _ ctx: CtlContext) throws -> CtlCommand {
        guard let sub = a.first else { throw CtlParseError("vpn: missing action") }
        let rest = Array(a.dropFirst())
        switch sub {
        case "on", "off", "restart", "show":
            try expect(rest.isEmpty, "vpn \(sub) takes no arguments")
            switch sub {
            case "on": return .vpn(.on)
            case "off": return .vpn(.off)
            case "restart": return .vpn(.restart)
            default: return .vpn(.show)
            }
        case "apply":
            try expect(rest.count == 1, "usage: vpn apply <staged.json>")
            return .vpn(.apply(path: try CtlPathGuard.validate(rest[0], allowedDirs: ctx.allowedApplyDirs)))
        case "killswitch":
            try expect(rest.count == 1, "usage: vpn killswitch on|off|status")
            guard let k = KillSwitchAction(rawValue: rest[0]) else {
                throw CtlParseError("vpn killswitch: expected on|off|status, got \(rest[0])")
            }
            return .vpn(.killswitch(k))
        case "rules":
            try expect(rest.count == 2 && rest[0] == "write", "usage: vpn rules write <direct|proxy|block>.json")
            let path = try CtlPathGuard.validate(rest[1], allowedDirs: ctx.allowedApplyDirs)
            guard VpnRules.target(forPath: path) != nil else {
                throw CtlParseError("vpn rules write: file name must be direct.json, proxy.json or block.json")
            }
            return .vpn(.rulesWrite(path: path))
        default: throw CtlParseError("vpn: unknown action \(sub)")
        }
    }

    private static func parseProc(_ a: [String], _ ctx: CtlContext) throws -> CtlCommand {
        try expect(a.count == 2 || a.count == 3, "usage: proc kill <pid> [signal]")
        try expect(a[0] == "kill", "proc: unknown action \(a[0])")
        let pid = try parsePid(a[1], ctx)
        let sig = a.count == 3 ? try parseSignal(a[2]) : SIGTERM
        return .procKill(pid: pid, signal: sig)
    }

    public static func parsePid(_ s: String, _ ctx: CtlContext) throws -> Int32 {
        guard !s.isEmpty, s.count <= 10, s.allSatisfy({ $0 >= "0" && $0 <= "9" }), let v = Int64(s), v <= Int64(Int32.max) else {
            throw CtlParseError("proc kill: bad pid \(s)")
        }
        let pid = Int32(v)
        if pid <= 1 { throw CtlParseError("proc kill: refusing pid \(pid)") }
        if pid == ctx.ownPid || pid == ctx.parentPid { throw CtlParseError("proc kill: refusing own or parent pid") }
        return pid
    }

    public static func parseSignal(_ s: String) throws -> Int32 {
        var name = s.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        if let v = allowedSignals[name] { return v }
        if let n = Int32(s), allowedSignals.values.contains(n) { return n }
        throw CtlParseError("proc kill: signal not allowed: \(s)")
    }

    public static let fanIndexRange = 0...9
    public static let fanRpmRange = 0...10000

    // Canonical decimal only: no sign, no spaces, no leading zeros.
    static func decimal(_ s: String, maxDigits: Int) -> Int? {
        guard !s.isEmpty, s.utf8.count <= maxDigits, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        if s.utf8.count > 1, s.hasPrefix("0") { return nil }
        return Int(s)
    }

    private static func fanIndex(_ s: String) throws -> Int {
        guard let i = decimal(s, maxDigits: 2), fanIndexRange.contains(i) else {
            throw CtlParseError("smc: fan index must be an integer in \(fanIndexRange)")
        }
        return i
    }

    private static func parseSmc(_ a: [String]) throws -> CtlCommand {
        guard let sub = a.first else { throw CtlParseError("usage: smc fan-auto|fan-set|fan-mode ...") }
        let rest = Array(a.dropFirst())
        switch sub {
        case "fan-auto":
            try expect(rest.count == 1, "usage: smc fan-auto <index>|all")
            return .smcFanAuto(rest[0] == "all" ? .all : .index(try fanIndex(rest[0])))
        case "fan-set":
            try expect(rest.count == 2, "usage: smc fan-set <index> <rpm>")
            let idx = try fanIndex(rest[0])
            guard let rpm = decimal(rest[1], maxDigits: 5), fanRpmRange.contains(rpm) else {
                throw CtlParseError("smc fan-set: rpm must be an integer in \(fanRpmRange)")
            }
            return .smcFanSet(index: idx, rpm: rpm)
        case "fan-mode":
            try expect(rest.count == 2, "usage: smc fan-mode <index> auto|manual")
            let idx = try fanIndex(rest[0])
            switch rest[1] {
            case "auto": return .smcFanMode(index: idx, manual: false)
            case "manual": return .smcFanMode(index: idx, manual: true)
            default: throw CtlParseError("smc fan-mode: expected auto|manual, got \(rest[1])")
            }
        default: throw CtlParseError("smc: unknown action \(sub)")
        }
    }
}
