import Foundation
import CoreGraphics
import CoreText

public enum ShotTextMetrics {
    public static func font(_ size: Double) -> CTFont {
        CTFontCreateWithName("Helvetica Neue Bold" as CFString, CGFloat(size), nil)
    }

    public static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public static func lineHeight(_ size: Double) -> CGFloat {
        let f = font(size)
        return CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
    }

    public static func measure(_ text: String, _ size: Double) -> CGSize {
        let f = font(size)
        var w: CGFloat = 0
        for l in lines(text) {
            let a = NSAttributedString(string: l.isEmpty ? " " : l, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f])
            let line = CTLineCreateWithAttributedString(a)
            w = max(w, CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        return CGSize(width: ceil(w), height: ceil(lineHeight(size) * CGFloat(max(lines(text).count, 1))))
    }
}

public enum ShotRenderer {
    public static func cgColor(_ c: ShotColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    static func makeContext(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer?) -> CGContext? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func render(base: CGImage, document: AnnotationDocument, applyCrop: Bool = true) -> CGImage? {
        let w = base.width, h = base.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let scaleX = CGFloat(w) / max(CGFloat(document.canvasWidth), 1)
        let scaleY = CGFloat(h) / max(CGFloat(document.canvasHeight), 1)
        let order = document.renderOrder
        let image: CGImage? = buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = makeContext(w, h, data: raw.baseAddress) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            let typed = raw.bindMemory(to: UInt8.self)
            for it in order where it.kind.isEffect && it.points.count >= 2 {
                let r = AnnotationItem.rect(it.points[0], it.points[1])
                let px = CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY)
                if it.kind == .pixelate {
                    ShotEffects.pixelate(typed, width: w, height: h, region: px, block: ShotEffectMath.blockSize(strength: it.style.strength, region: px.size))
                } else {
                    ShotEffects.blur(typed, width: w, height: h, region: px, radius: ShotEffectMath.blurRadius(strength: it.style.strength, region: px.size))
                }
            }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scaleX, y: -scaleY)
            for it in order where !it.kind.isEffect { draw(it, in: ctx) }
            ctx.restoreGState()
            return ctx.makeImage()
        }
        guard let full = image else { return nil }
        if applyCrop, let c = document.effectiveCrop {
            let px = CGRect(x: c.minX * scaleX, y: c.minY * scaleY, width: c.width * scaleX, height: c.height * scaleY).integral
            return full.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: w, height: h))) ?? full
        }
        return full
    }

    static func draw(_ it: AnnotationItem, in ctx: CGContext) {
        let color = cgColor(it.style.color)
        let lw = CGFloat(it.style.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch it.kind {
        case .line:
            guard it.points.count >= 2 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.move(to: it.points[0])
            ctx.addLine(to: it.points[1])
            ctx.strokePath()
        case .arrow:
            guard it.points.count >= 2 else { return }
            let s = ShotArrowGeometry.shape(from: it.points[0], to: it.points[1], width: it.style.strokeWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.move(to: it.points[0])
            ctx.addLine(to: s.shaftEnd)
            ctx.strokePath()
            ctx.setFillColor(color)
            ctx.move(to: s.tip)
            ctx.addLine(to: s.left)
            ctx.addLine(to: s.right)
            ctx.closePath()
            ctx.fillPath()
        case .rectangle, .ellipse:
            guard it.points.count >= 2 else { return }
            let r = AnnotationItem.rect(it.points[0], it.points[1])
            if it.style.filled {
                ctx.setFillColor(color)
                if it.kind == .rectangle { ctx.fill(r) } else { ctx.fillEllipse(in: r) }
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lw)
                if it.kind == .rectangle { ctx.stroke(r) } else { ctx.strokeEllipse(in: r) }
            }
        case .pen, .highlighter:
            guard let first = it.points.first else { return }
            let hl = it.kind == .highlighter
            ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(hl ? it.highlighterWidth : it.style.strokeWidth))
            if hl { ctx.setLineCap(.butt) }
            if it.points.count == 1 {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: first.x - lw / 2, y: first.y - lw / 2, width: lw, height: lw))
                return
            }
            ctx.move(to: first)
            for p in it.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .step:
            guard let c = it.points.first else { return }
            let r = CGFloat(it.stepRadius)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(lw / 2, 1.5))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2).insetBy(dx: 1, dy: 1))
            let label = String(it.number)
            let size = Double(r * 1.15)
            let m = ShotTextMetrics.measure(label, size)
            let fg = luminance(it.style.color) > 0.6 ? ShotColor.black : ShotColor.white
            drawText(label, at: CGPoint(x: c.x - m.width / 2, y: c.y - m.height / 2), size: size, color: fg, in: ctx)
        case .text:
            guard let o = it.points.first else { return }
            drawText(it.text, at: o, size: it.style.fontSize, color: it.style.color, in: ctx)
        case .blur, .pixelate:
            break
        }
    }

    static func luminance(_ c: ShotColor) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    static func drawText(_ text: String, at origin: CGPoint, size: Double, color: ShotColor, in ctx: CGContext) {
        let f = ShotTextMetrics.font(size)
        let lh = ShotTextMetrics.lineHeight(size)
        let ascent = CTFontGetAscent(f)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, l) in ShotTextMetrics.lines(text).enumerated() where !l.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: attrs))
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + ascent + CGFloat(i) * lh)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    public static func compose(_ image: CGImage, padding: Int, scale: CGFloat, background: ShotBackground, cornerRadius: Int, watermark: ShotWatermark) -> CGImage? {
        let layout = ShotBackdropMath.layout(imageSize: CGSize(width: image.width, height: image.height), paddingPoints: padding, scale: scale, background: background, cornerRadiusPoints: cornerRadius)
        let wm = watermark.sanitized
        if layout.canvas.width == CGFloat(image.width) && layout.canvas.height == CGFloat(image.height) && !wm.isActive && !layout.hasBackground { return image }
        let cw = Int(layout.canvas.width), ch = Int(layout.canvas.height)
        guard cw > 0, ch > 0, let ctx = makeContext(cw, ch, data: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(ch))
        ctx.scaleBy(x: 1, y: -1)
        switch background {
        case .none: break
        case .solid(let c):
            ctx.setFillColor(cgColor(c))
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        case .gradient(let a, let b, let angle):
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cgColor(a), cgColor(b)] as CFArray, locations: [0, 1]) {
                let ends = ShotBackdropMath.gradientEndpoints(angleDegrees: angle, in: layout.canvas)
                ctx.drawLinearGradient(g, start: ends.start, end: ends.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        let r = layout.imageRect
        if layout.hasBackground {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -r.height * 0.02 - 6), blur: max(r.width, r.height) * 0.03 + 12, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if layout.cornerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
            ctx.clip()
        }
        ctx.translateBy(x: r.minX, y: r.minY + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
        if wm.isActive {
            let size = wm.fontSize * Double(max(scale, 1))
            let m = ShotTextMetrics.measure(wm.text, size)
            let box = ShotWatermarkMath.rect(textSize: m, canvas: layout.canvas, corner: wm.corner, margin: 12 * max(scale, 1))
            drawText(wm.text, at: box.origin, size: size, color: ShotColor(255, 255, 255, UInt8(wm.opacity * 255)), in: ctx)
        }
        return ctx.makeImage()
    }

    public static func downscaled(_ image: CGImage, factor: CGFloat) -> CGImage? {
        guard factor > 0, factor < 1 else { return image }
        let w = max(Int((CGFloat(image.width) * factor).rounded()), 1), h = max(Int((CGFloat(image.height) * factor).rounded()), 1)
        guard let ctx = makeContext(w, h, data: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
