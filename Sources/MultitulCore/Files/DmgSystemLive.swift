import Foundation
import AppKit
import MultitulCtlCore

public struct DmgAttachError: Error, CustomStringConvertible {
    public let description: String
}

public final class DmgSystemLive: DmgSystem, @unchecked Sendable {
    private let runner: ProcessRunning
    private let fm = FileManager.default

    public init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    public func listTopLevel(_ path: String) -> [DmgEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return DmgEntry(name: u.lastPathComponent, isDirectory: v?.isDirectory ?? false, isSymlink: v?.isSymbolicLink ?? false)
        }
    }

    public func bundleInfo(_ appPath: String) -> AppBundleInfo? {
        guard let info = Bundle(path: appPath)?.infoDictionary else { return nil }
        let v = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        return AppBundleInfo(bundleID: info["CFBundleIdentifier"] as? String, version: v)
    }

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    public func isRunning(appAt path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }

    public func isWritableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: path)
    }

    public func verifySignature(_ appPath: String) -> SignatureCheck {
        let o = runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath], timeout: 60)
        if o.status == 0 { return .valid }
        if o.stderr.contains("not signed at all") { return .unsigned }
        return .invalid(o.stderr.split(separator: "\n").first.map(String.init) ?? "код \(o.status)")
    }

    public func copyBundle(from: String, to: String, replacing: Bool) throws {
        let dir = (to as NSString).deletingLastPathComponent
        let tmp = dir + "/." + (to as NSString).lastPathComponent + ".multitul-new"
        if fm.fileExists(atPath: tmp) { try? fm.removeItem(atPath: tmp) }
        if !fm.fileExists(atPath: dir) { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let o = runner.run("/usr/bin/ditto", [from, tmp], timeout: 600)
        guard o.status == 0 else {
            try? fm.removeItem(atPath: tmp)
            throw DmgAttachError(description: o.stderr.isEmpty ? "ditto завершился с кодом \(o.status)" : o.stderr)
        }
        do {
            if replacing, fm.fileExists(atPath: to) { try moveToTrash(to) }
            try fm.moveItem(atPath: tmp, toPath: to)
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw error
        }
    }

    public func moveToTrash(_ path: String) throws {
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    public func detach(mountPoint: String, force: Bool) -> Bool {
        runner.run("/usr/bin/hdiutil", ["detach", mountPoint] + (force ? ["-force"] : []), timeout: 60).status == 0
    }

    public func reveal(_ path: String) {
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    public func attachedImages() -> [AttachedImage] {
        let o = runner.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30)
        return HdiutilParser.images(infoPlist: Data(o.stdout.utf8))
    }

    public func attach(dmgPath: String) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-plist", "-nobrowse", "-readonly", "-noverify", "-noautoopen", dmgPath]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        try p.run()
        inp.fileHandleForWriting.write(Data("Y\n".utf8))
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DmgAttachError(description: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return HdiutilParser.mountPoints(attachPlist: data)
    }
}
