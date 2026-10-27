import SwiftUI
import AppKit
import MultitulCore

@MainActor
final class ShelfIntake {
    let service: ShelfService
    let filesDir: String
    var onAdded: ((ShelfAddResult) -> Void)?

    init(service: ShelfService, filesDir: String = MultitulPaths.shelfFilesDir) {
        self.service = service
        self.filesDir = filesDir
    }

    @discardableResult
    func accept(_ pb: NSPasteboard) -> Bool {
        let receivers = ShelfPasteboardReader.receivers(pb)
        var incoming = ShelfIngest.parse(ShelfPasteboardReader.read(pb))
        if !receivers.isEmpty { incoming = incoming.filter { if case .file = $0 { true } else { false } } }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if !incoming.isEmpty {
            let r = service.add(incoming, source: source)
            onAdded?(r)
        }
        for r in receivers { receive(r) }
        return !incoming.isEmpty || !receivers.isEmpty
    }

    func addPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        onAdded?(service.addPaths(paths, source: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    private func receive(_ r: NSFilePromiseReceiver) {
        let dest = URL(fileURLWithPath: filesDir + "/" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { [weak self] url, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { try? FileManager.default.removeItem(at: dest); return }
                let res = self.service.addPaths([url.path], owned: true)
                self.onAdded?(res)
            }
        }
    }
}

final class ShelfDropContainer: NSView {
    var intake: ShelfIntake?
    var onTarget: ((Bool) -> Void)?

    init(content: NSView) {
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes(ShelfPasteboardReader.draggedTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] }
        onTarget?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingSource == nil ? .copy : [] }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTarget?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTarget?(false)
        guard sender.draggingSource == nil else { return false }
        let pb = sender.draggingPasteboard
        return MainActor.assumeIsolated { intake?.accept(pb) ?? false }
    }
}

final class ShelfStatusDropView: NSView {
    var intake: ShelfIntake?
    var onClick: ((NSEvent) -> Void)?
    var onTarget: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfPasteboardReader.draggedTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?(event) }
    override func rightMouseDown(with event: NSEvent) { onClick?(event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] }
        onTarget?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTarget?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTarget?(false)
        let pb = sender.draggingPasteboard
        return MainActor.assumeIsolated { intake?.accept(pb) ?? false }
    }
}

@MainActor
final class ShelfStatusItem: NSObject {
    private var item: NSStatusItem?
    private var drop: ShelfStatusDropView?
    var onLeftClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    var intake: ShelfIntake? { didSet { drop?.intake = intake } }

    var iconFrame: CGRect? { item?.button?.window?.frame }
    var isInstalled: Bool { item != nil }

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Полка")
        it.button?.image?.isTemplate = true
        it.button?.imagePosition = .imageLeading
        it.button?.toolTip = "Полка: брось сюда файл, клик открывает список"
        if let b = it.button {
            let v = ShelfStatusDropView(frame: b.bounds)
            v.autoresizingMask = [.width, .height]
            v.intake = intake
            v.onClick = { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if e.type == .rightMouseDown || e.modifierFlags.contains(.control) {
                        if let m = self.menuProvider?() { NSMenu.popUpContextMenu(m, with: e, for: v) }
                    } else {
                        self.onLeftClick?()
                    }
                }
            }
            v.onTarget = { [weak b] on in b?.highlight(on) }
            b.addSubview(v)
            drop = v
        }
        item = it
    }

    func remove() {
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
        drop = nil
    }

    func setCount(_ n: Int) {
        item?.button?.title = n > 0 ? " \(n)" : ""
    }
}
