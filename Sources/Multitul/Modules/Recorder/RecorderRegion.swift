import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct RecRegionEditor: View {
    @ObservedObject var m: RecEditorModel
    let mode: RecRegionMode
    @State private var rect = RecNormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
    @State private var aspect = RecAspect.free
    @State private var drag: DragKind?
    @State private var startRect = RecNormRect.full
    @State private var created = false

    enum DragKind {
        case move(CGPoint)
        case resize(RecCropHandle)
        case create(CGPoint)
    }

    private var isCrop: Bool { mode == .crop }

    var body: some View {
        VStack(spacing: 10) {
            Text(isCrop ? "Выдели область, которая останется в кадре" : "Выдели участок, который нужно скрыть").font(.system(size: 13, weight: .semibold))
            GeometryReader { geo in
                let fit = imageRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let img = m.stillFrame {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: geo.size.width, height: geo.size.height)
                    }
                    Canvas { ctx, _ in drawOverlay(ctx, fit: fit) }.allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in onDrag(v, fit: fit) }
                    .onEnded { _ in drag = nil })
            }
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .frame(minWidth: 640, minHeight: 360)
            HStack {
                if isCrop {
                    Picker("Пропорции", selection: $aspect) { ForEach(RecAspect.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu).frame(width: 190)
                        .onChange(of: aspect) { _, a in rect = RecCropMath.fit(aspect: a, in: rect, source: m.doc.source.size) }
                    Button("Весь кадр") { rect = .full }
                } else {
                    Text("Тяни углы и стороны, чтобы изменить; новую рамку можно нарисовать в пустом месте").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Отмена") { m.region = nil }.keyboardShortcut(.cancelAction)
                Button(isCrop ? "Применить" : "Готово") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { load() }
    }

    private func load() {
        switch mode {
        case .crop:
            rect = m.doc.crop
            aspect = m.doc.aspect
        case .newBlur:
            rect = RecNormRect(x: 0.3, y: 0.4, w: 0.4, h: 0.15)
        case .editBlur(let id):
            if let b = m.doc.blurs.first(where: { $0.id == id }) { rect = b.rect }
        }
    }

    private func apply() {
        switch mode {
        case .crop:
            m.setCrop(rect)
            m.setAspectKeepingCrop(aspect)
        case .newBlur:
            m.addBlur(rect, pixelate: m.pendingBlurStyle.pixelate, strength: m.pendingBlurStyle.strength)
        case .editBlur(let id):
            let r = rect
            m.updateBlur(id) { $0.rect = r }
        }
        m.region = nil
    }

    private func imageRect(in size: CGSize) -> CGRect {
        guard let img = m.stillFrame, img.width > 0, img.height > 0 else { return CGRect(origin: .zero, size: size) }
        let k = min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
        let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toView(_ r: RecNormRect, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + CGFloat(r.x) * fit.width, y: fit.minY + CGFloat(r.y) * fit.height, width: CGFloat(r.w) * fit.width, height: CGFloat(r.h) * fit.height)
    }

    private func norm(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - fit.minX) / max(fit.width, 1), 0), 1), y: min(max((p.y - fit.minY) / max(fit.height, 1), 0), 1))
    }

    private func handlePoints(_ r: CGRect) -> [(RecCropHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    private func onDrag(_ v: DragGesture.Value, fit: CGRect) {
        let vr = toView(rect, fit)
        if drag == nil {
            startRect = rect
            if let h = handlePoints(vr).first(where: { hypot($0.1.x - v.startLocation.x, $0.1.y - v.startLocation.y) < 14 }) {
                drag = .resize(h.0)
            } else if vr.contains(v.startLocation) {
                drag = .move(v.startLocation)
            } else if !isCrop {
                drag = .create(v.startLocation)
            } else {
                drag = .move(v.startLocation)
            }
        }
        guard let kind = drag else { return }
        let p = norm(v.location, fit)
        switch kind {
        case .move(let s):
            let dx = Double((v.location.x - s.x) / max(fit.width, 1)), dy = Double((v.location.y - s.y) / max(fit.height, 1))
            rect = RecCropMath.moved(startRect, dx: dx, dy: dy)
        case .resize(let h):
            rect = RecCropMath.resized(startRect, handle: h, to: (Double(p.x), Double(p.y)), aspect: isCrop ? aspect : .free, source: m.doc.source.size)
        case .create(let s):
            let a = norm(s, fit)
            rect = RecNormRect(x: min(Double(a.x), Double(p.x)), y: min(Double(a.y), Double(p.y)), w: abs(Double(p.x - a.x)), h: abs(Double(p.y - a.y))).sanitized
        }
    }

    private func drawOverlay(_ ctx: GraphicsContext, fit: CGRect) {
        let r = toView(rect, fit)
        var dim = Path(fit)
        dim.addRect(r)
        ctx.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        ctx.stroke(Path(r), with: .color(isCrop ? .white : .orange), lineWidth: 2)
        for (_, p) in handlePoints(r) {
            ctx.fill(Path(roundedRect: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10), cornerRadius: 2), with: .color(.white))
            ctx.stroke(Path(roundedRect: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10), cornerRadius: 2), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }
}

extension RecEditorModel {
    func setAspectKeepingCrop(_ a: RecAspect) {
        editAspect(a)
    }
}
