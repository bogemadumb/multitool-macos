import AppKit
import MultitulCore

enum MenuBarRenderer {
    static let height: CGFloat = 22

    static func color(_ level: MenuLevel) -> NSColor {
        switch level {
        case .normal: NSColor.labelColor
        case .warn: NSColor.systemOrange
        case .critical: NSColor.systemRed
        }
    }

    static func segmentWidth(_ v: MenuBarValue, style: MenuBarStyle) -> CGFloat {
        switch style {
        case .number:
            let widest = v.lines.map { textWidth($0, font: valueFont) }.max() ?? 20
            return max(widest, textWidth(v.caption, font: captionFont)) + 2
        case .bar: return 34
        case .graph: return 38
        }
    }

    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    static func image(_ segments: [(value: MenuBarValue, style: MenuBarStyle)]) -> NSImage {
        let gap: CGFloat = 7
        let widths = segments.map { segmentWidth($0.value, style: $0.style) }
        let total = max(widths.reduce(0, +) + gap * CGFloat(max(segments.count - 1, 0)), 12)
        let img = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, seg) in segments.enumerated() {
                draw(seg.value, style: seg.style, in: NSRect(x: x, y: 0, width: widths[i], height: height))
                x += widths[i] + gap
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static func draw(_ v: MenuBarValue, style: MenuBarStyle, in r: NSRect) {
        let tone = color(v.level)
        let capAttr: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: NSColor.secondaryLabelColor]
        switch style {
        case .number:
            if v.lines.count >= 2 {
                for (i, line) in v.lines.prefix(2).enumerated() {
                    let attr: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: tone]
                    (line as NSString).draw(at: NSPoint(x: r.minX, y: r.maxY - 11 - CGFloat(i) * 10 + 0.5), withAttributes: attr)
                }
            } else {
                (v.caption as NSString).draw(at: NSPoint(x: r.minX, y: r.maxY - 9.5), withAttributes: capAttr)
                let attr: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: tone]
                (v.text as NSString).draw(at: NSPoint(x: r.minX, y: r.minY + 1.5), withAttributes: attr)
            }
        case .bar:
            (v.caption as NSString).draw(at: NSPoint(x: r.minX, y: r.maxY - 9.5), withAttributes: capAttr)
            let track = NSRect(x: r.minX, y: r.minY + 4, width: r.width, height: 5)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let f = CGFloat(min(max(v.fraction ?? 0, 0), 1))
            if f > 0 {
                tone.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(track.height, track.width * f), height: track.height), xRadius: 2.5, yRadius: 2.5).fill()
            }
        case .graph:
            (v.caption as NSString).draw(at: NSPoint(x: r.minX, y: r.maxY - 9.5), withAttributes: capAttr)
            let box = NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: 11)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            let pts = v.series.suffix(Int(box.width / 1.5))
            guard pts.count > 1 else { return }
            let step = box.width / CGFloat(pts.count - 1)
            let path = NSBezierPath()
            for (i, p) in pts.enumerated() {
                let pt = NSPoint(x: box.minX + step * CGFloat(i), y: box.minY + 1 + (box.height - 2) * CGFloat(p))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            tone.setStroke()
            path.lineWidth = 1.2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

@MainActor
final class MonitorStatusItems: NSObject {
    private var items: [NSStatusItem] = []
    private var shape: [SystemMetric] = []
    private var combined = true
    private var layout = MenuBarLayout()
    private var lastShown: [MenuBarItem] = []
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
    }

    var count: Int { items.count }

    func apply(layout: MenuBarLayout, enabled: Set<SystemMetric>) {
        self.layout = layout
        let shown = layout.shown(enabled: enabled)
        lastShown = shown
        let wantShape = layout.combined ? (shown.isEmpty ? [] : [shown[0].metric]) : shown.map(\.metric)
        if wantShape != shape || layout.combined != combined {
            rebuild(count: wantShape.count)
            shape = wantShape
            combined = layout.combined
        }
    }

    private func rebuild(count: Int) {
        for i in items { NSStatusBar.system.removeStatusItem(i) }
        items = []
        for _ in 0..<count {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.target = self
            it.button?.action = #selector(clicked)
            it.button?.sendAction(on: [.leftMouseDown])
            it.button?.imagePosition = .imageOnly
            items.append(it)
        }
    }

    @objc private func clicked() { onClick() }

    func update(snapshot: LiveSnapshot, history: NamedHistory, uploadFirst: Bool) {
        guard !items.isEmpty else { return }
        let segs = lastShown.map { (value: MenuBarValues.make($0.metric, snapshot: snapshot, history: history, uploadFirst: uploadFirst), style: $0.style) }
        if layout.combined {
            items[0].button?.image = MenuBarRenderer.image(segs)
            items[0].button?.toolTip = "Мультитул: " + segs.map { "\($0.value.caption) \($0.value.text)" }.joined(separator: " · ")
        } else {
            for (i, seg) in segs.reversed().enumerated() where i < items.count {
                items[i].button?.image = MenuBarRenderer.image([seg])
                items[i].button?.toolTip = "\(seg.value.metric.title): \(seg.value.text)"
            }
        }
    }

    func removeAll() {
        for i in items { NSStatusBar.system.removeStatusItem(i) }
        items = []
        shape = []
    }
}
