import Foundation
import AppKit
import CoreImage
import SwiftUI
import MultitulCtlCore

public enum VpnServerError: Error, Equatable, Sendable {
    case unreachable(String)
    case remote(String)
    case badOutput

    public var text: String {
        switch self {
        case .unreachable(let s): return s
        case .remote(let s):
            switch s {
            case "user exists": return "Такой ключ уже есть"
            case "no such user": return "Такого ключа нет на сервере"
            case "refusing to revoke mac without --force": return "Ключ этого Мака не отзывается"
            case "command not allowed": return "Команда не разрешена ключом доступа"
            default: return "Сервер ответил: \(s)"
            }
        case .badOutput: return "Сервер вернул непонятный ответ"
        }
    }
}

public struct VpnVnstatMonth: Equatable, Sendable {
    public var iface: String
    public var rx: Double
    public var tx: Double
}

public struct VpnServerHealth: Equatable, Sendable {
    public var xray: Bool
    public var nginx: Bool
    public var cpuPercent: Double
    public var load: [Double]
    public var cpus: Int
    public var ramUsed: Double
    public var ramTotal: Double
    public var diskFree: Double
    public var diskTotal: Double
    public var uptime: Double
    public var certNotAfter: Date?
    public var vnstat: VpnVnstatMonth?
    public var xrayVersion: String?

    public init(xray: Bool, nginx: Bool, cpuPercent: Double, load: [Double], cpus: Int, ramUsed: Double, ramTotal: Double,
                diskFree: Double, diskTotal: Double, uptime: Double, certNotAfter: Date? = nil, vnstat: VpnVnstatMonth? = nil,
                xrayVersion: String? = nil) {
        self.xray = xray
        self.nginx = nginx
        self.cpuPercent = cpuPercent
        self.load = load
        self.cpus = cpus
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.uptime = uptime
        self.certNotAfter = certNotAfter
        self.vnstat = vnstat
        self.xrayVersion = xrayVersion
    }
}

public struct VpnServerUserStat: Equatable, Sendable {
    public var up: Double
    public var down: Double
    public var lastSeen: Date?
}

public struct VpnServerStats: Equatable, Sendable {
    public var month: String
    public var users: [String: VpnServerUserStat]
}

public struct VpnServerUserInfo: Equatable, Sendable {
    public var name: String
    public var notorrent: Bool
    public var created: String?

    public init(name: String, notorrent: Bool, created: String?) {
        self.name = name
        self.notorrent = notorrent
        self.created = created
    }
}

public struct VpnKeyRow: Identifiable, Equatable, Sendable {
    public var name: String
    public var label: String
    public var hint: String
    public var up: Double
    public var down: Double
    public var lastSeen: Date?
    public var notorrent: Bool
    public var online: Bool
    public var id: String { name }
}

