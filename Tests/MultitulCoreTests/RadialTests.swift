import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func pt(_ r: Double, _ deg: Double) -> (dx: Double, dy: Double) {
    let a = deg * .pi / 180
    return (r * sin(a), -r * cos(a))
}

private func item(_ i: Int) -> RadialItem { RadialItem(id: "i\(i)", title: "Пункт \(i)", symbol: "star", action: .target(.url("https://example.com/\(i)"))) }

private func items(_ n: Int) -> [RadialItem] { (0..<n).map(item) }

@Suite struct RadialGeometryTests {
    private let g = RadialGeometry()

    @Test(arguments: [(0.0, -100.0, 0.0), (100.0, 0.0, 90.0), (0.0, 100.0, 180.0), (-100.0, 0.0, 270.0), (100.0, -100.0, 45.0), (-100.0, -100.0, 315.0)])
    func angleIsClockwiseFromUp(_ dx: Double, _ dy: Double, _ expected: Double) {
        #expect(abs(RadialGeometry.angle(dx: dx, dy: dy) - expected) < 1e-9)
    }

    @Test func fourSectorsFollowTheCompass() {
        #expect(g.index(dx: 0, dy: -100, count: 4) == 0)
        #expect(g.index(dx: 100, dy: 0, count: 4) == 1)
        #expect(g.index(dx: 0, dy: 100, count: 4) == 2)
        #expect(g.index(dx: -100, dy: 0, count: 4) == 3)
    }

    @Test func sectorBoundariesAreHalfAWidthFromTheCentre() {
        let a = pt(100, 44.9), b = pt(100, 45.1)
        #expect(g.index(dx: a.dx, dy: a.dy, count: 4) == 0)
        #expect(g.index(dx: b.dx, dy: b.dy, count: 4) == 1)
        let c = pt(100, 359), d = pt(100, 315.5)
        #expect(g.index(dx: c.dx, dy: c.dy, count: 4) == 0)
        #expect(g.index(dx: d.dx, dy: d.dy, count: 4) == 0)
        let e = pt(100, 314.5)
        #expect(g.index(dx: e.dx, dy: e.dy, count: 4) == 3)
    }

    @Test func deadZoneSelectsNothing() {
        #expect(g.index(dx: 0, dy: 0, count: 8) == nil)
        #expect(g.index(dx: 10, dy: -20, count: 8) == nil)
        #expect(g.index(dx: 0, dy: -33.9, count: 8) == nil)
        #expect(g.index(dx: 0, dy: -34, count: 8) == 0)
    }

    @Test func deadZoneIsConfigurable() {
        var big = g
        big.innerRadius = 60
        #expect(big.index(dx: 0, dy: -50, count: 4) == nil && big.index(dx: 0, dy: -61, count: 4) == 0)
    }

    @Test func cancelRadiusRejectsFarPointers() {
        var far = g
        far.cancelRadius = 200
        #expect(far.index(dx: 0, dy: -199, count: 4) == 0 && far.index(dx: 0, dy: -201, count: 4) == nil)
        #expect(g.index(dx: 0, dy: -5000, count: 4) == 0)
    }

    @Test(arguments: Array(1...12))
    func everySectorIsHitAtItsOwnCentre(_ n: Int) {
        for i in 0..<n {
            let p = pt(100, g.centerAngle(index: i, count: n))
            #expect(g.index(dx: p.dx, dy: p.dy, count: n) == i, "n=\(n) i=\(i)")
        }
    }

    @Test(arguments: Array(1...12))
    func sectorsTileTheFullCircle(_ n: Int) {
        var hits = [Int](repeating: 0, count: n)
        for deg in stride(from: 0.0, to: 360.0, by: 0.5) {
            let p = pt(100, deg)
            if let i = g.index(dx: p.dx, dy: p.dy, count: n) { hits[i] += 1 }
        }
        #expect(hits.reduce(0, +) == 720)
        let expected = 720 / n
        #expect(hits.allSatisfy { abs($0 - expected) <= 2 })
    }

    @Test func oneItemOwnsTheWholeRing() {
        for deg in stride(from: 0.0, to: 360.0, by: 37) {
            let p = pt(80, deg)
            #expect(g.index(dx: p.dx, dy: p.dy, count: 1) == 0)
        }
    }

