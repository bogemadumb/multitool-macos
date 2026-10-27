import Foundation

public struct FanCurvePoint: Equatable, Sendable {
    public var temp: Double
    public var percent: Double

    public init(temp: Double, percent: Double) {
        self.temp = temp
        self.percent = percent
    }
}

public enum FanCurve {
    public static let tempRange = 20.0...110.0
    public static let percentRange = 0.0...100.0
    public static let maxPoints = 12

    public static let defaultPoints = [
        FanCurvePoint(temp: 40, percent: 0), FanCurvePoint(temp: 55, percent: 25),
        FanCurvePoint(temp: 70, percent: 60), FanCurvePoint(temp: 85, percent: 100)
    ]

    // Sorted by temperature, values clamped, equal temperatures merged into the stronger cooling.
    public static func normalized(_ points: [FanCurvePoint]) -> [FanCurvePoint] {
        var byTemp: [Double: Double] = [:]
        for p in points where p.temp.isFinite && p.percent.isFinite {
            let t = min(max(p.temp, tempRange.lowerBound), tempRange.upperBound)
            let v = min(max(p.percent, percentRange.lowerBound), percentRange.upperBound)
            byTemp[t] = max(byTemp[t] ?? 0, v)
        }
        var out = byTemp.keys.sorted().map { FanCurvePoint(temp: $0, percent: byTemp[$0]!) }
        if out.count > maxPoints { out = Array(out.prefix(maxPoints - 1)) + [out[out.count - 1]] }
        return out
    }

    public static func percent(at temp: Double, in points: [FanCurvePoint]) -> Double? {
        guard temp.isFinite else { return nil }
        let pts = normalized(points)
        guard let first = pts.first, let last = pts.last else { return nil }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for i in 1..<pts.count where temp <= pts[i].temp {
            let a = pts[i - 1], b = pts[i]
            return a.percent + (b.percent - a.percent) * (temp - a.temp) / (b.temp - a.temp)
        }
        return last.percent
    }
}