public enum VpnLevel: Int, Comparable, Sendable {
    case ok = 0, warn, alarm
    public static func < (a: VpnLevel, b: VpnLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct VpnServerLevels: Equatable, Sendable {
    public var xray: VpnLevel
    public var nginx: VpnLevel
    public var cpu: VpnLevel
    public var load: VpnLevel
    public var ram: VpnLevel
    public var disk: VpnLevel
    public var cert: VpnLevel
}

public enum VpnServerParse {
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    static func object(_ d: Data) -> Result<[String: Any], VpnServerError> {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .failure(.badOutput) }
        if let e = o["error"] as? String { return .failure(.remote(e)) }
        return .success(o)
    }

    public static func health(_ d: Data) -> Result<VpnServerHealth, VpnServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let xray = o["xray"] as? Bool, let nginx = o["nginx"] as? Bool,
                  let cpu = num(o["cpu_percent"]), let cpus = num(o["cpus"]),
                  let ru = num(o["ram_used"]), let rt = num(o["ram_total"]),
                  let df = num(o["disk_free"]), let dt = num(o["disk_total"]),
                  let up = num(o["uptime_s"]) else { return .failure(.badOutput) }
            let load = (o["load"] as? [Any] ?? []).compactMap { num($0) }
            var vn: VpnVnstatMonth?
            if let m = o["vnstat_month"] as? [String: Any], let rx = num(m["rx"]), let tx = num(m["tx"]) {
                vn = VpnVnstatMonth(iface: m["iface"] as? String ?? "", rx: rx, tx: tx)
            }
            return .success(VpnServerHealth(
                xray: xray, nginx: nginx, cpuPercent: cpu, load: load, cpus: max(1, Int(cpus)),
                ramUsed: ru, ramTotal: rt, diskFree: df, diskTotal: dt, uptime: up,
                certNotAfter: date(o["cert_not_after"] as? String), vnstat: vn,
                xrayVersion: o["xray_version"] as? String))
        }
    }

    public static func stats(_ d: Data) -> Result<VpnServerStats, VpnServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let month = o["month"] as? String, let arr = o["users"] as? [[String: Any]] else { return .failure(.badOutput) }
            var users: [String: VpnServerUserStat] = [:]
            for u in arr {
                guard let n = u["email"] as? String else { continue }
                users[n] = VpnServerUserStat(up: num(u["up"]) ?? 0, down: num(u["down"]) ?? 0, lastSeen: date(u["last_seen"] as? String))
            }
            return .success(VpnServerStats(month: month, users: users))
        }
    }

    public static func users(_ d: Data) -> Result<[VpnServerUserInfo], VpnServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let arr = o["users"] as? [[String: Any]] else { return .failure(.badOutput) }
            return .success(arr.compactMap { u in
                guard let n = u["email"] as? String else { return nil }
                return VpnServerUserInfo(name: n, notorrent: u["notorrent"] as? Bool ?? false, created: u["created"] as? String)
            })
        }
    }

    public static func link(_ d: Data) -> Result<String, VpnServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let l = o["link"] as? String, l.hasPrefix("vless://") else { return .failure(.badOutput) }
            return .success(l)
        }
    }

    public static func ok(_ d: Data) -> Result<Bool, VpnServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard o["ok"] as? Bool == true else { return .failure(.badOutput) }
            return .success(o["restart_needed"] as? Bool ?? false)
        }
    }
}

public enum VpnServerLogic {
    public static let onlineWindow: TimeInterval = 300

    public static func validName(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (1...32).contains(u.count) else { return false }
        func lower(_ c: Unicode.Scalar) -> Bool { (c.value >= 97 && c.value <= 122) || (c.value >= 48 && c.value <= 57) }
        guard lower(u[0]) else { return false }
        return u.dropFirst().allSatisfy { lower($0) || $0 == "_" || $0 == "-" }
    }

    public static func nameError(_ s: String, existing: [String]) -> String? {
        if s.isEmpty { return nil }
        if !validName(s) { return "Только латиница a–z, цифры, _ и -; начало — буква или цифра; до 32 символов" }
        if existing.contains(s) { return "Такой ключ уже есть" }
        return nil
    }

    public static func canRevoke(_ name: String) -> Bool { name != "mac" }

    public static func label(_ name: String) -> String {
        switch name {
        case "mac": return "Этот Мак"
        case "home": return "Домашний сервер"
        case "phone": return "Телефон"
        case "friend": return "Друг"
        default: return name
        }
    }

    public static func hint(_ name: String, created: String?) -> String {
        switch name {
        case "mac": return "mac · sing-box, TUN"
        case "home": return "home · xray, прокси для дома"
        case "phone": return "phone · iPhone"
        case "friend": return "friend"
        default: return created.map { "\(name) · создан \($0)" } ?? name
        }
    }

    public static func isOnline(_ seen: Date?, now: Date) -> Bool {
        guard let s = seen else { return false }
        return now.timeIntervalSince(s) < onlineWindow
    }