    @Test func twelveItemsAreThirtyDegreesWide() {
        #expect(g.sectorWidth(count: 12) == 30)
        let s = g.span(index: 0, count: 12)
        #expect(s.start == -15 && s.end == 15)
        let s3 = g.span(index: 3, count: 12)
        #expect(s3.start == 75 && s3.end == 105)
    }

    @Test func emptyRingSelectsNothing() {
        #expect(g.index(dx: 0, dy: -100, count: 0) == nil)
    }

    @Test func hysteresisKeepsTheCurrentSectorNearABorder() {
        let near = pt(100, 47), past = pt(100, 52)
        #expect(g.index(dx: near.dx, dy: near.dy, count: 4, current: 0) == 0)
        #expect(g.index(dx: near.dx, dy: near.dy, count: 4, current: nil) == 1)
        #expect(g.index(dx: past.dx, dy: past.dy, count: 4, current: 0) == 1)
    }

    @Test func hysteresisDoesNotTrapAcrossAWholeSector() {
        let far = pt(100, 180)
        #expect(g.index(dx: far.dx, dy: far.dy, count: 4, current: 0) == 2)
    }

    @Test func offsetsPlaceLabelsOnTheRing() {
        let o = g.offset(index: 1, count: 4, radius: 100)
        #expect(abs(o.dx - 100) < 1e-9 && abs(o.dy) < 1e-9)
        let top = g.offset(index: 0, count: 8, radius: 50)
        #expect(abs(top.dx) < 1e-9 && abs(top.dy + 50) < 1e-9)
        #expect(g.labelRadius == (g.innerRadius + g.outerRadius) / 2)
    }

    @Test func angularDistanceWrapsAround() {
        #expect(RadialGeometry.angularDistance(350, 10) == 20)
        #expect(RadialGeometry.angularDistance(10, 350) == 20)
        #expect(RadialGeometry.angularDistance(0, 180) == 180)
    }
}

@Suite struct RadialPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func centreStaysWhenThereIsRoom() {
        #expect(RadialPlacement.center(pointer: CGPoint(x: 500, y: 400), radius: 170, in: screen) == CGPoint(x: 500, y: 400))
    }

    @Test func wheelIsPushedAwayFromEdges() {
        #expect(RadialPlacement.center(pointer: CGPoint(x: 10, y: 10), radius: 170, in: screen) == CGPoint(x: 170, y: 170))
        #expect(RadialPlacement.center(pointer: CGPoint(x: 995, y: 795), radius: 170, in: screen) == CGPoint(x: 830, y: 630))
    }

    @Test func tinyScreenCentresTheWheel() {
        #expect(RadialPlacement.center(pointer: CGPoint(x: 5, y: 5), radius: 170, in: CGRect(x: 0, y: 0, width: 200, height: 200)) == CGPoint(x: 100, y: 100))
    }

    @Test func secondaryDisplayWithOffsetOrigin() {
        let ext = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        #expect(RadialPlacement.center(pointer: CGPoint(x: -1910, y: 110), radius: 170, in: ext) == CGPoint(x: -1750, y: 270))
    }
}

@Suite struct RadialSessionTests {
    private func session(_ n: Int = 8, mode: RadialMode = .hold, center: CGPoint = CGPoint(x: 500, y: 400), anchor: CGPoint? = nil, clock: WndBox<TimeInterval> = WndBox(100), sticky: Int = 250) -> (RadialSession, WndBox<TimeInterval>) {
        (RadialSession(items: items(n), center: center, anchor: anchor, geometry: RadialGeometry(), mode: mode, stickyMs: sticky, clock: { clock.value }), clock)
    }

    private func at(_ s: RadialSession, _ r: Double, _ deg: Double) -> CGPoint {
        let o = pt(r, deg)
        return CGPoint(x: s.center.x + o.dx, y: s.center.y + o.dy)
    }

    @Test func hoverFollowsThePointer() {
        let (s, _) = session()
        s.move(to: at(s, 100, 0))
        #expect(s.hovered == 0)
        s.move(to: at(s, 100, 90))
        #expect(s.hovered == 2)
        s.move(to: at(s, 10, 90))
        #expect(s.hovered == nil)
    }

