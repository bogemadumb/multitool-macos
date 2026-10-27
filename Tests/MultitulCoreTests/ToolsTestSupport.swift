import Foundation
import CoreGraphics
@testable import MultitulCore

final class TlsClock: ToolsClock {
    var now: Date
    init(_ t: Double = 1_800_000_000) { now = Date(timeIntervalSince1970: t) }
    func advance(_ s: Double) { now = now.addingTimeInterval(s) }
}

final class TlsTextSink: TextWriting {
    var writes: [String] = []
    func write(_ text: String) { writes.append(text) }
}

final class TlsPixels: PixelSource {
    let pixelWidth: Int
    let pixelHeight: Int
    var fill: (Int, Int) -> RGBAColor
    init(_ w: Int, _ h: Int, fill: @escaping (Int, Int) -> RGBAColor = { x, y in RGBAColor(red8: x * 10 % 256, green8: y * 10 % 256, blue8: 7) }) {
        pixelWidth = w
        pixelHeight = h
        self.fill = fill
    }
    func color(atX x: Int, y: Int) -> RGBAColor? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        return fill(x, y)
    }
}

func tlsImage(_ w: Int = 8, _ h: Int = 8, topRed: Bool = true) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
    return ctx.makeImage()!
}

final class TlsRecognizer: OcrRecognizing {
    var lines: [OcrLine] = []
    var codes: [String] = []
    var error: Error?
    var textCalls = 0
    var codeCalls = 0
    var lastConfig: OcrRequestConfig?

    func recognizeText(in image: CGImage, config: OcrRequestConfig) throws -> [OcrLine] {
        textCalls += 1
        lastConfig = config
        if let error { throw error }
        return lines
    }

    func detectCodes(in image: CGImage) -> [String] {
        codeCalls += 1
        return codes
    }
}

struct TlsError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

final class TlsToggleDriver: QuickToggleDriving {
    var dark = false
    var hidden = false
    var vols: [VolumeInfo] = []
    var failEject: Set<String> = []
    var ejected: [String] = []
    var trash: Int? = 3
    var okAll = true
    var calls: [String] = []

    func isDarkMode() -> Bool { dark }
    func setDarkMode(_ on: Bool) -> Bool { calls.append("dark"); if okAll { dark = on }; return okAll }
    func desktopIconsHidden() -> Bool { hidden }
    func setDesktopIconsHidden(_ h: Bool) -> Bool { calls.append("icons"); if okAll { hidden = h }; return okAll }
    func volumes() -> [VolumeInfo] { vols }
    func eject(_ v: VolumeInfo) -> Bool { calls.append("eject:\(v.name)"); if failEject.contains(v.name) { return false }; ejected.append(v.name); return true }
    func trashItemCount() -> Int? { trash }
    func emptyTrash() -> Bool { calls.append("trash"); if okAll { trash = 0 }; return okAll }
    func restartFinder() -> Bool { calls.append("finder"); return okAll }
    func lockScreen() -> Bool { calls.append("lock"); return okAll }
    func sleepDisplays() -> Bool { calls.append("display"); return okAll }
    func startScreenSaver() -> Bool { calls.append("saver"); return okAll }
}

final class TlsOverlay: CleaningOverlayShowing {
    var shown: [(CleaningScreenMode, Int)] = []
    var updates: [Int] = []
    var hides = 0
    func show(mode: CleaningScreenMode, needed: Int) { shown.append((mode, needed)) }
    func update(presses: Int, needed: Int) { updates.append(presses) }
    func hide() { hides += 1 }
}

final class TlsCamera: CameraDriving {
    var auth = CameraAuthorization.authorized
    var list: [CameraDevice] = [CameraDevice(id: "ext", name: "Logitech"), CameraDevice(id: "built", name: "FaceTime", isBuiltIn: true)]
    var running = false
    var started: [String] = []
    var stops = 0
    var failStart = false
    var pending: ((Bool) -> Void)?

    var isRunning: Bool { running }
    func authorization() -> CameraAuthorization { auth }
    func requestAccess(_ completion: @escaping (Bool) -> Void) { pending = completion }
    func devices() -> [CameraDevice] { list }
    func start(deviceID: String) -> Bool {
        if failStart { return false }
        started.append(deviceID)
        running = true
        return true
    }
    func stop() { stops += 1; running = false }
}

final class TlsScratchStore: ScratchNoteStoring {
    var notes: [ScratchNote] = []
    var nextID: Int64 = 1
    var saves = 0
    var fail = false

    func loadAll() throws -> [ScratchNote] { notes }
    func insert(title: String, text: String, at: Date) throws -> ScratchNote {
        if fail { throw TlsError() }
        let n = ScratchNote(id: nextID, title: title, text: text, created: at, updated: at)
        nextID += 1
        notes.append(n)
        return n
    }
    func save(_ note: ScratchNote) throws {
        if fail { throw TlsError() }
        saves += 1
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
    }
    func delete(id: Int64) throws { notes.removeAll { $0.id == id } }
    func savePositions(_ ids: [Int64]) throws { notes = ids.compactMap { id in notes.first { $0.id == id } } }
}

final class TlsScheduler: ScratchScheduling {
    var action: (() -> Void)?
    var lastDelay: TimeInterval?
    var cancels = 0
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) { lastDelay = seconds; self.action = action }
    func cancel() { cancels += 1; action = nil }
    func fire() { let a = action; action = nil; a?() }
}

final class TlsFiles: LauncherFileChecking {
    var files: Set<String> = []
    var executables: Set<String> = []
    var bundles: [String: String] = [:]
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func appPath(forBundleID id: String) -> String? { bundles[id] }
}

final class TlsExecutor: LauncherExecuting {
    var commands: [LauncherCommand] = []
    var result = LauncherExecResult.ok
    func execute(_ command: LauncherCommand) -> LauncherExecResult { commands.append(command); return result }
}
