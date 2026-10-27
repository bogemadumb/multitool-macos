import Foundation
import Darwin
import Network
import AppKit
import MultitulCtlCore

struct VpnDaemonStatus: Equatable, Sendable {
    var running: Bool
    var started: Date?
    var disabled: Bool
}

protocol VpnDaemonProbing: Sendable {
    func read() -> VpnDaemonStatus
}

enum VpnDaemonParse {
    static func running(_ text: String) -> (running: Bool, pid: Int32?) {
        var running = false
        var pid: Int32?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "state = running" { running = true }
            if line.hasPrefix("pid = "), let n = Int32(line.dropFirst(6)) { pid = n }
        }
        return (running, pid)
    }
}

struct LaunchctlDaemonProbe: VpnDaemonProbing {
    static let label = "dev.multitool.singbox"
    let runner: ProcessRunning

    init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    func read() -> VpnDaemonStatus {
        let r = runner.run("/bin/launchctl", ["print", "system/" + Self.label], timeout: 10)
        if r.status == 0 {
            let p = VpnDaemonParse.running(r.stdout)
            if p.running { return VpnDaemonStatus(running: true, started: p.pid.flatMap(Self.startTime), disabled: false) }
        }
        let d = runner.run("/bin/launchctl", ["print-disabled", "system"], timeout: 10)
        return VpnDaemonStatus(running: false, started: nil, disabled: VpnIntentSync.isDisabled(d.stdout, label: Self.label))
    }

    static func startTime(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_un.__p_starttime.tv_sec))
    }
}

protocol VpnControlling: Sendable {
    func turnOn() -> String?
    func turnOff() -> String?
    func restart() -> String?
    func killSwitchStatus() -> Bool?
    func setKillSwitch(_ on: Bool) -> Bool
}

// Each call returns nil on success or a human-readable error.
struct PrivilegedVpnControl: VpnControlling {
    let ctl: PrivilegedCtl

    private func attempt(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return "\(error)" }
    }

    func turnOn() -> String? { attempt { try ctl.vpnOn() } }
    func turnOff() -> String? { attempt { try ctl.vpnOff() } }
    func restart() -> String? { attempt { try ctl.vpnRestart() } }

    func killSwitchStatus() -> Bool? {
        guard let out = try? ctl.killSwitch(.status) else { return nil }
        if out.contains("killswitch: on") { return true }
        if out.contains("killswitch: off") { return false }
        return nil
    }

    func setKillSwitch(_ on: Bool) -> Bool {
        (try? ctl.killSwitch(on ? .on : .off)) != nil
    }
}

final class VpnNetworkWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.multitool.app.vpn.netwatch")
    private let order: [NWInterface.InterfaceType] = [.wiredEthernet, .wifi, .cellular]
    private var monitors: [NWPathMonitor] = []
    private var flags: [NWInterface.InterfaceType: (up: Bool, expensive: Bool)] = [:]
    private let onChange: @Sendable (Bool, String) -> Void

    init(onChange: @escaping @Sendable (Bool, String) -> Void) { self.onChange = onChange }

    func start() {
        guard monitors.isEmpty else { return }
        for type in order {
            let m = NWPathMonitor(requiredInterfaceType: type)
            m.pathUpdateHandler = { [weak self] path in self?.update(type, path) }
            m.start(queue: queue)
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { $0.cancel() }
        monitors = []
    }

    private func update(_ type: NWInterface.InterfaceType, _ path: NWPath) {
        flags[type] = (path.status == .satisfied, path.isExpensive || path.isConstrained)
        let active = order.first { flags[$0]?.up == true }
        let label: String
        switch active {
        case .some(.wiredEthernet): label = "ethernet"
        case .some(.wifi): label = "wifi"
        case .some(.cellular): label = "cellular"
        default: label = "none"
        }
        onChange(active.flatMap { flags[$0]?.expensive } ?? false, label)
    }
}

public enum VpnBrowserURL {
    public enum Result: Equatable, Sendable {
        case url(String)
        case noBrowser
        case denied
        case empty
    }

    private static let scripts: [(bundle: String, source: String)] = [
        ("com.apple.Safari", "tell application \"Safari\" to get URL of current tab of front window"),
        ("com.google.Chrome", "tell application \"Google Chrome\" to get URL of active tab of front window"),
    ]

    private static func exec(_ source: String) -> (value: String?, code: Int?) {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: source) else { return (nil, nil) }
        let r = s.executeAndReturnError(&err)
        if let e = err { return (nil, (e[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1) }
        return (r.stringValue, nil)
    }

    // Blocking: AppleScript to Safari/Chrome; call off the main thread.
    public static func front() -> Result {
        var any = false, denied = false
        for (bundle, source) in scripts where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            any = true
            let r = exec(source)
            if let v = r.value, !v.isEmpty { return .url(v) }
            if r.code == -1743 { denied = true }
        }
        if !any { return .noBrowser }
        return denied ? .denied : .empty
    }
}
