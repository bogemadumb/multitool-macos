import Foundation

public enum NativeSwitcherHotKey: Int32, CaseIterable, Sendable {
    case commandTab = 1
    case commandShiftTab = 2
    case nextWindow = 27
    case previousWindow = 220
}

public protocol SymbolicHotKeyDriving: AnyObject {
    var isAvailable: Bool { get }
    func isEnabled(_ id: Int32) -> Bool?
    func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool
}

public enum TakeoverResult: Equatable, Sendable {
    case held([Int32])
    case alreadyHeld
    case released([Int32])
    case nothingToRelease
    case unavailable
    case failed(String)
}

public enum TakeoverPolicy {
    public static func shouldHoldNative(takeOver: Bool, trusted: Bool, tapRunning: Bool) -> Bool {
        takeOver && trusted && tapRunning
    }
}

public final class SystemShortcutTakeover {
    public static let journalKey = "windowSwitcher.takeoverJournal"
    private let driver: SymbolicHotKeyDriving
    private let store: KeyValueStoring
    private let key: String

    public init(driver: SymbolicHotKeyDriving, store: KeyValueStoring = UserDefaults.standard, journalKey: String = SystemShortcutTakeover.journalKey) {
        self.driver = driver
        self.store = store
        key = journalKey
    }

    public var journal: [Int32] {
        ((store.object(forKey: key) as? [Int]) ?? []).map { Int32($0) }
    }

    public var isHolding: Bool { !journal.isEmpty }

    private func writeJournal(_ ids: [Int32]) {
        if ids.isEmpty { store.removeObject(forKey: key) } else { store.set(ids.map { Int($0) }, forKey: key) }
    }

    public func hold(_ keys: [NativeSwitcherHotKey] = NativeSwitcherHotKey.allCases) -> TakeoverResult {
        hold(ids: keys.map(\.rawValue))
    }

    public func hold(ids: [Int32]) -> TakeoverResult {
        guard driver.isAvailable else { return .unavailable }
        let alreadyOurs = Set(journal)
        let toDisable = ids.filter { !alreadyOurs.contains($0) && driver.isEnabled($0) == true }
        if toDisable.isEmpty { return alreadyOurs.isEmpty ? .held([]) : .alreadyHeld }
        writeJournal(Array(alreadyOurs.union(toDisable)).sorted())
        var done: [Int32] = []
        for id in toDisable {
            if driver.setEnabled(id, false) { done.append(id) }
        }
        if done.count != toDisable.count {
            let failedIDs = Set(toDisable).subtracting(done)
            writeJournal(Array(alreadyOurs.union(done)).sorted())
            return .failed("не удалось отключить системные сочетания: \(failedIDs.sorted().map(String.init).joined(separator: ", "))")
        }
        return .held(done)
    }

    public func release() -> TakeoverResult {
        let ids = journal
        guard !ids.isEmpty else { return .nothingToRelease }
        guard driver.isAvailable else { return .unavailable }
        var restored: [Int32] = []
        var left: [Int32] = []
        for id in ids {
            if driver.setEnabled(id, true) { restored.append(id) } else { left.append(id) }
        }
        writeJournal(left)
        return left.isEmpty ? .released(restored) : .failed("не удалось вернуть системные сочетания: \(left.map(String.init).joined(separator: ", "))")
    }

    public func recoverStale(moduleEnabled: Bool) -> TakeoverResult? {
        guard !moduleEnabled, isHolding else { return nil }
        return release()
    }
}
