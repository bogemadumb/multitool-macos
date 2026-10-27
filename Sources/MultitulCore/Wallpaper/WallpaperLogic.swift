import Foundation
import CoreGraphics

public enum WallpaperColor: String, CaseIterable, Sendable {
    case white, black
    public var title: String { self == .white ? "Белый" : "Чёрный" }
}

public enum DayMode: String, CaseIterable, Sendable {
    case auto, night, day
    public var title: String {
        switch self {
        case .auto: "Авто"
        case .night: "Всегда ночь"
        case .day: "Всегда день"
        }
    }
}

public enum WallpaperKeys {
    public static let color = "wallpaper.color"
    public static let dayMode = "wallpaper.dayMode"
    public static let pauseOnBattery = "wallpaper.pauseOnBattery"
    public static let manualPause = "wallpaper.manualPause"
    public static let lockFollows = "wallpaper.lockFollows"
    public static let lockVideo = "wallpaper.lockVideo"
    public static let excludedScreens = "wallpaper.excludedScreens"
    public static let staticSources = "staticWallpaper.sources"
}

public struct WallpaperSettings {
    private let d: KeyValueStoring
    public init(_ defaults: KeyValueStoring = UserDefaults.standard) { d = defaults }

    public var color: WallpaperColor {
        get { WallpaperColor(rawValue: d.string(forKey: WallpaperKeys.color) ?? "") ?? .black }
        nonmutating set { d.set(newValue.rawValue, forKey: WallpaperKeys.color) }
    }
    public var dayMode: DayMode {
        get { DayMode(rawValue: d.string(forKey: WallpaperKeys.dayMode) ?? "") ?? .auto }
        nonmutating set { d.set(newValue.rawValue, forKey: WallpaperKeys.dayMode) }
    }
    public var pauseOnBattery: Bool {
        get { d.object(forKey: WallpaperKeys.pauseOnBattery) as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: WallpaperKeys.pauseOnBattery) }
    }
    public var manualPause: Bool {
        get { d.bool(forKey: WallpaperKeys.manualPause) }
        nonmutating set { d.set(newValue, forKey: WallpaperKeys.manualPause) }
    }
    // Off by default: replacing the Aerial file touches system folders and restarts WallpaperAgent.
    public var lockFollows: Bool {
        get { d.object(forKey: WallpaperKeys.lockFollows) as? Bool ?? false }
        nonmutating set { d.set(newValue, forKey: WallpaperKeys.lockFollows) }
    }
    public var lockVideo: String? {
        get { let v = d.string(forKey: WallpaperKeys.lockVideo); return (v?.isEmpty ?? true) ? nil : v }
        nonmutating set { d.set(newValue ?? "", forKey: WallpaperKeys.lockVideo) }
    }
    public var excludedScreens: Set<String> {
        get { Set(d.object(forKey: WallpaperKeys.excludedScreens) as? [String] ?? []) }
        nonmutating set { d.set(newValue.sorted(), forKey: WallpaperKeys.excludedScreens) }
    }
}

public enum WallpaperFiles {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let standardNames: Set<String> = ["cls-white-night", "cls-black-night", "cls-white-day", "cls-black-day"]
    public static let aerialAssetID = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    // A file changed less than this long ago is still being written/copied: do not switch to it yet.
    public static let settleSeconds: TimeInterval = 3

    public static var dir: String { MultitulPaths.home + "/wallpapers" }
    public static var aerialDir: String { dir + "/aerial" }
    public static var aerialOriginalDir: String { dir + "/aerial-original" }
    public static var titlesPath: String { dir + "/titles.json" }

    public static func scanNames(_ dir: String) -> [String: URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var out: [String: URL] = [:]
        for u in urls where videoExtensions.contains(u.pathExtension.lowercased()) {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == false { continue }
            out[u.deletingPathExtension().lastPathComponent] = u
        }
        return out
    }

    public static func loadTitles(path: String = titlesPath) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }
}

public struct FileStamp: Equatable, Sendable {
    public let stamp: String
    public let age: TimeInterval

