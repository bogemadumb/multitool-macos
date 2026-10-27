import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let displays = WndFix.displays([WndFix.clean])
private let area = displays[0].visible
private let small = CGRect(x: 300, y: 200, width: 700, height: 500)

private func decide(_ b: MaximizerBrain, key: Int = 1, bundle: String? = "com.test.app", frame: CGRect = small, mods: GestureModifiers = [], full: Bool = false, screens: [WndDisplay] = displays, _ s: MaximizerSettings = MaximizerSettings()) -> MaximizerDecision {
    b.decide(key: key, bundleID: bundle, frame: frame, modifiers: mods, isFullScreen: full, displays: screens, settings: s)
}

@Suite struct MaximizerBrainTests {
    @Test func firstClickMaximisesToTheVisibleArea() {
        #expect(decide(MaximizerBrain()) == .maximize(area))
    }

    @Test func secondClickRestoresTheOriginalFrame() {
        let b = MaximizerBrain()
        _ = decide(b)
        #expect(decide(b, frame: area) == .restore(small))
    }

    @Test func maximisedWithoutAMemoryFallsBackToNative() {
        #expect(decide(MaximizerBrain(), frame: area) == .passThrough)
    }

    @Test func restoreCanBeDisabled() {
        let b = MaximizerBrain()
        var s = MaximizerSettings()
        s.toggleRestores = false
        _ = decide(b, s)
        #expect(decide(b, frame: area, s) == .passThrough)
    }

    @Test func excludedAppsKeepTheNativeButton() {
        var s = MaximizerSettings()
        s.excluded = AppExceptionList(["com.test.app"])
        #expect(decide(MaximizerBrain(), s) == .passThrough)
        s.excluded = AppExceptionList(["com.test.*"])
        #expect(decide(MaximizerBrain(), s) == .passThrough)
    }

    @Test func gamesAndPlayersAreExcludedByDefault() {
        #expect(decide(MaximizerBrain(), bundle: "org.videolan.vlc") == .passThrough)
        #expect(decide(MaximizerBrain(), bundle: "com.valvesoftware.steam") == .passThrough)
    }

    @Test func anyModifierMeansNative() {
        #expect(decide(MaximizerBrain(), mods: [.option]) == .passThrough)
        #expect(decide(MaximizerBrain(), mods: [.shift]) == .passThrough)
    }

    @Test func fullScreenWindowsAreLeftAlone() {
        #expect(decide(MaximizerBrain(), full: true) == .passThrough)
    }

    @Test func insetShrinksTheMaximisedFrame() {
        var s = MaximizerSettings()
        s.inset = 12
        #expect(decide(MaximizerBrain(), s) == .maximize(area.insetBy(dx: 12, dy: 12)))
    }

    @Test func insetIsSanitized() {
        var s = MaximizerSettings()
        s.inset = 999
        #expect(s.sanitized.inset == 64)
        s.inset = -9
        #expect(s.sanitized.inset == 0)
    }

    @Test func maximiseUsesTheDisplayTheWindowIsOn() {
        let two = WndFix.displays([WndFix.clean, WndFix.rightExt])
        let f = CGRect(x: 2500, y: 0, width: 600, height: 400)
        #expect(decide(MaximizerBrain(), frame: f, screens: two) == .maximize(two[1].visible))
    }

    @Test func tinyOriginalsAreNotRestored() {
        let b = MaximizerBrain()
        _ = decide(b, frame: CGRect(x: 0, y: 100, width: 40, height: 40))
        #expect(decide(b, frame: area) == .passThrough)
    }

    @Test func restoredFrameIsBroughtBackOnScreenAfterAnUnplug() {
        let two = WndFix.displays([WndFix.clean, WndFix.rightExt])
        let b = MaximizerBrain()
        _ = decide(b, frame: CGRect(x: 2500, y: 0, width: 600, height: 400), screens: two)
        guard case .restore(let r) = decide(b, frame: area, screens: displays) else { Issue.record("not restore"); return }
        #expect(area.contains(r))
    }

    @Test func memoryIsPerWindowAndClearedAfterRestore() {
        let b = MaximizerBrain()
        _ = decide(b, key: 1)
        _ = decide(b, key: 2, frame: CGRect(x: 10, y: 100, width: 300, height: 300))
        let d = decide(b, key: 1, frame: area)
        b.applied(d, key: 1, success: true)
        #expect(b.originals[1] == nil && b.originals[2] != nil)
    }

    @Test func failedMaximiseForgetsTheOriginal() {
        let b = MaximizerBrain()
        let d = decide(b)
        b.applied(d, key: 1, success: false)
        #expect(b.originals[1] == nil)
    }
}

final class WndZoomProbe: ZoomButtonProbing {
    var current: ZoomTarget?
    var pressed: [ZoomTarget] = []
    func target(at point: CGPoint) -> ZoomTarget? { current }
    func pressNative(_ target: ZoomTarget) { pressed.append(target) }
}

@Suite struct MaximizerClickEngineTests {
    private let button = CGRect(x: 330, y: 205, width: 12, height: 12)
    private let press = CGPoint(x: 336, y: 211)

