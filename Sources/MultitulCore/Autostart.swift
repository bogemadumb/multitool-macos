import Foundation

public enum Autostart {
    public static let label = "dev.multitool.app"
    public static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    public static func isEnabled() -> Bool {
        guard let d = NSDictionary(contentsOfFile: plistPath) else { return false }
        return (d["RunAtLoad"] as? Bool) == true
    }

    // Rewrites only the plist: bootout from inside would SIGTERM this process.
    @discardableResult
    public static func set(_ on: Bool) -> Bool {
        let d = NSMutableDictionary(contentsOfFile: plistPath) ?? NSMutableDictionary(dictionary: [
            "Label": label,
            "ProgramArguments": [NSHomeDirectory() + "/Applications/Multitul.app/Contents/MacOS/Multitul"],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ])
        d["RunAtLoad"] = on
        if on { d["KeepAlive"] = ["SuccessfulExit": false] } else { d.removeObject(forKey: "KeepAlive") }
        return d.write(toFile: plistPath, atomically: true)
    }
}
