import Foundation

public struct FanConfig: Equatable, Sendable {
    public static let rpmRange = 0...10000
    public static let percentRange = 0...100
    public static let hysteresisRange = 0.0...15.0
    public static let rampRange = 0...5000

    public var mode = FanControlMode.auto
    public var manualRpm = 2500
    public var manualPercent = 50
    public var curve = FanCurve.defaultPoints
    public var source = FanSensorSource.soc
    public var aggregate = FanAggregate.hottest
    public var hysteresis = 3.0
    public var rampUp = 800
    public var rampDown = 200
    public var resumeOnLaunch = false

    public init() {}

    public var curveUsable: Bool { !FanCurve.normalized(curve).isEmpty }

    public var sanitized: FanConfig {
        var c = self
        c.manualRpm = ToolsClamp.int(manualRpm, Self.rpmRange)
        c.manualPercent = ToolsClamp.int(manualPercent, Self.percentRange)
        c.curve = FanCurve.normalized(curve)
        c.hysteresis = hysteresis.isFinite ? ToolsClamp.double(hysteresis, Self.hysteresisRange) : 3
        c.rampUp = ToolsClamp.int(rampUp, Self.rampRange)
        c.rampDown = ToolsClamp.int(rampDown, Self.rampRange)
        if c.curve.isEmpty { c.curve = FanCurve.defaultPoints }
        return c
    }
}

public struct FanPreset: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var config: FanConfig

    public init(id: String, name: String, builtIn: Bool = false, config: FanConfig) {
        self.id = id
        self.name = name
        self.builtIn = builtIn
        self.config = config
    }
}

public enum FanPresets {
    public static let maxUser = 20
    public static let nameLimit = 40

    public static var builtIn: [FanPreset] {
        func curve(_ pairs: [(Double, Double)], hyst: Double, down: Int) -> FanConfig {
            var c = FanConfig()
            c.mode = .curve
            c.curve = pairs.map { FanCurvePoint(temp: $0.0, percent: $0.1) }
            c.hysteresis = hyst
            c.rampDown = down
            return c
        }
        var maxed = FanConfig()
        maxed.mode = .manualPercent
        maxed.manualPercent = 100
        maxed.rampDown = 0
        return [
            FanPreset(id: "quiet", name: "Тихий", builtIn: true, config: curve([(50, 0), (70, 30), (85, 70), (95, 100)], hyst: 4, down: 150)),
            FanPreset(id: "balanced", name: "Сбалансированный", builtIn: true, config: curve([(40, 0), (55, 25), (70, 60), (85, 100)], hyst: 3, down: 200)),
            FanPreset(id: "cool", name: "Прохладный", builtIn: true, config: curve([(35, 20), (50, 45), (65, 75), (80, 100)], hyst: 2, down: 300)),
            FanPreset(id: "max", name: "Максимум", builtIn: true, config: maxed)
        ]
    }

    public static func cleanName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
    }

    public static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 24 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7a) }
    }
}