    public static func relative(_ d: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let d else { return "не подключался" }
        let secs = now.timeIntervalSince(d)
        if secs < onlineWindow { return "сейчас" }
        if secs < 3600 { return "\(Int(secs / 60)) мин назад" }
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "ru_RU"); hm.calendar = calendar; hm.timeZone = calendar.timeZone
        hm.dateFormat = "HH:mm"
        if calendar.isDate(d, inSameDayAs: now) { return "\(Int(secs / 3600)) ч назад" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "вчера, \(hm.string(from: d))"
        }
        hm.dateFormat = "dd.MM, HH:mm"
        return hm.string(from: d)
    }

    public static func rows(users: [VpnServerUserInfo], stats: VpnServerStats?, now: Date) -> [VpnKeyRow] {
        users.map { u in
            let s = stats?.users[u.name]
            return VpnKeyRow(name: u.name, label: label(u.name), hint: hint(u.name, created: u.created),
                             up: s?.up ?? 0, down: s?.down ?? 0, lastSeen: s?.lastSeen,
                             notorrent: u.notorrent, online: isOnline(s?.lastSeen, now: now))
        }
    }

    public static func limits(_ r: VpnKeyRow) -> String { r.notorrent ? "без торрентов" : "нет" }

    public static func certDays(_ h: VpnServerHealth, now: Date) -> Int? {
        guard let c = h.certNotAfter else { return nil }
        return Int((c.timeIntervalSince(now) / 86400).rounded(.down))
    }

    public static func loadPerCpu(_ h: VpnServerHealth) -> Double? {
        h.load.first.map { $0 / Double(max(1, h.cpus)) }
    }

    public static func levels(_ h: VpnServerHealth, now: Date) -> VpnServerLevels {
        let load: VpnLevel = (loadPerCpu(h) ?? 0) > 1 ? .warn : .ok
        let cpu: VpnLevel = h.cpuPercent >= 90 ? .warn : .ok
        let ram: VpnLevel = h.ramTotal > 0 && h.ramUsed / h.ramTotal >= 0.9 ? .warn : .ok
        let disk: VpnLevel = h.diskTotal > 0 && h.diskFree / h.diskTotal < 0.1 ? .warn : .ok
        var cert = VpnLevel.ok
        if let d = certDays(h, now: now) { cert = d < 7 ? .alarm : (d < 21 ? .warn : .ok) }
        return VpnServerLevels(xray: h.xray ? .ok : .alarm, nginx: h.nginx ? .ok : .alarm,
                               cpu: cpu, load: load, ram: ram, disk: disk, cert: cert)
    }

    public static func monthTotal(_ h: VpnServerHealth) -> Double? {
        h.vnstat.map { $0.rx + $0.tx }
    }

    public static func uptimeText(_ s: Double) -> String {
        let m = Int(s / 60)
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(mm) мин" }
        return "\(mm) мин"
    }
}

public enum VpnAdminCommand: Equatable, Sendable {
    case health, stats, users
    case link(String)
    case add(String, noTorrent: Bool)
    case revoke(String)

    // nil when the command would not pass the server-side forced-command filter.
    public var arguments: [String]? {
        switch self {
        case .health: return ["health"]
        case .stats: return ["stats"]
        case .users: return ["users"]
        case .link(let n): return VpnServerLogic.validName(n) ? ["link", n] : nil
        case .add(let n, let nt):
            guard VpnServerLogic.validName(n) else { return nil }
            return nt ? ["add", n, "--no-torrent"] : ["add", n]
        case .revoke(let n):
            guard VpnServerLogic.validName(n), VpnServerLogic.canRevoke(n) else { return nil }
            return ["revoke", n]
        }
    }

    public var timeout: TimeInterval {
        switch self {
        case .add, .revoke: return 40
        default: return 20
        }
    }
}

public protocol VpnAdminRunning: Sendable {
    func call(_ command: VpnAdminCommand) -> Result<Data, VpnServerError>
}

