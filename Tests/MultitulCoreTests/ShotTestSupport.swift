import Foundation
import CoreGraphics
@testable import MultitulCore

func shotPage(rows: Int, width: Int = 24) -> ShotBitmap {
    ShotBitmap(width: width, height: rows) { x, y in (UInt8(y & 255), UInt8((y >> 8) & 255), UInt8((x * 5 + y * 13) & 255), 255) }
}

func shotView(_ page: ShotBitmap, top: Int, height: Int) -> ShotBitmap { page.rows(top..<(top + height)) }

func shotSticky(_ view: ShotBitmap, header: Int = 0, footer: Int = 0) -> ShotBitmap {
    var v = view
    let w = v.width
    for y in 0..<header { for x in 0..<w { v.setPixel(x, y, (200, 201, UInt8(x), 255)) } }
    for y in (v.height - footer)..<v.height where footer > 0 { for x in 0..<w { v.setPixel(x, y, (10, 11, UInt8(x), 255)) } }
    return v
}

func shotImage(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8) = (30, 60, 90, 255)) -> CGImage {
    ShotBitmap(width: w, height: h, color: c).makeImage()!
}

func shotDisplay(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2) -> ShotDisplay {
    ShotDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h), scale: scale)
}

let shotMain = shotDisplay(1, 0, 0, 1440, 900)
let shotRight = shotDisplay(2, 1440, 0, 1920, 1080, scale: 1)
let shotLeft = shotDisplay(3, -1280, 100, 1280, 800, scale: 1)

func shotWin(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, title: String = "", owner: String = "App", layer: Int = 0, pid: Int32 = 100) -> ShotWindowInfo {
    ShotWindowInfo(id: id, ownerPid: pid, ownerName: owner, title: title, frame: CGRect(x: x, y: y, width: w, height: h), layer: layer)
}

final class ShotFakeFiles: ShotFileStoring {
    var files: [String: Data] = [:]
    var trashed: [String] = []
    var removed: [String] = []
    var failWrites = false

    func exists(_ path: String) -> Bool { files[path] != nil }
    func read(_ path: String) -> Data? { files[path] }

    func write(_ data: Data, to path: String) -> Bool {
        if failWrites { return false }
        files[path] = data
        return true
    }

    func trash(_ path: String) -> Bool { trashed.append(path); return files.removeValue(forKey: path) != nil }
    func remove(_ path: String) -> Bool { removed.append(path); return files.removeValue(forKey: path) != nil }
}

final class ShotFakeEncoder: ShotImageEncoding {
    var supported: Set<ShotFormat> = Set(ShotFormat.allCases)
    var fail = false
    var calls: [(ShotFormat, Int, Int)] = []

    func supports(_ format: ShotFormat) -> Bool { supported.contains(format) }

    func encode(_ image: CGImage, format: ShotFormat, quality: Double) -> Data? {
        calls.append((format, image.width, image.height))
        if fail { return nil }
        return Data("\(format.rawValue):\(image.width)x\(image.height)".utf8)
    }
}

final class ShotFakeClipboard: ShotClipboardWriting {
    var images: [Data] = []
    var ok = true
    func writeImage(png: Data) -> Bool { images.append(png); return ok }
}

final class ShotFakeShelf: ShotShelfSinking {
    var isAvailable = true
    var added: [(path: String?, name: String)] = []
    func addScreenshot(path: String?, data: Data, fileName: String) -> Bool { added.append((path, fileName)); return true }
}

final class ShotFakeIndexer: ShotTextIndexing {
    var result = ""
    var calls = 0
    func text(in image: CGImage) -> String { calls += 1; return result }
}

final class ShotFakeHTTP: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    var response = HTTPResponse(status: 200, body: Data(#"{"url":"https://files.example.com/a.png"}"#.utf8))
    var error: Error?

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        if let error { throw error }
        return response
    }
}

final class ShotFakeScroll: ShotScrollDriving {
    let page: ShotBitmap
    let height: Int
    var top = 0
    var scrolled: [Int] = []
    var captures = 0
    var failAfter: Int?
    var onCapture: ((ShotFakeScroll) -> Void)?
    var moveFactor = 1.0

    init(page: ShotBitmap, height: Int) {
        self.page = page
        self.height = height
    }

    func captureFrame() async -> ShotBitmap? {
        captures += 1
        onCapture?(self)
        if let f = failAfter, captures > f { return nil }
        return shotView(page, top: top, height: height)
    }

    func scroll(pixels: Int) async {
        scrolled.append(pixels)
        top = min(top + Int(Double(pixels) * moveFactor), page.height - height)
    }

    func settle() async {}
}
