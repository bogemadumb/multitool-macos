import Foundation
import AppKit

public struct StaticWallpaperSource: Codable, Equatable, Sendable {
    public var path: String
    public var isFolder: Bool
    public init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
    }
}

public enum StaticWallpaperLibrary {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    public static func loadSources(_ d: KeyValueStoring = UserDefaults.standard) -> [StaticWallpaperSource] {
        guard let data = d.object(forKey: WallpaperKeys.staticSources) as? Data,
              let list = try? JSONDecoder().decode([StaticWallpaperSource].self, from: data) else { return [] }
        return list
    }

    public static func saveSources(_ list: [StaticWallpaperSource], _ d: KeyValueStoring = UserDefaults.standard) {
        d.set(try? JSONEncoder().encode(list), forKey: WallpaperKeys.staticSources)
    }

    public static func adding(_ urls: [URL], to list: [StaticWallpaperSource]) -> [StaticWallpaperSource] {
        var out = list
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue && !isImage(u) { continue }
            let s = StaticWallpaperSource(path: u.path, isFolder: isDir.boolValue)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    // Single images as picked, plus images directly inside each folder; de-duplicated, folders sorted by natural name order.
    public static func images(from sources: [StaticWallpaperSource]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func key(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }
        for s in sources {
            if s.isFolder {
                let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: s.path), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                let imgs = urls.filter(isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for u in imgs where seen.insert(key(u)).inserted { out.append(u) }
            } else {
                let u = URL(fileURLWithPath: s.path)
                if FileManager.default.fileExists(atPath: u.path), isImage(u), seen.insert(key(u)).inserted { out.append(u) }
            }
        }
        return out
    }
}

public enum ScreenIdentity {
    public static func id(for screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let did = CGDirectDisplayID(n.uint32Value)
            if let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(), let s = CFUUIDCreateString(nil, u) as String? { return s }
            return "display-\(did)"
        }
        return screen.localizedName
    }
}
