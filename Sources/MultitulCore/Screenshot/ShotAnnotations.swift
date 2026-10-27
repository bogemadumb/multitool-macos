import Foundation
import CoreGraphics

public enum AnnotationTool: String, CaseIterable, Codable, Sendable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate, crop

    public var title: String {
        switch self {
        case .select: "Выбор"
        case .arrow: "Стрелка"
        case .line: "Линия"
        case .rectangle: "Прямоугольник"
        case .ellipse: "Овал"
        case .pen: "Карандаш"
        case .highlighter: "Маркер"
        case .text: "Текст"
        case .step: "Шаги"
        case .blur: "Размытие"
        case .pixelate: "Пикселизация"
        case .crop: "Обрезка"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .step: "1.circle"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .crop: "crop"
        }
    }

    public var kind: AnnotationKind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .step: .step
        case .blur: .blur
        case .pixelate: .pixelate
        case .select, .crop: nil
        }
    }

    public var key: String? {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .step: "n"
        case .blur: "b"
        case .pixelate: "x"
        case .crop: "c"
        }
    }
}

public enum AnnotationKind: String, CaseIterable, Codable, Sendable {
    case arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate

    public var renderLayer: Int {
        switch self {
        case .blur, .pixelate: 0
        case .highlighter: 1
        case .line, .arrow, .rectangle, .ellipse, .pen: 2
        case .step: 3
        case .text: 4
        }
    }

    public var isEffect: Bool { self == .blur || self == .pixelate }
    public var isBox: Bool { self == .rectangle || self == .ellipse || self == .blur || self == .pixelate }
    public var isSegment: Bool { self == .arrow || self == .line }
    public var isPath: Bool { self == .pen || self == .highlighter }
}

public struct AnnotationStyle: Equatable, Codable, Sendable {
    public var color: ShotColor = .red
    public var strokeWidth: Double = 4
    public var filled = false
    public var fontSize: Double = 28
    public var strength: Double = 0.6

    public init(color: ShotColor = .red, strokeWidth: Double = 4, filled: Bool = false, fontSize: Double = 28, strength: Double = 0.6) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.filled = filled
        self.fontSize = fontSize
        self.strength = strength
    }

    public static let strokeRange = 1.0...40.0
    public static let fontRange = 8.0...200.0

    public var sanitized: AnnotationStyle {
        var s = self
        s.strokeWidth = min(max(strokeWidth, Self.strokeRange.lowerBound), Self.strokeRange.upperBound)
        s.fontSize = min(max(fontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        s.strength = min(max(strength, 0), 1)
        return s
    }
}

public struct AnnotationItem: Identifiable, Equatable, Codable, Sendable {
    public var id: Int
    public var kind: AnnotationKind
    public var points: [CGPoint]
    public var style: AnnotationStyle
    public var text: String
    public var number: Int
    public var boxSize: CGSize

    public init(id: Int, kind: AnnotationKind, points: [CGPoint], style: AnnotationStyle = AnnotationStyle(), text: String = "", number: Int = 0, boxSize: CGSize = .zero) {
        self.id = id
        self.kind = kind
        self.points = points
        self.style = style
        self.text = text
        self.number = number
        self.boxSize = boxSize
    }

    public var highlighterWidth: Double { max(style.strokeWidth * 4, 12) }
    public var stepRadius: Double { max(style.strokeWidth * 3, 14) }

    public var bounds: CGRect {
        switch kind {
        case .arrow, .line:
            guard points.count >= 2 else { return .null }
            return Self.rect(points[0], points[1]).insetBy(dx: -style.strokeWidth / 2, dy: -style.strokeWidth / 2)
        case .rectangle, .ellipse, .blur, .pixelate:
            guard points.count >= 2 else { return .null }
            let r = Self.rect(points[0], points[1])
            return kind.isEffect ? r : r.insetBy(dx: -style.strokeWidth / 2, dy: -style.strokeWidth / 2)
        case .pen, .highlighter:
            guard let f = points.first else { return .null }
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            let w = kind == .highlighter ? highlighterWidth : style.strokeWidth
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -w / 2, dy: -w / 2)
        case .text:
            guard let o = points.first else { return .null }
            let s = boxSize == .zero ? ShotTextEstimate.size(text, fontSize: style.fontSize) : boxSize
            return CGRect(origin: o, size: s)
        case .step:
            guard let c = points.first else { return .null }
            let r = stepRadius
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        }
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public func moved(by d: CGPoint) -> AnnotationItem {
        var c = self
        c.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return c
    }
}

public enum ShotTextEstimate {
    public static func size(_ text: String, fontSize: Double) -> CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map { $0.count }.max() ?? 0
        return CGSize(width: max(Double(longest), 1) * fontSize * 0.58, height: Double(max(lines.count, 1)) * fontSize * 1.22)
    }
}

