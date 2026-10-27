import Foundation

public struct DmgEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool

    public init(name: String, isDirectory: Bool = false, isSymlink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

public struct AppBundleInfo: Equatable, Sendable {
    public var bundleID: String?
    public var version: String?
    public init(bundleID: String? = nil, version: String? = nil) {
        self.bundleID = bundleID
        self.version = version
    }
}

public enum SignatureCheck: Equatable, Sendable {
    case valid, unsigned, invalid(String)
}

public enum DmgDestination: String, CaseIterable, Sendable {
    case system, user

    public var title: String { self == .system ? "/Applications" : "~/Applications" }

    public func path(home: String) -> String { self == .system ? "/Applications" : home + "/Applications" }
}

public struct DmgSettings: Equatable, Sendable {
    public var askFirst = true
    public var destination = DmgDestination.system
    public var ejectAfter = true
    public var trashDmg = false
    public var reveal = true
    public var requireValidSignature = true
    public var reinstallSameVersion = false
    public var watchDownloads = false

    public init() {}
}

public enum DmgScan: Equatable, Sendable {
    case singleApp(String)
    case noApp
    case multiple([String])
    case installerOnly([String])
    case appAndInstaller(app: [String], installer: [String])
}

public enum DmgRefusal: Error, Equatable, Sendable {
    case noApp
    case multipleApps([String])
    case installerOnly
    case appAndInstaller
    case alreadyInstalled(String)
    case appRunning
    case destinationNotWritable(String)

    public var message: String {
        switch self {
        case .noApp: "В образе нет приложения"
        case .multipleApps(let a): "В образе несколько приложений: \(a.joined(separator: ", "))"
        case .installerOnly: "В образе установщик .pkg, а не приложение"
        case .appAndInstaller: "В образе приложение и установщик .pkg одновременно"
        case .alreadyInstalled(let v): "Эта версия (\(v)) уже установлена"
        case .appRunning: "Установленное приложение сейчас запущено"
        case .destinationNotWritable(let p): "Нет доступа на запись в \(p)"
        }
    }

    public var isQuiet: Bool {
        switch self {
        case .noApp, .multipleApps, .installerOnly, .appAndInstaller: true
        default: false
        }
    }
}

public enum DmgStep: Equatable, Sendable {
    case verifySignature, copy, eject, trashDmg, reveal
}

public struct DmgPlan: Equatable, Sendable {
    public var appName: String
    public var sourcePath: String
    public var destinationPath: String
    public var mountPoint: String
    public var dmgPath: String?
    public var replaces: Bool
    public var steps: [DmgStep]
    public var version: String?
}

public protocol DmgSystem: AnyObject {
    func listTopLevel(_ path: String) -> [DmgEntry]
    func bundleInfo(_ appPath: String) -> AppBundleInfo?
    func exists(_ path: String) -> Bool
    func isRunning(appAt path: String) -> Bool
    func isWritableDirectory(_ path: String) -> Bool
    func verifySignature(_ appPath: String) -> SignatureCheck
    func copyBundle(from: String, to: String, replacing: Bool) throws
    func moveToTrash(_ path: String) throws
    func detach(mountPoint: String, force: Bool) -> Bool
    func reveal(_ path: String)
}

public enum DmgScanner {
    public static func scan(_ entries: [DmgEntry]) -> DmgScan {
        var apps: [String] = []
        var pkgs: [String] = []
        for e in entries where !e.name.hasPrefix(".") && !e.isSymlink {
            let lower = e.name.lowercased()
            if lower.hasSuffix(".app"), e.isDirectory { apps.append(e.name) }
            else if lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") { pkgs.append(e.name) }
        }
        apps.sort()
        pkgs.sort()
        switch (apps.count, pkgs.isEmpty) {
        case (0, true): return .noApp
        case (0, false): return .installerOnly(pkgs)
        case (1, true): return .singleApp(apps[0])
        case (_, true): return .multiple(apps)
        default: return .appAndInstaller(app: apps, installer: pkgs)
        }
    }
}

public enum DmgPlanner {
    public static func plan(mountPoint: String, dmgPath: String?, settings: DmgSettings, system: DmgSystem, home: String = NSHomeDirectory()) -> Result<DmgPlan, DmgRefusal> {
        switch DmgScanner.scan(system.listTopLevel(mountPoint)) {
        case .noApp: return .failure(.noApp)
        case .multiple(let a): return .failure(.multipleApps(a))
        case .installerOnly: return .failure(.installerOnly)
        case .appAndInstaller: return .failure(.appAndInstaller)
        case .singleApp(let name):
            let src = mountPoint + "/" + name
            let root = settings.destination.path(home: home)
            let dest = root + "/" + name
            let hasRoot = system.exists(root)
            if hasRoot, !system.isWritableDirectory(root) { return .failure(.destinationNotWritable(root)) }
            let replaces = system.exists(dest)
            let info = system.bundleInfo(src)
            if replaces {
                if system.isRunning(appAt: dest) { return .failure(.appRunning) }
                if !settings.reinstallSameVersion, let v = info?.version, let cur = system.bundleInfo(dest)?.version, v == cur {
                    return .failure(.alreadyInstalled(v))
                }
            }
            var steps: [DmgStep] = []
            if settings.requireValidSignature { steps.append(.verifySignature) }
            steps.append(.copy)
            if settings.ejectAfter { steps.append(.eject) }
            if settings.trashDmg, settings.ejectAfter, dmgPath != nil { steps.append(.trashDmg) }
            if settings.reveal { steps.append(.reveal) }
            return .success(DmgPlan(appName: name, sourcePath: src, destinationPath: dest, mountPoint: mountPoint, dmgPath: dmgPath, replaces: replaces, steps: steps, version: info?.version))
        }
    }
}

public struct DmgReport: Equatable, Sendable {
    public var done: [DmgStep] = []
    public var failedStep: DmgStep?
    public var message: String?
    public var warnings: [String] = []
    public var ok: Bool { failedStep == nil }
}

public final class DmgInstaller {
    private let system: DmgSystem

    public init(system: DmgSystem) { self.system = system }

    public func execute(_ plan: DmgPlan) -> DmgReport {
        var r = DmgReport()
        var ejected = false
        for step in plan.steps {
            switch step {
            case .verifySignature:
                switch system.verifySignature(plan.sourcePath) {
                case .valid: r.done.append(step)
                case .unsigned: return fail(r, step, "Приложение без подписи")
                case .invalid(let why): return fail(r, step, "Подпись не прошла проверку: \(why)")
                }
            case .copy:
                do { try system.copyBundle(from: plan.sourcePath, to: plan.destinationPath, replacing: plan.replaces) } catch {
                    return fail(r, step, "Не удалось скопировать: \(error.localizedDescription)")
                }
                r.done.append(step)
            case .eject:
                if system.detach(mountPoint: plan.mountPoint, force: false) || system.detach(mountPoint: plan.mountPoint, force: true) {
                    ejected = true
                    r.done.append(step)
                } else {
                    r.warnings.append("Образ не извлечён: диск занят")
                }
            case .trashDmg:
                guard ejected, let dmg = plan.dmgPath else { r.warnings.append("Образ не убран в Корзину: он не извлечён"); continue }
                do { try system.moveToTrash(dmg); r.done.append(step) } catch {
                    r.warnings.append("Образ не убран в Корзину: \(error.localizedDescription)")
                }
            case .reveal:
                system.reveal(plan.destinationPath)
                r.done.append(step)
            }
        }
        return r
    }

    private func fail(_ r: DmgReport, _ step: DmgStep, _ msg: String) -> DmgReport {
        var o = r
        o.failedStep = step
        o.message = msg
        return o
    }
}

public struct AttachedImage: Equatable, Sendable {
    public var imagePath: String
    public var mountPoints: [String]
}

public enum HdiutilParser {
    public static func mountPoints(attachPlist data: Data) -> [String] {
        guard let root = plist(data), let ents = root["system-entities"] as? [[String: Any]] else { return [] }
        return ents.compactMap { $0["mount-point"] as? String }
    }

    public static func images(infoPlist data: Data) -> [AttachedImage] {
        guard let root = plist(data), let imgs = root["images"] as? [[String: Any]] else { return [] }
        return imgs.compactMap { img in
            guard let path = img["image-path"] as? String else { return nil }
            let ents = (img["system-entities"] as? [[String: Any]]) ?? []
            return AttachedImage(imagePath: path, mountPoints: ents.compactMap { $0["mount-point"] as? String })
        }
    }

    public static func imagePath(forMountPoint mp: String, in images: [AttachedImage]) -> String? {
        images.first { $0.mountPoints.contains(mp) }?.imagePath
    }

    private static func plist(_ d: Data) -> [String: Any]? {
        guard let start = d.range(of: Data("<?xml".utf8)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d.subdata(in: start.lowerBound..<d.endIndex), options: [], format: nil)) as? [String: Any]
    }
}

