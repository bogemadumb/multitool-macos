import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ClipPreviewStatusItem: NSObject {
    private var item: NSStatusItem?
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) { self.onClick = onClick }

    func render(text: String?) {
        guard let text else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.target = self
            it.button?.action = #selector(clicked)
            it.button?.sendAction(on: [.leftMouseDown])
            it.button?.font = .systemFont(ofSize: 11)
            item = it
        }
        item?.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Буфер обмена")
        item?.button?.imagePosition = .imageLeading
        item?.button?.title = " " + (text.count > 22 ? String(text.prefix(22)) + "…" : text)
        item?.button?.toolTip = "Последнее скопированное. Нажми, чтобы открыть историю"
    }

    @objc private func clicked() { onClick() }
}

@MainActor
final class ClipboardHistoryModule: Module {
    let info = ModuleID.clipboardHistory.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(ClipboardTile()) }
    private var preview: ClipPreviewStatusItem?

    func start() {
        let c = ClipboardController.shared
        preview = ClipPreviewStatusItem { ClipboardController.shared.picker.toggle() }
        c.onChange = { [weak self] in self?.render() }
        c.start()
        ToolsRouter.shared.register(.clipboard) { ClipboardController.shared.picker.toggle() }
        render()
        Log.write("module clipboardHistory start")
    }

    func stop() {
        ClipboardController.shared.stop()
        ToolsRouter.shared.unregister(.clipboard)
        preview?.render(text: nil)
        preview = nil
        Log.write("module clipboardHistory stop")
    }

    private func render() {
        let c = ClipboardController.shared
        preview?.render(text: c.settings.menuBarPreview ? (c.lastItem?.title ?? "Буфер") : nil)
    }
}

struct ClipboardTile: View {
    var body: some View {
        QuickTile(symbol: "doc.on.clipboard", caption: "Буфер") { ClipboardController.shared.picker.toggle() }
    }
}

@MainActor
final class PastePlainModule: Module {
    let info = ModuleID.pastePlain.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "textformat.abc", caption: "Без формата") { PastePlainController.shared.run() }) }

    func start() { PastePlainController.shared.start() }
    func stop() { PastePlainController.shared.stop() }
}

@MainActor
final class UrlCleanerModule: Module {
    let info = ModuleID.urlCleaner.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "link", caption: "Ссылка", help: "Чистка ссылки") { UrlCleanerController.shared.cleanNow() }) }

    func start() { UrlCleanerController.shared.start() }
    func stop() { UrlCleanerController.shared.stop() }
}

@MainActor
final class DmgInstallerModule: Module {
    let info = ModuleID.dmgInstaller.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { DmgController.shared.start() }
    func stop() { DmgController.shared.stop() }
}

@MainActor
final class FinderCutPasteModule: Module {
    let info = ModuleID.finderCutPaste.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { FinderCutController.shared.start() }
    func stop() { FinderCutController.shared.stop() }
}

@MainActor
final class FinderRenameModule: Module {
    let info = ModuleID.finderRename.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { FinderRenameController.shared.start() }
    func stop() { FinderRenameController.shared.stop() }
}
