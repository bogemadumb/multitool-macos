import Foundation

public let ctlVersion = "1"

public struct CtlPaths: Sendable {
    public var label = "dev.multitool.singbox"
    public var daemonPlist = "/Library/LaunchDaemons/dev.multitool.singbox.plist"
    public var configDir = "/usr/local/etc/singbox"
    public var singbox = "/opt/homebrew/bin/sing-box"
    public var killswitchAnchor = "com.apple/250.MultitulVPNKillSwitch"
    public var killswitchRules = "/usr/local/etc/singbox/killswitch.pf"
    public var killswitchToken = "/var/run/multitul-vpn-pf.token"
    public var vpsAddress = VpnEndpoint.serverAddress
    public var config: String { configDir + "/config.json" }
    public var userRulesDir: String { configDir + "/user" }
    public init() {}
    public static let production = CtlPaths()
}

public final class CtlExecutor {
    private let runner: ProcessRunning
    private let paths: CtlPaths
    private let context: CtlContext
    private let trustedUid: uid_t
    private let euid: uid_t
    private let sleeper: (TimeInterval) -> Void
    private let killer: (Int32, Int32) -> Int32
    private let tunnelAttempts: Int
    private let smcFactory: () -> SmcWriting?
    private let out: (String) -> Void
    private let err: (String) -> Void

    public init(runner: ProcessRunning = SystemProcessRunner(),
                paths: CtlPaths = .production,
                context: CtlContext,
                trustedUid: uid_t = 0,
                euid: uid_t = geteuid(),
                tunnelAttempts: Int = 25,
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                killer: @escaping (Int32, Int32) -> Int32 = { pid, sig in kill(pid, sig) == 0 ? 0 : errno },
                smcFactory: @escaping () -> SmcWriting? = { nil },
                out: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                err: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.runner = runner
        self.paths = paths
        self.context = context
        self.trustedUid = trustedUid
        self.euid = euid
        self.tunnelAttempts = tunnelAttempts
        self.sleeper = sleeper
        self.killer = killer
        self.smcFactory = smcFactory
        self.out = out
        self.err = err
    }