public enum AnnotationHandleKind: Equatable, Sendable {
    case start, end
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct AnnotationHandle: Equatable, Sendable {
    public var kind: AnnotationHandleKind
    public var position: CGPoint
}

public enum ShotGeometryMath {
    public static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    public static func distanceToRectBorder(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let inside = r.contains(p)
        let dl = abs(p.x - r.minX), dr = abs(p.x - r.maxX), dt = abs(p.y - r.minY), db = abs(p.y - r.maxY)
        if inside { return min(dl, dr, dt, db) }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    public static func ellipseValue(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        guard r.width > 0, r.height > 0 else { return .infinity }
        let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
        return (nx * nx + ny * ny).squareRoot()
    }
}

public struct ShotArrowShape: Equatable, Sendable {
    public var tip: CGPoint
    public var left: CGPoint
    public var right: CGPoint
    public var shaftEnd: CGPoint
}

public enum ShotArrowGeometry {
    public static func headLength(width: Double) -> CGFloat { CGFloat(max(width * 4, 14)) }

    public static func shape(from a: CGPoint, to b: CGPoint, width: Double) -> ShotArrowShape {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0 else { return ShotArrowShape(tip: b, left: b, right: b, shaftEnd: b) }
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let hl = min(headLength(width: width), len)
        let hw = hl * 0.55
        let base = CGPoint(x: b.x - ux * hl, y: b.y - uy * hl)
        let left = CGPoint(x: base.x - uy * hw, y: base.y + ux * hw)
        let right = CGPoint(x: base.x + uy * hw, y: base.y - ux * hw)
        let shaft = CGPoint(x: b.x - ux * hl * 0.8, y: b.y - uy * hl * 0.8)
        return ShotArrowShape(tip: b, left: left, right: right, shaftEnd: shaft)
    }
}

public enum AnnotationHit {
    public static func test(_ item: AnnotationItem, at p: CGPoint, tolerance t: CGFloat = 6) -> Bool {
        let w = CGFloat(item.style.strokeWidth) / 2 + t
        switch item.kind {
        case .arrow, .line:
            guard item.points.count >= 2 else { return false }
            if item.kind == .arrow {
                let s = ShotArrowGeometry.shape(from: item.points[0], to: item.points[1], width: item.style.strokeWidth)
                let hw = hypot(s.left.x - s.right.x, s.left.y - s.right.y) / 2
                if ShotGeometryMath.distance(p, toSegment: s.shaftEnd, s.tip) <= max(hw, w) { return true }
            }
            return ShotGeometryMath.distance(p, toSegment: item.points[0], item.points[1]) <= w
        case .rectangle:
            guard item.points.count >= 2 else { return false }
            let r = AnnotationItem.rect(item.points[0], item.points[1])
            if item.style.filled { return r.insetBy(dx: -w, dy: -w).contains(p) }
            return ShotGeometryMath.distanceToRectBorder(p, r) <= w
        case .ellipse:
            guard item.points.count >= 2 else { return false }
            let r = AnnotationItem.rect(item.points[0], item.points[1])
            if r.width < 1 || r.height < 1 { return r.insetBy(dx: -w, dy: -w).contains(p) }
            let v = ShotGeometryMath.ellipseValue(p, r)
            if item.style.filled { return v <= 1 + w / max(min(r.width, r.height) / 2, 1) }
            let band = w / max(min(r.width, r.height) / 2, 1)
            return abs(v - 1) <= band
        case .blur, .pixelate:
            guard item.points.count >= 2 else { return false }
            return AnnotationItem.rect(item.points[0], item.points[1]).insetBy(dx: -t, dy: -t).contains(p)
        case .pen, .highlighter:
            let width = item.kind == .highlighter ? CGFloat(item.highlighterWidth) / 2 + t : w
            guard item.points.count >= 2 else { return item.points.first.map { hypot($0.x - p.x, $0.y - p.y) <= width } ?? false }
            for i in 0..<(item.points.count - 1) where ShotGeometryMath.distance(p, toSegment: item.points[i], item.points[i + 1]) <= width { return true }
            return false
        case .text:
            return item.bounds.insetBy(dx: -t, dy: -t).contains(p)
        case .step:
            guard let c = item.points.first else { return false }
            return hypot(c.x - p.x, c.y - p.y) <= CGFloat(item.stepRadius) + t
        }
    }

    public static func handles(of item: AnnotationItem) -> [AnnotationHandle] {
        if item.kind.isSegment, item.points.count >= 2 {
            return [AnnotationHandle(kind: .start, position: item.points[0]), AnnotationHandle(kind: .end, position: item.points[1])]
        }
        if item.kind.isBox, item.points.count >= 2 {
            let r = AnnotationItem.rect(item.points[0], item.points[1])
            return [AnnotationHandle(kind: .topLeft, position: CGPoint(x: r.minX, y: r.minY)),
                    AnnotationHandle(kind: .topRight, position: CGPoint(x: r.maxX, y: r.minY)),
                    AnnotationHandle(kind: .bottomLeft, position: CGPoint(x: r.minX, y: r.maxY)),
                    AnnotationHandle(kind: .bottomRight, position: CGPoint(x: r.maxX, y: r.maxY))]
        }
        return []
    }

