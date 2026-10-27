import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

public struct AerialError: Error, Equatable, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

public struct AerialPaths: Sendable {
    public let aerialsDir: String
    public let clipsDir: String
    public let originalDir: String
    public let assetID: String

    public init(home: String = NSHomeDirectory(), storeDir: String = WallpaperFiles.dir, assetID: String = WallpaperFiles.aerialAssetID) {
        aerialsDir = home + "/Library/Application Support/com.apple.wallpaper/aerials"
        clipsDir = storeDir + "/aerial"
        originalDir = storeDir + "/aerial-original"
        self.assetID = assetID
    }

    public var targetVideo: String { aerialsDir + "/videos/" + assetID + ".mov" }
    public var targetThumb: String { aerialsDir + "/thumbnails/" + assetID + ".png" }
    public var originalVideo: String { originalDir + "/" + assetID + ".mov" }
    public var originalThumb: String { originalDir + "/" + assetID + ".png" }
    public func clip(_ name: String) -> String { clipsDir + "/" + name + ".mov" }
}

public struct AerialEnv {
    public var paths: AerialPaths
    public var osMajor: () -> Int
    public var makeThumbnail: (_ src: String, _ dst: String) throws -> Void
    public var reload: () -> Void

    public init(paths: AerialPaths = AerialPaths(),
                osMajor: @escaping () -> Int = { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
                makeThumbnail: @escaping (String, String) throws -> Void = AerialLockscreen.videoThumbnail,
                reload: @escaping () -> Void = AerialLockscreen.restartWallpaperAgents) {
        self.paths = paths
        self.osMajor = osMajor
        self.makeThumbnail = makeThumbnail
        self.reload = reload
    }
}

// Replaces the "Tahoe Day" Aerial with our clip so the lock screen follows the desktop wallpaper.
// Перенесено из прежней версии (setLockscreen / restoreLockscreen). Only runs from an explicit user toggle.
public enum AerialLockscreen {
    // Layout verified by hand on 27.0 (old app); 26 uses the same per-user folder per the catalogue.
    public static let supportedMajors: ClosedRange<Int> = 26...27

    public static func versionError(major: Int) -> AerialError? {
        supportedMajors.contains(major) ? nil : AerialError("Подмена экрана блокировки проверена только на macOS \(supportedMajors.lowerBound)–\(supportedMajors.upperBound), здесь \(major) — не делаю.")
    }

    public static func apply(name: String, env: AerialEnv = AerialEnv()) throws {
        if let e = versionError(major: env.osMajor()) { throw e }
        let p = env.paths
        let fm = FileManager.default
        guard fm.fileExists(atPath: p.clip(name)) else { throw AerialError("Нет ролика: \(name)") }
        guard fm.fileExists(atPath: p.originalVideo) else { throw AerialError("Нет копии оригинала в \(p.originalDir) — подмену не делаю.") }
        guard fm.fileExists(atPath: p.aerialsDir + "/videos") else { throw AerialError("Нет папки Aerial: \(p.aerialsDir)/videos") }

        let etag = readXattr(p.originalVideo, "LastETag")
        let tmp = p.targetVideo + ".tmp"
        try? fm.removeItem(atPath: tmp)
        try copy(p.clip(name), tmp, flags: copyfile_flags_t(COPYFILE_DATA))
        if let etag { try writeXattr(tmp, "LastETag", etag) }
        try replace(tmp, p.targetVideo)
        chmod(p.targetVideo, 0o600)

        let thumbTmp = p.targetThumb + ".tmp.png"
        try? fm.removeItem(atPath: thumbTmp)
        try env.makeThumbnail(p.clip(name), thumbTmp)
        try replace(thumbTmp, p.targetThumb)
        env.reload()
    }

    public static func restore(env: AerialEnv = AerialEnv()) throws {
        if let e = versionError(major: env.osMajor()) { throw e }
        let p = env.paths
        let fm = FileManager.default
        guard fm.fileExists(atPath: p.originalVideo), fm.fileExists(atPath: p.originalThumb) else {
            throw AerialError("Нет копии оригинала в \(p.originalDir) — вернуть нечего.")
        }
        let all = copyfile_flags_t(COPYFILE_ALL)
        let tmp = p.targetVideo + ".tmp"
        try? fm.removeItem(atPath: tmp)
        try copy(p.originalVideo, tmp, flags: all)
        try replace(tmp, p.targetVideo)
        let thumbTmp = p.targetThumb + ".tmp.png"
        try? fm.removeItem(atPath: thumbTmp)
        try copy(p.originalThumb, thumbTmp, flags: all)
        try replace(thumbTmp, p.targetThumb)
        env.reload()
    }

    // Which clip should be on the lock screen now, or nil when nothing needs to change.
    public static func syncTarget(follows: Bool, busy: Bool, desired: String?, current: String?, hasClip: (String) -> Bool) -> String? {
        guard follows, !busy, let desired, desired != current, WallpaperFiles.standardNames.contains(desired), hasClip(desired) else { return nil }
        return desired
    }

    static func copy(_ src: String, _ dst: String, flags: copyfile_flags_t) throws {
        if copyfile(src, dst, nil, flags) != 0 { throw AerialError("Не удалось скопировать \(src): \(String(cString: strerror(errno)))") }
    }

    static func replace(_ tmp: String, _ dst: String) throws {
        if rename(tmp, dst) != 0 { throw AerialError("Не удалось заменить \(dst): \(String(cString: strerror(errno)))") }
    }

    public static func readXattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, name, &buf, size, 0, 0)
        return got >= 0 ? Data(buf.prefix(got)) : nil
    }

    public static func writeXattr(_ path: String, _ name: String, _ value: Data) throws {
        let r = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
        if r != 0 { throw AerialError("Не удалось записать атрибут \(name): \(String(cString: strerror(errno)))") }
    }

    public static func restartWallpaperAgents() {
        for name in ["WallpaperAerialsExtension", "WallpaperAgent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // 214x130 PNG, frame at 2 s, cover-fit; must run off the main thread (blocks on the async generator).
    public static func videoThumbnail(from src: String, to dst: String) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var got: CGImage?
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 2, preferredTimescale: 600)) { img, _, _ in got = img; sem.signal() }
        sem.wait()
        guard let frame = got else { throw AerialError("Не удалось получить кадр для миниатюры") }
        let w = 214, h = 130
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AerialError("Не удалось создать контекст для миниатюры")
        }
        ctx.interpolationQuality = .high
        let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
        let k = max(CGFloat(w) / fw, CGFloat(h) / fh)
        ctx.draw(frame, in: CGRect(x: (CGFloat(w) - fw * k) / 2, y: (CGFloat(h) - fh * k) / 2, width: fw * k, height: fh * k))
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, "public.png" as CFString, 1, nil) else {
            throw AerialError("Не удалось записать миниатюру")
        }
        CGImageDestinationAddImage(dest, out, nil)
        if !CGImageDestinationFinalize(dest) { throw AerialError("Не удалось записать миниатюру") }
    }
}