public struct SshVpnAdminRunner: VpnAdminRunning {
    public static let host = "root@" + VpnEndpoint.serverAddress
    public static var defaultKeyPath: String { NSHomeDirectory() + "/.ssh/multitul_vpn" }

    let runner: ProcessRunning
    let keyPath: String
    let host: String
    let keyExists: @Sendable (String) -> Bool

    public init(runner: ProcessRunning = SystemProcessRunner(), keyPath: String = SshVpnAdminRunner.defaultKeyPath,
                host: String = SshVpnAdminRunner.host,
                keyExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.runner = runner
        self.keyPath = keyPath
        self.host = host
        self.keyExists = keyExists
    }

    func sshArguments(_ args: [String]) -> [String] {
        ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         "-o", "StrictHostKeyChecking=accept-new", host] + args
    }

    public func call(_ command: VpnAdminCommand) -> Result<Data, VpnServerError> {
        guard let args = command.arguments else { return .failure(.remote("command not allowed")) }
        guard keyExists(keyPath) else { return .failure(.unreachable("Нет ключа ~/.ssh/multitul_vpn")) }
        let r = runner.run("/usr/bin/ssh", sshArguments(args), timeout: command.timeout)
        if r.timedOut { return .failure(.unreachable("Сервер не ответил за \(Int(command.timeout)) с")) }
        let data = Data(r.stdout.utf8)
        if data.isEmpty { return .failure(.unreachable("Нет связи с сервером по ssh")) }
        return .success(data)
    }
}

public enum VpnAddOutcome: Equatable, Sendable {
    case ok(link: String, restartNeeded: Bool)
    case createdNoLink(String)
    case failed(String)
}

final class VpnOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Result<Data, VpnServerError>, Never>?

    init(_ cont: CheckedContinuation<Result<Data, VpnServerError>, Never>) { self.cont = cont }

    func resume(_ r: Result<Data, VpnServerError>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: r)
    }
}

@MainActor
public final class VpnServerModel: ObservableObject {
    public static let healthTTL: TimeInterval = 60
    public static let keysTTL: TimeInterval = 300

    @Published public private(set) var health: VpnServerHealth?
    @Published public private(set) var healthAt: Date?
    @Published public private(set) var healthError: String?
    @Published public private(set) var loadingHealth = false
    @Published public private(set) var keys: [VpnKeyRow] = []
    @Published public private(set) var keysAt: Date?
    @Published public private(set) var keysError: String?
    @Published public private(set) var loadingKeys = false
    @Published public var busyName: String?
    @Published public var creating = false
    @Published public var notice: String?

    private let runner: VpnAdminRunning
    private let clock: () -> Date
    private let hardLimit: @Sendable (VpnAdminCommand) -> TimeInterval

    public init(runner: VpnAdminRunning = SshVpnAdminRunner(), clock: @escaping () -> Date = { Date() },
                hardLimit: @escaping @Sendable (VpnAdminCommand) -> TimeInterval = { $0.timeout + 5 }) {
        self.runner = runner
        self.clock = clock
        self.hardLimit = hardLimit
    }

