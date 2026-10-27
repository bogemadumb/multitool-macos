import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct RecTimelineView: View {
    @ObservedObject var m: RecEditorModel
    @State private var dragStart: Double?
    @State private var selecting = false

    private let laneHeight: CGFloat = 12
    private let barTop: CGFloat = 28
    private let barHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let dur = max(m.doc.source.duration, 0.001)
            Canvas { ctx, size in
                draw(ctx, size: size, duration: dur)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let t = min(max(Double(v.location.x / w) * dur, 0), dur)
                    if dragStart == nil {
                        dragStart = min(max(Double(v.startLocation.x / w) * dur, 0), dur)
                        selecting = NSEvent.modifierFlags.contains(.option)
                    }
                    if selecting, let s = dragStart {
                        m.selection = min(s, t)...max(s, t)
                    } else {
                        m.scrub(to: t)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    selecting = false
                    m.endScrub()
                })
        }
        .frame(height: 92)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, duration: Double) {
        let w = size.width
        func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * w }
        let bar = CGRect(x: 0, y: barTop, width: w, height: barHeight)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 6), with: .color(.gray.opacity(0.18)))
        for s in m.doc.timeline.segments {
            let r = CGRect(x: x(s.srcStart), y: barTop, width: max(x(s.srcEnd) - x(s.srcStart), 1), height: barHeight)
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(s.speed == 1 ? Theme.accent.opacity(0.62) : Color.purple.opacity(0.62)))
            if r.width > 28, s.speed != 1 {
                ctx.draw(Text("×\(RecTimeFormat.speed(s.speed))").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: r.midX, y: r.midY))
            }
        }
        for c in m.doc.timeline.cutRanges {
            let r = CGRect(x: x(c.lowerBound), y: barTop, width: max(x(c.upperBound) - x(c.lowerBound), 1), height: barHeight)
            var p = Path()
            var xx = r.minX - r.height
            while xx < r.maxX {
                p.move(to: CGPoint(x: max(xx, r.minX), y: xx < r.minX ? r.minY + (r.minX - xx) : r.minY))
                p.addLine(to: CGPoint(x: min(xx + r.height, r.maxX), y: xx + r.height > r.maxX ? r.minY + (r.maxX - xx) : r.maxY))
                xx += 7
            }
            ctx.stroke(p, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        }
        for sp in m.doc.zoom.spans where m.doc.zoomEnabled {
            let r = CGRect(x: x(sp.start), y: 2, width: max(x(sp.end) - x(sp.start), 2), height: laneHeight)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.teal.opacity(0.35)))
            let h = CGRect(x: x(sp.holdStart), y: 2, width: max(x(sp.holdEnd) - x(sp.holdStart), 2), height: laneHeight)
            ctx.fill(Path(roundedRect: h, cornerRadius: 3), with: .color(.teal.opacity(0.85)))
        }
        for b in m.doc.blurs {
            let r = CGRect(x: x(b.srcStart), y: 2 + laneHeight + 3, width: max(x(b.srcEnd) - x(b.srcStart), 2), height: laneHeight)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.orange.opacity(0.85)))
        }
        for e in m.clicks {
            let cx = x(e.t)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.5, y: barTop + barHeight - 7, width: 3, height: 3)), with: .color(.yellow))
        }
        if let s = m.selection {
            let r = CGRect(x: x(s.lowerBound), y: barTop - 3, width: max(x(s.upperBound) - x(s.lowerBound), 1), height: barHeight + 6)
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.22)))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        let step = tickStep(duration: duration, width: w)
        var t = 0.0
        while t <= duration {
            ctx.draw(Text(RecTimeFormat.clock(t)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary), at: CGPoint(x: min(max(x(t), 12), w - 12), y: barTop + barHeight + 12))
            t += step
        }
        let px = x(m.playhead)
        ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: barTop + barHeight + 4)) }, with: .color(.red), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: 0, width: 8, height: 8)), with: .color(.red))
    }

    private func tickStep(duration: Double, width: CGFloat) -> Double {
        let maxTicks = max(Int(width / 70), 2)
        for s in [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600] where duration / s <= Double(maxTicks) { return s }
        return 3600
    }
}
