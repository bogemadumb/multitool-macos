import Foundation
import AppKit
import ApplicationServices

public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var isRepeat: Bool

    public init(keyCode: UInt32, modifiers: UInt32, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    public static func modifiers(from flags: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= KeyCombo.cmd }
        if flags.contains(.maskShift) { m |= KeyCombo.shift }
        if flags.contains(.maskAlternate) { m |= KeyCombo.opt }
        if flags.contains(.maskControl) { m |= KeyCombo.ctrl }
        return m
    }

    public init(event: CGEvent) {
        self.init(keyCode: UInt32(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: Self.modifiers(from: event.flags),
                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }
}

public struct FinderContext: Equatable, Sendable {
    public var frontmostBundleID: String?
    public var focusIsText: Bool
    public var hasCut: Bool
    public var clipboardHasImage: Bool
    public var clipboardHasFiles: Bool

    public init(frontmostBundleID: String?, focusIsText: Bool = false, hasCut: Bool = false, clipboardHasImage: Bool = false, clipboardHasFiles: Bool = false) {
        self.frontmostBundleID = frontmostBundleID
        self.focusIsText = focusIsText
        self.hasCut = hasCut
        self.clipboardHasImage = clipboardHasImage
        self.clipboardHasFiles = clipboardHasFiles
    }

    public var isFinder: Bool { frontmostBundleID == FinderKeys.finderBundleID }
}

public enum FinderKeys {
    public static let finderBundleID = "com.apple.finder"
    public static let keyX: UInt32 = 7
    public static let keyV: UInt32 = 9
    public static let keyF2: UInt32 = 120
}

public enum FocusRole {
    public static func isTextInput(role: String?, subrole: String?) -> Bool {
        if let subrole, subrole == "AXSearchField" { return true }
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}

public protocol FocusInspecting: AnyObject {
    func focusIsTextInput(pid: Int32) -> Bool
}

public final class AXFocusInspector: FocusInspecting {
    public init() {}

    public func focusIsTextInput(pid: Int32) -> Bool {
        guard AXIsProcessTrusted(), pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let el = focused else { return false }
        let element = el as! AXUIElement
        func attr(_ name: String) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success ? v as? String : nil
        }
        return FocusRole.isTextInput(role: attr(kAXRoleAttribute), subrole: attr(kAXSubroleAttribute))
    }
}

public enum FinderRoute: Equatable, Sendable {
    case pass, swallow, cut, pasteMove, pasteImage
}

public enum FinderCutRouter {
    public static func route(_ k: KeyStroke, ctx: FinderContext, pasteImage: Bool) -> FinderRoute {
        guard ctx.isFinder, k.modifiers == KeyCombo.cmd, !ctx.focusIsText else { return .pass }
        switch k.keyCode {
        case FinderKeys.keyX:
            return k.isRepeat ? .swallow : .cut
        case FinderKeys.keyV:
            if ctx.hasCut { return k.isRepeat ? .swallow : .pasteMove }
            if pasteImage, ctx.clipboardHasImage, !ctx.clipboardHasFiles { return k.isRepeat ? .swallow : .pasteImage }
            return .pass
        default:
            return .pass
        }
    }
}

public enum FinderRenameRouter {
    public static func shouldRename(_ k: KeyStroke, ctx: FinderContext, combo: KeyCombo) -> Bool {
        guard ctx.isFinder, !combo.isNone, !ctx.focusIsText, !k.isRepeat else { return false }
        return k.keyCode == combo.keyCode && k.modifiers == combo.modifiers
    }

    public static func shouldSwallow(_ k: KeyStroke, ctx: FinderContext, combo: KeyCombo) -> Bool {
        guard ctx.isFinder, !combo.isNone, !ctx.focusIsText, k.isRepeat else { return false }
        return k.keyCode == combo.keyCode && k.modifiers == combo.modifiers
    }
}

public struct FinderCutState: Equatable, Sendable {
    public var paths: [String]
    public var changeCount: Int
}

public enum FinderMoveSkip: Equatable, Sendable {
    case missing, sameFolder, intoItself, nameExists

    public var title: String {
        switch self {
        case .missing: "файла больше нет"
        case .sameFolder: "уже в этой папке"
        case .intoItself: "нельзя переместить папку в саму себя"
        case .nameExists: "такое имя уже есть"
        }
    }
}

public struct FinderMovePlan: Equatable, Sendable {
    public var moves: [String]
    public var skipped: [(path: String, reason: FinderMoveSkip)]
    public var destination: String

    public static func == (a: FinderMovePlan, b: FinderMovePlan) -> Bool {
        a.moves == b.moves && a.destination == b.destination && a.skipped.map(\.path) == b.skipped.map(\.path) && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }
}

public protocol FinderFiles: AnyObject {
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func write(_ data: Data, to path: String) throws
}

public enum FinderPaths {
    public static func normalized(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func parent(_ p: String) -> String {
        let n = normalized(p)
        let d = (n as NSString).deletingLastPathComponent
        return d.isEmpty ? "/" : d
    }

    public static func parsePaths(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { normalized(String($0).trimmingCharacters(in: .whitespaces)) }.filter { $0.hasPrefix("/") }
    }
}

public enum FinderMovePlanner {
    public static func plan(sources: [String], destination rawDest: String, files: FinderFiles) -> FinderMovePlan {
        let dest = FinderPaths.normalized(rawDest)
        var seen = Set<String>()
        let list = sources.map(FinderPaths.normalized).filter { seen.insert($0).inserted }
        var moves: [String] = []
        var skipped: [(path: String, reason: FinderMoveSkip)] = []
        var takenNames = Set<String>()
        for src in list {
            let name = (src as NSString).lastPathComponent
            let target = (dest == "/" ? "" : dest) + "/" + name
            if list.contains(where: { $0 != src && src.hasPrefix($0 + "/") }) { continue }
            if !files.exists(src) { skipped.append((src, .missing)); continue }
            if FinderPaths.parent(src) == dest { skipped.append((src, .sameFolder)); continue }
            if dest == src || dest.hasPrefix(src + "/") { skipped.append((src, .intoItself)); continue }
            if files.exists(target) || !takenNames.insert(name).inserted { skipped.append((src, .nameExists)); continue }
            moves.append(src)
        }
        return FinderMovePlan(moves: moves, skipped: skipped, destination: dest)
    }
}

public enum ImageFileNamer {
    public static func name(date: Date, exists: (String) -> Bool, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let base = "Изображение " + f.string(from: date)
        var candidate = base + ".png"
        var n = 2
        while exists(candidate) {
            candidate = "\(base) \(n).png"
            n += 1
        }
        return candidate
    }

    public static func pngData(png: Data?, tiff: Data?) -> Data? {
        if let png { return png }
        guard let tiff, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

public protocol FinderScripting: AnyObject {
    func selectedPaths() -> [String]
    func currentFolderPath() -> String?
    func move(_ paths: [String], to folder: String) -> [Bool]
}

public enum FinderScripts {
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static let selection = """
    tell application "Finder"
        set sel to selection
        if sel is {} then return ""
        set out to {}
        repeat with i in sel
            set end of out to POSIX path of (i as alias)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as text
    end tell
    """

    public static let currentFolder = """
    tell application "Finder"
        if (count of Finder windows) is 0 then return POSIX path of (desktop as alias)
        try
            return POSIX path of ((target of front Finder window) as alias)
        on error
            return ""
        end try
    end tell
    """

    public static func move(_ paths: [String], to folder: String) -> String {
        let list = paths.map(quote).joined(separator: ", ")
        return """
        tell application "Finder"
            set dest to (POSIX file \(quote(folder))) as alias
            set results to {}
            repeat with p in {\(list)}
                try
                    move ((POSIX file (contents of p)) as alias) to dest
                    set end of results to "ok"
                on error
                    set end of results to "err"
                end try
            end repeat
            set AppleScript's text item delimiters to linefeed
            return results as text
        end tell
        """
    }

    public static func parseMoveResults(_ output: String, count: Int) -> [Bool] {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return (0..<count).map { $0 < lines.count && lines[$0] == "ok" }
    }
}

public final class FinderScriptingLive: FinderScripting {
    public init() {}

    private func run(_ source: String) -> String? {
        guard let s = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let r = s.executeAndReturnError(&err)
        if let err { Log.write("finder script error \(err[NSAppleScript.errorNumber] ?? "?")"); return nil }
        return r.stringValue ?? ""
    }

    public func selectedPaths() -> [String] { run(FinderScripts.selection).map(FinderPaths.parsePaths) ?? [] }

    public func currentFolderPath() -> String? {
        guard let s = run(FinderScripts.currentFolder) else { return nil }
        let p = FinderPaths.normalized(s.trimmingCharacters(in: .whitespacesAndNewlines))
        return p.hasPrefix("/") ? p : nil
    }

    public func move(_ paths: [String], to folder: String) -> [Bool] {
        guard !paths.isEmpty else { return [] }
        guard let out = run(FinderScripts.move(paths, to: folder)) else { return paths.map { _ in false } }
        return FinderScripts.parseMoveResults(out, count: paths.count)
    }
}

public final class FinderFilesLive: FinderFiles {
    public init() {}
    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
    public func write(_ data: Data, to path: String) throws { try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
}

public final class FinderCutPasteEngine {
    private let pasteboard: PasteboardDriving
    private let finder: FinderScripting
    private let files: FinderFiles
    private let now: () -> Date
    private let acknowledge: () -> Void
    public private(set) var cut: FinderCutState?
    public var onChange: ((FinderCutState?) -> Void)?
    public var onMessage: ((String) -> Void)?

    public init(pasteboard: PasteboardDriving, finder: FinderScripting, files: FinderFiles, now: @escaping () -> Date = Date.init, acknowledge: @escaping () -> Void = {}) {
        self.pasteboard = pasteboard
        self.finder = finder
        self.files = files
        self.now = now
        self.acknowledge = acknowledge
    }

    public var hasCut: Bool {
        guard let c = cut else { return false }
        if pasteboard.changeCount == c.changeCount { return true }
        cut = nil
        onChange?(nil)
        return false
    }

    public func cutSelection() {
        let paths = finder.selectedPaths()
        guard !paths.isEmpty else { onMessage?("Нечего вырезать: ничего не выделено"); return }
        let items = paths.map { PasteboardItemData(reps: [PBType.fileURL: Data(URL(fileURLWithPath: $0).absoluteString.utf8)]) }
        let count = pasteboard.write(items)
        cut = FinderCutState(paths: paths, changeCount: count)
        onChange?(cut)
        onMessage?("Вырезано: \(paths.count)")
    }

    public func cancel() {
        guard cut != nil else { return }
        cut = nil
        onChange?(nil)
        onMessage?("Вырезание отменено")
    }

    public func pasteMove() {
        guard hasCut, let c = cut else { return }
        guard let dest = finder.currentFolderPath() else { onMessage?("Сюда вставить нельзя: нет открытой папки"); return }
        let plan = FinderMovePlanner.plan(sources: c.paths, destination: dest, files: files)
        var moved = 0
        var failed = 0
        if !plan.moves.isEmpty {
            let res = finder.move(plan.moves, to: plan.destination)
            moved = res.filter { $0 }.count
            failed = res.count - moved
        }
        cut = nil
        pasteboard.clear()
        acknowledge()
        onChange?(nil)
        var msg = moved > 0 ? "Перемещено: \(moved)" : "Ничего не перемещено"
        let skipped = plan.skipped.filter { $0.reason != .sameFolder }
        if !skipped.isEmpty { msg += " · пропущено \(skipped.count): \(skipped[0].reason.title)" }
        if failed > 0 { msg += " · ошибок Finder: \(failed)" }
        if moved == 0, skipped.isEmpty, failed == 0, !plan.skipped.isEmpty { msg = "Файлы уже в этой папке" }
        onMessage?(msg)
    }

    public func pasteImage() {
        let items = pasteboard.readItems(types: [PBType.png, PBType.tiff])
        let png = items.compactMap { $0.reps[PBType.png] }.first
        let tiff = items.compactMap { $0.reps[PBType.tiff] }.first
        guard let data = ImageFileNamer.pngData(png: png, tiff: tiff) else { return }
        guard let dest = finder.currentFolderPath() else { onMessage?("Сюда сохранить нельзя: нет открытой папки"); return }
        let name = ImageFileNamer.name(date: now(), exists: { files.exists(dest + "/" + $0) })
        do {
            try files.write(data, to: (dest == "/" ? "" : dest) + "/" + name)
            onMessage?("Сохранено: \(name)")
        } catch {
            onMessage?("Не удалось сохранить картинку: \(error.localizedDescription)")
        }
    }
}