    @Test func releaseOverAnItemRunsIt() {
        let (s, _) = session()
        s.move(to: at(s, 100, 180))
        #expect(s.release(at: at(s, 100, 180)) == .run(item(4)))
        #expect(s.finished)
    }

    @Test func quickReleaseInTheCentreKeepsTheWheelOpen() {
        let (s, clock) = session()
        clock.value += 0.1
        #expect(s.release(at: s.center) == .becameSticky && s.mode == .sticky && !s.finished)
    }

    @Test func slowReleaseInTheCentreCancels() {
        let (s, clock) = session()
        clock.value += 0.6
        #expect(s.release(at: s.center) == .cancelled && s.finished)
    }

    @Test func stickyThresholdIsConfigurable() {
        let (s, clock) = session(sticky: 800)
        clock.value += 0.6
        #expect(s.release(at: s.center) == .becameSticky)
    }

    @Test func releaseOnAnItemIsInstantEvenWhenQuick() {
        let (s, _) = session()
        #expect(s.release(at: at(s, 100, 45)) == .run(item(1)))
    }

    @Test func stickyClickPicksTheHoveredItem() {
        let (s, clock) = session()
        clock.value += 0.1
        _ = s.release(at: s.center)
        #expect(s.click(at: at(s, 100, 270)) == .run(item(6)))
    }

    @Test func stickyClickOutsideEverythingCancels() {
        let (s, clock) = session()
        clock.value += 0.1
        _ = s.release(at: s.center)
        #expect(s.click(at: s.center) == .cancelled)
    }

    @Test func releaseIsIgnoredOnceSticky() {
        let (s, clock) = session()
        clock.value += 0.1
        _ = s.release(at: s.center)
        #expect(s.release(at: at(s, 100, 0)) == .none && !s.finished)
    }

    @Test func numbersPickByPosition() {
        let (s, _) = session(12)
        #expect(s.pick(number: 3) == .run(item(2)))
        let (t, _) = session(12)
        #expect(t.pick(number: 0) == .run(item(9)))
        let (u, _) = session(4)
        #expect(u.pick(number: 7) == .none && !u.finished)
    }

    @Test func escapeCancelsAndFinishedSessionsIgnoreEverything() {
        let (s, _) = session()
        #expect(s.cancel() == .cancelled)
        #expect(s.cancel() == .none && s.pick(index: 0) == .none && s.click(at: s.center) == .none && s.release(at: s.center) == .none && s.back() == .none)
        s.move(to: at(s, 100, 0))
        #expect(s.hovered == nil)
    }

    @Test func ringIsCappedAtTwelveItems() {
        let (s, _) = session(20)
        #expect(s.items.count == 12)
    }

    @Test func armDistanceIgnoresTheStartingPointerWhenTheWheelWasPushedAway() {
        let center = CGPoint(x: 170, y: 170)
        let anchor = CGPoint(x: 10, y: 10)
        let (s, clock) = session(center: center, anchor: anchor)
        s.move(to: CGPoint(x: 12, y: 12))
        #expect(s.hovered == nil)
        clock.value += 0.1
        #expect(s.release(at: CGPoint(x: 12, y: 12)) == .becameSticky)
    }

    @Test func armDistanceReleasesAfterRealMovement() {
        let (s, _) = session(center: CGPoint(x: 170, y: 170), anchor: CGPoint(x: 10, y: 10))
        s.move(to: CGPoint(x: 40, y: 40))
        #expect(s.hovered != nil)
        s.move(to: CGPoint(x: 170, y: 70))
        #expect(s.hovered == 0)
    }

    @Test func hysteresisReducesFlicker() {
        let (s, _) = session(4)
        s.move(to: at(s, 100, 10))
        #expect(s.hovered == 0)
        s.move(to: at(s, 100, 47))
        #expect(s.hovered == 0)
        s.move(to: at(s, 100, 60))
        #expect(s.hovered == 1)
    }
}

@Suite struct RadialSubmenuTests {
    private func tree() -> [RadialItem] {
        let deep = RadialItem(id: "deep", title: "Глубже", action: .submenu([item(20), item(21)]))
        let sub = RadialItem(id: "sub", title: "Подменю", action: .submenu([item(10), deep, item(12)]))
        return [item(0), sub, item(2), item(3)]
    }

