import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(text: String, indent: Int)
    case numbered(number: Int, text: String)
    case checkbox(done: Bool, text: String)
    case quote(String)
    case code(language: String, text: String)
    case rule
}

public enum MarkdownParser {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLang = ""
        var code: [String] = []

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }

        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(language: codeLang, text: code.joined(separator: "\n")))
                    code = []; codeLang = ""; inCode = false
                } else {
                    flush()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode { code.append(raw); continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) || trimmed.allSatisfy({ $0 == "*" }) || trimmed.allSatisfy({ $0 == "_" }) {
                flush(); out.append(.rule); continue
            }
            if let h = heading(trimmed) { flush(); out.append(h); continue }
            if trimmed.hasPrefix(">") {
                flush()
                out.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let item = listItem(trimmed, indent: indent) { flush(); out.append(item); continue }
            paragraph.append(trimmed)
        }
        if inCode { out.append(.code(language: codeLang, text: code.joined(separator: "\n"))) }
        flush()
        return out
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String, indent: Int) -> MarkdownBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = String(line.dropFirst(2))
            if rest.hasPrefix("[ ] ") { return .checkbox(done: false, text: String(rest.dropFirst(4))) }
            if rest.lowercased().hasPrefix("[x] ") { return .checkbox(done: true, text: String(rest.dropFirst(4))) }
            return .bullet(text: rest, indent: indent)
        }
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 4, let n = Int(digits) {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return .numbered(number: n, text: String(rest.dropFirst(2))) }
        }
        return nil
    }
}
