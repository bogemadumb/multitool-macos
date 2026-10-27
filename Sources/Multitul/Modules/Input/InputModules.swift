import SwiftUI
import MultitulCore

@MainActor
final class InputModule: Module {
    let info: ModuleInfo
    private let controller: InputTapController?
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    init(id: ModuleID) {
        info = id.info
        switch id {
        case .scrollInverter: controller = ScrollInverterController.shared
        case .scrollHorizontal: controller = HorizontalScrollController.shared
        case .linearScroll: controller = LinearScrollController.shared
        case .smoothScroll: controller = SmoothScrollController.shared
        case .scrollZoom: controller = ScrollZoomController.shared
        case .mouseClickDebounce: controller = ClickDebounceController.shared
        case .keyboardDebounce: controller = KeyDebounceController.shared
        case .focusFollowsMouse: controller = FocusFollowsController.shared
        case .mouseNavigation: controller = MouseNavigationController.shared
        case .mouseButtonShortcuts: controller = ButtonShortcutsController.shared
        case .middleClick: controller = MiddleClickController.shared
        case .superKey: controller = SuperKeyController.shared
        case .quitProtection: controller = QuitProtectionController.shared
        case .textSnippets: controller = SnippetsController.shared
        default: controller = nil
        }
    }

    func start() {
        if info.id == .mouseAcceleration { MouseAccelerationController.shared.start() } else { controller?.start() }
        if info.id == .textSnippets {
            HotkeyManager.shared.register(SnippetHotkeys.library, owner: info.id.rawValue) { SnippetsController.shared.toggleLibrary() }
        }
        Log.write("module \(info.id.rawValue) start")
    }

    func stop() {
        if info.id == .textSnippets { HotkeyManager.shared.unregisterAll(owner: info.id.rawValue) }
        if info.id == .mouseAcceleration { MouseAccelerationController.shared.stop() } else { controller?.stop() }
        Log.write("module \(info.id.rawValue) stop")
    }
}