    private func session() -> RadialSession {
        RadialSession(items: tree(), center: CGPoint(x: 500, y: 400), geometry: RadialGeometry(), mode: .hold, clock: { 0 })
    }

    private func pos(_ s: RadialSession, _ i: Int) -> CGPoint {
        let o = pt(100, s.geometry.centerAngle(index: i, count: s.items.count))
        return CGPoint(x: s.center.x + o.dx, y: s.center.y + o.dy)
    }

    @Test func choosingASubmenuOpensItInStickyMode() {
        let s = session()
        s.move(to: pos(s, 1))
        #expect(s.release(at: pos(s, 1)) == .enteredSubmenu)
        #expect(s.depth == 1 && s.title == "Подменю" && s.items.count == 3 && s.mode == .sticky && !s.finished && s.hovered == nil)
    }

    @Test func clickingTheCentreGoesBack() {
        let s = session()
        _ = s.pick(index: 1)
        #expect(s.click(at: s.center) == .leftSubmenu && s.depth == 0 && s.items.count == 4)
    }

    @Test func backspaceStyleBackAtTheRootCancels() {
        let s = session()
        #expect(s.back() == .cancelled)
    }

    @Test func nestedLevels() {
        let s = session()
        _ = s.pick(index: 1)
        _ = s.pick(index: 1)
        #expect(s.depth == 2 && s.title == "Глубже" && s.items.map(\.id) == ["i20", "i21"])
        #expect(s.back() == .leftSubmenu && s.depth == 1)
        #expect(s.back() == .leftSubmenu && s.depth == 0)
    }

    @Test func runningFromASubmenuFinishes() {
        let s = session()
        _ = s.pick(index: 1)
        #expect(s.pick(index: 2) == .run(item(12)) && s.finished)
    }

    @Test func emptySubmenuDoesNotOpen() {
        let s = RadialSession(items: [RadialItem(id: "e", title: "Пусто", action: .submenu([]))], center: .zero, geometry: RadialGeometry(), clock: { 0 })
        #expect(s.pick(index: 0) == .none && s.depth == 0)
    }
}

private final class RdPresenter: RadialPresenting {
    var shown: [RadialViewState] = []
    var updates: [RadialViewState] = []
    var hides = 0
    func show(_ state: RadialViewState) { shown.append(state) }
    func update(_ state: RadialViewState) { updates.append(state) }
    func hide() { hides += 1 }
}

private final class RdRunner: RadialRunning {
    var ran: [RadialItem] = []
    func run(_ item: RadialItem) { ran.append(item) }
}

private let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd

private struct Wheel {
    let presenter = RdPresenter()
    let runner = RdRunner()
    let clock = WndBox<TimeInterval>(50)
    let settings: WndBox<RadialSettings>
    let front = WndBox<String?>(nil)
    let trusted = WndBox(true)
    let controller: RadialController

    init(_ configure: (inout RadialSettings) -> Void = { _ in }) {
        var s = RadialSettings()
        s.profiles = [RadialProfile(id: "p", name: "P", items: items(8))]
        s.activeProfileID = "p"
        configure(&s)
        settings = WndBox(s)
        let sb = settings, cb = clock, fb = front, tb = trusted
        controller = RadialController(settings: { sb.value }, presenter: presenter, runner: runner, clock: { cb.value }, frontBundleID: { fb.value },
                                      screenFrame: { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) }, trusted: { tb.value })
    }

    @discardableResult
    func send(_ i: RadialInput) -> EventTapAction { controller.handle(i) }

    func open(at p: CGPoint = CGPoint(x: 500, y: 400)) {
        send(.moved(p))
        send(.keyDown(code: Keys.space, mods: layer, repeating: false))
    }

    func point(_ r: Double, _ deg: Double) -> CGPoint {
        let o = pt(r, deg)
        let c = controller.state?.center ?? CGPoint(x: 500, y: 400)
        return CGPoint(x: c.x + o.dx, y: c.y + o.dy)
    }
}

