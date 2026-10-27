import Foundation
import CoreGraphics

public struct SwitcherSession {
    public private(set) var all: [SwitchEntry]
    public private(set) var visible: [SwitchEntry]
    public private(set) var selected: Int?
    public private(set) var query = ""
    public private(set) var searching = false
    private var index: SwitcherSearchIndex?

    public init(entries: [SwitchEntry], backward: Bool = false) {
        all = entries
        visible = entries
        selected = SwitcherListBuilder.initialIndex(count: entries.count, backward: backward)
    }

    public var count: Int { visible.count }
    public var isEmpty: Bool { visible.isEmpty }
    public var selectedEntry: SwitchEntry? { selected.flatMap { visible.indices.contains($0) ? visible[$0] : nil } }
    public var selectedID: SwitchEntryID? { selectedEntry?.id }

    public mutating func move(_ step: Int, wrap: Bool = true) {
        guard !visible.isEmpty else { selected = nil; return }
        let n = visible.count
        guard let cur = selected else { selected = step >= 0 ? 0 : n - 1; return }
        let next = cur + step
        if wrap { selected = ((next % n) + n) % n } else { selected = min(max(next, 0), n - 1) }
    }

    public mutating func moveVertical(_ rows: Int, columns: Int) {
        guard !visible.isEmpty, columns > 0 else { return }
        guard let cur = selected else { selected = rows >= 0 ? 0 : visible.count - 1; return }
        let n = visible.count
        let lastRow = (n - 1) / columns
        let row = cur / columns
        let col = cur % columns
        var target = row + rows
        if target > lastRow { target = 0 }
        else if target < 0 { target = lastRow }
        var idx = target * columns + col
        if idx >= n {
            if rows < 0, target > 0 { idx = (target - 1) * columns + col } else { idx = n - 1 }
        }
        selected = idx
    }

    public mutating func select(index i: Int) {
        guard visible.indices.contains(i) else { return }
        selected = i
    }

    @discardableResult
    public mutating func select(id: SwitchEntryID) -> Bool {
        guard let i = visible.firstIndex(where: { $0.id == id }) else { return false }
        selected = i
        return true
    }

    public mutating func beginSearch() { searching = true }

    public mutating func endSearch() {
        searching = false
        setQuery("")
    }

    public mutating func setQuery(_ q: String) {
        let keep = selectedID
        query = q
        if q.isEmpty {
            visible = all
            index = nil
            if let keep, let i = visible.firstIndex(where: { $0.id == keep }) { selected = i } else { selected = visible.isEmpty ? nil : 0 }
            return
        }
        if index == nil { index = SwitcherSearchIndex(all) }
        visible = SwitcherSearch.rank(all, query: q, index: index)
        selected = visible.isEmpty ? nil : 0
    }

    public mutating func appendQuery(_ s: String) { setQuery(query + s) }

    public mutating func deleteLastQueryCharacter() {
        guard !query.isEmpty else { return }
        setQuery(String(query.dropLast()))
    }

    public mutating func remove(id: SwitchEntryID) {
        let was = selected
        guard let i = visible.firstIndex(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }
        visible.remove(at: i)
        index = nil
        if visible.isEmpty { selected = nil; return }
        if let s = was { selected = min(i < s ? s - 1 : s, visible.count - 1) }
    }

    public mutating func replace(_ entry: SwitchEntry) {
        if let i = all.firstIndex(where: { $0.id == entry.id }) { all[i] = entry }
        if let i = visible.firstIndex(where: { $0.id == entry.id }) { visible[i] = entry }
        index = nil
    }

    public mutating func merge(fresh: [SwitchEntry]) {
        let keep = selectedID
        all = fresh
        index = nil
        if query.isEmpty { visible = fresh } else {
            index = SwitcherSearchIndex(all)
            visible = SwitcherSearch.rank(all, query: query, index: index)
        }
        if let keep, let i = visible.firstIndex(where: { $0.id == keep }) { selected = i }
        else if let s = selected { selected = visible.isEmpty ? nil : min(s, visible.count - 1) }
        else { selected = visible.isEmpty ? nil : 0 }
    }
}

public struct SwitcherGridMetrics: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var visibleRows: Int
    public var cell: CGSize
    public var thumb: CGSize
    public var spacing: CGFloat
    public var padding: CGFloat
    public var panel: CGSize
    public var scale: CGFloat
    public var header: CGFloat = 0

    public var scrolls: Bool { visibleRows < rows }

    public func row(of index: Int) -> Int { columns > 0 ? index / columns : 0 }
    public func column(of index: Int) -> Int { columns > 0 ? index % columns : 0 }

    public func cellFrame(_ index: Int) -> CGRect {
        CGRect(x: padding + CGFloat(column(of: index)) * (cell.width + spacing), y: padding + CGFloat(row(of: index)) * (cell.height + spacing), width: cell.width, height: cell.height)
    }

    public func index(at p: CGPoint, count: Int) -> Int? {
        let x = p.x - padding, y = p.y - padding
        guard x >= 0, y >= 0 else { return nil }
        let c = Int(x / (cell.width + spacing)), r = Int(y / (cell.height + spacing))
        guard c < columns, x - CGFloat(c) * (cell.width + spacing) <= cell.width, y - CGFloat(r) * (cell.height + spacing) <= cell.height else { return nil }
        let i = r * columns + c
        return i < count ? i : nil
    }

    public func scrollOffset(forSelected i: Int, current: CGFloat) -> CGFloat {
        guard scrolls else { return 0 }
        let f = cellFrame(i)
        let viewport = panel.height - header - padding * 2
        let top = f.minY - padding
        let bottom = f.maxY - padding
        var off = current
        if top < off { off = top }
        if bottom > off + viewport { off = bottom - viewport }
        let maxOff = CGFloat(rows) * (cell.height + spacing) - spacing - viewport
        return min(max(off, 0), max(maxOff, 0))
    }
}

