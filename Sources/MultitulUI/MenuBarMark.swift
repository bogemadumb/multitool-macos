import AppKit

public enum MenuBarMark {
    public static func image(side: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let k = rect.width / 18
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ rad: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x * k, y: y * k, width: w * k, height: w * k), xRadius: rad * k, yRadius: rad * k)
            }
            NSColor.black.set()
            r(1.5, 1.5, 6.6, 1.9).fill()
            for (x, y) in [(10.4, 2.05), (2.05, 10.4)] {
                let p = r(CGFloat(x), CGFloat(y), 5.5, 1.55)
                p.lineWidth = 1.3 * k
                p.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: (13.15 - 3.4) * k, y: (13.15 - 3.4) * k, width: 6.8 * k, height: 6.8 * k)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