    public static func of(_ url: URL, now: Date = Date()) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        return FileStamp(stamp: "\(m.timeIntervalSince1970)-\(s)", age: now.timeIntervalSince(m))
    }

    public var isSettled: Bool { age > WallpaperFiles.settleSeconds }
}

public enum WallpaperSelection {
    public static func standardName(color: WallpaperColor, day: Bool) -> String { "cls-\(color.rawValue)-\(day ? "day" : "night")" }

    // Same preference order as the old app: exact match, same colour other time, other colour same time, rest.
    public static func resolveName(color: WallpaperColor, day: Bool, available: Set<String>) -> String? {
        let other: WallpaperColor = color == .white ? .black : .white
        let order = [standardName(color: color, day: day), standardName(color: color, day: false), standardName(color: color, day: true),
                     standardName(color: other, day: day), standardName(color: other, day: false), standardName(color: other, day: true)]
        return order.first { available.contains($0) }
    }

    // Standard clip if any, else the first file by natural name order.
    public static func pick(color: WallpaperColor, day: Bool, videos: [String: URL]) -> (name: String, url: URL, standard: Bool)? {
        if let n = resolveName(color: color, day: day, available: Set(videos.keys).intersection(WallpaperFiles.standardNames)), let u = videos[n] {
            return (n, u, true)
        }
        guard let n = videos.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first, let u = videos[n] else { return nil }
        return (n, u, false)
    }

    public static func isDay(mode: DayMode, sun: SunCalc, now: Date) -> Bool {
        switch mode {
        case .day: true
        case .night: false
        case .auto: sun.isDay(now)
        }
    }
}

public enum PauseReason: String, Sendable { case manual, locked, asleep, battery, occluded, covered }

public struct PauseInputs: Equatable, Sendable {
    public var manual = false
    public var locked = false
    public var systemAsleep = false
    public var screensAsleep = false
    public var onBattery = false
    public var pauseOnBattery = true
    public var occluded = false
    public var covered = false

    public init() {}

    // Global reasons apply to every screen; occlusion is per screen.
    public var globalReason: PauseReason? {
        if manual { return .manual }
        if locked { return .locked }
        if systemAsleep || screensAsleep { return .asleep }
        if pauseOnBattery && onBattery { return .battery }
        return nil
    }

    public var reason: PauseReason? {
        globalReason ?? (occluded ? .occluded : covered ? .covered : nil)
    }

    public var shouldPlay: Bool { reason == nil }
}

public enum Occlusion {
    // `rects` are opaque normal-layer window frames in top-left screen coordinates, `area` is the screen's visible frame in the same space.
    // The screen counts as covered when every cell of a 24x14 grid lies inside some window.
    public static func isCovered(area: CGRect, rects: [CGRect], cols: Int = 24, rows: Int = 14) -> Bool {
        if rects.isEmpty || area.width <= 0 || area.height <= 0 { return false }
        for r in 0..<rows {
            for c in 0..<cols {
                let pt = CGPoint(x: area.minX + area.width * (CGFloat(c) + 0.5) / CGFloat(cols),
                                 y: area.minY + area.height * (CGFloat(r) + 0.5) / CGFloat(rows))
                if !rects.contains(where: { $0.contains(pt) }) { return false }
            }
        }
        return true
    }

    // Window-list entry filter: layer 0, not ours, essentially opaque.
    public static func countsAsCover(layer: Int?, ownerPID: Int32?, alpha: Double?, ownPID: Int32) -> Bool {
        layer == 0 && ownerPID != ownPID && (alpha ?? 1) >= 0.98
    }

    // Cocoa (bottom-left origin) visible frame to the window-list space (top-left origin of the primary screen).
    public static func topLeftArea(visibleFrame v: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }
}

public enum WallpaperExclusion {
    public static func liveRuns(on screenID: String, liveEnabled: Bool, excluded: Set<String>) -> Bool {
        liveEnabled && !excluded.contains(screenID)
    }

    public enum StaticDecision: Equatable, Sendable { case allowed, blockedByLive }

    public static func staticDecision(screenID: String, liveEnabled: Bool, excluded: Set<String>) -> StaticDecision {
        liveRuns(on: screenID, liveEnabled: liveEnabled, excluded: excluded) ? .blockedByLive : .allowed
    }
}