@Suite struct RadialControllerHotkeyTests {
    @Test func holdingTheHotkeyOpensTheWheelAtThePointer() {
        let w = Wheel()
        w.send(.moved(CGPoint(x: 400, y: 300)))
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: false)) == .drop)
        #expect(w.controller.isActive && w.presenter.shown.count == 1 && w.presenter.shown[0].center == CGPoint(x: 400, y: 300) && w.presenter.shown[0].items.count == 8)
    }

    @Test func releaseAfterHoveringRunsTheItem() {
        let w = Wheel()
        w.open()
        w.clock.value += 1
        w.send(.moved(w.point(100, 90)))
        #expect(w.presenter.updates.last?.hovered == 2)
        #expect(w.send(.keyUp(code: Keys.space)) == .drop)
        #expect(w.runner.ran == [item(2)] && !w.controller.isActive && w.presenter.hides == 1)
    }

    @Test func wrongModifiersOrKeyDoNotOpen() {
        let w = Wheel()
        #expect(w.send(.keyDown(code: Keys.space, mods: KeyCombo.ctrl | KeyCombo.opt, repeating: false)) == .pass)
        #expect(w.send(.keyDown(code: Keys.space, mods: layer | KeyCombo.shift, repeating: false)) == .pass)
        #expect(w.send(.keyDown(code: 0, mods: layer, repeating: false)) == .pass)
        #expect(!w.controller.isActive)
    }

    @Test func autorepeatDoesNotReopenOrRestart() {
        let w = Wheel()
        w.open()
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: true)) == .drop)
        #expect(w.presenter.shown.count == 1)
    }

    @Test func idleKeyRepeatIsLeftAlone() {
        let w = Wheel()
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: true)) == .pass)
    }

    @Test func letGoOfAModifierEndsTheHold() {
        let w = Wheel()
        w.open()
        w.clock.value += 1
        w.send(.moved(w.point(100, 0)))
        #expect(w.send(.modsChanged(KeyCombo.ctrl | KeyCombo.opt)) == .pass)
        #expect(w.runner.ran == [item(0)] && !w.controller.isActive)
    }

    @Test func otherModifierChangesDoNotEndIt() {
        let w = Wheel()
        w.open()
        w.send(.modsChanged(layer | KeyCombo.shift))
        #expect(w.controller.isActive)
    }

    @Test func escapeCancelsWithoutRunning() {
        let w = Wheel()
        w.open()
        #expect(w.send(.keyDown(code: Keys.escape, mods: layer, repeating: false)) == .drop)
        #expect(!w.controller.isActive && w.runner.ran.isEmpty && w.presenter.hides == 1)
    }

    @Test func quickTapStaysOpenAndAClickPicks() {
        let w = Wheel()
        w.open()
        w.clock.value += 0.1
        #expect(w.send(.keyUp(code: Keys.space)) == .drop)
        #expect(w.controller.isActive && w.controller.state?.mode == .sticky)
        w.send(.moved(w.point(100, 180)))
        #expect(w.send(.leftDown(w.point(100, 180))) == .drop)
        #expect(w.runner.ran == [item(4)])
        #expect(w.send(.leftUp(w.point(100, 180))) == .drop)
        #expect(w.send(.leftUp(w.point(100, 180))) == .pass)
    }

    @Test func pressingTheHotkeyAgainClosesAStickyWheel() {
        let w = Wheel()
        w.open()
        w.clock.value += 0.1
        w.send(.keyUp(code: Keys.space))
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: false)) == .drop)
        #expect(!w.controller.isActive && w.runner.ran.isEmpty)
    }

    @Test func digitsPickWhileOpen() {
        let w = Wheel()
        w.open()
        #expect(w.send(.keyDown(code: 20, mods: layer, repeating: false)) == .drop)
        #expect(w.runner.ran == [item(2)])
    }

    @Test func otherKeysAreSwallowedWhileOpen() {
        let w = Wheel()
        w.open()
        #expect(w.send(.keyDown(code: 0, mods: layer, repeating: false)) == .drop)
        #expect(w.controller.isActive)
    }

    @Test func idleKeysAndClicksPassThrough() {
        let w = Wheel()
        #expect(w.send(.keyDown(code: 0, mods: 0, repeating: false)) == .pass)
        #expect(w.send(.leftDown(CGPoint(x: 1, y: 1))) == .pass && w.send(.leftUp(CGPoint(x: 1, y: 1))) == .pass)
        #expect(w.send(.keyUp(code: 0)) == .pass && w.send(.moved(CGPoint(x: 3, y: 3))) == .pass)
    }

    @Test func pointerIsPassedThroughWhileOpen() {
        let w = Wheel()
        w.open()
        #expect(w.send(.moved(CGPoint(x: 510, y: 410))) == .pass)
    }

    @Test func disabledHotkeyOrMissingTrustDoNothing() {
        let off = Wheel { $0.trigger.hotkeyEnabled = false }
        off.open()
        #expect(!off.controller.isActive)
        let untrusted = Wheel()
        untrusted.trusted.value = false
        untrusted.open()
        #expect(!untrusted.controller.isActive)
    }

    @Test func customHotkey() {
        let w = Wheel { $0.trigger.hotkey = KeyCombo(keyCode: 9, modifiers: KeyCombo.cmd | KeyCombo.shift) }
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: false)) == .pass)
        #expect(w.send(.keyDown(code: 9, mods: KeyCombo.cmd | KeyCombo.shift, repeating: false)) == .drop)
        #expect(w.controller.isActive)
    }

    @Test func emptyProfileNeverOpens() {
        let w = Wheel { $0.profiles = [RadialProfile(id: "p", name: "P", items: [])] }
        #expect(w.send(.keyDown(code: Keys.space, mods: layer, repeating: false)) == .pass)
        #expect(!w.controller.isActive && w.presenter.shown.isEmpty)
    }

    @Test func wheelIsPushedAwayFromTheScreenEdge() {
        let w = Wheel()
        w.open(at: CGPoint(x: 5, y: 5))
        #expect(w.presenter.shown[0].center == CGPoint(x: 170, y: 170))
    }

    @Test func pushedWheelDoesNotPickAnythingOnAQuickTap() {
        let w = Wheel()
        w.open(at: CGPoint(x: 5, y: 5))
        w.clock.value += 0.1
        w.send(.keyUp(code: Keys.space))
        #expect(w.runner.ran.isEmpty && w.controller.isActive)
    }

    @Test func profileFollowsTheFrontApp() {
        let w = Wheel {
            $0.profiles = [RadialProfile(id: "p", name: "P", items: items(8)), RadialProfile(id: "s", name: "Safari", items: items(3), bundleIDs: ["com.apple.Safari"])]
            $0.activeProfileID = "p"
        }
        w.front.value = "com.apple.Safari"
        w.open()
        #expect(w.presenter.shown[0].items.count == 3)
        w.controller.cancel()
        w.settings.value.switchByApp = false
        w.open()
        #expect(w.presenter.shown[1].items.count == 8)
    }

    @Test func cancelFromOutsideHidesTheWheel() {
        let w = Wheel()
        w.open()
        w.controller.cancel()
        #expect(!w.controller.isActive && w.presenter.hides == 1)
        w.controller.cancel()
        #expect(w.presenter.hides == 1)
    }

    @Test func openCountGrows() {
        let w = Wheel()
        w.open()
        w.controller.cancel()
        w.open()
        #expect(w.controller.openCount == 2)
    }
}

