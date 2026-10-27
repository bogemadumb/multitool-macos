import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

public final class PowerAssertionHolder {
    private var ids: [IOPMAssertionID] = []

    public init() {}

    public var isHeld: Bool { !ids.isEmpty }

    @discardableResult
    public func hold(displayToo: Bool) -> Bool {
        let types = displayToo ? ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"] : ["PreventUserIdleSystemSleep"]
        var fresh: [IOPMAssertionID] = []
        for t in types {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Мультитул: Keep Awake" as CFString, &id)
            if r == kIOReturnSuccess { fresh.append(id) }
        }
        let old = ids
        ids = fresh
        for id in old { IOPMAssertionRelease(id) }
        return fresh.count == types.count
    }

    public func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
    }

    deinit { release() }
}

public enum LidState {
    public static func isClosed() -> Bool {
        var closed = false
        Registry.services("IOPMrootDomain") { e in
            if let v = Registry.property(e, "AppleClamshellState") as? Bool { closed = v }
        }
        return closed
    }
}

public enum ExternalDisplays {
    public static func count() -> Int {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return 0 }
        return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}

public enum MouseJiggler {
    public static func jiggle() {
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Мультитул: Keep Awake" as CFString, kIOPMUserActiveLocal, &activity)
        guard let here = CGEvent(source: nil)?.location else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let nudged = CGPoint(x: here.x + 1, y: here.y)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left)?.post(tap: .cghidEventTap)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}

public final class BuiltinDimmer {
    private let markers: KeepAwakeMarkers

    public init(markers: KeepAwakeMarkers) { self.markers = markers }

    private func builtinID() -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    public func set(_ on: Bool) {
        if on {
            guard markers.dim == nil, let id = builtinID() else { return }
            let backend = DisplayServicesBackend(cgID: id)
            guard let current = backend.read() else { return }
            markers.dim = KeepAwakeMarkers.Dim(displayID: id, brightness: current)
            if !backend.write(0) { markers.dim = nil }
        } else {
            restorePending()
        }
    }

    @discardableResult
    public func restorePending() -> Bool {
        guard let saved = markers.dim else { return true }
        let id = builtinID() ?? saved.displayID
        if DisplayServicesBackend(cgID: id).write(saved.brightness) {
            markers.dim = nil
            return true
        }
        return false
    }
}

public final class KeepAwakeSystemHost: KeepAwakeHost {
    private let assertion = PowerAssertionHolder()
    private let ctl: PrivilegedCtl
    private let dimmer: BuiltinDimmer
    private let onNotice: (KeepAwakeNotice) -> Void

    public init(ctl: PrivilegedCtl = PrivilegedCtl(), markers: KeepAwakeMarkers, onNotice: @escaping (KeepAwakeNotice) -> Void) {
        self.ctl = ctl
        self.dimmer = BuiltinDimmer(markers: markers)
        self.onNotice = onNotice
    }

    public func holdAssertion(displayToo: Bool) -> Bool { assertion.hold(displayToo: displayToo) }
    public func releaseAssertion() { assertion.release() }

    public func setClosedLid(_ on: Bool) -> String? {
        do {
            try ctl.run(.powerDisableSleep(on), timeout: 15)
            return nil
        } catch {
            Log.write("keepAwake lid \(on) failed: \(error)")
            return "\(error)"
        }
    }

    public func dimBuiltin(_ on: Bool) { dimmer.set(on) }
    public func jiggle() { MouseJiggler.jiggle() }
    public func notify(_ notice: KeepAwakeNotice) { onNotice(notice) }

    public func isSleepDisabled() -> Bool? {
        KeepAwakeParsers.sleepDisabled(pmsetG: ToolRunner.run("/usr/bin/pmset", ["-g"], timeout: 10))
    }

    public func restoreDimIfPending() { dimmer.restorePending() }
}
