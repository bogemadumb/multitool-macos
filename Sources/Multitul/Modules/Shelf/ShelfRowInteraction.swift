import SwiftUI
import AppKit

struct ShelfRowInteraction: NSViewRepresentable {
    var onDown: (_ command: Bool, _ shift: Bool, _ clicks: Int) -> Void
    var onUp: (_ command: Bool, _ shift: Bool) -> Void
    var dragSetup: () -> ShelfDragSetup?
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ v: InteractionView, context: Context) {
        v.onDown = onDown
        v.onUp = onUp
        v.dragSetup = dragSetup
        v.menuProvider = menu
    }
}

struct ShelfDragSetup {
    var writers: [NSPasteboardWriting]
    var preview: NSImage
    var ids: [Int64]
    var finished: (Bool) -> Void
}

final class InteractionView: NSView, NSDraggingSource {
    var onDown: ((Bool, Bool, Int) -> Void)?
    var onUp: ((Bool, Bool) -> Void)?
    var dragSetup: (() -> ShelfDragSetup?)?
    var menuProvider: (() -> NSMenu?)?
    private var downEvent: NSEvent?
    private var dragging = false
    private var finish: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        let f = event.modifierFlags
        onDown?(f.contains(.command), f.contains(.shift), event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragging else { return }
        let f = event.modifierFlags
        onUp?(f.contains(.command), f.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16, let setup = dragSetup?(), !setup.writers.isEmpty else { return }
        dragging = true
        finish = setup.finished
        let items = setup.writers.enumerated().map { i, w -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: w)
            let size = NSSize(width: 36, height: 36)
            let origin = convert(down.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: origin.x - 18 + CGFloat(i) * 6, y: origin.y - 18 - CGFloat(i) * 6, width: size.width, height: size.height), contents: setup.preview)
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = menuProvider?() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let f = finish
        finish = nil
        dragging = false
        downEvent = nil
        f?(operation != [])
    }
}
