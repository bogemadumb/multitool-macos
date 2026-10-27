import Foundation

public struct AppcastItem: Equatable, Sendable {
    public var title = ""
    public var version: String?
    public var shortVersion: String?
    public var pubDate: Date?
    public var downloadURL: URL?
    public var length: Int64?
    public var mimeType: String?
    public var minimumSystemVersion: String?
    public var maximumSystemVersion: String?
    public var releaseNotesURL: URL?
    public var descriptionHTML: String?
    public var channel: String?
    public var os: String?
    public var isCritical = false
    public var link: URL?

    public init() {}

    public var displayVersion: String { shortVersion ?? version ?? "" }
    public var comparableVersion: String { version ?? shortVersion ?? "" }
}

public enum AppcastError: Error, Equatable, Sendable {
    case malformed(String)
}

public enum AppcastParser {
    public static func parse(_ text: String) throws -> [AppcastItem] {
        guard let data = text.data(using: .utf8) else { throw AppcastError.malformed("кодировка") }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        if !parser.parse() || delegate.failed {
            if delegate.items.isEmpty { throw AppcastError.malformed(parser.parserError?.localizedDescription ?? "xml") }
        }
        return delegate.items
    }

    static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        var failed = false
        private var current: AppcastItem?
        private var path: [String] = []
        private var text = ""
        private var deltaDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            switch name {
            case "item":
                current = AppcastItem()
            case "sparkle:deltas":
                deltaDepth += 1
            case "enclosure" where deltaDepth == 0:
                guard current != nil else { return }
                if let u = attributes["url"] { current?.downloadURL = URL(string: u.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let l = attributes["length"], let n = Int64(l) { current?.length = n }
                current?.mimeType = attributes["type"]
                if let v = attributes["sparkle:version"], !v.isEmpty { current?.version = v }
                if let v = attributes["sparkle:shortVersionString"], !v.isEmpty { current?.shortVersion = v }
                if let v = attributes["sparkle:os"], !v.isEmpty { current?.os = v }
                if let v = attributes["sparkle:minimumSystemVersion"], !v.isEmpty { current?.minimumSystemVersion = v }
            case "sparkle:criticalUpdate":
                current?.isCritical = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { _ = path.popLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current != nil else { return }
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            switch name {
            case "item":
                if let item = current { items.append(item) }
                current = nil
            case "sparkle:deltas":
                deltaDepth = max(0, deltaDepth - 1)
            case "title" where parent == "item": current?.title = value
            case "pubDate" where parent == "item": current?.pubDate = AppcastParser.date(value)
            case "description" where parent == "item": if !value.isEmpty { current?.descriptionHTML = value }
            case "link" where parent == "item": current?.link = URL(string: value)
            case "sparkle:version" where parent == "item": if !value.isEmpty { current?.version = value }
            case "sparkle:shortVersionString" where parent == "item": if !value.isEmpty { current?.shortVersion = value }
            case "sparkle:minimumSystemVersion": if !value.isEmpty { current?.minimumSystemVersion = value }
            case "sparkle:maximumSystemVersion": if !value.isEmpty { current?.maximumSystemVersion = value }
            case "sparkle:releaseNotesLink": if current?.releaseNotesURL == nil { current?.releaseNotesURL = URL(string: value) }
            case "sparkle:channel": if !value.isEmpty { current?.channel = value }
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
    }
}

public enum AppcastSelector {
    public static func eligible(_ item: AppcastItem, osVersion: String, allowedChannels: Set<String>, includePrerelease: Bool) -> Bool {
        guard !item.comparableVersion.isEmpty, item.downloadURL != nil || item.link != nil else { return false }
        if let os = item.os?.lowercased(), os != "macos" && os != "osx" { return false }
        if let ch = item.channel, !allowedChannels.contains(ch) { return false }
        if let min = item.minimumSystemVersion, !min.isEmpty, AppVersion.isNewer(min, than: osVersion) { return false }
        if let max = item.maximumSystemVersion, !max.isEmpty, AppVersion.isNewer(osVersion, than: max) { return false }
        if !includePrerelease && AppVersion(item.displayVersion).isPreRelease { return false }
        return true
    }

    public static func latest(_ items: [AppcastItem], osVersion: String, allowedChannels: Set<String> = [], includePrerelease: Bool = false) -> AppcastItem? {
        var best: AppcastItem?
        for item in items where eligible(item, osVersion: osVersion, allowedChannels: allowedChannels, includePrerelease: includePrerelease) {
            if let b = best {
                if AppVersion.compare(AppVersion(item.comparableVersion), AppVersion(b.comparableVersion)) > 0 { best = item }
            } else {
                best = item
            }
        }
        return best
    }
}

public enum UpdateDecision {
    // Build numbers decide when both sides have them; the marketing version is the second opinion for feeds that only carry one of the two.
    public static func isNewer(_ item: AppcastItem, installedBuild: String, installedShort: String) -> Bool {
        if let v = item.version, !installedBuild.isEmpty, AppVersion.isNewer(v, than: installedBuild) { return true }
        let short = item.shortVersion ?? item.version
        if let s = short, !installedShort.isEmpty, AppVersion.isNewer(s, than: installedShort) { return true }
        return false
    }
}
