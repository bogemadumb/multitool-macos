import Foundation

public final class PidLock {
    public let path: String
    private var fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    public static func defaultPath() -> String { MultitulPaths.home + "/agent.lock" }

    public static func acquire(path: String = PidLock.defaultPath()) -> PidLock? {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        ftruncate(fd, 0)
        let line = "\(getpid())\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        return PidLock(path: path, fd: fd)
    }

    public static func holderPID(path: String = PidLock.defaultPath()) -> Int32? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
