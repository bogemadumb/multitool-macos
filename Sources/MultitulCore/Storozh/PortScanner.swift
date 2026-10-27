import Foundation

public enum PortProtocol: String, Sendable, Comparable {
    case tcp = "TCP"
    case udp = "UDP"
    public static func < (a: PortProtocol, b: PortProtocol) -> Bool { a.rawValue < b.rawValue }
}

public struct ListeningPort: Equatable, Identifiable, Sendable {
    public var proto: PortProtocol
    public var port: Int
    public var pid: Int32
    public var command: String
    public var user: String
    public var addresses: [String]
    public var id: String { "\(proto.rawValue)-\(port)-\(pid)" }

    public var isLocalOnly: Bool { addresses.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" || $0 == "localhost" } }
}

public enum LsofParser {
    // lsof prints a space in COMMAND as \x20
    static func unescape(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(i, offsetBy: 3, limitedBy: s.endIndex) != nil, s[s.index(after: i)] == "x" {
                let hexStart = s.index(i, offsetBy: 2)
                let hexEnd = s.index(hexStart, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                if let v = UInt8(s[hexStart..<hexEnd], radix: 16) {
                    out.unicodeScalars.append(Unicode.Scalar(v))
                    i = hexEnd
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    // "*:3000", "127.0.0.1:8080", "[::1]:7000", "[fe80::1%lo0]:5353"
    static func splitAddress(_ name: String) -> (host: String, port: Int)? {
        guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { return nil }
        var host = String(name[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    // TCP: only "(LISTEN)" rows. UDP: bound sockets; connected ones ("a->b") are not listening and are skipped.
    public static func parse(_ text: String, proto: PortProtocol) -> [ListeningPort] {
        var merged: [String: ListeningPort] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 9, f[0] != "COMMAND", let pid = Int32(f[1]), f[7] == proto.rawValue else { continue }
            let name = f[8]
            if proto == .tcp, !line.contains("(LISTEN)") { continue }
            if name.contains("->") { continue }
            guard let (host, port) = splitAddress(name) else { continue }
            let key = "\(proto.rawValue)-\(port)-\(pid)"
            if var p = merged[key] {
                if !p.addresses.contains(host) { p.addresses.append(host) }
                merged[key] = p
            } else {
                merged[key] = ListeningPort(proto: proto, port: port, pid: pid, command: unescape(f[0]), user: f[2], addresses: [host])
            }
        }
        return merged.values.map { var p = $0; p.addresses.sort(); return p }.sorted { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
    }
}

public enum PortScanner {
    public static let tcpArguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
    public static let udpArguments = ["-nP", "-iUDP"]

    // Blocking (lsof takes ~0.3 s). Only sees sockets of the current user without root: that is what the module promises.
    public static func scan(run: (String, [String]) -> String = { ToolRunner.run($0, $1, timeout: 15) }) -> [ListeningPort] {
        let tcp = LsofParser.parse(run("/usr/sbin/lsof", tcpArguments), proto: .tcp)
        let udp = LsofParser.parse(run("/usr/sbin/lsof", udpArguments), proto: .udp)
        return (tcp + udp).sorted { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
    }
}
