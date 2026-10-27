import Foundation

public struct SmcKeyInfo: Equatable, Sendable {
    public var size: Int
    public var type: String
    public init(size: Int, type: String) {
        self.size = size
        self.type = type
    }
}

public protocol SmcReading: AnyObject {
    func keyInfo(_ name: String) -> SmcKeyInfo?
    func readBytes(_ name: String) -> [UInt8]?
    func allKeyNames() -> [String]
}

public protocol SmcWriting: SmcReading {
    func writeBytes(_ name: String, _ bytes: [UInt8]) -> Bool
}

public extension SmcReading {
    func readValue(_ name: String) -> Double? {
        guard let info = keyInfo(name), let bytes = readBytes(name) else { return nil }
        return SmcCodec.decode(bytes, type: info.type)
    }
}