@Suite struct RadialControllerOtherTriggerTests {
    @Test func sideButtonOpensAndReleaseRuns() {
        let w = Wheel { $0.trigger.hotkeyEnabled = false; $0.trigger.mouseButton = 3 }
        w.send(.moved(CGPoint(x: 500, y: 400)))
        #expect(w.send(.buttonDown(3, CGPoint(x: 500, y: 400))) == .drop && w.controller.isActive)
        w.clock.value += 1
        w.send(.moved(w.point(100, 270)))
        #expect(w.send(.buttonUp(3, w.point(100, 270))) == .drop)
        #expect(w.runner.ran == [item(6)])
    }

    @Test func otherButtonsAreIgnored() {
        let w = Wheel { $0.trigger.mouseButton = 3 }
        #expect(w.send(.buttonDown(4, .zero)) == .pass && w.send(.buttonDown(2, .zero)) == .pass && !w.controller.isActive)
    }

    @Test func noButtonConfiguredMeansNoButtonTrigger() {
        let w = Wheel()
        #expect(w.send(.buttonDown(3, .zero)) == .pass)
    }

    @Test func buttonRepeatedDownIsSwallowedWhileOpen() {
        let w = Wheel { $0.trigger.mouseButton = 3 }
        w.send(.buttonDown(3, CGPoint(x: 500, y: 400)))
        #expect(w.send(.buttonDown(3, CGPoint(x: 500, y: 400))) == .drop)
        #expect(w.presenter.shown.count == 1)
    }

