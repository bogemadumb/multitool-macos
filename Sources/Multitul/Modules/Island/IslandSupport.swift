import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore
import MultitulUI

enum IslandScreens {
    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    @MainActor
    static func current() -> [IslScreenInfo] {
        let screens = NSScreen.screens
        let identities = screens.map { s -> DisplayIdentity in
            let id = displayID(s)
            return DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        let keys = BrightnessIDs.assign(identities)
        return screens.enumerated().map { i, s in
            IslScreenInfo(id: displayID(s), key: keys[i], name: s.localizedName, frame: s.frame, visibleFrame: s.visibleFrame, safeAreaTop: s.safeAreaInsets.top,
                          auxLeftWidth: s.auxiliaryTopLeftArea?.width, auxRightWidth: s.auxiliaryTopRightArea?.width, scale: s.backingScaleFactor,
                          isBuiltin: identities[i].isBuiltin, isMain: i == 0)
        }
    }

    @MainActor
    static func screen(id: UInt32) -> NSScreen? { NSScreen.screens.first { displayID($0) == id } }
}

@MainActor
final class IslandEnvironment {
    private var menuMaxX: CGFloat?
    private var menuQueued = false
    var onMenuClearance: (() -> Void)?

    func fullscreenScreens(_ screens: [IslScreenInfo]) -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? screens.first?.frame.height ?? 0
        let me = getpid()
        var out = Set<UInt32>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            for s in screens {
                let cg = CGRect(x: s.frame.minX, y: primaryH - s.frame.maxY, width: s.frame.width, height: s.frame.height)
                if abs(r.minX - cg.minX) < 2, abs(r.minY - cg.minY) < 2, abs(r.width - cg.width) < 2, abs(r.height - cg.height) < 2 { out.insert(s.id) }
            }
        }
        return out
    }

    func isMenuOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = getpid()
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == level && ($0[kCGWindowOwnerPID as String] as? Int32) != me }
    }

    var clearance: IslMenuClearance { IslMenuClearance(appMenuMaxX: menuMaxX, statusItemsMinX: nil) }

    func refreshMenuClearance(enabled: Bool) {
        guard enabled, AXIsProcessTrusted(), !menuQueued, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            if !enabled || !AXIsProcessTrusted() { menuMaxX = nil }
            return
        }
        menuQueued = true
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.measureMenuBar(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuQueued = false
                    if self.menuMaxX != value { self.menuMaxX = value; self.onMenuClearance?() }
                }
            }
        }
    }

    nonisolated private static func measureMenuBar(pid: pid_t) -> CGFloat? {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success, let items = kids as? [AXUIElement] else { return nil }
        var maxX: CGFloat?
        for item in items {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let pv = pos, let sv = size else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { continue }
            maxX = max(maxX ?? 0, p.x + s.width)
        }
        return maxX
    }
}

enum IslandColors {
    static func average(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        let m = max(r, g, b)
        guard m > 0.05 else { return nil }
        let k = min(0.95 / m, 2.2)
        return Color(red: min(r * k, 1), green: min(g * k, 1), blue: min(b * k, 1))
    }
}

struct IslNotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4, rect.height / 2)
        let b = min(bottomRadius, rect.width / 4, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
