import Foundation

public enum MultitulPaths {
    public static var home: String {
        if let e = ProcessInfo.processInfo.environment["MULTITUL_HOME"], !e.isEmpty { return e }
        return NSHomeDirectory() + "/Library/Application Support/Multitul"
    }
    public static var dbPath: String { home + "/multitul.db" }
    public static var stagingDir: String { home + "/staging" }
    public static var shelfFilesDir: String { home + "/shelf-files" }
    public static var shelfOutDir: String { home + "/shelf-out" }
    public static var shelfArchivesDir: String { home + "/shelf-archives" }
    public static var shotCacheDir: String { home + "/screenshots" }
    public static var recCacheDir: String { home + "/recordings" }
}
