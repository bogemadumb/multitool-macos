import Foundation

public enum VpnEndpoint {
    public static let placeholder = "203.0.113.10"
    public static let envFile = "/usr/local/etc/singbox/server.env"

    public static func parse(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SERVER_IP=") else { continue }
            let v = String(line.dropFirst("SERVER_IP=".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !v.isEmpty { return v }
        }
        return nil
    }

    public static let serverAddress: String = {
        if let v = ProcessInfo.processInfo.environment["MULTITUL_VPS_ADDRESS"], !v.isEmpty { return v }
        if let text = try? String(contentsOfFile: envFile, encoding: .utf8), let v = parse(text) { return v }
        return placeholder
    }()
}
