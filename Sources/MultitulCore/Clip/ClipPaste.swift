import Foundation
import AppKit

public enum PasteOutcome: Equatable, Sendable {
    case pasted, copiedOnly, nothing, needsAccessibility
}

public enum ClipComposer {
    public static func plainText(_ reps: [ClipRep]) -> String? {
        reps.first { $0.type == PBType.utf8 }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    public static func filePaths(_ reps: [ClipRep]) -> [String] {
        reps.filter { $0.type == PBType.fileURL }.compactMap { ClipCapture.fileURLString($0.data) }
    }

    public static func pasteboardItems(_ reps: [ClipRep]) -> [PasteboardItemData] {
        var byIndex: [Int: [String: Data]] = [:]
        for r in reps { byIndex[r.index, default: [:]][r.type] = r.data }
        return byIndex.keys.sorted().map { PasteboardItemData(reps: byIndex[$0]!) }
    }

    public static func compose(_ entries: [(item: ClipItem, reps: [ClipRep])], plain: Bool, separator: String = "\n") -> [PasteboardItemData] {
        guard !entries.isEmpty else { return [] }
        if entries.count == 1 {
            let e = entries[0]
            if plain, let t = plainText(e.reps) { return [PasteboardItemData(text: t)] }
            return pasteboardItems(e.reps)
        }
        if entries.allSatisfy({ $0.item.kind == .files }) {
            var out: [PasteboardItemData] = []
            for e in entries { out += pasteboardItems(e.reps) }
            return out
        }
        let parts: [String] = entries.compactMap { e in
            switch e.item.kind {
            case .text, .rich: return plainText(e.reps)
            case .files: return filePaths(e.reps).joined(separator: separator)
            case .color: return e.item.title
            case .image: return nil
            }
        }
        return parts.isEmpty ? [] : [PasteboardItemData(text: parts.joined(separator: separator))]
    }
}

public final class ClipPasteEngine {
    private let pasteboard: PasteboardDriving
    private let keys: KeystrokeSending
    private let activator: AppActivating
    private let scheduler: Scheduling
    private let acknowledge: () -> Void
    public var settleDelay = 0.12
    public var modifierPoll = 0.05
    public var modifierPolls = 20

    public init(pasteboard: PasteboardDriving, keys: KeystrokeSending, activator: AppActivating, scheduler: Scheduling, acknowledge: @escaping () -> Void) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.activator = activator
        self.scheduler = scheduler
        self.acknowledge = acknowledge
    }

    @discardableResult
    public func paste(_ entries: [(item: ClipItem, reps: [ClipRep])], plain: Bool, target: AppIdentity?, copyOnly: Bool, completion: ((PasteOutcome) -> Void)? = nil) -> PasteOutcome {
        let items = ClipComposer.compose(entries, plain: plain)
        guard !items.isEmpty else { completion?(.nothing); return .nothing }
        pasteboard.write(items)
        acknowledge()
        if copyOnly { completion?(.copiedOnly); return .copiedOnly }
        guard keys.canSend else { completion?(.needsAccessibility); return .needsAccessibility }
        if let target { activator.activate(target) }
        scheduler.after(settleDelay) { [weak self] in self?.fire(polls: 0, completion: completion) }
        return .pasted
    }

    private func fire(polls: Int, completion: ((PasteOutcome) -> Void)?) {
        if keys.modifiersHeld(), polls < modifierPolls {
            scheduler.after(modifierPoll) { [weak self] in self?.fire(polls: polls + 1, completion: completion) }
            return
        }
        let sent = keys.sendCommandV()
        completion?(sent ? .pasted : .needsAccessibility)
    }
}
