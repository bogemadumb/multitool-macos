import Foundation

public enum IslDlBrowser: String, Sendable {
    case chromium, safari, firefox, opera, other

    public var title: String {
        switch self {
        case .chromium: "Chrome и родственные"
        case .safari: "Safari"
        case .firefox: "Firefox"
        case .opera: "Opera"
        case .other: "Загрузка"
        }
    }
}

public struct IslDlFile: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool
    public var expectedTotal: Int64?

    public init(name: String, size: Int64, modified: Date, isDirectory: Bool = false, expectedTotal: Int64? = nil) {
        self.name = name
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.expectedTotal = expectedTotal
    }
}

public enum IslDlRules {
    public static let suffixes: [(suffix: String, browser: IslDlBrowser)] = [
        (".crdownload", .chromium), (".download", .safari), (".part", .firefox), (".opdownload", .opera), (".partial", .other), (".!ut", .other)
    ]

    static let ignoredNames: Set<String> = [".DS_Store", ".localized", ".com.apple.timemachine.donotpresent"]

    public static func tempSuffix(_ name: String) -> (suffix: String, browser: IslDlBrowser)? {
        let lower = name.lowercased()
        return suffixes.first { lower.hasSuffix($0.suffix) && lower.count > $0.suffix.count }
    }

    // Chromium writes ".com.google.Chrome.AbC123" while saving extension or blob downloads.
    public static func isChromiumHiddenTemp(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        return name.hasPrefix(".com.google.Chrome") || name.hasPrefix(".com.microsoft.Edge") || name.hasPrefix(".com.brave.Browser")
            || name.hasPrefix(".org.chromium.Chromium") || name.hasPrefix(".company.thebrowser.Browser") || name.hasPrefix(".com.vivaldi.Vivaldi")
    }

    public static func isTemp(_ name: String) -> Bool { tempSuffix(name) != nil || isChromiumHiddenTemp(name) }

    public static func isIgnored(_ name: String) -> Bool {
        if isTemp(name) { return false }
        return name.hasPrefix(".") || ignoredNames.contains(name) || name.hasPrefix("~$")
    }

    public static func browser(forTemp name: String) -> IslDlBrowser {
        if isChromiumHiddenTemp(name) { return .chromium }
        return tempSuffix(name)?.browser ?? .other
    }

    // "Unconfirmed 123456.crdownload" and hidden temp files have no name of the future file.
    public static func finalName(ofTemp name: String) -> String? {
        guard !isChromiumHiddenTemp(name), let s = tempSuffix(name) else { return nil }
        let base = String(name.dropLast(s.suffix.count))
        if base.hasPrefix("Unconfirmed ") || base.isEmpty { return nil }
        return base
    }

    public static func displayName(forTemp name: String) -> String {
        finalName(ofTemp: name) ?? "Загрузка…"
    }
}

public enum IslDlSafariInfo {
    public struct Info: Equatable, Sendable {
        public var total: Int64?
        public var soFar: Int64?
    }

    public static func parse(_ data: Data) -> Info? {
        guard let obj = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        func num(_ k: String) -> Int64? {
            if let n = obj[k] as? NSNumber { return n.int64Value }
            return nil
        }
        let total = num("DownloadEntryProgressTotalToLoad")
        let soFar = num("DownloadEntryProgressBytesSoFar")
        if total == nil, soFar == nil { return nil }
        return Info(total: total.flatMap { $0 > 0 ? $0 : nil }, soFar: soFar)
    }
}

public enum IslDlFormat {
    public static func bytes(_ b: Int64) -> String {
        let v = Double(max(b, 0))
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var x = v, i = 0
        while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return "\(Int(x)) \(units[0])" }
        let s = String(format: x >= 100 ? "%.0f" : "%.1f", x).replacingOccurrences(of: ".", with: ",")
        return "\(s) \(units[i])"
    }

    public static func speed(_ bps: Double) -> String { bytes(Int64(max(bps, 0))) + "/с" }

    public static func eta(remaining: Int64, speed: Double) -> String? {
        guard speed > 1024, remaining > 0 else { return nil }
        let s = Int((Double(remaining) / speed).rounded(.up))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }
}
