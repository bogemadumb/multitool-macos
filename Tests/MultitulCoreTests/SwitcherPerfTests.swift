import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func seconds(_ block: () -> Void) -> Double {
    let c = ContinuousClock()
    let d = c.measure(block)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

private func median(_ runs: Int, _ block: () -> Void) -> Double {
    var xs: [Double] = []
    for _ in 0..<runs { xs.append(seconds(block)) }
    return xs.sorted()[xs.count / 2]
}

@Suite struct SwitcherPerfTests {
    private func filled(_ n: Int) -> (SwitcherSnapshot, WindowUseOrder) {
        let w = SwcFix.manyWindows(n)
        let order = WindowUseOrder()
        for (i, x) in w.enumerated() where i % 3 == 0 { order.touch(window: x.key, pid: x.pid) }
        return (SwitcherSnapshot(windows: w, apps: SwcFix.manyApps(), focusedKey: 1, frontPID: 100, displays: [SwcFix.display]), order)
    }

    private func buildModel(_ snap: SwitcherSnapshot, _ order: WindowUseOrder) -> SwitcherSession {
        var f = SwitchFilter()
        f.ownPID = 1
        let e = SwitcherListBuilder.build(windows: snap.windows, apps: snap.apps, filter: f, context: SwitcherContext(focusedKey: snap.focusedKey), order: order)
        return SwitcherSession(entries: e)
    }

    @Test func buildingThirtyWindowsStaysFarInsideTheBudget() {
        let (snap, order) = filled(30)
        let t = median(9) { _ = buildModel(snap, order) }
        #expect(t < 0.02, "30 окон: \(t * 1000) мс")
        #expect(buildModel(snap, order).count >= 30)
    }

    @Test func buildingAHundredWindowsStaysInsideTheBudget() {
        let (snap, order) = filled(100)
        let t = median(9) { _ = buildModel(snap, order) }
        #expect(t < 0.06, "100 окон: \(t * 1000) мс")
    }

    @Test func fullOpenPathForThirtyWindowsFitsTheRoadmapTarget() {
        let (snap, order) = filled(30)
        let src = SwcSource(windows: snap.windows, apps: snap.apps, focused: 1, front: 100)
        let panel = SwcPanel()
        var s = SwitcherSettings()
        s.screenPlacement = .pointer
        let e = SwitcherEngine(source: src, actor: SwcActor(), panel: panel, order: order, settings: { s }, ownPID: 1)
        let t = median(9) {
            _ = e.begin(trigger: .apps, backward: false)
            e.present()
            e.move(1)
            e.commit()
        }
        #expect(t < 0.05, "begin+present+move+commit для 30 окон: \(t * 1000) мс (цель этапа 150 мс целиком, с живым перечислением)")
        #expect(panel.presented.last?.entries.count ?? 0 >= 30)
    }

    @Test func fullOpenPathForAHundredWindows() {
        let (snap, order) = filled(100)
        let src = SwcSource(windows: snap.windows, apps: snap.apps, focused: 1, front: 100)
        let e = SwitcherEngine(source: src, actor: SwcActor(), panel: SwcPanel(), order: order, settings: { SwitcherSettings() }, ownPID: 1)
        let t = median(5) {
            _ = e.begin(trigger: .apps, backward: false)
            e.present()
            e.cancel()
        }
        #expect(t < 0.15, "100 окон: \(t * 1000) мс")
    }

    @Test func searchRankingScalesToAHundredWindows() {
        let (snap, order) = filled(100)
        var s = buildModel(snap, order)
        let t = median(9) {
            s.setQuery("докум 5")
            s.setQuery("")
        }
        #expect(t < 0.05, "поиск по 100 окнам: \(t * 1000) мс")
        s.setQuery("приложение 3")
        #expect(s.count > 0)
    }

    @Test func typingCharacterByCharacterIsCheap() {
        let (snap, order) = filled(100)
        var s = buildModel(snap, order)
        let t = seconds {
            for ch in "документ номер черновик" { s.appendQuery(String(ch)) }
        }
        #expect(t < 0.25, "ввод 22 символов: \(t * 1000) мс")
    }

    @Test func gridMathIsInstantEvenForAThousandWindows() {
        let t = median(9) {
            for n in [1, 5, 30, 100, 1000] { _ = SwitcherGrid.metrics(count: n, available: CGSize(width: 1800, height: 976), layout: .windows, size: .normal) }
        }
        #expect(t < 0.01, "сетка: \(t * 1000) мс")
    }

    @Test func snapshotMergeOfThirtyWindowsIsFast() {
        let apps = Dictionary(uniqueKeysWithValues: SwcFix.manyApps().map { ($0.pid, $0) })
        var cg: [CGWindowRecord] = []
        var ax: [AXWindowRecord] = []
        for i in 0..<30 {
            let pid = Int32(100 + i % 10)
            let x = CGFloat(i * 40)
            cg.append(CGWindowRecord(windowID: UInt32(i + 1), pid: pid, title: "Окно \(i)", frame: CGRect(x: x, y: 50, width: 700, height: 500), zIndex: i))
            ax.append(AXWindowRecord(key: i + 1, pid: pid, title: "Окно \(i)", frame: CGRect(x: x, y: 50, width: 700, height: 500)))
        }
        let t = median(9) { _ = WindowSnapshotMerger.merge(cg: cg, ax: ax, apps: apps, displays: [SwcFix.display]) }
        #expect(t < 0.01, "склейка CG и AX: \(t * 1000) мс")
        #expect(WindowSnapshotMerger.merge(cg: cg, ax: ax, apps: apps, displays: [SwcFix.display]).count == 30)
    }

    @Test func thumbnailPlanningForAHundredWindowsIsInstant() {
        let (snap, order) = filled(100)
        let s = buildModel(snap, order)
        let cache = ThumbnailCache()
        let t = median(9) { _ = ThumbnailPlanner.plan(entries: s.visible, selected: 1, cache: cache, now: 0, allowCapture: true, budget: 24) }
        #expect(t < 0.005, "план миниатюр: \(t * 1000) мс")
    }

    @Test func useOrderSortingOfFiveHundredWindowsIsCheap() {
        let w = SwcFix.manyWindows(500, apps: 25)
        let order = WindowUseOrder()
        for x in w.prefix(200) { order.touch(window: x.key, pid: x.pid) }
        let t = median(5) { _ = order.sorted(w) }
        #expect(t < 0.05, "MRU 500 окон: \(t * 1000) мс")
    }
}
