import Foundation
import SwiftUI

public enum VpnConnFilter: CaseIterable, Sendable {
    case all, vps, direct, local

    public var label: String {
        switch self {
        case .all: "Все"
        case .vps: "Через VPS"
        case .direct: "Напрямую"
        case .local: "Локально"
        }
    }

    public func matches(_ r: VpnRoute) -> Bool {
        switch self {
        case .all: true
        case .vps: r == .vps
        case .direct: r == .direct
        case .local: r == .local
        }
    }
}

public struct VpnConnRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let app: String
    public let host: String
    public let rawHost: String
    public let destIP: String
    public let route: VpnRoute
    public let ruleText: String
    public let speed: Double
    public let started: Date?

    var searchText: String { "\(app) \(host) \(destIP) \(ruleText) \(route.label)".lowercased() }
}

@MainActor
public final class VpnRulesModel: ObservableObject {
    let files: VpnRuleFiles
    let browser: @Sendable () -> VpnBrowserURL.Result
    @Published public private(set) var user: [VpnUserRule] = []
    @Published public private(set) var alwaysVps: [String] = []
    @Published public private(set) var busyWrite = false
    @Published public var toast: String?
    @Published public var siteNote: String?
    @Published public private(set) var busyBrowser = false

    init(files: VpnRuleFiles, browser: @escaping @Sendable () -> VpnBrowserURL.Result = { VpnBrowserURL.front() }) {
        self.files = files
        self.browser = browser
    }

    public func reload() async {
        let f = files
        let r = await Task.detached { (f.load(), f.alwaysVps()) }.value
        user = r.0
        alwaysVps = r.1
    }

    public func say(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    @discardableResult
    public func add(kind: VpnRuleKind, value: String, target: VpnRuleTarget) async -> Bool {
        busyWrite = true
        defer { busyWrite = false }
        let f = files
        let err = await Task.detached { () -> String? in
            do { try f.add(value, kind: kind, target: target); return nil } catch { return "\(error)" }
        }.value
        if let err {
            Log.write("vpn rules add failed: \(err)")
            say("Не удалось записать правило: \(err)")
            return false
        }
        await reload()
        return true
    }

    public func remove(_ r: VpnUserRule) async {
        busyWrite = true
        defer { busyWrite = false }
        let f = files
        let err = await Task.detached { () -> String? in
            do { try f.remove(r); return nil } catch { return "\(error)" }
        }.value
        if let err {
            Log.write("vpn rules remove failed: \(err)")
            say("Не удалось удалить правило: \(err)")
        }
        await reload()
    }

    public func addCurrentSite() {
        guard !busyBrowser else { return }
        busyBrowser = true
        let browser = self.browser
        Task { [weak self] in
            let r = await Task.detached { browser() }.value
            guard let self else { return }
            self.busyBrowser = false
            await self.applyBrowser(r)
        }
    }

    func applyBrowser(_ r: VpnBrowserURL.Result) async {
        switch r {
        case .url(let u):
            guard let host = VpnRuleDetect.hostFromURL(u), let rule = VpnRuleDetect.forHost(host) else {
                flash("В браузере нет открытого сайта")
                return
            }
            let f = files
            if await Task.detached(operation: { f.find(rule.kind, rule.value) }).value == .direct {
                flash("\(rule.value) уже напрямую")
                return
            }
            if await add(kind: rule.kind, value: rule.value, target: .direct) { flash("\(rule.value) — теперь напрямую") }
        case .noBrowser: flash("Открой сайт в Safari или Chrome")
        case .denied: flash("Нет доступа: Настройки → Конфиденциальность → Автоматизация")
        case .empty: flash("В браузере нет открытого сайта")
        }
    }

    private func flash(_ text: String) {
        siteNote = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.siteNote == text { self?.siteNote = nil }
        }
    }
}

@MainActor
public final class VpnConnectionsModel: ObservableObject {
    @Published public private(set) var rows: [VpnConnRow] = []
    @Published public private(set) var failed = false
    @Published public var filter: VpnConnFilter = .all
    @Published public var search = ""

    var isActive: () -> Bool = { true }
    private let client: ClashAPI
    private let rules: VpnRulesModel
    private var prev: [String: (bytes: Double, at: Date)] = [:]

    init(client: ClashAPI, rules: VpnRulesModel) {
        self.client = client
        self.rules = rules
    }

    public func count(_ f: VpnConnFilter) -> Int { rows.filter { f.matches($0.route) }.count }

    public var visible: [VpnConnRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { filter.matches($0.route) && (q.isEmpty || $0.searchText.contains(q)) }
    }

    public func run() async {
        while !Task.isCancelled {
            if isActive() {
                await poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func poll(at now: Date = Date()) async {
        let raw: [ClashConn]
        do { raw = try await client.connections() } catch {
            failed = true
            return
        }
        failed = false
        var next: [String: (bytes: Double, at: Date)] = [:]
        var out: [VpnConnRow] = []
        for c in raw {
            let total = c.download + c.upload
            next[c.id] = (total, now)
            var speed = 0.0
            if let p = prev[c.id] {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.2 { speed = max(0, (total - p.bytes) / dt) }
            } else if let st = c.start {
                speed = total / max(1, now.timeIntervalSince(st))
            }
            let name = VpnConnLogic.processName(c.processPath)
            out.append(VpnConnRow(
                id: c.id,
                app: name.isEmpty ? "—" : name,
                host: VpnConnLogic.hostName(host: c.host, ip: c.destIP, port: c.destPort),
                rawHost: c.host,
                destIP: c.destIP,
                route: VpnConnLogic.route(chains: c.chains, rule: c.rule, destIP: c.destIP),
                ruleText: VpnConnLogic.humanRule(c.rule),
                speed: speed,
                started: c.start))
        }
        prev = next
        out.sort { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        rows = out
    }

    public func drop(_ r: VpnConnRow) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.client.closeConnection(r.id) } catch { self.rules.say("Не удалось оборвать соединение") }
            await self.poll()
        }
    }

    public func ruleForSite(_ r: VpnConnRow, _ target: VpnRuleTarget) {
        let h = r.rawHost.isEmpty ? r.destIP : r.rawHost
        guard let rule = VpnRuleDetect.forHost(h) else { return }
        Task { [rules] in
            if await rules.add(kind: rule.kind, value: rule.value, target: target) {
                rules.say("\(rule.value) — \(target.label). Действует на новые соединения")
            }
        }
    }

    public func ruleForApp(_ r: VpnConnRow, _ target: VpnRuleTarget) {
        guard r.app != "—" else { return }
        Task { [rules] in
            if await rules.add(kind: .processName, value: r.app, target: target) {
                rules.say("\(r.app) — \(target.label). Действует на новые соединения")
            }
        }
    }
}
