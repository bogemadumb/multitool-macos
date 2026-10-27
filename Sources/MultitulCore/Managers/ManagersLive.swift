import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

public struct SystemMediaFileOps: MediaFileOps {
    public init() {}

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func size(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    public func move(_ from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    public func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    public func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

public enum ImageIOConvertError: Error, LocalizedError {
    case unreadable, unsupportedFormat, writeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "картинка не читается"
        case .unsupportedFormat: "формат не поддерживается системой"
        case .writeFailed: "не удалось записать картинку"
        }
    }
}

public struct ImageIOConverter: ImageConverting {
    public init() {}

    static func typeIdentifier(_ t: ImageTarget) -> String? {
        switch t {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        case .bmp: UTType.bmp.identifier
        case .gif: UTType.gif.identifier
        case .webp: nil
        }
    }

    public func convert(input: String, output: String, options o: ImageConvertOptions) throws {
        guard let type = Self.typeIdentifier(o.format) else { throw ImageIOConvertError.unsupportedFormat }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil) else { throw ImageIOConvertError.unreadable }
        var image: CGImage?
        if o.maxSide > 0 {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: o.maxSide]
            if let full = CGImageSourceCreateImageAtIndex(src, 0, nil), max(full.width, full.height) > o.maxSide {
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            } else {
                image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard var img = image else { throw ImageIOConvertError.unreadable }
        if o.format == .jpeg || o.format == .bmp, Self.hasAlpha(img), let flat = Self.flatten(img) { img = flat }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, type as CFString, 1, nil) else { throw ImageIOConvertError.unsupportedFormat }
        var props: [CFString: Any] = [:]
        if !o.stripMetadata, let original = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] { props = original }
        if o.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = Double(ToolsClamp.int(o.quality, 1...100)) / 100 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageIOConvertError.writeFailed }
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func flatten(_ img: CGImage) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}

private final class DiscardingText: TextWriting {
    func write(_ text: String) {}
}

public struct VisionMediaTextExtractor: MediaTextExtracting {
    public init() {}

    public func extractText(imagePath: String) throws -> String {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageIOConvertError.unreadable
        }
        let engine = ScreenOcrEngine(recognizer: VisionOcrRecognizer(), clipboard: DiscardingText(), settings: OcrSettings())
        engine.settings.detectQr = false
        switch engine.process(image) {
        case .text(let t): return t
        case .failed(let m): throw NSError(domain: "dev.multitool.app.ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
        default: return ""
        }
    }
}

public struct URLSessionFetcher: HTTPFetching {
    public init() {}

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("Multitul/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/xml, text/xml, application/rss+xml, application/json, */*", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public final class SystemAppCatalog: AppCataloging {
    private let extraFolders: () -> [String]

    public init(extraFolders: @escaping () -> [String] = { [] }) { self.extraFolders = extraFolders }

    public func installedApps() -> [UpdateAppBundle] {
        let home = NSHomeDirectory()
        let dirs = ["/Applications", "/Applications/Utilities", home + "/Applications"] + extraFolders()
        var out: [UpdateAppBundle] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for d in dirs {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let p = d + "/" + n
                if n.hasSuffix(".app") {
                    if let a = read(p), seen.insert(a.path).inserted { out.append(a) }
                } else if !n.hasPrefix("."), (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeDirectory {
                    for m in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where m.hasSuffix(".app") {
                        if let a = read(p + "/" + m), seen.insert(a.path).inserted { out.append(a) }
                    }
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func read(_ path: String) -> UpdateAppBundle? {
        guard let d = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { return nil }
        let receipt = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        return UpdateAppBundleReader.parse(plist: d, path: path, hasStoreReceipt: receipt)
    }
}

public final class TerminalAppleScriptOpener: TerminalOpening {
    public init() {}

    public func open(command: String) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: TerminalScript.appleScript(running: command))
        script?.executeAndReturnError(&error)
        if let error { Log.write("terminal open failed: \(error)") }
        return error == nil
    }
}
