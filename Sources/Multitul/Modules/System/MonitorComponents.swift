import SwiftUI
import Charts
import MultitulCore
import MultitulUI

extension MenuLevel {
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warn: .orange
        case .critical: .red
        }
    }
}

func loadColor(_ f: Double) -> Color {
    f >= 0.95 ? .red : (f >= 0.8 ? .orange : .accentColor)
}

struct SeriesChart: View {
    var series: [ChartSeries]
    var range: ClosedRange<Double> = 0...100
    var height: CGFloat = 90
    var format: (Double) -> String = { String(Int($0.rounded())) }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    var body: some View {
        if series.contains(where: { $0.values.count > 1 }) {
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { si, s in
                    ForEach(Array(s.values.enumerated()), id: \.offset) { i, v in
                        if s.filled {
                            AreaMark(x: .value("Время", i), y: .value("Значение", clamp(v)), series: .value("Ряд", si))
                                .foregroundStyle(s.color.opacity(0.2))
                        }
                        LineMark(x: .value("Время", i), y: .value("Значение", clamp(v)), series: .value("Ряд", si))
                            .foregroundStyle(s.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: s.dashed ? [4, 3] : []))
                    }
                }
            }
            .chartYScale(domain: range)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(format(v.as(Double.self) ?? 0)).font(.caption2) }
                }
            }
            .frame(height: height)
        } else {
            Text("Нет данных").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: height)
        }
    }
}

struct ChartBlock: View {
    var title: String
    var current: String
    var legend: [(String, Color)] = []
    var series: [ChartSeries]
    var range: ClosedRange<Double> = 0...100
    var height: CGFloat = 90
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                ForEach(Array(legend.enumerated()), id: \.offset) { _, l in
                    StatusLabel(l.0, color: l.1).font(.caption).foregroundStyle(.secondary)
                }
                Text(current).monospacedDigit().foregroundStyle(.secondary)
            }
            SeriesChart(series: series, range: range, height: height, format: format)
        }
    }
}

struct TopRows: View {
    var title: String
    var rows: [(name: String, value: String)]

    var body: some View {
        Section {
            if rows.isEmpty {
                EmptyHint(text: "Ждём первый замер…")
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    LabeledContent(r.name) { Text(r.value).monospacedDigit() }
                }
            }
        } header: { Text(title) }
    }
}

struct EmptyHint: View {
    var text: String
    var symbol = "tray"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

func autoRange(_ values: [Double], pad: Double = 0.1, floor: Double? = nil) -> ClosedRange<Double> {
    guard let lo = values.min(), let hi = values.max(), hi > lo else {
        let v = values.first ?? 0
        return (v - 1)...(v + 1)
    }
    let p = (hi - lo) * pad
    return max(floor ?? -Double.infinity, lo - p)...(hi + p)
}
