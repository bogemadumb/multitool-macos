import Foundation
import AppKit
import CryptoKit
import ImageIO

public enum ClipSkipReason: Equatable, Sendable {
    case empty, concealed, transient, ignoredApp, sensitive, typeDisabled, tooLarge
}

public enum ClipCaptureResult: Equatable, Sendable {
    case record(ClipCandidate)
    case skip(ClipSkipReason)
}

public enum SensitiveText {
    private static let tokenPrefixes = ["sk-", "sk_live_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "npm_", "hf_", "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "AIza", "AKIA", "ASIA", "ya29."]

    public static func looksSecret(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if s.contains("-----BEGIN") && s.contains("PRIVATE KEY") { return true }
        if s.contains("\n") || s.contains(" ") || s.contains("\t") {
            if s.lowercased().hasPrefix("bearer "), s.count > 20, !s.dropFirst(7).contains(" ") { return true }
            return false
        }
        if s.contains("://") || s.hasPrefix("/") || s.hasPrefix("~") { return false }
        if let at = s.firstIndex(of: "@"), s[at...].contains(".") { return false }
        if s.hasPrefix("eyJ"), s.split(separator: ".").count == 3, s.count > 30 { return true }
        for p in tokenPrefixes where s.hasPrefix(p) && s.count >= p.count + 12 { return true }
        let scalars = s.unicodeScalars
        let hasLower = s.contains { $0.isLowercase }
        let hasUpper = s.contains { $0.isUppercase }
        let hasDigit = s.contains { $0.isNumber }
        let hasSymbol = scalars.contains { !CharacterSet.alphanumerics.contains($0) }
        if (8...64).contains(s.count), hasLower, hasUpper, hasDigit, hasSymbol { return true }
        if s.count >= 24, s.count <= 256, hasDigit, hasLower || hasUpper, scalars.allSatisfy({ $0.isASCII }),
           !s.contains("."), entropy(s) >= 4.0 { return true }
        return false
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0.0) { $0 - (Double($1) / n) * log2(Double($1) / n) }
    }
}

public enum ClipCapture {
    static let fileSchemePrefix = "file://"

    public static func wantedTypes(_ s: ClipSettings) -> Set<String> {
        var t: Set<String> = [PBType.utf8]
        if s.keepRich { t.formUnion([PBType.rtf, PBType.html]) }
        if s.keepImages { t.formUnion([PBType.png, PBType.tiff]) }
        if s.keepFiles { t.insert(PBType.fileURL) }
        if s.keepColors { t.insert(PBType.color) }
        return t
    }

    public static func evaluate(_ snap: ClipSnapshot, settings s: ClipSettings, ownBundleID: String? = nil) -> ClipCaptureResult {
        let types = Set(snap.types)
        if s.skipConcealed, !types.isDisjoint(with: PBType.concealedMarkers) { return .skip(.concealed) }
        if s.skipTransient, !types.isDisjoint(with: PBType.transientMarkers) { return .skip(.transient) }
        if let b = snap.source?.bundleID, b == ownBundleID || s.ignoredApps.contains(b) { return .skip(.ignoredApp) }
        if snap.items.isEmpty || snap.items.allSatisfy({ $0.reps.values.allSatisfy(\.isEmpty) }) { return .skip(.empty) }
        guard let cand = build(snap, settings: s) else {
            let hasAny = !types.isDisjoint(with: [PBType.utf8, PBType.rtf, PBType.html, PBType.png, PBType.tiff, PBType.fileURL, PBType.color])
            return .skip(hasAny ? .typeDisabled : .empty)
        }
        let limit = s.maxItemKB * 1024
        if cand.size > limit { return .skip(.tooLarge) }
        if cand.kind == .text || cand.kind == .rich {
            let text = textOf(cand) ?? ""
            if text.count > s.maxTextChars { return .skip(.tooLarge) }
            if s.skipSensitive, SensitiveText.looksSecret(text) { return .skip(.sensitive) }
        }
        return .record(cand)
    }

