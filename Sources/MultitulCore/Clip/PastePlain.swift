import Foundation
import AppKit

public struct PastePlainSettings: Equatable, Sendable {
    public var trimEdges = false
    public var restoreDelay = 0.45
    public init() {}
}

public enum PlainText {
    public static func extract(_ items: [PasteboardItemData], trim: Bool = false) -> String? {
        var text: String?
        for it in items {
            if let s = it.string, !s.isEmpty { text = s; break }
        }
        if text == nil {
            for it in items {
                if let d = it.reps[PBType.rtf],
                   let s = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string, !s.isEmpty { text = s; break }
                if let d = it.reps[PBType.html], let s = htmlToText(d), !s.isEmpty { text = s; break }
            }
        }
        guard var out = text else { return nil }
        if trim { out = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out.isEmpty ? nil : out
    }

    static func htmlToText(_ data: Data) -> String? {
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]
        return (try? NSAttributedString(data: data, options: opts, documentAttributes: nil))?.string
    }
}

public final class PastePlainEngine {
    private let pasteboard: PasteboardDriving
    private let keys: KeystrokeSending
    private let scheduler: Scheduling
    private let acknowledge: () -> Void
    public var settings: PastePlainSettings
    public var modifierPoll = 0.05
    public var modifierPolls = 20
    public var settleDelay = 0.05

    public init(pasteboard: PasteboardDriving, keys: KeystrokeSending, scheduler: Scheduling, settings: PastePlainSettings = PastePlainSettings(), acknowledge: @escaping () -> Void) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.scheduler = scheduler
        self.settings = settings
        self.acknowledge = acknowledge
    }

    @discardableResult
    public func run(completion: ((PasteOutcome) -> Void)? = nil) -> PasteOutcome {
        guard keys.canSend else { completion?(.needsAccessibility); return .needsAccessibility }
        let backup = pasteboard.readItems(types: nil)
        guard let text = PlainText.extract(backup, trim: settings.trimEdges) else { completion?(.nothing); return .nothing }
        let mine = pasteboard.write([PasteboardItemData(text: text)])
        acknowledge()
        scheduler.after(settleDelay) { [weak self] in self?.fire(polls: 0, mine: mine, backup: backup, completion: completion) }
        return .pasted
    }

    private func fire(polls: Int, mine: Int, backup: [PasteboardItemData], completion: ((PasteOutcome) -> Void)?) {
        if keys.modifiersHeld(), polls < modifierPolls {
            scheduler.after(modifierPoll) { [weak self] in self?.fire(polls: polls + 1, mine: mine, backup: backup, completion: completion) }
            return
        }
        let sent = keys.sendCommandV()
        scheduler.after(settings.restoreDelay) { [weak self] in
            guard let self, self.pasteboard.changeCount == mine else { return }
            self.pasteboard.write(backup)
            self.acknowledge()
        }
        completion?(sent ? .pasted : .needsAccessibility)
    }
}