    private func rig(_ edit: (inout MaximizerSettings) -> Void = { _ in }, full: Bool = false) -> (WndFakeDriver, WndZoomProbe, MaximizerClickEngine) {
        let d = WndFakeDriver()
        let w = d.add(1, small)
        let probe = WndZoomProbe()
        probe.current = ZoomTarget(window: w, frame: small, isFullScreen: full, button: button)
        var s = MaximizerSettings()
        edit(&s)
        return (d, probe, MaximizerClickEngine(probe: probe, driver: d) { s })
    }

    @Test func clickOnTheGreenButtonMaximisesInsteadOfFullScreen() {
        let (d, probe, e) = rig()
        #expect(e.mouseDown(at: press, flags: []) == .drop)
        #expect(e.mouseUp(at: press, flags: []) == .drop)
        #expect(d.frameOf(1) == area)
        #expect(probe.pressed.isEmpty && e.maximizedCount == 1)
    }

    @Test func secondClickRestores() {
        let (d, probe, e) = rig()
        _ = e.mouseDown(at: press, flags: []); _ = e.mouseUp(at: press, flags: [])
        probe.current!.frame = area
        _ = e.mouseDown(at: press, flags: []); _ = e.mouseUp(at: press, flags: [])
        #expect(d.frameOf(1) == small && e.restoredCount == 1)
    }

    @Test func clicksElsewherePassThrough() {
        let (_, probe, e) = rig()
        probe.current = nil
        #expect(e.mouseDown(at: press, flags: []) == .pass)
        #expect(e.mouseUp(at: press, flags: []) == .pass)
    }

    @Test func optionClickKeepsTheNativeBehaviour() {
        let (_, _, e) = rig()
        #expect(e.mouseDown(at: press, flags: .maskAlternate) == .pass)
    }

    @Test func excludedAppIsPassedThrough() {
        let (_, _, e) = rig({ $0.excluded = AppExceptionList(["com.test.app"]) })
        #expect(e.mouseDown(at: press, flags: []) == .pass)
    }

    @Test func fullScreenWindowIsPassedThrough() {
        let (_, _, e) = rig(full: true)
        #expect(e.mouseDown(at: press, flags: []) == .pass)
    }

    @Test func releasingAwayFromTheButtonFallsBackToTheNativeAction() {
        let (d, probe, e) = rig()
        _ = e.mouseDown(at: press, flags: [])
        #expect(e.mouseUp(at: CGPoint(x: 600, y: 400), flags: []) == .drop)
        #expect(probe.pressed.count == 1 && d.setCalls.isEmpty)
    }

    @Test func buttonSwappedForAnotherWindowFallsBack() {
        let (d, probe, e) = rig()
        _ = e.mouseDown(at: press, flags: [])
        probe.current = ZoomTarget(window: WndWindow(key: 99, pid: 1), frame: small, isFullScreen: false, button: button)
        _ = e.mouseUp(at: press, flags: [])
        #expect(probe.pressed.count == 1 && d.setCalls.isEmpty)
    }

    @Test func failedFrameChangeFallsBackToNative() {
        let (d, probe, e) = rig()
        d.failSet = true
        _ = e.mouseDown(at: press, flags: [])
        _ = e.mouseUp(at: press, flags: [])
        #expect(probe.pressed.count == 1 && e.maximizedCount == 0)
    }

    @Test func passThroughDecisionPressesTheNativeButton() {
        let (d, probe, e) = rig()
        d.wins[1]!.frame = area
        probe.current!.frame = area
        _ = e.mouseDown(at: press, flags: [])
        _ = e.mouseUp(at: press, flags: [])
        #expect(probe.pressed.count == 1)
    }

    @Test func mouseUpWithoutAPendingPressIsIgnored() {
        let (_, _, e) = rig()
        #expect(e.mouseUp(at: press, flags: []) == .pass)
    }

    @Test func resetForgetsAPendingPress() {
        let (_, _, e) = rig()
        _ = e.mouseDown(at: press, flags: [])
        e.reset()
        #expect(e.mouseUp(at: press, flags: []) == .pass)
    }

    @Test func stageSwallowsOnlyTheButtonClick() {
        let (hub, be) = actHub()
        let (d, _, e) = rig()
        let stage = MaximizerStage(hub: hub, engine: e)
        stage.start()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: press, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: press, mouseButton: .left)!
        #expect(be.fire(.leftMouseDown, down) == .drop)
        #expect(be.fire(.leftMouseUp, up) == .drop)
        #expect(d.frameOf(1) == area)
        stage.stop()
        #expect(hub.subscriberCount == 0)
    }

    @Test func stageDoesNothingWithoutAccessibility() {
        let (hub, be) = actHub()
        let (_, _, e) = rig()
        let stage = MaximizerStage(hub: hub, engine: e, trusted: { false })
        stage.start()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: press, mouseButton: .left)!
        #expect(be.fire(.leftMouseDown, down) == .pass)
        stage.stop()
    }
}
