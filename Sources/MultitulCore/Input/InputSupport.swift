import Foundation
import CoreGraphics

public protocol PointerAppResolver: AnyObject {
    func bundleID(at point: CGPoint) -> String?
}

public final class ExceptionGate {
    public var list: AppExceptionList
    private let resolver: PointerAppResolver

    public init(list: AppExceptionList = AppExceptionList(), resolver: PointerAppResolver) {
        self.list = list
        self.resolver = resolver
    }

    public func isExcepted(at point: CGPoint) -> Bool {
        guard !list.isEmpty else { return false }
        return list.contains(resolver.bundleID(at: point))
    }
}

public struct InputConflictApp: Equatable {
    public var bundleID: String
    public var name: String
    public var affects: Set<ModuleID>
}

public enum InputConflicts {
    public static let scrollModules: Set<ModuleID> = [.scrollInverter, .scrollHorizontal, .linearScroll, .smoothScroll, .scrollZoom]

    public static let known: [InputConflictApp] = [
        InputConflictApp(bundleID: "com.nuebling.mac-mouse-fix.helper", name: "Mac Mouse Fix", affects: scrollModules.union([.mouseAcceleration])),
        InputConflictApp(bundleID: "com.nuebling.mac-mouse-fix", name: "Mac Mouse Fix", affects: scrollModules.union([.mouseAcceleration])),
        InputConflictApp(bundleID: "com.pilotmoon.scroll-reverser", name: "Scroll Reverser", affects: scrollModules),
        InputConflictApp(bundleID: "com.lujjjh.LinearMouse", name: "LinearMouse", affects: scrollModules.union([.mouseAcceleration])),
        InputConflictApp(bundleID: "com.caldis.Mos", name: "Mos", affects: scrollModules)
    ]

    public static func detect(running: [(bundleID: String?, name: String?)], for module: ModuleID) -> [String] {
        var names: [String] = []
        for app in running {
            for k in known where k.affects.contains(module) {
                let byID = app.bundleID == k.bundleID
                let byName = (app.name ?? "").localizedCaseInsensitiveContains(k.name)
                if (byID || byName) && !names.contains(k.name) { names.append(k.name) }
            }
        }
        return names
    }
}

public enum CGScrollBridge {
    public static func read(_ e: CGEvent) -> ScrollSample {
        ScrollSample(
            vertical: ScrollAxisDelta(line: e.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                                      point: e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                                      fixed: e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
            horizontal: ScrollAxisDelta(line: e.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                                        point: e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                                        fixed: e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
            isContinuous: e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: e.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: e.getIntegerValueField(.scrollWheelEventMomentumPhase),
            scrollCount: e.getIntegerValueField(.scrollWheelEventScrollCount),
            flags: e.flags)
    }

    public static func write(_ s: ScrollSample, to e: CGEvent) {
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: s.vertical.line)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: s.horizontal.line)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: s.vertical.point)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: s.horizontal.point)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.vertical.fixed)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.horizontal.fixed)
        if e.flags != s.flags { e.flags = s.flags }
    }
}