    public func execute(_ command: CtlCommand) -> Int32 {
        switch command {
        case .selftest: return selftest()
        case .vpn(let a): return vpn(a)
        case .powerDisableSleep(let on): return passthrough("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"])
        case .memPurge: return passthrough("/usr/sbin/purge", [])
        case .procKill(let pid, let sig): return procKill(pid, sig)
        case .smcFanAuto, .smcFanSet, .smcFanMode: return smc(command)
        }
    }

    private func smc(_ command: CtlCommand) -> Int32 {
        guard let device = smcFactory() else {
            err("smc: AppleSMC is not available")
            return CtlExit.unavailable
        }
        let service = SmcFanService(smc: device, sleeper: sleeper)
        do {
            switch command {
            case .smcFanAuto(let sel):
                try service.setAuto(sel)
                out("smc: fan control returned to the system")
            case .smcFanSet(let i, let rpm):
                out("smc: fan \(i) target \(try service.setRpm(index: i, rpm: rpm)) rpm")
            case .smcFanMode(let i, let manual):
                if manual {
                    try service.setManual(index: i)
                    out("smc: fan \(i) manual")
                } else {
                    try service.setAuto(.index(i))
                    out("smc: fan \(i) auto")
                }
            default: return CtlExit.usage
            }
            return CtlExit.ok
        } catch let e as SmcFanError {
            err("smc: \(e)")
            switch e {
            case .noFans: return CtlExit.noFans
            case .badIndex, .stopNotSupported: return CtlExit.usage
            case .unsupported, .writeFailed, .verifyFailed: return CtlExit.smcFailed
            }
        } catch {
            err("smc: \(error)")
            return CtlExit.smcFailed
        }
    }

    @discardableResult
    private func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 30) -> ProcessOutput {
        runner.run(exe, args, timeout: timeout)
    }

    private func passthrough(_ exe: String, _ args: [String]) -> Int32 {
        let r = sh(exe, args, timeout: 120)
        if !r.stdout.isEmpty { out(r.stdout.trimmingCharacters(in: .newlines)) }
        if !r.stderr.isEmpty { err(r.stderr.trimmingCharacters(in: .newlines)) }
        return r.timedOut ? CtlExit.failure : r.status
    }

    private func selftest() -> Int32 {
        out("multitul-ctl \(ctlVersion)")
        out("euid: \(euid)")
        for tool in ["/bin/launchctl", "/sbin/pfctl", "/usr/bin/pmset", "/usr/sbin/purge", "/usr/bin/curl", "/sbin/ifconfig", paths.singbox] {
            out("tool \(tool): " + (FileManager.default.isExecutableFile(atPath: tool) ? "ok" : "MISSING"))
        }
        out("config: " + (FileManager.default.fileExists(atPath: paths.config) ? "ok" : "MISSING"))
        out("rules dir: " + (FileManager.default.fileExists(atPath: paths.userRulesDir) ? "ok" : "MISSING"))
        if euid != 0 {
            err("selftest: not running as root")
            return CtlExit.noPermission
        }
        out("selftest: ok")
        return CtlExit.ok
    }

    private func procKill(_ pid: Int32, _ sig: Int32) -> Int32 {
        do { _ = try CtlParser.parsePid(String(pid), context) } catch {
            err("\(error)")
            return CtlExit.usage
        }
        let e = killer(pid, sig)
        if e == 0 { return CtlExit.ok }
        err("proc kill: \(String(cString: strerror(e)))")
        return CtlExit.failure
    }

    private var target: String { "system/\(paths.label)" }

    private func running() -> Bool {
        sh("/bin/launchctl", ["print", target]).stdout.contains("state = running")
    }

    private func tunnelWorks() -> Bool {
        for _ in 0..<tunnelAttempts {
            sleeper(1)
            guard running() else { continue }
            guard sh("/sbin/ifconfig", []).stdout.contains("inet 172.19") else { continue }
            let code = sh("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "5", "-w", "%{http_code}",
                                            "https://www.gstatic.com/generate_204"], timeout: 10).stdout
            if code.trimmingCharacters(in: .whitespacesAndNewlines) == "204" { return true }
        }
        return false
    }

    private func vpn(_ a: VpnAction) -> Int32 {
        switch a {
        case .on:
            sh("/bin/launchctl", ["enable", target])
            let r = sh("/bin/launchctl", ["bootstrap", "system", paths.daemonPlist])
            if r.status == 0 { return CtlExit.ok }
            return sh("/bin/launchctl", ["kickstart", "-k", target]).status
        case .off:
            _ = killswitch(.off, quiet: true)
            sh("/bin/launchctl", ["bootout", target])
            sh("/bin/launchctl", ["disable", target])
            return CtlExit.ok
        case .restart:
            return sh("/bin/launchctl", ["kickstart", "-k", target]).status
        case .show:
            guard let data = FileManager.default.contents(atPath: paths.config) else {
                err("show: cannot read \(paths.config)")
                return CtlExit.failure
            }
            do {
                out(String(decoding: try VpnConfig.mask(data), as: UTF8.self))
                return CtlExit.ok
            } catch {
                err("show: \(error)")
                return CtlExit.failure
            }
        case .apply(let path): return apply(path)
        case .killswitch(let k): return killswitch(k, quiet: false)
        case .rulesWrite(let path): return rulesWrite(path)
        }
    }

    private func realpathOf(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    func resolveStaged(_ path: String) -> String? {
        guard let real = realpathOf(path) else { return nil }
        for d in context.allowedApplyDirs {
            guard let rd = realpathOf(d) else { continue }
            if real.hasPrefix(rd + "/") { return real }
        }
        return nil
    }

    private func readStaged(_ path: String) -> Data? {
        guard let real = resolveStaged(path) else {
            err("apply: path is outside the allowed directories")
            return nil
        }
        let fd = open(real, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { err("apply: need a regular staged file"); return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
              st.st_size > 0, st.st_size <= 1_048_576,
              st.st_uid == trustedUid || st.st_uid == 0 else {
            err("apply: need a regular staged file")
            return nil
        }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return (try? h.readToEnd()) ?? nil
    }

    private func writeSecret(_ data: Data, dir: String) -> String? {
        var template = Array((dir + "/.staged.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let path = String(cString: template)
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        fchmod(fd, 0o600)
        if !ok { unlink(path); return nil }
        return path
    }

    private func replaceConfig(with source: String) -> Bool {
        let tmp = paths.configDir + "/.restore.tmp"
        unlink(tmp)
        do { try FileManager.default.copyItem(atPath: source, toPath: tmp) } catch { return false }
        guard rename(tmp, paths.config) == 0 else { unlink(tmp); return false }
        chown(paths.config, 0, 0)
        chmod(paths.config, 0o600)
        return true
    }

    private func apply(_ stagedPath: String) -> Int32 {
        guard let staged = readStaged(stagedPath) else { return CtlExit.badStaged }
        guard let current = FileManager.default.contents(atPath: paths.config) else {
            err("apply: cannot read current config")
            return CtlExit.badConfig
        }
        let filled: Data
        do { filled = try VpnConfig.fill(staged: staged, current: current) } catch {
            err("apply: \(error)")
            return CtlExit.badConfig
        }
        guard let new = writeSecret(filled, dir: paths.configDir) else { return CtlExit.noTempFile }
        let check = sh(paths.singbox, ["check", "-c", new])
        if check.status != 0 {
            if !check.stdout.isEmpty { err(check.stdout) }
            if !check.stderr.isEmpty { err(check.stderr) }
            err("apply: sing-box check failed, nothing changed")
            unlink(new)
            return CtlExit.checkFailed
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let backup = "\(paths.config).backup-\(f.string(from: Date()))"
        do { try FileManager.default.copyItem(atPath: paths.config, toPath: backup) } catch {
            err("apply: cannot back up current config")
            unlink(new)
            return CtlExit.badConfig
        }
        guard rename(new, paths.config) == 0 else {
            err("apply: cannot replace config")
            unlink(new)
            return CtlExit.badConfig
        }
        chown(paths.config, 0, 0)
        chmod(paths.config, 0o600)
        sh("/bin/launchctl", ["kickstart", "-k", target])
        if tunnelWorks() {
            out("apply: ok, backup \(backup)")
            return CtlExit.ok
        }
        err("apply: tunnel did not come up in \(tunnelAttempts) s, rolling back")
        _ = replaceConfig(with: backup)
        sh("/bin/launchctl", ["kickstart", "-k", target])
        err(tunnelWorks() ? "apply: rolled back, tunnel ok" : "apply: rolled back, tunnel STILL DOWN")
        return CtlExit.rolledBack
    }

    private func rulesWrite(_ stagedPath: String) -> Int32 {
        guard let target = VpnRules.target(forPath: stagedPath) else {
            err("rules: file name must be direct.json, proxy.json or block.json")
            return CtlExit.usage
        }
        guard let data = readStaged(stagedPath) else { return CtlExit.badStaged }
        do { try VpnRules.validate(data) } catch {
            err("rules: \(error)")
            return CtlExit.badStaged
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.userRulesDir, isDirectory: &isDir), isDir.boolValue else {
            err("rules: \(paths.userRulesDir) does not exist")
            return CtlExit.badConfig
        }
        let final = paths.userRulesDir + "/" + target + ".json"
        guard let tmp = writeSecret(data, dir: paths.userRulesDir) else { return CtlExit.noTempFile }
        chmod(tmp, 0o644)
        chown(tmp, 0, 0)
        guard rename(tmp, final) == 0 else {
            unlink(tmp)
            err("rules: cannot replace \(final)")
            return CtlExit.badConfig
        }
        out("rules: \(target) written")
        return CtlExit.ok
    }

    public func killswitchRulesText() -> String {
        let utuns = (0...15).map { "utun\($0) " }.joined()
        return """
        pass quick on lo0 all
        pass quick on { \(utuns)} all
        pass out quick inet proto udp from any port 68 to any port 67
        pass out quick inet to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }
        pass out quick inet6 to { fe80::/10, ff00::/8 }
        pass out quick inet to \(paths.vpsAddress)
        pass out quick inet to 17.0.0.0/8
        pass out quick proto { tcp, udp } all user root
        block drop out quick inet all
        block drop out quick inet6 all

        """
    }

    private func killswitch(_ k: KillSwitchAction, quiet: Bool) -> Int32 {
        let pfctl = "/sbin/pfctl"
        switch k {
        case .on:
            do { try killswitchRulesText().write(toFile: paths.killswitchRules, atomically: true, encoding: .utf8) } catch {
                err("killswitch: cannot write rules")
                return CtlExit.pfFailed
            }
            chmod(paths.killswitchRules, 0o644)
            if sh(pfctl, ["-a", paths.killswitchAnchor, "-f", paths.killswitchRules]).status != 0 {
                err("killswitch: pf load failed")
                return CtlExit.pfFailed
            }
            let tokenSize = (try? FileManager.default.attributesOfItem(atPath: paths.killswitchToken)[.size] as? Int) ?? 0
            if tokenSize == 0 {
                let r = sh(pfctl, ["-E"])
                let text = r.stdout + "\n" + r.stderr
                let token = text.split(separator: "\n").first { $0.contains("Token") }?
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
                try? (token + "\n").write(toFile: paths.killswitchToken, atomically: true, encoding: .utf8)
            }
            if !quiet { out("killswitch: on") }
            return CtlExit.ok
        case .off:
            sh(pfctl, ["-a", paths.killswitchAnchor, "-F", "all"])
            if let t = try? String(contentsOfFile: paths.killswitchToken, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                sh(pfctl, ["-X", t])
            }
            unlink(paths.killswitchToken)
            if !quiet { out("killswitch: off") }
            return CtlExit.ok
        case .status:
            let r = sh(pfctl, ["-a", paths.killswitchAnchor, "-s", "rules"])
            out(r.stdout.contains("block drop out") ? "killswitch: on" : "killswitch: off")
            return CtlExit.ok
        }
    }
}
