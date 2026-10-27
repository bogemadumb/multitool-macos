import Foundation

public enum ShelfBookmarkResult: Equatable, Sendable {
    case resolved(path: String, stale: Bool)
    case failed
}

public protocol ShelfFileSystem: AnyObject {
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func fileSize(_ path: String) -> Int
    func makeBookmark(_ path: String) -> Data?
    func resolveBookmark(_ data: Data) -> ShelfBookmarkResult
    @discardableResult func remove(_ path: String) -> Bool
    func list(_ dir: String) -> [String]
    @discardableResult func write(_ data: Data, to path: String) -> Bool
    @discardableResult func makeDirectory(_ path: String) -> Bool
    @discardableResult func symlink(at path: String, to target: String) -> Bool
}

public final class LiveShelfFileSystem: ShelfFileSystem {
    private let fm = FileManager.default

    public init() {}

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    public func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    public func fileSize(_ path: String) -> Int {
        guard let a = try? fm.attributesOfItem(atPath: path), let n = a[.size] as? NSNumber else { return 0 }
        return n.intValue
    }

    public func makeBookmark(_ path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolveBookmark(_ data: Data) -> ShelfBookmarkResult {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { return .failed }
        return .resolved(path: url.path, stale: stale)
    }

    public func remove(_ path: String) -> Bool { (try? fm.removeItem(atPath: path)) != nil }

    public func list(_ dir: String) -> [String] { (try? fm.contentsOfDirectory(atPath: dir)) ?? [] }

    public func write(_ data: Data, to path: String) -> Bool {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    public func makeDirectory(_ path: String) -> Bool { (try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil }

    public func symlink(at path: String, to target: String) -> Bool { (try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)) != nil }
}
