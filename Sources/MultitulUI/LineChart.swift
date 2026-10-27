import SwiftUI

public struct ChartSeries: Identifiable {
    public let id = UUID()
    public var values: [Double]
    public var color: Color
    public var dashed: Bool
    public var filled: Bool

    public init(values: [Double], color: Color = Theme.accent, dashed: Bool = false, filled: Bool = false) {
        self.values = values
        self.color = color
        self.dashed = dashed
        self.filled = filled
    }
}

public struct LineChart: View {
    var series: [ChartSeries]
    var range: ClosedRange<Double>

    public init(series: [ChartSeries], range: ClosedRange<Double> = 0...100) {
        self.series = series
        self.range = range
    }

    private func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
            let n = (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span
            return CGPoint(x: x, y: size.height * (1 - CGFloat(n)))
        }
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Path { p in
                        let y = geo.size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.separator.opacity(0.5), lineWidth: 0.5)
                }
                ForEach(series) { s in
                    let pts = points(s.values, in: geo.size)
                    if s.filled, let first = pts.first, let last = pts.last {
                        Path { p in
                            p.move(to: CGPoint(x: first.x, y: geo.size.height))
                            pts.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [s.color.opacity(0.28), s.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    }
                    Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: first)
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(s.color, style: StrokeStyle(lineWidth: s.dashed ? 2 : 2.5, lineCap: .round, lineJoin: .round, dash: s.dashed ? [5, 4] : []))
                }
            }
        }
    }
}
