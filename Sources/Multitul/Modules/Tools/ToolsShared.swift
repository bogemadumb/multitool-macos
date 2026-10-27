import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ToolsRouter {
    static let shared = ToolsRouter()
    private var actions: [LauncherTool: () -> Void] = [:]

    func register(_ tool: LauncherTool, _ action: @escaping () -> Void) { actions[tool] = action }
    func unregister(_ tool: LauncherTool) { actions[tool] = nil }
    func isAvailable(_ tool: LauncherTool) -> Bool { actions[tool] != nil }

    @discardableResult
    func run(_ tool: LauncherTool) -> Bool {
        guard let a = actions[tool] else { return false }
        a()
        return true
    }
}

final class AppLauncherExecutor: LauncherExecuting {
    func execute(_ command: LauncherCommand) -> LauncherExecResult {
        MainActor.assumeIsolated {
            switch command {
            case .tool(let t):
                if ToolsRouter.shared.run(t) { return .ok }
                return .failed("Модуль «\(t.module.info.title)» выключен")
            case .toggle(let id):
                QuickTogglesController.shared.perform(id)
                return .ok
            case .openApp(let path):
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    if let err { Log.write("launcher open app failed: \(err.localizedDescription)") }
                }
                return .ok
            case .openURL(let url):
                return NSWorkspace.shared.open(url) ? .ok : .failed("Не удалось открыть ссылку")
            case .run(let exe, let args):
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return .failed("Не удалось запустить: \(error.localizedDescription)") }
                return .ok
            }
        }
    }
}
