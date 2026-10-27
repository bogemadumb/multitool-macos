import Foundation
import CoreGraphics

public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var isOnline: Bool
    public var isBuiltin: Bool
    public var isMain: Bool
    public var vendor: UInt32
    public var width: Int
    public var height: Int

    public init(id: UInt32, isOnline: Bool, isBuiltin: Bool = false, isMain: Bool = false, vendor: UInt32 = 0, width: Int = 0, height: Int = 0) {
        self.id = id
        self.isOnline = isOnline
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.vendor = vendor
        self.width = width
        self.height = height
    }
}

public enum DisplayKind: Equatable, Sendable {
    case builtin
    case externalActive
    case externalDisabled
    case placeholder
}

public enum DisplayApplyResult: Equatable, Sendable {
    case ok
    case failed(String)
}

public protocol DisplayProviding {
    var canSwitch: Bool { get }
    var canList: Bool { get }
    func displays() -> [DisplayInfo]
    func setEnabled(_ ids: [UInt32], enabled: Bool) -> DisplayApplyResult
}

public enum MonitorCommand: String, CaseIterable, Sendable {
    case status, off, on, toggle
}

public enum MonitorPlan: Equatable, Sendable {
    case apply(ids: [UInt32], enabled: Bool)
    case unchanged(String)
    case refuse(String)
}

public enum MonitorState: Equatable, Sendable {
    case on, off
}

public enum MonitorOutcome: Equatable, Sendable {
    case changed(String)
    case unchanged(String)
    case failed(String)

    public var message: String {
        switch self {
        case .changed(let m), .unchanged(let m), .failed(let m): m
        }
    }
    public var isFailure: Bool { if case .failed = self { true } else { false } }
}

public enum MonitorLogic {
    // A disabled display stays in CGSGetDisplayList with its id and vendor but leaves the online list and collapses to 1x1.
    // vendor == 0 filters out the service placeholder macOS keeps in the list (id with 1x1 and no vendor).
    public static func classify(_ d: DisplayInfo) -> DisplayKind {
        if d.isBuiltin { return .builtin }
        if d.isOnline { return .externalActive }
        if d.vendor != 0 { return .externalDisabled }
        return .placeholder
    }

    public static func activeExternals(_ all: [DisplayInfo]) -> [DisplayInfo] {
        all.filter { classify($0) == .externalActive }
    }

    public static func disabledExternals(_ all: [DisplayInfo]) -> [DisplayInfo] {
        all.filter { classify($0) == .externalDisabled }
    }

    public static func state(_ all: [DisplayInfo]) -> MonitorState {
        disabledExternals(all).isEmpty ? .on : .off
    }

    public static func plan(_ command: MonitorCommand, displays all: [DisplayInfo], protected: Set<UInt32> = []) -> MonitorPlan {
        switch command {
        case .status: return .unchanged(summary(all))
        case .off: return planOff(all, protected: protected)
        case .on: return planOn(all)
        case .toggle: return disabledExternals(all).isEmpty ? planOff(all, protected: protected) : planOn(all)
        }
    }

    static func planOff(_ all: [DisplayInfo], protected: Set<UInt32>) -> MonitorPlan {
        let targets = activeExternals(all).filter { !protected.contains($0.id) }
        if targets.isEmpty { return .unchanged("нечего выключать") }
        if targets.contains(where: { $0.isMain }) {
            return .refuse("внешний монитор сейчас главный — сначала сделай главным встроенный экран")
        }
        return .apply(ids: targets.map(\.id), enabled: false)
    }

    static func planOn(_ all: [DisplayInfo]) -> MonitorPlan {
        let targets = disabledExternals(all)
        if targets.isEmpty { return .unchanged("нечего включать") }
        return .apply(ids: targets.map(\.id), enabled: true)
    }

    public static func label(_ d: DisplayInfo) -> String {
        let kind = d.isBuiltin ? "встроенный" : "внешний"
        let size = d.width > 1 ? ", \(d.width)x\(d.height)" : ""
        return "\(d.id) (\(kind)\(size), vendor \(d.vendor))"
    }

    public static func statusLines(_ all: [DisplayInfo]) -> [String] {
        let online = all.filter(\.isOnline)
        let off = disabledExternals(all)
        var lines = ["Активные дисплеи (\(online.count)):"]
        for d in online { lines.append("  \(label(d))\(d.isMain ? " — главный" : "")") }
        if off.isEmpty {
            lines.append("Отключённых нет.")
        } else {
            lines.append("Отключены (\(off.count)):")
            for d in off { lines.append("  \(label(d))") }
        }
        lines.append("Состояние: " + (off.isEmpty ? "монитор ВКЛЮЧЁН" : "монитор ВЫКЛЮЧЕН"))
        return lines
    }

