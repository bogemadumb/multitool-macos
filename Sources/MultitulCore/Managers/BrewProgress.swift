import Foundation

public enum BrewEvent: Equatable, Sendable {
    case plan(count: Int)
    case planned(name: String, from: String, to: String)
    case fetching(String)
    case downloading(String)
    case downloaded(String)
    case percent(Double)
    case pouring(String)
    case upgrading(String)
    case installing(String)
    case uninstalling(String)
    case step(String)
    case caveats
    case summary(String)
    case succeeded(String)
    case cleanup
    case section(String)
    case warning(String)
    case error(String)
    case passwordPrompt
    case plain(String)
}

public enum BrewProgressParser {
    private static let successRegex = try! NSRegularExpression(pattern: #"^(?:🍺\s*)?(\S+) was successfully (?:installed|upgraded|uninstalled)!?$"#)
    private static let planRegex = try! NSRegularExpression(pattern: #"^==> (?:Upgrading|Installing|Uninstalling) (\d+) (?:outdated )?(?:packages?|formulae|formula|casks?)"#)
    private static let plannedRegex = try! NSRegularExpression(pattern: #"^(\S+) (\S+(?:, \S+)*) -> (\S+)$"#)
    private static let percentRegex = try! NSRegularExpression(pattern: #"(?:^|\s)#*\s*(\d{1,3}(?:\.\d+)?)%\s*$"#)

    private static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func rest(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ raw: String) -> BrewEvent {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return .plain("") }
        if line.hasPrefix("Error:") { return .error(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
        if line.hasPrefix("Warning:") { return .warning(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
        if isPasswordPrompt(line) { return .passwordPrompt }
        if line.hasPrefix("==>") {
            if let m = match(planRegex, line), let n = Int(m[1]) { return .plan(count: n) }
            let body = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let n = rest(body, "Fetching downloads for:") { return .fetching(n) }
            if let n = rest(body, "Fetching") { return .fetching(n) }
            if let n = rest(body, "Downloading from") { return .downloading(n) }
            if let n = rest(body, "Downloading") { return .downloading(n) }
            if let n = rest(body, "Pouring") { return .pouring(n) }
            if let n = rest(body, "Upgrading") { return .upgrading(n) }
            if let n = rest(body, "Installing Cask") { return .installing(n) }
            if let n = rest(body, "Installing") { return .installing(n) }
            if let n = rest(body, "Uninstalling Cask") { return .uninstalling(n) }
            if let n = rest(body, "Uninstalling") { return .uninstalling(n) }
            if body.hasPrefix("Caveats") { return .caveats }
            if body.hasPrefix("Summary") { return .summary("") }
            if body.hasPrefix("Running `brew cleanup") || body.hasPrefix("Autoremoving") { return .cleanup }
            for verb in ["Moving", "Linking", "Backing", "Removing", "Purging", "Unlinking", "Verifying", "Installing", "Extracting"] where body.hasPrefix(verb) { return .step(body) }
            return .section(body)
        }
        if line.unicodeScalars.first == "\u{2714}" {
            let skip: Set<Unicode.Scalar> = ["\u{2714}", "\u{FE0E}", "\u{FE0F}", " "]
            let body = String(String.UnicodeScalarView(line.unicodeScalars.drop(while: { skip.contains($0) })))
            if body.hasPrefix("Bottle Manifest") { return .step(body) }
            if body.hasPrefix("Bottle ") || body.hasPrefix("Cask ") {
                let parts = body.split(separator: " ")
                return .downloaded(parts.count >= 2 ? String(parts[1]) : body)
            }
            return .plain(line)
        }
        if let m = match(successRegex, line) { return .succeeded(m[1]) }
        if line.hasPrefix("🍺") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.contains(" files, ") { return .summary(body) }
            return .plain(line)
        }
        if line.contains(": ") && line.contains(" files, ") && line.hasPrefix("/") { return .summary(line) }
        if let m = match(plannedRegex, line), !line.contains("/") { return .planned(name: m[1], from: m[2], to: m[3]) }
        if let m = match(percentRegex, line), let v = Double(m[1]), v <= 100 { return .percent(v) }
        return .plain(line)
    }

    public static func isPasswordPrompt(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.hasPrefix("password:") || l.hasPrefix("==> password") { return true }
        if l.contains("sudo:") && (l.contains("password") || l.contains("terminal") || l.contains("tty")) { return true }
        if l.contains("failure while executing") && l.contains("/usr/bin/sudo") { return true }
        return false
    }
}

public enum BrewFailureKind: String, Equatable, Sendable {
    case locked, offline, needsPassword, notFound, permission, inUse, checksum, diskFull, timedOut, missingBrew, other

    public var title: String {
        switch self {
        case .locked: "Homebrew уже занят другой командой"
        case .offline: "Нет связи с интернетом"
        case .needsPassword: "Нужен пароль администратора"
        case .notFound: "Пакет не найден"
        case .permission: "Нет прав на папку Homebrew"
        case .inUse: "Пакет нужен другим пакетам"
        case .checksum: "Не сошлась контрольная сумма"
        case .diskFull: "Не хватает места на диске"
        case .timedOut: "Команда не уложилась во время"
        case .missingBrew: "Homebrew не установлен"
        case .other: "Ошибка Homebrew"
        }
    }

    public var hint: String {
        switch self {
        case .locked: "Дождись окончания другой команды brew (или закрой её) и повтори"
        case .offline: "Проверь соединение или VPN и повтори"
        case .needsPassword: "Этому пакету нужен sudo: открой команду в Terminal и введи пароль там"
        case .notFound: "Проверь название: поиск покажет точное имя формулы или cask"
        case .permission: "Права на /opt/homebrew нужно починить в Terminal: brew doctor подскажет"
        case .inUse: "Сначала убери зависящие пакеты или удали с ключом игнорирования зависимостей"
        case .checksum: "Повтори позже или сначала выполни brew update"
        case .diskFull: "Освободи место (cleanup) и повтори"
        case .timedOut: "Повтори; тяжёлые обновления можно запустить в Terminal"
        case .missingBrew: "Поставь Homebrew командой с сайта brew.sh"
        case .other: ""
        }
    }
}

public struct BrewFailure: Equatable, Sendable {
    public var kind: BrewFailureKind
    public var message: String
    public var blockers: [String]

    public var summary: String {
        let hint = kind.hint
        return hint.isEmpty ? "\(kind.title): \(message)" : "\(kind.title). \(hint)"
    }
}

public enum BrewErrorClassifier {
    public static func classify(_ output: String, status: Int32 = 1, timedOut: Bool = false) -> BrewFailure {
        let lower = output.lowercased()
        let allLines: [String] = output.split(whereSeparator: \.isNewline).map { String($0) }
        var firstError = allLines.first ?? ""
        if let e = allLines.first(where: { $0.hasPrefix("Error:") }) { firstError = String(e.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        func f(_ k: BrewFailureKind, blockers: [String] = []) -> BrewFailure { BrewFailure(kind: k, message: firstError, blockers: blockers) }
        if timedOut { return f(.timedOut) }
        if status == 127 && lower.contains("cannot launch") { return f(.missingBrew) }
        if lower.contains("already locked") || lower.contains("already in progress") || lower.contains("another active homebrew") || lower.contains("another `brew") {
            return f(.locked)
        }
        if BrewProgressParser.isPasswordPrompt(output) || output.split(whereSeparator: \.isNewline).contains(where: { BrewProgressParser.isPasswordPrompt(String($0)) }) {
            return f(.needsPassword)
        }
        if lower.contains("refusing to uninstall") || lower.contains("because it is required by") {
            return f(.inUse, blockers: requiredBy(output))
        }
        if lower.contains("no available formula") || lower.contains("no formulae or casks found") || lower.contains("no cask with this name") || lower.contains("no available cask")
            || lower.contains("no formula or cask found") {
            return f(.notFound)
        }
        if lower.contains("sha256 mismatch") || lower.contains("checksum") && lower.contains("mismatch") { return f(.checksum) }
        if lower.contains("no space left on device") { return f(.diskFull) }
        for marker in ["could not resolve host", "failed to connect", "network is unreachable", "internet connection appears to be offline", "operation timed out",
                       "failed to download resource", "curl: (6)", "curl: (7)", "curl: (28)", "unable to access 'https://", "ssl connect error", "connection reset"] where lower.contains(marker) {
            return f(.offline)
        }
        if lower.contains("permission denied") || lower.contains("not writable by your user") || lower.contains("operation not permitted") { return f(.permission) }
        return f(.other)
    }

    // "because it is required by curl, wget, which are currently installed."
    static func requiredBy(_ output: String) -> [String] {
        guard let r = output.range(of: "required by ") else { return [] }
        let tail = output[r.upperBound...]
        let list = tail.prefix { $0 != "\n" }
        let cut = list.range(of: ", which") ?? list.range(of: ", which are") ?? list.range(of: ", which is")
        let names = cut.map { String(list[..<$0.lowerBound]) } ?? String(list)
        return names.components(separatedBy: CharacterSet(charactersIn: ", ")).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { BrewName.isValid($0) && $0 != "and" && $0 != "which" }
    }
}

public enum BrewPackageStepState: Equatable, Sendable {
    case waiting, working, done
}

public struct BrewProgressStep: Equatable, Sendable {
    public var name: String
    public var state: BrewPackageStepState
    public var from: String
    public var to: String
}

// Folds the line stream of install/upgrade/uninstall into a fraction, a status line and the final verdict.
public struct BrewProgressTracker: Equatable, Sendable {
    public private(set) var steps: [BrewProgressStep] = []
    public private(set) var expectedCount = 0
    public private(set) var current: String?
    public private(set) var phase = ""
    public private(set) var percent: Double?
    public private(set) var errors: [String] = []
    public private(set) var warnings: [String] = []
    public private(set) var needsPassword = false
    public private(set) var succeededNames: [String] = []
    public private(set) var caveats: [String] = []
    private var inCaveats = false

    public init() {}

    public var total: Int { max(expectedCount, steps.count) }
    public var doneCount: Int { steps.filter { $0.state == .done }.count }

    public var fraction: Double? {
        guard total > 0 else { return nil }
        var done = Double(doneCount)
        if let p = percent, steps.contains(where: { $0.state == .working }) { done += min(p, 100) / 100 * 0.5 }
        return min(done / Double(total), 1)
    }

    public var statusLine: String {
        if needsPassword { return "Нужен пароль администратора" }
        if let current { return phase.isEmpty ? current : "\(phase): \(current)" }
        return phase
    }

    private mutating func begin(_ name: String) {
        for i in steps.indices where steps[i].state == .working && steps[i].name != name { steps[i].state = .done }
        if let i = steps.firstIndex(where: { $0.name == name }) {
            steps[i].state = .working
        } else {
            steps.append(BrewProgressStep(name: name, state: .working, from: "", to: ""))
        }
        current = name
        percent = nil
    }

    private mutating func finish(_ name: String) {
        if let i = steps.firstIndex(where: { $0.name == name }) { steps[i].state = .done }
    }

    public mutating func feed(_ line: String) {
        let ev = BrewProgressParser.parse(line)
        if inCaveats {
            switch ev {
            case .section, .summary, .upgrading, .installing, .uninstalling, .pouring, .cleanup: inCaveats = false
            default:
                if case .plain(let t) = ev, !t.isEmpty { caveats.append(t) }
                return
            }
        }
        switch ev {
        case .plan(let n):
            expectedCount = n
            phase = "План"
        case .planned(let name, let from, let to):
            if !steps.contains(where: { $0.name == name }) { steps.append(BrewProgressStep(name: name, state: .waiting, from: from, to: to)) }
        case .fetching(let n):
            phase = "Загрузка"
            if !n.contains(" ") && current == nil { current = n }
        case .downloading(let u):
            phase = "Загрузка"
            percent = nil
            if current == nil { current = (u as NSString).lastPathComponent }
        case .downloaded(let n):
            phase = "Загружено"
            if current == nil { current = n }
        case .percent(let p):
            percent = p
        case .pouring:
            phase = "Распаковка"
        case .upgrading(let n):
            phase = "Обновление"
            if !n.contains(" ") { begin(n) }
        case .installing(let n):
            phase = "Установка"
            begin(n)
        case .uninstalling(let n):
            phase = "Удаление"
            begin(n)
        case .step(let s):
            phase = s
        case .caveats:
            inCaveats = true
        case .summary:
            if let c = current { finish(c) }
        case .succeeded(let n):
            succeededNames.append(n)
            if steps.contains(where: { $0.name == n }) { finish(n) } else { steps.append(BrewProgressStep(name: n, state: .done, from: "", to: "")) }
        case .cleanup:
            phase = "Уборка"
        case .section(let s):
            phase = s
        case .warning(let w):
            warnings.append(w)
        case .error(let e):
            errors.append(e)
        case .passwordPrompt:
            needsPassword = true
        case .plain:
            break
        }
    }

    public mutating func finishAll() {
        for i in steps.indices where steps[i].state != .done && errors.isEmpty { steps[i].state = .done }
        current = nil
        percent = nil
    }
}
