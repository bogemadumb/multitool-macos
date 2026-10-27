import AppKit
import SwiftUI
import MultitulCore
import MultitulUI

@MainActor
final class NavState: ObservableObject {
    @Published var selection = NavCatalog.defaultID {
        didSet { if selection != oldValue { path = NavigationPath(); anchor = nil } }
    }
    @Published var path = NavigationPath()
    @Published var anchor: ScrollAnchor?

    func open(section: String, subpage: String?, isEnabled: (ModuleID) -> Bool, pageRenders: Bool = true) {
        let target = subpage.flatMap { SubpageTable.target(section: section, subpage: $0) }
        let anchorID = subpage.flatMap { SubpageTable.anchor(section: section, subpage: $0) }
        selection = section
        var next = NavigationPath()
        if let target, pageRenders || target.module.map(isEnabled) ?? true { target.push(&next) }
        path = next
        anchor = anchorID.map { ScrollAnchor($0) }
    }
}

@MainActor
final class AppController {
    static let shared = AppController()

    let runtime = ModuleRuntime(factory: makeModule)
    let nav = NavState()
    private var window: NSWindow?
    private var panel: PanelController?
    private var closeObserver: NSObjectProtocol?

    func start() {
        applyAppearance()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        installMainMenu()
        MouseAccelerationController.recoverStale()
        SuperKeyController.recoverStale()
        SpacesOrderController.recoverStale(moduleEnabled: runtime.isEnabled(.spacesOrder))
        SwitcherController.recoverStale(moduleEnabled: runtime.isEnabled(.windowSwitcher))
        ScreenshotController.recoverStale(moduleEnabled: runtime.isEnabled(.screenshot))
        runtime.startEnabled()
        panel = PanelController(runtime: runtime, openWindow: { [weak self] in self?.showWindow() })
        panel?.setIconHidden(statusIconHidden)
        HotkeyManager.shared.register(CoreHotkeys.panel, owner: "core") { [weak self] in self?.panel?.toggle() }
        HotkeyManager.shared.register(CoreHotkeys.window, owner: "core") { [weak self] in self?.showWindow() }
        Log.write("app started trusted_ax=\(AXIsProcessTrusted()) pid=\(getpid())")
    }

    private var statusIconHidden = false

    func setStatusIconHidden(_ hidden: Bool) {
        statusIconHidden = hidden
        panel?.setIconHidden(hidden)
    }

    func openSection(_ id: String) {
        nav.selection = NavCatalog.sidebarID(forSection: id)
        showWindow()
    }

    func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "ui.appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func showWindow() {
        Log.write("window shown")
        panel?.hide()
        if window == nil { window = makeWindow() }
        guard let w = window else { return }
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Мультитул"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.managed]
        w.minSize = NSSize(width: 780, height: 520)
        w.contentViewController = NSHostingController(rootView: RootView(nav: nav, runtime: runtime))
        w.setContentSize(NSSize(width: 1040, height: 740))
        w.center()
        w.setFrameAutosaveName("MultitulMain")
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        return w
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из Мультитула", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Окно")
        win.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.multitool.app").filter { $0.processIdentifier != me }
        if !others.isEmpty {
            Log.write("second instance pid=\(me) exits, running=\(others.map(\.processIdentifier))")
            exit(0)
        }
        MainActor.assumeIsolated { AppController.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppController.shared.showWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SpacesOrderController.shared.keepOnTerminate = true
            AppController.shared.runtime.stopAll()
            Log.write("app terminating")
        }
    }
}
