import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

public final class LiveShotFiles: ShotFileStoring {
    public init() {}

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    public func write(_ data: Data, to path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            Log.write("screenshot write failed: \(error.localizedDescription)")
            return false
        }
    }

    public func trash(_ path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    public func remove(_ path: String) -> Bool {
        (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}

public final class PasteboardShotWriter: ShotClipboardWriting {
    public init() {}

    public func writeImage(png: Data) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setData(png, forType: .png)
        if let img = NSImage(data: png), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        return ok
    }
}

public enum ShotLiveScreens {
    @MainActor
    public static func displays() -> [ShotDisplay] {
        let screens = NSScreen.screens
        let primaryH = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
        return screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return ShotDisplay(id: id, cocoaFrame: s.frame, scale: s.backingScaleFactor, primaryHeight: primaryH)
        }
    }

    @MainActor
    public static func primaryHeight() -> CGFloat {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    public static func windowList(excludingPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> [ShotWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [ShotWindowInfo] = []
        for d in raw {
            guard let num = d[kCGWindowNumber as String] as? Int, let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let b = d[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) <= 0.01 { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            out.append(ShotWindowInfo(id: UInt32(num), ownerPid: pid, ownerName: d[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "",
                                      bundleID: app?.bundleIdentifier, title: d[kCGWindowName as String] as? String ?? "", frame: rect,
                                      layer: d[kCGWindowLayer as String] as? Int ?? 0, isOnScreen: true))
        }
        return ShotWindowFilter.selectable(out, excludingPids: [excludingPid])
    }
}

public final class ShotLiveCapture {
    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private func content() async -> SCShareableContent? {
        try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func ownApps(_ c: SCShareableContent) -> [SCRunningApplication] {
        c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    }

    public func captureDisplays(_ displays: [ShotDisplay], includeCursor: Bool = false, excludeOwn: Bool = true) async -> [UInt32: ShotSourceImage] {
        guard Self.hasPermission, let c = await content() else { return [:] }
        var out: [UInt32: ShotSourceImage] = [:]
        for d in displays {
            guard let sc = c.displays.first(where: { $0.displayID == d.id }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(d.pixelSize.width)
            cfg.height = Int(d.pixelSize.height)
            cfg.showsCursor = includeCursor
            cfg.capturesAudio = false
            cfg.colorSpaceName = CGColorSpace.sRGB
            let filter = SCContentFilter(display: sc, excludingApplications: excludeOwn ? ownApps(c) : [], exceptingWindows: [])
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                out[d.id] = ShotSourceImage(image: img, originPixel: .zero)
            }
        }
        return out
    }

    public func capture(plan: ShotAreaPlan, includeCursor: Bool = false) async -> CGImage? {
        guard Self.hasPermission, !plan.isEmpty, let c = await content() else { return nil }
        var sources: [UInt32: ShotSourceImage] = [:]
        for s in plan.slices {
            guard let sc = c.displays.first(where: { $0.displayID == s.displayID }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = s.localPointRect
            cfg.width = max(Int(s.sourcePixelRect.width), 1)
            cfg.height = max(Int(s.sourcePixelRect.height), 1)
            cfg.showsCursor = includeCursor
            cfg.capturesAudio = false
            cfg.colorSpaceName = CGColorSpace.sRGB
            let filter = SCContentFilter(display: sc, excludingApplications: ownApps(c), exceptingWindows: [])
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                sources[s.displayID] = ShotSourceImage(image: img, originPixel: s.sourcePixelRect.origin)
            }
        }
        return ShotCompositor.compose(plan: plan, sources: sources)
    }

    public func captureWindow(id: UInt32, plan: ShotWindowPlan, includeCursor: Bool = false) async -> CGImage? {
        guard Self.hasPermission, let c = await content(), let w = c.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        var width = plan.pixelWidth, height = plan.pixelHeight
        if plan.withShadow {
            let info = SCShareableContent.info(for: filter)
            let r = info.contentRect
            if r.width > 0, r.height > 0 {
                let k = CGFloat(info.pointPixelScale)
                width = Int((r.width * k).rounded())
                height = Int((r.height * k).rounded())
            }
        }
        cfg.width = max(width, 1)
        cfg.height = max(height, 1)
        cfg.ignoreShadowsSingleWindow = !plan.withShadow
        cfg.showsCursor = includeCursor
        cfg.capturesAudio = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

public final class LiveScrollDriver: ShotScrollDriving {
    private let capture: ShotLiveCapture
    private let plan: ShotAreaPlan
    private let anchor: CGPoint
    private let scale: CGFloat
    private let settleNanos: UInt64

    public init(capture: ShotLiveCapture, plan: ShotAreaPlan, settleMillis: Int = 380) {
        self.capture = capture
        self.plan = plan
        anchor = CGPoint(x: plan.rect.midX, y: plan.rect.midY)
        scale = plan.outputScale
        settleNanos = UInt64(max(settleMillis, 50)) * 1_000_000
    }

    public func captureFrame() async -> ShotBitmap? {
        guard let img = await capture.capture(plan: plan, includeCursor: false) else { return nil }
        return ShotBitmap(image: img)
    }

    public func scroll(pixels: Int) async {
        let points = Int32((Double(pixels) / Double(max(scale, 1))).rounded())
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0) else { return }
        e.location = anchor
        e.post(tap: .cghidEventTap)
    }

    public func settle() async { try? await Task.sleep(nanoseconds: settleNanos) }
}

public final class AppKeychain: KeychainStore, @unchecked Sendable {
    private let account: String

    public init(account: String = "multitul") { self.account = account }

    private func query(_ service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read(_ service: String) -> JSON? {
        var q = query(service)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? JSON
    }

    public func write(_ service: String, _ payload: JSON) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        let status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData: d] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query(service)
        add[kSecValueData] = d
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func deleteOnce(_ service: String) -> Bool {
        SecItemDelete(query(service) as CFDictionary) == errSecSuccess
    }
}
