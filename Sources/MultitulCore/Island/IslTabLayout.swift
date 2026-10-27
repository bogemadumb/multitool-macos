import Foundation
import CoreGraphics

public struct IslTabSplit: Equatable, Sendable {
    public var left: [Int]
    public var right: [Int]
    public var overflow: [Int]
}

public enum IslTabLayout {
    public static let itemWidth: CGFloat = 30

    public static func split(count: Int, selected: Int?, leftWidth: CGFloat, rightWidth: CGFloat, rightReserved: CGFloat, itemWidth: CGFloat = IslTabLayout.itemWidth) -> IslTabSplit {
        guard count > 0 else { return IslTabSplit(left: [], right: [], overflow: []) }
        let leftCap = max(Int((leftWidth / itemWidth).rounded(.down)), 0)
        let rightCap = max(Int(((rightWidth - rightReserved) / itemWidth).rounded(.down)), 0)
        let all = Array(0..<count)
        if count <= leftCap { return IslTabSplit(left: all, right: [], overflow: []) }
        if count <= leftCap + rightCap { return IslTabSplit(left: Array(all.prefix(leftCap)), right: Array(all.dropFirst(leftCap)), overflow: []) }
        let rightShown = max(rightCap - 1, 0)
        var left = Array(all.prefix(leftCap))
        var right = Array(all.dropFirst(leftCap).prefix(rightShown))
        var overflow = Array(all.dropFirst(leftCap + rightShown))
        if let s = selected, overflow.contains(s) {
            if let last = right.popLast() {
                overflow.removeAll { $0 == s }
                overflow.insert(last, at: 0)
                right.append(s)
            } else if let last = left.popLast() {
                overflow.removeAll { $0 == s }
                overflow.insert(last, at: 0)
                left.append(s)
            }
        }
        return IslTabSplit(left: left, right: right, overflow: overflow)
    }
}
