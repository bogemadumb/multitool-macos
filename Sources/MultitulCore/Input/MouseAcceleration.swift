import Foundation

public struct PointerDevice: Equatable {
    public var registryID: UInt64
    public var key: String
    public var name: String

    public init(registryID: UInt64, key: String, name: String) {
        self.registryID = registryID
        self.key = key
        self.name = name
    }
}

public struct AccelJournalEntry: Codable, Equatable {
    public var registryID: UInt64
    public var key: String
    public var original: Int64

    public init(registryID: UInt64, key: String, original: Int64) {
        self.registryID = registryID
        self.key = key
        self.original = original
    }
}

public protocol PointerAccelDriver: AnyObject {
    func mice() -> [PointerDevice]
    func read(registryID: UInt64, key: String) -> Int64?
    func write(registryID: UInt64, key: String, value: Int64) -> Bool
}

public protocol AccelJournalStore: AnyObject {
    func load() -> [AccelJournalEntry]
    func save(_ entries: [AccelJournalEntry])
}

public final class DefaultsAccelJournal: AccelJournalStore {
    private let defaults: KeyValueStoring
    private let key = "input.mouseAcceleration.journal"

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> [AccelJournalEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AccelJournalEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [AccelJournalEntry]) {
        if entries.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

public enum AccelCurve {
    public static let flatValue: Int64 = -1
    public static let mouseKey = "HIDMouseAcceleration"
    public static let pointerKey = "HIDPointerAcceleration"
    public static let trackpadType = "HIDTrackpadAcceleration"
    public static let typeKey = "HIDPointerAccelerationType"

    public static func writableKey(forType type: String?) -> String? {
        switch type {
        case nil: mouseKey
        case mouseKey?: mouseKey
        case pointerKey?: pointerKey
        default: nil
        }
    }

    public static func isFlat(_ value: Int64?) -> Bool { value == flatValue }
}

public struct AccelApplyReport: Equatable {
    public var applied = 0
    public var alreadyFlat = 0
    public var failed = 0
    public init() {}
}

public final class MouseAccelerationEngine {
    private let driver: PointerAccelDriver
    private let store: AccelJournalStore
    public private(set) var journal: [AccelJournalEntry]

    public init(driver: PointerAccelDriver, store: AccelJournalStore) {
        self.driver = driver
        self.store = store
        self.journal = store.load()
    }

    @discardableResult
    public func apply() -> AccelApplyReport {
        var report = AccelApplyReport()
        for d in driver.mice() {
            let known = journal.contains { $0.registryID == d.registryID && $0.key == d.key }
            let current = driver.read(registryID: d.registryID, key: d.key)
            if AccelCurve.isFlat(current) { report.alreadyFlat += 1; continue }
            if !known {
                guard let current else { report.failed += 1; continue }
                journal.append(AccelJournalEntry(registryID: d.registryID, key: d.key, original: current))
                store.save(journal)
            }
            if driver.write(registryID: d.registryID, key: d.key, value: AccelCurve.flatValue) { report.applied += 1 } else { report.failed += 1 }
        }
        return report
    }

    @discardableResult
    public func restore() -> Int {
        let present = Set(driver.mice().map(\.registryID))
        var restored = 0
        var left: [AccelJournalEntry] = []
        for e in journal {
            guard present.contains(e.registryID) else { continue }
            if driver.write(registryID: e.registryID, key: e.key, value: e.original) { restored += 1 } else { left.append(e) }
        }
        journal = left
        store.save(left)
        return restored
    }

    public func recoverPending() -> Int {
        journal.isEmpty ? 0 : restore()
    }
}

public struct AccelReapplySchedule {
    public static let delays: [TimeInterval] = [0, 0.3, 1.0, 2.5]
    private var token = 0
    private var index = 0

    public init() {}

    public mutating func restart() -> Int {
        token += 1
        index = 0
        return token
    }

    public mutating func next(for t: Int) -> TimeInterval? {
        guard t == token, index < Self.delays.count else { return nil }
        defer { index += 1 }
        return Self.delays[index]
    }

    public mutating func cancel() { token += 1 }
}