    public static func summary(_ all: [DisplayInfo]) -> String {
        statusLines(all).last ?? ""
    }
}

public struct MonitorToggleService {
    public let provider: DisplayProviding
    public var protectedIDs: () -> Set<UInt32>

    public init(provider: DisplayProviding, protectedIDs: @escaping () -> Set<UInt32> = { [] }) {
        self.provider = provider
        self.protectedIDs = protectedIDs
    }

    public func snapshot() -> [DisplayInfo] { provider.displays() }

    public func run(_ command: MonitorCommand) -> MonitorOutcome {
        if (command == .on || command == .toggle) && !provider.canList {
            return .failed("системная функция CGSGetDisplayList недоступна: отключённые дисплеи не найти")
        }
        let all = provider.displays()
        let plan = MonitorLogic.plan(command, displays: all, protected: protectedIDs())
        switch plan {
        case .unchanged(let m): return .unchanged(m)
        case .refuse(let m): return .failed(m)
        case .apply(let ids, let enabled):
            guard provider.canSwitch else {
                return .failed("системная функция CGSConfigureDisplayEnabled недоступна в этой версии macOS")
            }
            switch provider.setEnabled(ids, enabled: enabled) {
            case .ok:
                let names = ids.map(String.init).joined(separator: ", ")
                return .changed(enabled ? "включён дисплей \(names)" : "выключен дисплей \(names)")
            case .failed(let m):
                return .failed(m)
            }
        }
    }
}

public final class CGSDisplayProvider: DisplayProviding {
    typealias ConfigureFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let configure: ConfigureFn?
    private let list: ListFn?
    private static let maxDisplays: UInt32 = 16

    public init() {
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            if let handle, let p = dlsym(handle, name) { return p }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        configure = sym("CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: ConfigureFn.self) }
        list = sym("CGSGetDisplayList").map { unsafeBitCast($0, to: ListFn.self) }
    }

    public var canSwitch: Bool { configure != nil }
    public var canList: Bool { list != nil }

    private func ids(_ body: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>, UnsafeMutablePointer<UInt32>) -> CGError) -> [CGDirectDisplayID] {
        var buf = [CGDirectDisplayID](repeating: 0, count: Int(Self.maxDisplays))
        var count: UInt32 = 0
        guard body(Self.maxDisplays, &buf, &count) == .success else { return [] }
        return Array(buf.prefix(Int(count)))
    }

    public func displays() -> [DisplayInfo] {
        let online = ids { CGGetOnlineDisplayList($0, $1, $2) }
        var known: [CGDirectDisplayID] = []
        if let list { known = ids { list($0, $1, $2) } }
        var seen = Set<CGDirectDisplayID>()
        var out: [DisplayInfo] = []
        for id in known + online where seen.insert(id).inserted {
            out.append(DisplayInfo(id: id, isOnline: online.contains(id), isBuiltin: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                                   vendor: CGDisplayVendorNumber(id), width: Int(CGDisplayPixelsWide(id)), height: Int(CGDisplayPixelsHigh(id))))
        }
        return out
    }

    public func setEnabled(_ ids: [UInt32], enabled: Bool) -> DisplayApplyResult {
        guard let configure else { return .failed("системная функция CGSConfigureDisplayEnabled недоступна") }
        guard !ids.isEmpty else { return .ok }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return .failed("не удалось начать перенастройку дисплеев") }
        for id in ids {
            let err = configure(config, id, enabled)
            if err != .success {
                CGCancelDisplayConfiguration(config)
                return .failed("дисплей \(id): ошибка \(err.rawValue)")
            }
        }
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else { return .failed("не удалось применить настройку, ошибка \(err.rawValue)") }
        return .ok
    }
}

// Multitul --monitor status|off|on|toggle  (замена ~/bin/monitortoggle)
public enum MonitorCLI {
    public static func handles(_ args: [String]) -> Bool { args.contains("--monitor") }

    public static func run(arguments a: [String], provider: DisplayProviding = CGSDisplayProvider(), out: (String) -> Void, err: (String) -> Void) -> Int32 {
        guard let k = a.firstIndex(of: "--monitor") else { return 2 }
        let word = a.count > k + 1 ? a[k + 1] : "toggle"
        guard let cmd = MonitorCommand(rawValue: word) else {
            err("usage: Multitul --monitor status|off|on|toggle")
            return 2
        }
        let service = MonitorToggleService(provider: provider)
        if cmd == .status {
            MonitorLogic.statusLines(service.snapshot()).forEach(out)
            return 0
        }
        let r = service.run(cmd)
        if r.isFailure { err("Ошибка: " + r.message); return 1 }
        out(r.message)
        return 0
    }
}
