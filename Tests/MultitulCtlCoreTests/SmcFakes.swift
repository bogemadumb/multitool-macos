import Foundation
@testable import MultitulCtlCore

final class SmcFakeDevice: SmcWriting, @unchecked Sendable {
    var infos: [String: SmcKeyInfo] = [:]
    var data: [String: [UInt8]] = [:]
    var writes: [(String, [UInt8])] = []
    var refuse: Set<String> = []
    var ignore: Set<String> = []
    var onWrite: ((String, [UInt8]) -> Void)?

    func keyInfo(_ name: String) -> SmcKeyInfo? { infos[name] }
    func readBytes(_ name: String) -> [UInt8]? { data[name] }
    func allKeyNames() -> [String] { infos.keys.sorted() }

    func writeBytes(_ name: String, _ bytes: [UInt8]) -> Bool {
        writes.append((name, bytes))
        guard let info = infos[name], info.size == bytes.count, !refuse.contains(name) else { return false }
        onWrite?(name, bytes)
        if !ignore.contains(name) { data[name] = bytes }
        return true
    }

    func put(_ name: String, _ type: String, _ size: Int, value: Double) {
        infos[name] = SmcKeyInfo(size: size, type: type)
        data[name] = SmcCodec.encode(value, type: type, size: size)
    }

    func putBytes(_ name: String, _ type: String, _ bytes: [UInt8]) {
        infos[name] = SmcKeyInfo(size: bytes.count, type: type)
        data[name] = bytes
    }

    var names: [String] { writes.map(\.0) }

    func value(_ name: String) -> Double? { readValue(name) }

    static func appleSilicon(fans: [(min: Double, max: Double, ac: Double)] = [(1200, 6000, 1300)], withTest: Bool = true, modeKeyCase: String = "Md") -> SmcFakeDevice {
        let d = SmcFakeDevice()
        d.put("FNum", "ui8", 1, value: Double(fans.count))
        for (i, f) in fans.enumerated() {
            d.put("F\(i)Ac", "flt", 4, value: f.ac)
            d.put("F\(i)Mn", "flt", 4, value: f.min)
            d.put("F\(i)Mx", "flt", 4, value: f.max)
            d.put("F\(i)Tg", "flt", 4, value: f.min)
            d.put("F\(i)\(modeKeyCase)", "ui8", 1, value: 0)
        }
        if withTest { d.put("Ftst", "ui8", 1, value: 0) }
        return d
    }

    static func intel(fans: [(min: Double, max: Double, ac: Double)] = [(1200, 6000, 1300), (1200, 5500, 1250)]) -> SmcFakeDevice {
        let d = SmcFakeDevice()
        d.put("FNum", "ui8", 1, value: Double(fans.count))
        for (i, f) in fans.enumerated() {
            d.put("F\(i)Ac", "fpe2", 2, value: f.ac)
            d.put("F\(i)Mn", "fpe2", 2, value: f.min)
            d.put("F\(i)Mx", "fpe2", 2, value: f.max)
            d.put("F\(i)Tg", "fpe2", 2, value: f.min)
        }
        d.putBytes("FS! ", "ui16", [0, 0])
        return d
    }
}
