import Foundation
import AppKit
import ApplicationServices

public protocol PasteboardDriving: AnyObject {
    var changeCount: Int { get }
    var typeIdentifiers: [String] { get }
    func readItems(types: Set<String>?) -> [PasteboardItemData]
    @discardableResult func write(_ items: [PasteboardItemData]) -> Int
    @discardableResult func clear() -> Int
}

public protocol KeystrokeSending: AnyObject {
    var canSend: Bool { get }
    func modifiersHeld() -> Bool
    @discardableResult func sendCommandV() -> Bool
    @discardableResult func sendReturn() -> Bool
}

public protocol Scheduling: AnyObject {
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void)
}

public protocol AppActivating: AnyObject {
    func activate(_ app: AppIdentity)
}

public protocol FrontmostAppProviding: AnyObject {
    func frontmost() -> AppIdentity?
}

public final class LivePasteboard: PasteboardDriving {
    private let pb: NSPasteboard

    public init(_ pb: NSPasteboard = .general) { self.pb = pb }

    public var changeCount: Int { pb.changeCount }

    public var typeIdentifiers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in pb.pasteboardItems ?? [] {
            for t in item.types where seen.insert(t.rawValue).inserted { out.append(t.rawValue) }
        }
        return out
    }

    public func readItems(types: Set<String>?) -> [PasteboardItemData] {
        (pb.pasteboardItems ?? []).map { item in
            var reps: [String: Data] = [:]
            for t in item.types where types == nil || types!.contains(t.rawValue) {
                if let d = item.data(forType: t) { reps[t.rawValue] = d }
            }
            return PasteboardItemData(reps: reps)
        }
    }

    @discardableResult
    public func write(_ items: [PasteboardItemData]) -> Int {
        pb.clearContents()
        let objs: [NSPasteboardItem] = items.map { it in
            let o = NSPasteboardItem()
            for (t, d) in it.reps { o.setData(d, forType: NSPasteboard.PasteboardType(t)) }
            return o
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
        return pb.changeCount
    }

    @discardableResult
    public func clear() -> Int {
        pb.clearContents()
        return pb.changeCount
    }
}

public final class LiveKeystrokes: KeystrokeSending {
    public static let marker: Int64 = 0x4D4C5453

    public init() {}

    public var canSend: Bool { AXIsProcessTrusted() }

    public func modifiersHeld() -> Bool {
        let f = NSEvent.modifierFlags
        return !f.intersection([.command, .option, .control, .shift]).isEmpty
    }

    public func sendCommandV() -> Bool { post(key: 9, flags: .maskCommand) }
    public func sendReturn() -> Bool { post(key: 36, flags: []) }

    private func post(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard AXIsProcessTrusted(), let src = CGEventSource(stateID: .privateState) else { return false }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return false }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
        }
        return true
    }
}

public final class LiveScheduler: Scheduling {
    public init() {}
    public func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

public final class LiveActivator: AppActivating {
    public init() {}
    public func activate(_ app: AppIdentity) {
        guard app.pid > 0 else { return }
        NSRunningApplication(processIdentifier: app.pid)?.activate()
    }
}

public final class LiveFrontmost: FrontmostAppProviding {
    public init() {}
    public func frontmost() -> AppIdentity? {
        guard let a = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(bundleID: a.bundleIdentifier, name: a.localizedName, pid: a.processIdentifier)
    }
}
