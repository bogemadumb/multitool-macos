import Foundation

public enum WallpaperMigrationAction: String, Equatable, Sendable { case copy, skipSame, conflict }

public struct WallpaperMigrationItem: Equatable, Sendable {
    public let src: String
    public let dst: String
    public let bytes: Int64
    public let action: WallpaperMigrationAction
}

public struct WallpaperMigrationPlan: Equatable, Sendable {
    public var items: [WallpaperMigrationItem] = []
    public var missingSource = false
    public var freeBytes: Int64?

    public var toCopy: [WallpaperMigrationItem] { items.filter { $0.action == .copy } }
    public var copyBytes: Int64 { toCopy.reduce(0) { $0 + $1.bytes } }
    public var conflicts: [WallpaperMigrationItem] { items.filter { $0.action == .conflict } }
    // 5% + 64 MiB margin so the disk is not filled to the brim.
    public var enoughSpace: Bool {
        guard let free = freeBytes else { return true }
        return free >= copyBytes + copyBytes / 20 + 64 * 1024 * 1024
    }
}

public struct WallpaperMigrationResult: Equatable, Sendable {
    public var copied: [String] = []
    public var failed: [String] = []
}

// Old LiveWallpaper layout -> Multitul layout. Copies only; the old folder is never changed.
//   videos/*.{mov,mp4,m4v} -> wallpapers/   aerial/*.mov -> wallpapers/aerial/   aerial-original/* -> wallpapers/aerial-original/   titles.json -> wallpapers/titles.json
public enum WallpaperMigration {
    public static var defaultOldRoot: String { NSHomeDirectory() + "/Library/Application Support/LiveWallpaper" }

    public static func freeBytes(at path: String) -> Int64? {
        var p = path
        let fm = FileManager.default
        while !fm.fileExists(atPath: p) && p.count > 1 { p = (p as NSString).deletingLastPathComponent }
        guard let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let n = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return n
    }

    private static func regularFiles(_ dir: String, exts: Set<String>?) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { u in
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            return exts.map { $0.contains(u.pathExtension.lowercased()) } ?? true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func size(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    public static func plan(oldRoot: String = defaultOldRoot, newRoot: String = WallpaperFiles.dir, freeBytes: Int64? = nil) -> WallpaperMigrationPlan {
        var plan = WallpaperMigrationPlan()
        plan.freeBytes = freeBytes
        guard FileManager.default.fileExists(atPath: oldRoot) else {
            plan.missingSource = true
            return plan
        }
        let fm = FileManager.default
        func add(_ src: URL, into dstDir: String) {
            let dst = dstDir + "/" + src.lastPathComponent
            let sb = size(src.path) ?? 0
            let action: WallpaperMigrationAction
            if let db = size(dst), fm.fileExists(atPath: dst) { action = db == sb ? .skipSame : .conflict } else { action = .copy }
            plan.items.append(WallpaperMigrationItem(src: src.path, dst: dst, bytes: sb, action: action))
        }
        for u in regularFiles(oldRoot + "/videos", exts: WallpaperFiles.videoExtensions) { add(u, into: newRoot) }
        for u in regularFiles(oldRoot + "/aerial", exts: ["mov"]) { add(u, into: newRoot + "/aerial") }
        for u in regularFiles(oldRoot + "/aerial-original", exts: nil) { add(u, into: newRoot + "/aerial-original") }
        let titles = URL(fileURLWithPath: oldRoot + "/titles.json")
        if fm.fileExists(atPath: titles.path) { add(titles, into: newRoot) }
        return plan
    }

    // COPYFILE_ALL keeps xattrs (LastETag on the original Aerial) and mode.
    public static func liveCopy(_ src: String, _ dst: String) throws {
        let tmp = dst + ".part"
        try? FileManager.default.removeItem(atPath: tmp)
        try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if copyfile(src, tmp, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
            let e = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "WallpaperMigration", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "copy \(src): \(e)"])
        }
        if rename(tmp, dst) != 0 {
            let e = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "WallpaperMigration", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "rename \(dst): \(e)"])
        }
    }

    public static func execute(_ plan: WallpaperMigrationPlan, copy: (String, String) throws -> Void = liveCopy) -> WallpaperMigrationResult {
        var r = WallpaperMigrationResult()
        guard plan.enoughSpace else {
            r.failed.append("мало свободного места: нужно \(plan.copyBytes) Б")
            return r
        }
        for it in plan.toCopy {
            do {
                try copy(it.src, it.dst)
                r.copied.append(it.dst)
            } catch {
                r.failed.append("\(it.src): \(error.localizedDescription)")
            }
        }
        return r
    }

    public static func describe(_ it: WallpaperMigrationItem) -> String {
        "\(it.action.rawValue)\t\(it.bytes)\t\(it.src)\t->\t\(it.dst)"
    }
}
