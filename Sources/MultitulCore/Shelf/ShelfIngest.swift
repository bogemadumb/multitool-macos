import Foundation
import CryptoKit

public enum ShelfPaths {
    public static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardized.path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func isFileReference(_ path: String) -> Bool { path.hasPrefix("/.file/id=") }

    public static func isInside(_ path: String, dir: String) -> Bool {
        let d = normalize(dir)
        let p = normalize(path)
        return p.hasPrefix(d + "/")
    }

    public static func displayDirectory(_ path: String, home: String = NSHomeDirectory()) -> String {
        let dir = (normalize(path) as NSString).deletingLastPathComponent
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }
}

public enum ShelfIngest {
    public static func sha(_ s: String) -> String { sha(Data(s.utf8)) }
    public static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static let linkSchemes: Set<String> = ["http", "https", "ftp", "mailto", "tel"]

    static func looksLikeLink(_ s: String) -> Bool {
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), linkSchemes.contains(scheme) else { return false }
        return scheme == "mailto" || scheme == "tel" || u.host?.isEmpty == false
    }

    public static func parse(_ items: [PasteboardItemData]) -> [ShelfIncoming] {
        var out: [ShelfIncoming] = []
        var seenFiles = Set<String>()
        for item in items {
            let reps = item.reps
            if let s = reps[PBType.fileURL].flatMap({ String(data: $0, encoding: .utf8) }), let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.isFileURL {
                let p = ShelfPaths.normalize(u.path)
                if !ShelfPaths.isFileReference(p), seenFiles.insert(p).inserted { out.append(.file(path: p, owned: false)) }
                continue
            }
            if let s = reps[PBType.url].flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                if let u = URL(string: s), u.isFileURL {
                    let p = ShelfPaths.normalize(u.path)
                    if !ShelfPaths.isFileReference(p), seenFiles.insert(p).inserted { out.append(.file(path: p, owned: false)) }
                    continue
                }
                if reps[PBType.png] == nil && reps[PBType.tiff] == nil {
                    out.append(.url(s, title: reps["public.url-name"].flatMap { String(data: $0, encoding: .utf8) }))
                    continue
                }
            }
            if let d = reps[PBType.png] { out.append(.image(d, ext: "png", name: nil)); continue }
            if let d = reps[PBType.tiff] { out.append(.image(d, ext: "tiff", name: nil)); continue }
            if let t = reps[PBType.utf8].flatMap({ String(data: $0, encoding: .utf8) }) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                out.append(looksLikeLink(trimmed) ? .url(trimmed, title: nil) : .text(t))
            }
        }
        return out
    }

    public static func titleLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > ShelfLimits.titleLength ? String(line.prefix(ShelfLimits.titleLength)) + "…" : line
    }

    public static func urlTitle(_ s: String, given: String?) -> String {
        if let g = given?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty { return titleLine(g) }
        guard let u = URL(string: s) else { return titleLine(s) }
        if let h = u.host, !h.isEmpty {
            let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            let path = u.path == "/" ? "" : u.path
            return titleLine(host + path)
        }
        return titleLine(s)
    }

    public static func normalizedURLKey(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        while c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path == "/" && c.query == nil && c.fragment == nil { c.path = "" }
        return c.string ?? s
    }

    public static func candidate(_ incoming: ShelfIncoming, fs: ShelfFileSystem, source: String? = nil) -> ShelfCandidate? {
        switch incoming {
        case .file(let raw, let owned):
            let path = ShelfPaths.normalize(raw)
            guard fs.exists(path) else { return nil }
            let dir = fs.isDirectory(path)
            let name = (path as NSString).lastPathComponent
            return ShelfCandidate(kind: dir ? .folder : .file, hash: sha("f:" + path), title: name.isEmpty ? path : name,
                                  detail: owned ? "" : ShelfPaths.displayDirectory(path), size: dir ? 0 : fs.fileSize(path), path: path, owned: owned,
                                  ext: (name as NSString).pathExtension.lowercased(), sourceBundle: source,
                                  payload: ShelfPayload(bookmark: fs.makeBookmark(path)))
        case .text(let t):
            let bytes = t.utf8.count
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bytes <= ShelfLimits.maxTextBytes else { return nil }
            return ShelfCandidate(kind: .text, hash: sha("t:" + t), title: titleLine(t), detail: "\(t.count) симв.", size: bytes, sourceBundle: source,
                                  payload: ShelfPayload(body: t))
        case .url(let s, let title):
            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            return ShelfCandidate(kind: .url, hash: sha("u:" + normalizedURLKey(clean)), title: urlTitle(clean, given: title), detail: clean, size: clean.utf8.count,
                                  sourceBundle: source, payload: ShelfPayload(body: clean))
        case .image(let d, let ext, let name):
            guard !d.isEmpty, d.count <= ShelfLimits.maxImageBytes else { return nil }
            let e = ext.lowercased()
            let label = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Изображение"
            return ShelfCandidate(kind: .image, hash: sha(d), title: label, detail: e.uppercased(), size: d.count, ext: e, sourceBundle: source,
                                  payload: ShelfPayload(data: d))
        }
    }
}