    private func call(_ c: VpnAdminCommand) async -> Result<Data, VpnServerError> {
        let r = runner
        let limit = hardLimit(c)
        return await withCheckedContinuation { cont in
            let gate = VpnOneShot(cont)
            DispatchQueue.global().async { gate.resume(r.call(c)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                gate.resume(.failure(.unreachable("Сервер не ответил за \(Int(limit.rounded())) с")))
            }
        }
    }

    public func refreshHealth(force: Bool = false) async {
        guard !loadingHealth else { return }
        if !force, health != nil, let t = healthAt, clock().timeIntervalSince(t) < Self.healthTTL { return }
        loadingHealth = true
        defer { loadingHealth = false }
        switch await call(.health).flatMap({ VpnServerParse.health($0) }) {
        case .success(let h):
            health = h; healthAt = clock(); healthError = nil
        case .failure(let e):
            healthError = e.text
        }
    }

    public func refreshKeys(force: Bool = false) async {
        guard !loadingKeys else { return }
        if !force, !keys.isEmpty, let t = keysAt, clock().timeIntervalSince(t) < Self.keysTTL { return }
        loadingKeys = true
        defer { loadingKeys = false }
        async let u = call(.users)
        async let s = call(.stats)
        let (ur, sr) = await (u, s)
        switch ur.flatMap({ VpnServerParse.users($0) }) {
        case .failure(let e):
            keysError = e.text
        case .success(let users):
            var stats: VpnServerStats?
            var err: String?
            switch sr.flatMap({ VpnServerParse.stats($0) }) {
            case .success(let st): stats = st
            case .failure(let e): err = "Статистика недоступна: \(e.text)"
            }
            keys = VpnServerLogic.rows(users: users, stats: stats, now: clock())
            keysAt = clock()
            keysError = err
        }
    }

    public func link(_ name: String) async -> Result<String, VpnServerError> {
        busyName = name
        defer { busyName = nil }
        return await call(.link(name)).flatMap { VpnServerParse.link($0) }
    }

    public func add(_ name: String, noTorrent: Bool) async -> VpnAddOutcome {
        guard VpnServerLogic.validName(name) else { return .failed("Недопустимое имя") }
        creating = true
        defer { creating = false }
        switch await call(.add(name, noTorrent: noTorrent)).flatMap({ VpnServerParse.ok($0) }) {
        case .failure(let e): return .failed(e.text)
        case .success(let restart):
            await refreshKeys(force: true)
            switch await call(.link(name)).flatMap({ VpnServerParse.link($0) }) {
            case .success(let l): return .ok(link: l, restartNeeded: restart)
            case .failure(let e): return .createdNoLink("Ключ создан, но ссылку получить не удалось: \(e.text). Нажми «QR» в списке.")
            }
        }
    }

    public func revoke(_ name: String) async -> String? {
        guard VpnServerLogic.canRevoke(name) else { return "Этот ключ не отзывается" }
        busyName = name
        defer { busyName = nil }
        switch await call(.revoke(name)).flatMap({ VpnServerParse.ok($0) }) {
        case .failure(let e): return e.text
        case .success(let restart):
            await refreshKeys(force: true)
            return restart ? "Ключ отозван, но правило торрентов применится только после перезапуска xray на сервере" : nil
        }
    }
}

public protocol VpnPasteboarding: AnyObject {
    var changeCount: Int { get }
    func clearContents()
    func setString(_ s: String)
}

public final class SystemPasteboard: VpnPasteboarding {
    public init() {}
    public var changeCount: Int { NSPasteboard.general.changeCount }
    public func clearContents() { NSPasteboard.general.clearContents() }
    public func setString(_ s: String) {
        let pb = NSPasteboard.general
        pb.setString(s, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

@MainActor
public final class VpnSecretClipboard {
    public static let ttl: TimeInterval = 60
    private let pasteboard: VpnPasteboarding
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    public init(pasteboard: VpnPasteboarding = SystemPasteboard(),
                schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
                }) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    public func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text)
        let stamp = pasteboard.changeCount
        schedule(Self.ttl) { [pasteboard] in
            if pasteboard.changeCount == stamp { pasteboard.clearContents() }
        }
    }
}

public enum VpnQR {
    public static let quietModules = 4

    public static func cgImage(_ text: String, module: Int = 8) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let raw = f.outputImage else { return nil }
        let m = CGFloat(module)
        let side = raw.extent.width * m + CGFloat(2 * quietModules * module)
        let scaled = raw.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: m, y: m))
            .transformed(by: CGAffineTransform(translationX: CGFloat(quietModules * module), y: CGFloat(quietModules * module)))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(scaled.composited(over: white), from: rect)
    }

    public static func decode(_ image: CGImage) -> String? {
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let feats = det?.features(in: CIImage(cgImage: image)) ?? []
        return (feats.first as? CIQRCodeFeature)?.messageString
    }
}
