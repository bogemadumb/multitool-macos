import AppKit
import ImageIO
import QuickLookThumbnailing
import MultitulCore

@MainActor
final class ShelfThumbs {
    static let shared = ShelfThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private var inflight = Set<String>()

    func image(for item: ShelfItem, state: ShelfFileState?, payload: @autoclosure () -> Data?, ready: @escaping () -> Void) -> NSImage {
        let key = "\(item.id)-\(item.hash.prefix(8))-\(state?.path ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let fallback = placeholder(item, state: state)
        switch item.kind {
        case .image:
            if let d = payload(), let img = Self.downscale(data: d, max: 96) { cache.setObject(img, forKey: key); return img }
        case .file:
            if let path = state?.path { generate(path: path, key: key as String, ready: ready) }
        default: break
        }
        return fallback
    }

    private func placeholder(_ item: ShelfItem, state: ShelfFileState?) -> NSImage {
        if item.kind.isPath, let p = state?.path ?? item.path, FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
        return NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil) ?? NSImage()
    }

    private func generate(path: String, key: String, ready: @escaping () -> Void) {
        guard inflight.insert(key).inserted else { return }
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let cg = rep?.cgImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inflight.remove(key)
                    guard let cg else { return }
                    self.cache.setObject(NSImage(cgImage: cg, size: NSSize(width: 32, height: 32)), forKey: key as NSString)
                    ready()
                }
            }
        }
    }

    nonisolated static func downscale(data: Data, max px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: px]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