public final class FanSettingsStore {
    private let a: KVAccess
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) {
        self.kv = kv
        a = KVAccess(kv: kv)
    }

    public var dirty: Bool {
        get { a.bool("fanControl.dirty", false) }
        set { a.put("fanControl.dirty", newValue, false) }
    }

    public var activePreset: String? {
        get { a.string("fanControl.preset") }
        set { if let newValue { kv.set(newValue, forKey: "fanControl.preset") } else { kv.removeObject(forKey: "fanControl.preset") } }
    }

    public func load() -> FanConfig { Self.read(prefix: "fanControl.", a) }

    public func save(_ c: FanConfig) { Self.write(c.sanitized, prefix: "fanControl.", a, kv) }

    static func read(prefix p: String, _ a: KVAccess) -> FanConfig {
        var c = FanConfig()
        if let v = a.string(p + "mode"), let m = FanControlMode(rawValue: v) { c.mode = m }
        c.manualRpm = a.int(p + "rpm", c.manualRpm)
        c.manualPercent = a.int(p + "pct", c.manualPercent)
        if let rows = a.kv.object(forKey: p + "curve") as? [[String: Double]] {
            let pts = rows.compactMap { r -> FanCurvePoint? in
                guard let t = r["t"], let v = r["p"] else { return nil }
                return FanCurvePoint(temp: t, percent: v)
            }
            if !pts.isEmpty { c.curve = pts }
        }
        if let v = a.string(p + "source"), let s = FanSensorSource(rawValue: v) { c.source = s }
        if let v = a.string(p + "aggregate"), let s = FanAggregate(rawValue: v) { c.aggregate = s }
        c.hysteresis = a.double(p + "hyst", c.hysteresis)
        c.rampUp = a.int(p + "up", c.rampUp)
        c.rampDown = a.int(p + "down", c.rampDown)
        c.resumeOnLaunch = a.bool(p + "resume", false)
        return c.sanitized
    }

    static func write(_ c: FanConfig, prefix p: String, _ a: KVAccess, _ kv: KeyValueStoring) {
        let b = FanConfig()
        a.put(p + "mode", c.mode.rawValue, b.mode.rawValue)
        a.put(p + "rpm", c.manualRpm, b.manualRpm)
        a.put(p + "pct", c.manualPercent, b.manualPercent)
        let rows = c.curve.map { ["t": $0.temp, "p": $0.percent] }
        if c.curve == b.curve { kv.removeObject(forKey: p + "curve") } else { kv.set(rows, forKey: p + "curve") }
        a.put(p + "source", c.source.rawValue, b.source.rawValue)
        a.put(p + "aggregate", c.aggregate.rawValue, b.aggregate.rawValue)
        a.put(p + "hyst", c.hysteresis, b.hysteresis)
        a.put(p + "up", c.rampUp, b.rampUp)
        a.put(p + "down", c.rampDown, b.rampDown)
        a.put(p + "resume", c.resumeOnLaunch, b.resumeOnLaunch)
    }

    public func loadUserPresets() -> [FanPreset] {
        guard let rows = kv.object(forKey: "fanControl.presets") as? [[String: Any]] else { return [] }
        var seen = Set(FanPresets.builtIn.map(\.id))
        var out: [FanPreset] = []
        for r in rows {
            guard let id = r["id"] as? String, FanPresets.isValidID(id), seen.insert(id).inserted,
                  let name = r["name"] as? String, !FanPresets.cleanName(name).isEmpty,
                  let cfg = r["cfg"] as? [String: Any] else { continue }
            let mem = FanMemoryStore(cfg)
            var c = Self.read(prefix: "", KVAccess(kv: mem))
            c.resumeOnLaunch = false
            out.append(FanPreset(id: id, name: FanPresets.cleanName(name), config: c))
            if out.count >= FanPresets.maxUser { break }
        }
        return out
    }

    public func saveUserPresets(_ presets: [FanPreset]) {
        let rows: [[String: Any]] = presets.filter { !$0.builtIn }.prefix(FanPresets.maxUser).map { p in
            let mem = FanMemoryStore([:])
            var c = p.config
            c.resumeOnLaunch = false
            Self.write(c.sanitized, prefix: "", KVAccess(kv: mem), mem)
            return ["id": p.id, "name": p.name, "cfg": mem.values]
        }
        if rows.isEmpty { kv.removeObject(forKey: "fanControl.presets") } else { kv.set(rows, forKey: "fanControl.presets") }
    }
}

final class FanMemoryStore: KeyValueStoring {
    var values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

public final class FanPresetLibrary {
    private let store: FanSettingsStore
    public private(set) var user: [FanPreset]

    public init(store: FanSettingsStore) {
        self.store = store
        user = store.loadUserPresets()
    }

    public var all: [FanPreset] { FanPresets.builtIn + user }

    public func preset(_ id: String) -> FanPreset? { all.first { $0.id == id } }

    // Same name replaces the user preset; returns nil for an empty name or when the list is full.
    @discardableResult
    public func save(name: String, config: FanConfig) -> FanPreset? {
        let clean = FanPresets.cleanName(name)
        guard !clean.isEmpty, !FanPresets.builtIn.contains(where: { $0.name == clean }) else { return nil }
        var cfg = config.sanitized
        cfg.resumeOnLaunch = false
        if let i = user.firstIndex(where: { $0.name == clean }) {
            user[i].config = cfg
            store.saveUserPresets(user)
            return user[i]
        }
        guard user.count < FanPresets.maxUser else { return nil }
        let taken = Set(all.map(\.id))
        var n = 1
        while taken.contains("u\(n)") { n += 1 }
        let p = FanPreset(id: "u\(n)", name: clean, config: cfg)
        user.append(p)
        store.saveUserPresets(user)
        return p
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        guard let i = user.firstIndex(where: { $0.id == id }) else { return false }
        user.remove(at: i)
        store.saveUserPresets(user)
        if store.activePreset == id { store.activePreset = nil }
        return true
    }

    public func rename(_ id: String, to name: String) -> Bool {
        let clean = FanPresets.cleanName(name)
        guard !clean.isEmpty, let i = user.firstIndex(where: { $0.id == id }),
              !all.contains(where: { $0.name == clean && $0.id != id }) else { return false }
        user[i].name = clean
        store.saveUserPresets(user)
        return true
    }

    // The loaded preset keeps the launch-resume choice of the current settings.
    public func config(applying id: String, to current: FanConfig) -> FanConfig? {
        guard let p = preset(id) else { return nil }
        var c = p.config.sanitized
        c.resumeOnLaunch = current.resumeOnLaunch
        return c
    }
}
