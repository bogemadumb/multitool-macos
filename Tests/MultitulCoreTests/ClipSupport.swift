import Foundation
import AppKit
@testable import MultitulCore

final class ClpFakePasteboard: PasteboardDriving {
    var items: [PasteboardItemData] = []
    var changeCount = 1
    var writes = 0
    var clears = 0

    var typeIdentifiers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for it in items { for t in it.reps.keys.sorted() where seen.insert(t).inserted { out.append(t) } }
        return out
    }

    func readItems(types: Set<String>?) -> [PasteboardItemData] {
        items.map { it in PasteboardItemData(reps: it.reps.filter { types == nil || types!.contains($0.key) }) }
    }

    func write(_ new: [PasteboardItemData]) -> Int {
        items = new
        changeCount += 1
        writes += 1
        return changeCount
    }

    func clear() -> Int {
        items = []
        changeCount += 1
        clears += 1
        return changeCount
    }

    func external(_ new: [PasteboardItemData]) {
        items = new
        changeCount += 1
    }

    func externalText(_ s: String, extra: [String: Data] = [:]) {
        var it = PasteboardItemData(text: s)
        for (k, v) in extra { it.reps[k] = v }
        external([it])
    }
}

final class ClpFakeKeys: KeystrokeSending {
    var canSend = true
    var heldPolls: [Bool] = []
    var pastes = 0
    var returns = 0
    var failSend = false
    var log: [String] = []

    func modifiersHeld() -> Bool { heldPolls.isEmpty ? false : heldPolls.removeFirst() }

    func sendCommandV() -> Bool {
        log.append("paste")
        if failSend { return false }
        pastes += 1
        return true
    }

    func sendReturn() -> Bool {
        returns += 1
        return !failSend
    }
}

final class ClpFakeScheduler: Scheduling {
    var queue: [(delay: TimeInterval, block: () -> Void)] = []
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) { queue.append((delay, block)) }

    func runAll(limit: Int = 100) {
        var n = 0
        while !queue.isEmpty, n < limit {
            let sorted = queue.enumerated().min { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }!
            let item = queue.remove(at: sorted.offset)
            item.block()
            n += 1
        }
    }

    func runNext() {
        guard !queue.isEmpty else { return }
        queue.removeFirst().block()
    }
}

final class ClpFakeActivator: AppActivating {
    var activated: [AppIdentity] = []
    func activate(_ app: AppIdentity) { activated.append(app) }
}

final class ClpFakeFront: FrontmostAppProviding {
    var app: AppIdentity?
    init(_ app: AppIdentity? = nil) { self.app = app }
    func frontmost() -> AppIdentity? { app }
}

final class ClpClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

enum Clp {
    static let safari = AppIdentity(bundleID: "com.apple.Safari", name: "Safari", pid: 101)
    static let notes = AppIdentity(bundleID: "com.apple.Notes", name: "Заметки", pid: 202)

    static func snap(_ items: [PasteboardItemData], source: AppIdentity? = Clp.safari, count: Int = 5) -> ClipSnapshot {
        var seen = Set<String>()
        var types: [String] = []
        for it in items { for t in it.reps.keys.sorted() where seen.insert(t).inserted { types.append(t) } }
        return ClipSnapshot(changeCount: count, types: types, items: items, source: source)
    }

    static func text(_ s: String, extra: [String: Data] = [:]) -> PasteboardItemData {
        var it = PasteboardItemData(text: s)
        for (k, v) in extra { it.reps[k] = v }
        return it
    }

    static func fileItem(_ path: String) -> PasteboardItemData {
        PasteboardItemData(reps: [PBType.fileURL: Data(URL(fileURLWithPath: path).absoluteString.utf8)])
    }

    static func png(width: Int = 4, height: Int = 3) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    static func colorData(_ c: NSColor) -> Data {
        try! NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true)
    }

    static func candidate(_ text: String, source: AppIdentity? = Clp.safari, settings: ClipSettings = ClipSettings()) -> ClipCandidate {
        guard case .record(let c) = ClipCapture.evaluate(snap([Clp.text(text)], source: source), settings: settings) else { fatalError("not recorded: \(text)") }
        return c
    }

    static func store(clock: ClpClock = ClpClock(), path: String? = nil) -> ClipStore {
        try! ClipStore(store: ClipSchema.openStore(path: path ?? tempDBPath()), now: { clock.now })
    }

    static func entries(_ store: ClipStore, _ items: [ClipItem]) -> [(item: ClipItem, reps: [ClipRep])] {
        items.map { ($0, try! store.reps(id: $0.id)) }
    }
}
