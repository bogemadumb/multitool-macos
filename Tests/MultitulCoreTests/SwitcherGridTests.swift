import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let screen = CGSize(width: 1800, height: 976)

private func grid(_ n: Int, layout: SwitcherLayout = .windows, size: PreviewSize = .normal, cols: Int = 0, avail: CGSize = screen, bar: CGFloat = 0) -> SwitcherGridMetrics {
    SwitcherGrid.metrics(count: n, available: avail, layout: layout, size: size, maxColumns: cols, searchBar: bar)
}

@Suite struct SwitcherGridTests {
    @Test func oneWindowGetsASingleCell() {
        let m = grid(1)
        #expect(m.columns == 1 && m.rows == 1 && m.scale == 1 && !m.scrolls)
        #expect(m.thumb.width == PreviewSize.normal.thumbWidth)
    }

    @Test func fewWindowsStayInOneRow() {
        let m = grid(4)
        #expect(m.columns == 4 && m.rows == 1)
    }

    @Test func panelNeverExceedsTheScreenShare() {
        for n in [1, 2, 3, 5, 8, 13, 21, 30, 50, 100] {
            let m = grid(n)
            #expect(m.panel.width <= screen.width * SwitcherGrid.widthShare + 0.5, "n=\(n)")
            #expect(m.panel.height <= screen.height * SwitcherGrid.heightShare + 0.5, "n=\(n)")
        }
    }

    @Test func everyCellIsReachableAndTilesTheGrid() {
        for n in [1, 7, 12, 30, 64] {
            let m = grid(n)
            #expect(m.columns * m.rows >= n && m.columns * (m.rows - 1) < n, "n=\(n)")
        }
    }

    @Test func thirtyWindowsFitWithoutScrolling() {
        let m = grid(30)
        #expect(!m.scrolls && m.scale >= 0.5)
    }

    @Test func tooManyWindowsShrinkThenScroll() {
        let m = grid(300)
        #expect(abs(m.scale - SwitcherGrid.minScale) < 0.001)
        #expect(m.scrolls && m.visibleRows < m.rows && m.visibleRows >= 1)
    }

    @Test func largerPreviewsMeanFewerColumns() {
        #expect(grid(20, size: .small).columns >= grid(20, size: .xlarge).columns)
        #expect(grid(1, size: .small).thumb.width < grid(1, size: .xlarge).thumb.width)
    }

    @Test func maxColumnsIsHonouredAndRowsBalanced() {
        let m = grid(10, cols: 3)
        #expect(m.columns <= 3 && m.rows == 4)
    }

    @Test func rowsAreBalancedInsteadOfLeavingAnOrphan() {
        let m = grid(7, avail: CGSize(width: 1100, height: 976))
        #expect(m.rows == 2 && m.columns == 4)
    }

    @Test func narrowScreenForcesFewerColumns() {
        let m = grid(6, avail: CGSize(width: 700, height: 976))
        #expect(m.columns <= 2)
    }

    @Test func iconsLayoutUsesSmallFixedCells() {
        let m = grid(12, layout: .icons)
        #expect(m.cell == SwitcherGrid.iconCell && m.columns == 12 && m.thumb == CGSize(width: 64, height: 64))
    }

    @Test func simpleLayoutIsASingleColumnList() {
        let m = grid(5, layout: .simple)
        #expect(m.columns == 1 && m.rows == 5 && m.cell.height == SwitcherGrid.simpleRowHeight && m.panel.width <= SwitcherGrid.simpleWidth)
        let big = grid(200, layout: .simple)
        #expect(big.scrolls && big.panel.height <= screen.height * SwitcherGrid.heightShare + 0.5)
    }

    @Test func searchBarAddsToThePanelHeight() {
        let a = grid(6), b = grid(6, bar: 44)
        #expect(abs((b.panel.height - a.panel.height) - 44) < 0.5 && b.header == 44)
    }

    @Test func cellFramesDoNotOverlapAndStayInsideThePanel() {
        let m = grid(11)
        var frames: [CGRect] = []
        for i in 0..<11 { frames.append(m.cellFrame(i)) }
        for i in frames.indices {
            #expect(CGRect(origin: .zero, size: m.panel).contains(frames[i]) || m.scrolls)
            for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
        }
    }

    @Test func hitTestFindsTheCellUnderThePoint() {
        let m = grid(9)
        for i in 0..<9 {
            let f = m.cellFrame(i)
            #expect(m.index(at: CGPoint(x: f.midX, y: f.midY), count: 9) == i)
        }
        #expect(m.index(at: CGPoint(x: 1, y: 1), count: 9) == nil)
        #expect(m.index(at: CGPoint(x: m.cellFrame(0).maxX + m.spacing / 2, y: m.cellFrame(0).midY), count: 9) == nil)
    }

    @Test func hitTestRejectsTheEmptyTail() {
        let m = grid(5, avail: CGSize(width: 700, height: 976))
        let past = m.cellFrame(m.columns * m.rows - 1)
        if m.columns * m.rows > 5 { #expect(m.index(at: CGPoint(x: past.midX, y: past.midY), count: 5) == nil) }
    }

    @Test func scrollOffsetKeepsTheSelectionVisible() {
        let m = grid(300)
        let viewport = m.panel.height - m.header - m.padding * 2
        var off: CGFloat = 0
        for i in stride(from: 0, to: 300, by: 7) {
            off = m.scrollOffset(forSelected: i, current: off)
            let f = m.cellFrame(i)
            #expect(f.minY - m.padding >= off - 0.5 && f.maxY - m.padding <= off + viewport + 0.5, "i=\(i)")
        }
        #expect(grid(6).scrollOffset(forSelected: 3, current: 40) == 0)
    }

    @Test func panelFrameIsCentredAndClamped() {
        let m = grid(6)
        let area = CGRect(x: 0, y: 24, width: 1800, height: 976)
        let f = SwitcherGrid.panelFrame(metrics: m, in: area)
        #expect(abs(f.midX - area.midX) <= 1 && abs(f.midY - area.midY) <= 1 && area.contains(f))
        let tiny = SwitcherGrid.panelFrame(metrics: grid(30), in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(tiny.width <= 300 && tiny.height <= 200)
    }

    @Test func degenerateInputsStillProduceAUsableGrid() {
        let m = grid(0, avail: CGSize(width: 10, height: 10))
        #expect(m.columns >= 1 && m.rows >= 1 && m.panel.width > 0 && m.panel.height > 0)
    }
}