public struct DownloadFile: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var modified: Date
    public init(name: String, size: Int64, modified: Date) {
        self.name = name
        self.size = size
        self.modified = modified
    }
}

public struct DownloadsDmgDetector: Sendable {
    private var seen: [String: DownloadFile] = [:]
    private var reported: Set<String> = []
    private var primed = false
    public var settleSeconds: TimeInterval = 2

    public init() {}

    public static func isPartial(_ name: String) -> Bool {
        let l = name.lowercased()
        return [".download", ".crdownload", ".part", ".partial", ".opdownload"].contains { l.hasSuffix($0) }
    }

    public mutating func poll(_ files: [DownloadFile], now: Date) -> [String] {
        let names = Set(files.map(\.name))
        let dmgs = files.filter { $0.name.lowercased().hasSuffix(".dmg") && !$0.name.hasPrefix(".") }
        let partialPresent = files.contains { Self.isPartial($0.name) }
        if !primed {
            primed = true
            for f in dmgs { reported.insert(f.name); seen[f.name] = f }
            return []
        }
        reported = reported.intersection(names)
        var ready: [String] = []
        for f in dmgs.sorted(by: { $0.name < $1.name }) where !reported.contains(f.name) {
            defer { seen[f.name] = f }
            guard let prev = seen[f.name], prev.size == f.size, prev.modified == f.modified, f.size > 0,
                  now.timeIntervalSince(f.modified) >= settleSeconds else { continue }
            if partialPresent, files.contains(where: { Self.isPartial($0.name) && $0.name.hasPrefix(f.name) }) { continue }
            reported.insert(f.name)
            ready.append(f.name)
        }
        seen = seen.filter { names.contains($0.key) }
        return ready
    }
}
