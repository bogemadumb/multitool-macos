import Foundation

public struct InstalledApp: Identifiable, Sendable, Equatable {
    public var path: String
    public var bundleId: String
    public var name: String
    public var version: String
    public var id: String { path }

    public init(path: String, bundleId: String, name: String, version: String = "") {
        self.path = path
        self.bundleId = bundleId
        self.name = name
        self.version = version
    }

    // Apple's own apps, anything inside /System, and Multitul itself are never offered for removal.
    public var protection: String? {
        let b = bundleId.lowercased()
        if b.hasPrefix("com.apple.") { return "приложение Apple" }
        if path.hasPrefix("/System/") { return "системное приложение" }
        if b == "dev.multitool.app" || b.hasPrefix("dev.multitool.app.") { return "это сам Мультитул" }
        return nil
    }
}

public enum InstalledApps {
    public static func read(appPath: String) -> InstalledApp? {
        guard let d = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") as? [String: Any],
              let id = d["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let file = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? file
        return InstalledApp(path: appPath, bundleId: id, name: name, version: (d["CFBundleShortVersionString"] as? String) ?? "")
    }

    // One level of subfolders is looked into (JetBrains Toolbox, Utilities, vendor folders).
    public static func scan(dirs: [String]) -> [InstalledApp] {
        var out: [InstalledApp] = []
        var seen = Set<String>()
        for d in dirs {
            for n in childNames(d) {
                let p = d + "/" + n
                if n.hasSuffix(".app") {
                    if let a = read(appPath: p), seen.insert(a.path).inserted { out.append(a) }
                } else if isRealDir(p), !n.hasPrefix(".") {
                    for m in childNames(p) where m.hasSuffix(".app") {
                        if let a = read(appPath: p + "/" + m), seen.insert(a.path).inserted { out.append(a) }
                    }
                }
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public static func live(env: CleanEnv) -> [InstalledApp] { scan(dirs: env.appDirs) }
}