    static func textOf(_ c: ClipCandidate) -> String? {
        c.reps.first { $0.type == PBType.utf8 }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    public static func fileURLString(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), s.hasPrefix(fileSchemePrefix),
              let url = URL(string: s) else { return nil }
        return url.path
    }

    public static func build(_ snap: ClipSnapshot, settings s: ClipSettings) -> ClipCandidate? {
        let items = snap.items
        let paths = items.compactMap { $0.reps[PBType.fileURL].flatMap(fileURLString) }
        let text = items.compactMap(\.string).first(where: { !$0.isEmpty })
        let rtf = items.compactMap { $0.reps[PBType.rtf] }.first
        let html = items.compactMap { $0.reps[PBType.html] }.first
        let png = items.compactMap { $0.reps[PBType.png] }.first
        let tiff = items.compactMap { $0.reps[PBType.tiff] }.first
        let color = items.compactMap { $0.reps[PBType.color] }.first

        if !paths.isEmpty {
            guard s.keepFiles else { return nil }
            var reps: [ClipRep] = []
            for (i, it) in items.enumerated() { if let d = it.reps[PBType.fileURL] { reps.append(ClipRep(index: i, type: PBType.fileURL, data: d)) } }
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let title = paths.count == 1 ? names[0] : "\(paths.count) файл." + " · " + names.prefix(3).joined(separator: ", ")
            return make(.files, key: "f:" + paths.joined(separator: "\u{1}"), title: title, search: paths.joined(separator: " ").lowercased(), reps: reps, snap)
        }
        if (png != nil || tiff != nil), text == nil {
            guard s.keepImages else { return nil }
            let main = png ?? tiff!
            let type = png != nil ? PBType.png : PBType.tiff
            let dim = imageSize(main)
            let title = dim.map { "Изображение \(Int($0.width))×\(Int($0.height))" } ?? "Изображение"
            return make(.image, key: "i:" + sha(main), title: title, search: "изображение картинка image " + (snap.source?.name ?? "").lowercased(), reps: [ClipRep(index: 0, type: type, data: main)], snap)
        }
        if let color, text == nil {
            guard s.keepColors else { return nil }
            let hex = colorHex(color)
            return make(.color, key: "c:" + sha(color), title: hex ?? "Цвет", search: "цвет color " + (hex ?? "").lowercased(), reps: [ClipRep(index: 0, type: PBType.color, data: color)], snap)
        }
        var plain = text
        if plain == nil, s.keepRich, let r = rtf, let str = try? NSAttributedString(data: r, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string, !str.isEmpty { plain = str }
        guard let plain else { return nil }
        let isRich = s.keepRich && (rtf != nil || html != nil)
        var reps = [ClipRep(index: 0, type: PBType.utf8, data: Data(plain.utf8))]
        if isRich {
            if let r = rtf { reps.append(ClipRep(index: 0, type: PBType.rtf, data: r)) }
            if let h = html { reps.append(ClipRep(index: 0, type: PBType.html, data: h)) }
        }
        return make(isRich ? .rich : .text, key: "t:" + plain, title: titleLine(plain), search: String(plain.prefix(20_000)).lowercased(), reps: reps, snap)
    }

    private static func make(_ kind: ClipKind, key: String, title: String, search: String, reps: [ClipRep], _ snap: ClipSnapshot) -> ClipCandidate {
        ClipCandidate(kind: kind, hash: sha(Data(key.utf8)), title: title, search: search, size: reps.reduce(0) { $0 + $1.data.count }, reps: reps, source: snap.source)
    }

    public static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    public static func titleLine(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? Substring(text)
        let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    public static func imageSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    public static func colorHex(_ data: Data) -> String? {
        guard let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
              let rgb = c.usingColorSpace(.sRGB) else { return nil }
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(rgb.redComponent), b(rgb.greenComponent), b(rgb.blueComponent))
    }
}