    @Test func anotherButtonCancelsAHeldWheel() {
        let w = Wheel { $0.trigger.mouseButton = 3 }
        w.send(.buttonDown(3, CGPoint(x: 500, y: 400)))
        #expect(w.send(.buttonDown(4, CGPoint(x: 500, y: 400))) == .drop && !w.controller.isActive)
    }

    @Test func fourFingerTapOpensAStickyWheel() {
        let w = Wheel { $0.trigger.fourFingerTap = true; $0.trigger.hotkeyEnabled = false }
        w.send(.moved(CGPoint(x: 500, y: 400)))
        #expect(w.send(.fourFingerTap) == .pass)
        #expect(w.controller.isActive && w.controller.state?.mode == .sticky)
        w.send(.moved(w.point(100, 315)))
        w.send(.leftDown(w.point(100, 315)))
        #expect(w.runner.ran == [item(7)])
    }

    @Test func tapWhileOpenClosesIt() {
        let w = Wheel { $0.trigger.fourFingerTap = true }
        w.send(.fourFingerTap)
        w.send(.fourFingerTap)
        #expect(!w.controller.isActive)
    }

    @Test func tapIsIgnoredWhenDisabled() {
        let w = Wheel()
        w.send(.fourFingerTap)
        #expect(!w.controller.isActive)
    }

    @Test func clickingTheCentreOfAStickyWheelCancels() {
        let w = Wheel { $0.trigger.fourFingerTap = true }
        w.send(.moved(CGPoint(x: 500, y: 400)))
        w.send(.fourFingerTap)
        w.send(.leftDown(CGPoint(x: 500, y: 400)))
        #expect(!w.controller.isActive && w.runner.ran.isEmpty)
    }

    @Test func submenuNavigationThroughTheController() {
        let sub = RadialItem(id: "sub", title: "Подменю", action: .submenu([item(10), item(11)]))
        let w = Wheel { $0.profiles = [RadialProfile(id: "p", name: "P", items: [sub, item(1), item(2), item(3)])] }
        w.open()
        w.clock.value += 1
        w.send(.moved(w.point(100, 0)))
        w.send(.keyUp(code: Keys.space))
        #expect(w.controller.isActive && w.controller.state?.depth == 1 && w.controller.state?.items.count == 2)
        w.send(.keyDown(code: Keys.backspace, mods: 0, repeating: false))
        #expect(w.controller.state?.depth == 0)
        w.send(.keyDown(code: 18, mods: 0, repeating: false))
        #expect(w.controller.state?.depth == 1)
        w.send(.keyDown(code: 19, mods: 0, repeating: false))
        #expect(w.runner.ran == [item(11)] && !w.controller.isActive)
    }
}

@Suite struct RadialTapDetectorTests {
    private func frames(_ d: FourFingerTapDetector, _ list: [(Int, Double, Float, Float)]) -> [Bool] {
        list.map { d.ingest(TouchFrame(fingers: $0.0, time: $0.1, x: $0.2, y: $0.3)) }
    }

    @Test func aQuickFourFingerTapFiresOnLift() {
        let d = FourFingerTapDetector()
        #expect(frames(d, [(4, 1.0, 0.5, 0.5), (4, 1.05, 0.5, 0.5), (0, 1.1, 0, 0)]) == [false, false, true])
    }

    @Test func threeFingersNeverFire() {
        let d = FourFingerTapDetector()
        #expect(!frames(d, [(3, 1.0, 0.5, 0.5), (3, 1.05, 0.5, 0.5), (0, 1.1, 0, 0)]).contains(true))
    }

