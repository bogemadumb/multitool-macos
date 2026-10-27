import Foundation

public enum WindowConflicts {
    public struct Known: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var affects: Set<ModuleID>
    }

    public static let known: [Known] = [
        Known(bundleID: "com.knollsoft.Rectangle", name: "Rectangle", affects: [.windowLayout]),
        Known(bundleID: "com.knollsoft.Hookshot", name: "Rectangle Pro", affects: [.windowLayout]),
        Known(bundleID: "com.crowdcafe.windowmagnet", name: "Magnet", affects: [.windowLayout]),
        Known(bundleID: "com.manytricks.Moom", name: "Moom", affects: [.windowLayout, .windowMaximizer]),
        Known(bundleID: "com.hegenberg.BetterSnapTool", name: "BetterSnapTool", affects: [.windowLayout]),
        Known(bundleID: "com.mizage.direct.Divvy", name: "Divvy", affects: [.windowLayout]),
        Known(bundleID: "com.divisiblebyzero.Spectacle", name: "Spectacle", affects: [.windowLayout]),
        Known(bundleID: "co.highlyopinionated.swish", name: "Swish", affects: [.windowLayout, .windowMaximizer, .dockClick]),
        Known(bundleID: "com.amethyst.Amethyst", name: "Amethyst", affects: [.windowLayout]),
        Known(bundleID: "com.lwouis.alt-tab-macos", name: "AltTab", affects: [.dockClick, .windowSwitcher]),
        Known(bundleID: "com.ethanbills.DockDoor", name: "DockDoor", affects: [.dockClick, .windowSwitcher, .dockPreview]),
        Known(bundleID: "", name: "Contexts", affects: [.windowSwitcher]),
        Known(bundleID: "", name: "HyperSwitch", affects: [.windowSwitcher]),
        Known(bundleID: "", name: "HyperDock", affects: [.dockPreview])
    ]

    public static let extraDefaultsKey = "windowConflicts.extraBundleIDs"

    public static var extraBundleIDs: [String] { UserDefaults.standard.stringArray(forKey: extraDefaultsKey) ?? [] }

    public static func detect(running: [(bundleID: String?, name: String?)], for module: ModuleID, extraBundleIDs: [String] = WindowConflicts.extraBundleIDs) -> [String] {
        var names: [String] = []
        for app in running {
            if let id = app.bundleID, extraBundleIDs.contains(id), !names.contains(id) { names.append(id) }
            for k in known where k.affects.contains(module) {
                let byID = app.bundleID == k.bundleID
                let byName = (app.name ?? "").localizedCaseInsensitiveContains(k.name)
                if (byID || byName), !names.contains(k.name) { names.append(k.name) }
            }
        }
        return names
    }
}
