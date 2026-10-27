import SwiftUI
import MultitulCore

@MainActor
final class WindowsModule: Module {
    let info: ModuleInfo
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var panelCard: AnyView? { info.id == .windowLayout ? AnyView(WindowLayoutPanelCard()) : nil }

    init(id: ModuleID) { info = id.info }

    func start() {
        switch info.id {
        case .windowLayout: WindowLayoutController.shared.start()
        case .windowMaximizer: MaximizerController.shared.start()
        case .dockClick: DockClickController.shared.start()
        case .autoQuit: AutoQuitController.shared.start()
        case .spacesOrder: SpacesOrderController.shared.start()
        case .windowSwitcher: SwitcherController.shared.start()
        case .dockPreview: DockPreviewController.shared.start()
        default: break
        }
        Log.write("module \(info.id.rawValue) start")
    }

    func stop() {
        switch info.id {
        case .windowLayout: WindowLayoutController.shared.stop()
        case .windowMaximizer: MaximizerController.shared.stop()
        case .dockClick: DockClickController.shared.stop()
        case .autoQuit: AutoQuitController.shared.stop()
        case .spacesOrder: SpacesOrderController.shared.stop()
        case .windowSwitcher: SwitcherController.shared.stop()
        case .dockPreview: DockPreviewController.shared.stop()
        default: break
        }
        Log.write("module \(info.id.rawValue) stop")
    }
}
