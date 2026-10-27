import Foundation

public protocol KeyValueStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func double(forKey defaultName: String) -> Double
    func data(forKey defaultName: String) -> Data?
    func array(forKey defaultName: String) -> [Any]?
    func stringArray(forKey defaultName: String) -> [String]?
    func dictionary(forKey defaultName: String) -> [String: Any]?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

// Typed reads on top of object(forKey:); UserDefaults keeps its own native implementations.
public extension KeyValueStoring {
    func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }

    func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let i as Int: return i
        case let b as Bool: return b ? 1 : 0
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let b as Bool: return b ? 1 : 0
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
}

extension UserDefaults: KeyValueStoring {}

public final class InMemoryKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    public init(_ initial: [String: Any] = [:]) { values = initial }

    public func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    public func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }

    public func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }
}
