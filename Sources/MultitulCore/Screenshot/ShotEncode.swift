import Foundation
import CoreGraphics
import ImageIO

public protocol ShotImageEncoding: AnyObject {
    func encode(_ image: CGImage, format: ShotFormat, quality: Double) -> Data?
    func supports(_ format: ShotFormat) -> Bool
}

public final class ImageIOShotEncoder: ShotImageEncoding {
    public init() {}

    public func supports(_ format: ShotFormat) -> Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(format.typeIdentifier)
    }

    public func encode(_ image: CGImage, format: ShotFormat, quality: Double) -> Data? {
        let out = NSMutableData()
        guard supports(format), let dest = CGImageDestinationCreateWithData(out, format.typeIdentifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format.usesQuality { props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1) }
        var source = image
        if !format.keepsAlpha, let flat = ShotImageOps.flattened(image) { source = flat }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

public enum ShotImageOps {
    public static func flattened(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage? {
        guard let ctx = ShotRenderer.makeContext(image.width, image.height, data: nil) else { return nil }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func load(path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

public enum ShotThumbnail {
    public static let defaultSide = 320

    public static func fit(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        guard width > 0, height > 0, maxSide > 0 else { return (0, 0) }
        let longest = max(width, height)
        if longest <= maxSide { return (width, height) }
        let k = Double(maxSide) / Double(longest)
        return (max(Int((Double(width) * k).rounded()), 1), max(Int((Double(height) * k).rounded()), 1))
    }

    public static func make(from image: CGImage, maxSide: Int = defaultSide) -> CGImage? {
        let (w, h) = fit(width: image.width, height: image.height, maxSide: maxSide)
        guard w > 0, let ctx = ShotRenderer.makeContext(w, h, data: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    public static func jpegData(from image: CGImage, maxSide: Int = defaultSide, encoder: ShotImageEncoding = ImageIOShotEncoder()) -> Data? {
        guard let t = make(from: image, maxSide: maxSide) else { return nil }
        return encoder.encode(t, format: .jpeg, quality: 0.7)
    }
}
