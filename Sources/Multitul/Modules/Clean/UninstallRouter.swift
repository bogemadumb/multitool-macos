import SwiftUI
import MultitulCore

@MainActor
final class UninstallRouter: ObservableObject {
    static let shared = UninstallRouter()
    @Published var pending: String?

    @discardableResult
    func request(_ appPath: String) -> Bool {
        guard AppController.shared.runtime.isEnabled(.uninstaller), appPath.hasSuffix(".app") else { return false }
        pending = appPath
        AppController.shared.openSection(ModuleGroup.clean.rawValue)
        return true
    }
}
