import Foundation

struct KVAccess {
    let kv: KeyValueStoring

    func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { kv.removeObject(forKey: key) } else { kv.set(v, forKey: key) }
    }

    func bool(_ key: String, _ d: Bool) -> Bool { (kv.object(forKey: key) as? Bool) ?? d }
    func int(_ key: String, _ d: Int) -> Int { (kv.object(forKey: key) as? Int) ?? d }
    func double(_ key: String, _ d: Double) -> Double { (kv.object(forKey: key) as? Double) ?? d }
    func string(_ key: String) -> String? { kv.object(forKey: key) as? String }
    func strings(_ key: String) -> [String]? { kv.object(forKey: key) as? [String] }
}

public enum ToolsClamp {
    public static func int(_ v: Int, _ range: ClosedRange<Int>) -> Int { min(max(v, range.lowerBound), range.upperBound) }
    public static func double(_ v: Double, _ range: ClosedRange<Double>) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

public protocol TextWriting: AnyObject {
    func write(_ text: String)
}

public protocol ToolsClock: AnyObject {
    var now: Date { get }
}

public final class SystemToolsClock: ToolsClock {
    public init() {}
    public var now: Date { Date() }
}
