import Foundation

public enum Log {
    public static let dir = NSHomeDirectory() + "/Library/Logs/Multitul"
    public static var path: String { dir + "/app.log" }
    private static let queue = DispatchQueue(label: "dev.multitool.app.log")
    nonisolated(unsafe) public static var enabled = ProcessInfo.processInfo.environment["MULTITUL_NO_LOG"] == nil

    public static func write(_ message: String) {
        guard enabled else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
