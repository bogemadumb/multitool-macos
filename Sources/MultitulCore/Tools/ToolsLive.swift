import Foundation
import AppKit
import AVFoundation
import Vision
import ScreenCaptureKit
import MultitulCtlCore

public final class PasteboardTextWriter: TextWriting {
    public init() {}

    public func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

public final class VisionOcrRecognizer: OcrRecognizing {
    public init() {}

    public func recognizeText(in image: CGImage, config: OcrRequestConfig) throws -> [OcrLine] {
        let c = config.sanitized
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = c.level == .accurate ? .accurate : .fast
        req.usesLanguageCorrection = c.usesLanguageCorrection
        req.minimumTextHeight = Float(c.minimumTextHeight)
        let supported = Set((try? req.supportedRecognitionLanguages()) ?? [])
        let langs = c.languages.filter { supported.contains($0) }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return OcrLine(top.string, confidence: Double(top.confidence), box: obs.boundingBox)
        }
    }

    public func detectCodes(in image: CGImage) -> [String] {
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil else { return [] }
        var seen = Set<String>()
        return (req.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public final class AVCameraDriver: CameraDriving {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.multitool.app.camera")
    private var wantsRunning = false

    public init() {}

    public var isRunning: Bool { wantsRunning }

    public func authorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok) } }
    }

    public func devices() -> [CameraDevice] {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        return found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isBuiltIn: $0.deviceType == .builtInWideAngleCamera) }
    }

    public func start(deviceID: String) -> Bool {
        guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device) else { return false }
        wantsRunning = true
        queue.async { [session] in
            session.beginConfiguration()
            for i in session.inputs { session.removeInput(i) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
        return true
    }

    public func stop() {
        wantsRunning = false
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for i in session.inputs { session.removeInput(i) }
            session.commitConfiguration()
        }
    }
}

public final class SystemToggleDriver: QuickToggleDriving {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    private func call(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> Bool {
        let r = runner.run(path, args, timeout: timeout)
        return r.status == 0 && !r.timedOut
    }

    private func script(_ source: String) -> Bool {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: source) else { return false }
        s.executeAndReturnError(&err)
        if let err { Log.write("quickToggles script error \(err[NSAppleScript.errorNumber] ?? "?")"); return false }
        return true
    }

    public func isDarkMode() -> Bool {
        let v = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return v == "Dark"
    }

    public func setDarkMode(_ on: Bool) -> Bool {
        typealias Fn = @convention(c) (Bool) -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), let sym = dlsym(h, "SLSSetAppearanceThemeLegacy") {
            unsafeBitCast(sym, to: Fn.self)(on)
            return true
        }
        return script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
    }

    public func desktopIconsHidden() -> Bool {
        let v = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString)
        if let b = v as? Bool { return !b }
        if let s = v as? String { return s == "0" || s.lowercased() == "false" }
        return false
    }

    public func setDesktopIconsHidden(_ hidden: Bool) -> Bool {
        guard call("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"]) else { return false }
        return restartFinder()
    }

    public func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return VolumeInfo(name: v?.volumeName ?? u.lastPathComponent, path: u.path, isInternal: v?.volumeIsInternal ?? true,
                              isEjectable: v?.volumeIsEjectable ?? false, isRemovable: v?.volumeIsRemovable ?? false, isLocal: v?.volumeIsLocal ?? true)
        }
    }

    public func eject(_ volume: VolumeInfo) -> Bool {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
            return true
        } catch {
            Log.write("quickToggles eject \(volume.name) failed: \(error.localizedDescription)")
            return false
        }
    }

    public func trashItemCount() -> Int? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash") else { return nil }
        return items.filter { $0 != ".DS_Store" }.count
    }

    public func emptyTrash() -> Bool { script("tell application \"Finder\" to empty trash") }

    public func restartFinder() -> Bool { call("/usr/bin/killall", ["Finder"]) }

    public func lockScreen() -> Bool {
        typealias Fn = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Fn.self)()
            return true
        }
        return script("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
    }

    public func sleepDisplays() -> Bool { call("/usr/bin/pmset", ["displaysleepnow"]) }

    public func startScreenSaver() -> Bool { call("/usr/bin/open", ["-a", "ScreenSaverEngine"]) }
}

public final class FileSystemLauncherChecker: LauncherFileChecking {
    public init() {}

    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
    public func appPath(forBundleID id: String) -> String? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path }
}

public final class ScreenCapture {
    public struct Shot {
        public var image: CGImage
        public var frame: CGRect
        public var scale: CGFloat
        public var displayID: CGDirectDisplayID
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public init() {}

    @MainActor
    public func captureAll() async -> [Shot] {
        guard Self.hasPermission, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
            cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.colorSpaceName = CGColorSpace.displayP3
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                shots.append(Shot(image: img, frame: screen.frame, scale: screen.backingScaleFactor, displayID: id))
            }
        }
        return shots
    }
}

public final class BitmapPixelSource: PixelSource {
    public let pixelWidth: Int
    public let pixelHeight: Int
    private let data: Data
    private let bytesPerRow: Int
    private let space: ColorSpaceKind

    public init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let isP3 = image.colorSpace?.name == CGColorSpace.displayP3
        let cs = CGColorSpace(name: isP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let bpr = w * 4
        var buf = Data(count: bpr * h)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        pixelWidth = w
        pixelHeight = h
        data = buf
        bytesPerRow = bpr
        space = isP3 ? .displayP3 : .srgb
    }

    public func color(atX x: Int, y: Int) -> RGBAColor? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        let i = y * bytesPerRow + x * 4
        let a = Int(data[i + 3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255 / Double(a)).rounded())) }
        return RGBAColor(red8: un(data[i]), green8: un(data[i + 1]), blue8: un(data[i + 2]), alpha8: 255, space: space)
    }
}