    public static func hitHandle(of item: AnnotationItem, at p: CGPoint, radius: CGFloat = 8) -> AnnotationHandle? {
        handles(of: item).first { hypot($0.position.x - p.x, $0.position.y - p.y) <= radius }
    }

    public static func resized(_ item: AnnotationItem, handle: AnnotationHandleKind, to p: CGPoint, lockSquare: Bool = false) -> AnnotationItem {
        var c = item
        if item.kind.isSegment, c.points.count >= 2 {
            var target = p
            if lockSquare { target = snapAngle(from: handle == .start ? c.points[1] : c.points[0], to: p) }
            if handle == .start { c.points[0] = target } else if handle == .end { c.points[1] = target }
            return c
        }
        guard item.kind.isBox, c.points.count >= 2 else { return c }
        let r = AnnotationItem.rect(c.points[0], c.points[1])
        let fixed: CGPoint
        switch handle {
        case .topLeft: fixed = CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: fixed = CGPoint(x: r.minX, y: r.maxY)
        case .bottomLeft: fixed = CGPoint(x: r.maxX, y: r.minY)
        case .bottomRight: fixed = CGPoint(x: r.minX, y: r.minY)
        default: return c
        }
        var target = p
        if lockSquare {
            let d = max(abs(p.x - fixed.x), abs(p.y - fixed.y))
            target = CGPoint(x: fixed.x + (p.x >= fixed.x ? d : -d), y: fixed.y + (p.y >= fixed.y ? d : -d))
        }
        c.points = [fixed, target]
        return c
    }

    public static func snapAngle(from a: CGPoint, to b: CGPoint, step: Double = .pi / 4) -> CGPoint {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let ang = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: Double(a.x) + cos(ang) * len, y: Double(a.y) + sin(ang) * len)
    }
}

public struct AnnotationDocument: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public var version = AnnotationDocument.currentVersion
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var items: [AnnotationItem] = []
    public var crop: CGRect?
    public var nextID = 1

    public init(canvasWidth: Int, canvasHeight: Int) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
    public var isEmpty: Bool { items.isEmpty && crop == nil }

    public func item(_ id: Int) -> AnnotationItem? { items.first { $0.id == id } }
    public func index(of id: Int) -> Int? { items.firstIndex { $0.id == id } }

    @discardableResult
    public mutating func add(_ kind: AnnotationKind, points: [CGPoint], style: AnnotationStyle = AnnotationStyle(), text: String = "", boxSize: CGSize = .zero) -> Int {
        let id = nextID
        nextID += 1
        let number = kind == .step ? nextStepNumber : 0
        items.append(AnnotationItem(id: id, kind: kind, points: points, style: style.sanitized, text: text, number: number, boxSize: boxSize))
        return id
    }

    public var nextStepNumber: Int { (items.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    public mutating func remove(_ ids: Set<Int>) {
        let hadSteps = items.contains { ids.contains($0.id) && $0.kind == .step }
        items.removeAll { ids.contains($0.id) }
        if hadSteps { renumberSteps() }
    }

    public mutating func renumberSteps() {
        var n = 1
        for i in items.indices where items[i].kind == .step {
            items[i].number = n
            n += 1
        }
    }

    public mutating func update(_ item: AnnotationItem) {
        if let i = index(of: item.id) { items[i] = item }
    }

    public func hitTest(_ p: CGPoint, tolerance: CGFloat = 6) -> Int? {
        for it in renderOrder.reversed() where AnnotationHit.test(it, at: p, tolerance: tolerance) { return it.id }
        return nil
    }

    public var renderOrder: [AnnotationItem] {
        items.enumerated().sorted { a, b in
            a.element.kind.renderLayer != b.element.kind.renderLayer ? a.element.kind.renderLayer < b.element.kind.renderLayer : a.offset < b.offset
        }.map(\.element)
    }

    public mutating func bringToFront(_ id: Int) {
        guard let i = index(of: id) else { return }
        items.append(items.remove(at: i))
    }

    public mutating func sendToBack(_ id: Int) {
        guard let i = index(of: id) else { return }
        items.insert(items.remove(at: i), at: 0)
    }

    public var effectiveCrop: CGRect? {
        guard let c = crop else { return nil }
        let r = c.standardized.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !r.isNull, r.width >= 1, r.height >= 1, r.size != canvasSize else { return nil }
        return r
    }

    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> AnnotationDocument {
        let doc = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        guard doc.version <= currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported version \(doc.version)"))
        }
        return doc
    }
}