    @Test func fiveFingersNeverFire() {
        let d = FourFingerTapDetector()
        #expect(!frames(d, [(4, 1.0, 0.5, 0.5), (5, 1.02, 0.5, 0.5), (0, 1.1, 0, 0)]).contains(true))
    }

    @Test func aLongTouchIsNotATap() {
        let d = FourFingerTapDetector()
        #expect(!frames(d, [(4, 1.0, 0.5, 0.5), (4, 1.2, 0.5, 0.5), (4, 1.4, 0.5, 0.5), (0, 1.5, 0, 0)]).contains(true))
    }

    @Test func aSwipeIsNotATap() {
        let d = FourFingerTapDetector()
        #expect(!frames(d, [(4, 1.0, 0.2, 0.5), (4, 1.05, 0.5, 0.5), (0, 1.1, 0, 0)]).contains(true))
    }

    @Test func cooldownBlocksDoubleFiring() {
        let d = FourFingerTapDetector()
        #expect(frames(d, [(4, 1.0, 0.5, 0.5), (0, 1.1, 0, 0), (4, 1.2, 0.5, 0.5), (0, 1.3, 0, 0)]) == [false, true, false, false])
        #expect(frames(d, [(4, 2.0, 0.5, 0.5), (0, 2.1, 0, 0)]) == [false, true])
    }

    @Test func resetForgetsAnUnfinishedTouch() {
        let d = FourFingerTapDetector()
        _ = d.ingest(TouchFrame(fingers: 4, time: 1, x: 0.5, y: 0.5))
        d.reset()
        #expect(!d.ingest(TouchFrame(fingers: 0, time: 1.05)))
    }
}

private final class RdTouchSource: TouchSource {
    var onFrame: ((TouchFrame) -> Void)?
    var starts = 0
    var stops = 0
    var canStart = true
    func start() -> Bool { starts += 1; return canStart }
    func stop() { stops += 1 }
    func emit(_ f: Int) { onFrame?(TouchFrame(fingers: f, time: 1)) }
}

@Suite struct TouchHubTests {
    private func hub() -> (TouchHub, RdTouchSource) {
        let src = RdTouchSource()
        return (TouchHub { src }, src)
    }

    @Test func firstSubscriberStartsAndLastStops() {
        let (h, src) = hub()
        let a = h.attach { _ in }, b = h.attach { _ in }
        #expect(src.starts == 1 && h.subscriberCount == 2 && h.isRunning)
        h.detach(a!)
        #expect(src.stops == 0)
        h.detach(b!)
        #expect(src.stops == 1 && !h.isRunning && h.subscriberCount == 0)
    }

    @Test func framesFanOut() {
        let (h, src) = hub()
        var one = 0, two = 0
        let a = h.attach { _ in one += 1 }
        _ = h.attach { _ in two += 1 }
        src.emit(2)
        h.detach(a!)
        src.emit(3)
        #expect(one == 1 && two == 2)
    }

    @Test func failedStartReturnsNilAndForgetsTheHandler() {
        let (h, src) = hub()
        src.canStart = false
        #expect(h.attach { _ in } == nil && h.subscriberCount == 0 && !h.isRunning && h.failedToStart)
    }

    @Test func facadeBehavesLikeATouchSource() {
        let (h, src) = hub()
        let f1 = h.makeSource(), f2 = h.makeSource()
        var got1 = 0, got2 = 0
        f1.onFrame = { _ in got1 += 1 }
        f2.onFrame = { _ in got2 += 1 }
        #expect(f1.start() && f2.start() && src.starts == 1)
        src.emit(1)
        f1.stop()
        src.emit(1)
        #expect(got1 == 1 && got2 == 2)
        f2.stop()
        #expect(src.stops == 1)
    }

    @Test func facadeRestartDoesNotLeakSubscriptions() {
        let (h, _) = hub()
        let f = h.makeSource()
        _ = f.start()
        _ = f.start()
        #expect(h.subscriberCount == 1)
        f.stop()
        f.stop()
        #expect(h.subscriberCount == 0)
    }

    @Test func detachOfUnknownIdIsHarmless() {
        let (h, src) = hub()
        h.detach(99)
        #expect(src.stops == 0)
    }
}