public enum SwitcherGrid {
    public static let aspect: CGFloat = 0.625
    public static let titleHeight: CGFloat = 30
    public static let spacing: CGFloat = 14
    public static let padding: CGFloat = 20
    public static let minScale: CGFloat = 0.35
    public static let widthShare: CGFloat = 0.92
    public static let heightShare: CGFloat = 0.8
    public static let simpleRowHeight: CGFloat = 38
    public static let simpleWidth: CGFloat = 560
    public static let iconCell = CGSize(width: 104, height: 112)

    public static func metrics(count: Int, available: CGSize, layout: SwitcherLayout, size: PreviewSize, maxColumns: Int = 0, searchBar: CGFloat = 0) -> SwitcherGridMetrics {
        let n = max(count, 1)
        let maxW = max(available.width * widthShare, 200)
        let maxH = max(available.height * heightShare - searchBar, 120)
        switch layout {
        case .simple: return simple(n: n, maxW: maxW, maxH: maxH, searchBar: searchBar)
        case .icons: return fit(n: n, maxW: maxW, maxH: maxH, baseCell: iconCell, thumb: CGSize(width: 64, height: 64), maxColumns: maxColumns, searchBar: searchBar, minScale: 0.6)
        case .windows:
            let tw = size.thumbWidth
            let thumb = CGSize(width: tw, height: (tw * aspect).rounded())
            return fit(n: n, maxW: maxW, maxH: maxH, baseCell: CGSize(width: tw, height: thumb.height + titleHeight), thumb: thumb, maxColumns: maxColumns, searchBar: searchBar, minScale: minScale)
        }
    }

    private static func fit(n: Int, maxW: CGFloat, maxH: CGFloat, baseCell: CGSize, thumb: CGSize, maxColumns: Int, searchBar: CGFloat, minScale: CGFloat) -> SwitcherGridMetrics {
        var scale: CGFloat = 1
        while true {
            let cell = CGSize(width: (baseCell.width * scale).rounded(), height: (baseCell.height * scale).rounded())
            let fitCols = max(Int((maxW - padding * 2 + spacing) / (cell.width + spacing)), 1)
            var cols = min(fitCols, n)
            if maxColumns > 0 { cols = min(cols, maxColumns) }
            cols = balanced(cols: cols, n: n, hardMax: maxColumns > 0 ? min(maxColumns, fitCols) : fitCols)
            let rows = (n + cols - 1) / cols
            let height = CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing + padding * 2
            if height <= maxH || scale <= minScale + 0.001 {
                let visibleRows: Int
                var panelH = height
                if height <= maxH { visibleRows = rows } else {
                    visibleRows = max(Int((maxH - padding * 2 + spacing) / (cell.height + spacing)), 1)
                    panelH = CGFloat(visibleRows) * cell.height + CGFloat(visibleRows - 1) * spacing + padding * 2
                }
                let width = CGFloat(cols) * cell.width + CGFloat(cols - 1) * spacing + padding * 2
                return SwitcherGridMetrics(columns: cols, rows: rows, visibleRows: visibleRows, cell: cell,
                                           thumb: CGSize(width: (thumb.width * scale).rounded(), height: (thumb.height * scale).rounded()),
                                           spacing: spacing, padding: padding, panel: CGSize(width: width, height: panelH + searchBar), scale: scale, header: searchBar)
            }
            scale = max(scale - 0.05, minScale)
        }
    }

    static func balanced(cols: Int, n: Int, hardMax: Int) -> Int {
        guard cols > 1, n > cols else { return cols }
        let rows = (n + cols - 1) / cols
        let even = (n + rows - 1) / rows
        return min(max(even, 1), hardMax)
    }

    private static func simple(n: Int, maxW: CGFloat, maxH: CGFloat, searchBar: CGFloat) -> SwitcherGridMetrics {
        let w = min(simpleWidth, maxW)
        let rowH = simpleRowHeight
        let rows = n
        let full = CGFloat(rows) * rowH + CGFloat(rows - 1) * 2 + padding * 2
        let visible = full <= maxH ? rows : max(Int((maxH - padding * 2 + 2) / (rowH + 2)), 1)
        let h = CGFloat(visible) * rowH + CGFloat(visible - 1) * 2 + padding * 2
        return SwitcherGridMetrics(columns: 1, rows: rows, visibleRows: visible, cell: CGSize(width: w - padding * 2, height: rowH), thumb: .zero, spacing: 2, padding: padding,
                                   panel: CGSize(width: w, height: h + searchBar), scale: 1, header: searchBar)
    }

    public static func panelFrame(metrics m: SwitcherGridMetrics, in display: CGRect) -> CGRect {
        let w = min(m.panel.width, display.width), h = min(m.panel.height, display.height)
        return CGRect(x: (display.midX - w / 2).rounded(), y: (display.midY - h / 2).rounded(), width: w, height: h)
    }
}
