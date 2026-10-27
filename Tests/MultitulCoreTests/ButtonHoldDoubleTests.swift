import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

final class ActSymbolic: SymbolicHotKeyPosting {
    var ids: [Int32] = []
    var result = true
    func post(_ id: Int32) -> Bool {
        ids.append(id)
        return result
    }
}

final class ActMagnify: MagnifyPosting {
    var values: [Double] = []
    func post(magnification: Double) { values.append(magnification) }
}

@Suite struct ButtonHoldDoubleTests {
    private let closeTab = ButtonAction.shortcut(KeyCombo(keyCode: Keys.w, modifiers: KeyCombo.cmd))
    private let reopen = ButtonAction.shortcut(KeyCombo(keyCode: Keys.s, modifiers: KeyCombo.cmd))

    private func rig(_ b: ButtonBinding, symbolic: ActSymbolic? = nil) -> (ButtonShortcutEngine, ActKeys, ActMouse, ActTimers) {
        var s = ButtonShortcutsSettings()
        s.bindings = [b]
        let keys = ActKeys()
        let mouse = ActMouse()
        let timers = ActTimers()
        let e = ButtonShortcutEngine(settings: s, keys: keys, mouse: mouse, timers: timers, symbolic: symbolic, frontmostBundle: { nil })
        return (e, keys, mouse, timers)
    }

    @Test func holdFiresAfterDelayAndSuppressesClick() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, hold: .spaceLeft))
        #expect(e.buttonDown(3, at: .zero, flags: []) == .drop)
        #expect(timers.items.count == 1 && timers.items[0].delay == 0.3)
        #expect(keys.posts.isEmpty)
        timers.fireAll()
        #expect(keys.codes() == [Keys.left])
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.codes() == [Keys.left])
    }

    @Test func releaseBeforeHoldFiresClickOnUpAndCancelsTimer() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, hold: .spaceLeft))
        e.buttonDown(3, at: .zero, flags: [])
        #expect(keys.posts.isEmpty)
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.codes() == [Keys.w])
        #expect(timers.items[0].handle.cancelled)
        timers.fireAll()
        #expect(keys.codes() == [Keys.w])
    }

    @Test func holdOnlyBindingReplaysPlainClickOnShortPress() {
        let (e, keys, mouse, _) = rig(ButtonBinding(trigger: .button(3), click: .none, hold: .spaceRight))
        #expect(e.buttonDown(3, at: CGPoint(x: 1, y: 2), flags: []) == .drop)
        #expect(e.buttonUp(3, at: CGPoint(x: 1, y: 2)) == .drop)
        #expect(keys.posts.isEmpty)
        #expect(mouse.posts.map(\.down) == [true, false] && mouse.posts.allSatisfy { $0.button == 3 })
    }

    @Test func holdUsesConfiguredDelay() {
        var s = ButtonShortcutsSettings()
        s.holdMs = 600
        s.bindings = [ButtonBinding(trigger: .button(3), click: .none, hold: .middleClick)]
        let timers = ActTimers()
        let mouse = ActMouse()
        let e = ButtonShortcutEngine(settings: s, keys: ActKeys(), mouse: mouse, timers: timers, frontmostBundle: { nil })
        e.buttonDown(3, at: .zero, flags: [])
        #expect(timers.items[0].delay == 0.6)
        timers.fireAll()
        #expect(mouse.posts.count == 2 && mouse.posts.allSatisfy { $0.button == 2 })
    }

    @Test func gestureBeatsHold() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, gesture: true, hold: reopen))
        e.buttonDown(3, at: .zero, flags: [])
        _ = e.buttonDragged(3, dx: 80, dy: 0)
        #expect(keys.codes() == [Keys.right])
        #expect(timers.items[0].handle.cancelled)
        timers.fireAll()
        e.buttonUp(3, at: .zero)
        #expect(keys.codes() == [Keys.right])
    }

    @Test func holdFiredFirstIgnoresLaterDrag() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, gesture: true, hold: reopen))
        e.buttonDown(3, at: .zero, flags: [])
        timers.fireAll()
        #expect(keys.codes() == [Keys.s])
        _ = e.buttonDragged(3, dx: 200, dy: 0)
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.codes() == [Keys.s])
    }

    @Test func singleClickIsDelayedWhenDoubleIsBound() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, doubleClick: reopen))
        #expect(e.buttonDown(3, at: .zero, flags: []) == .drop)
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.posts.isEmpty)
        #expect(timers.items.count == 1 && timers.items[0].delay == 0.25)
        timers.fireAll()
        #expect(keys.codes() == [Keys.w])
    }

    @Test func doubleClickFiresOnSecondPressAndCancelsSingle() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, doubleClick: reopen))
        e.buttonDown(3, at: .zero, flags: [])
        e.buttonUp(3, at: .zero)
        #expect(e.buttonDown(3, at: .zero, flags: []) == .drop)
        #expect(keys.codes() == [Keys.s])
        #expect(e.buttonUp(3, at: .zero) == .drop)
        timers.fireAll()
        #expect(keys.codes() == [Keys.s])
        e.buttonDown(3, at: .zero, flags: [])
        e.buttonUp(3, at: .zero)
        timers.fireAll()
        #expect(keys.codes() == [Keys.s, Keys.w])
    }

    @Test func doubleWindowUsesConfiguredDelay() {
        var s = ButtonShortcutsSettings()
        s.doubleMs = 400
        s.bindings = [ButtonBinding(trigger: .button(3), click: closeTab, doubleClick: reopen)]
        let timers = ActTimers()
        let e = ButtonShortcutEngine(settings: s, keys: ActKeys(), mouse: ActMouse(), timers: timers, frontmostBundle: { nil })
        e.buttonDown(3, at: .zero, flags: [])
        e.buttonUp(3, at: .zero)
        #expect(timers.items[0].delay == 0.4)
    }

    @Test func doubleWithoutClickReplaysPlainClickAfterWindow() {
        let (e, _, mouse, timers) = rig(ButtonBinding(trigger: .button(4), click: .none, doubleClick: .showDesktop))
        e.buttonDown(4, at: CGPoint(x: 3, y: 4), flags: [])
        e.buttonUp(4, at: CGPoint(x: 3, y: 4))
        #expect(mouse.posts.isEmpty)
        timers.fireAll()
        #expect(mouse.posts.map(\.down) == [true, false] && mouse.posts.allSatisfy { $0.button == 4 })
    }

    @Test func plainBindingStillFiresOnDownWithoutTimers() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab))
        e.buttonDown(3, at: .zero, flags: [])
        #expect(keys.codes() == [Keys.w])
        #expect(timers.items.isEmpty)
        e.buttonUp(3, at: .zero)
        #expect(keys.codes() == [Keys.w])
    }

    @Test func emptyBindingStillPasses() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: .none))
        #expect(e.buttonDown(3, at: .zero, flags: []) == .pass)
        #expect(e.buttonUp(3, at: .zero) == .pass)
        #expect(keys.posts.isEmpty && timers.items.isEmpty)
    }

    @Test func resetCancelsPendingTimers() {
        let (e, keys, _, timers) = rig(ButtonBinding(trigger: .button(3), click: closeTab, hold: reopen, doubleClick: reopen))
        e.buttonDown(3, at: .zero, flags: [])
        e.buttonUp(3, at: .zero)
        e.reset()
        timers.fireAll()
        #expect(keys.posts.isEmpty)
    }

    @Test func showDesktopAndLaunchpadUseSymbolicHotKeys() {
        let sym = ActSymbolic()
        let (e, keys, _, _) = rig(ButtonBinding(trigger: .button(3), click: .showDesktop), symbolic: sym)
        e.buttonDown(3, at: .zero, flags: [])
        #expect(sym.ids == [36] && keys.posts.isEmpty)
        let sym2 = ActSymbolic()
        let (e2, keys2, _, _) = rig(ButtonBinding(trigger: .button(4), click: .launchpad), symbolic: sym2)
        e2.buttonDown(4, at: .zero, flags: [])
        #expect(sym2.ids == [160] && keys2.posts.isEmpty)
    }

    @Test func symbolicFailureFallsBackToKeyCombo() {
        let sym = ActSymbolic()
        sym.result = false
        let (e, keys, _, _) = rig(ButtonBinding(trigger: .button(3), click: .showDesktop), symbolic: sym)
        e.buttonDown(3, at: .zero, flags: [])
        #expect(keys.codes() == [Keys.f11])
        let (e2, keys2, _, _) = rig(ButtonBinding(trigger: .button(3), click: .showDesktop))
        e2.buttonDown(3, at: .zero, flags: [])
        #expect(keys2.codes() == [Keys.f11])
    }
}

@Suite struct ButtonHoldDoubleStorageTests {
    @Test func newActionsRoundTrip() {
        for a in [ButtonAction.showDesktop, .launchpad] { #expect(ButtonAction(storage: a.storage) == a) }
        #expect(ButtonAction.showDesktop.symbolicHotKeyID == 36 && ButtonAction.launchpad.symbolicHotKeyID == 160)
        #expect(ButtonAction.showDesktop.title == "Показать рабочий стол" && ButtonAction.launchpad.title == "Launchpad")
    }

    @Test func bindingWithHoldAndDoubleRoundTrips() {
        let b = ButtonBinding(trigger: .button(3), click: .spaceLeft, gesture: true, hold: .showDesktop, doubleClick: .shortcut(KeyCombo(keyCode: 13, modifiers: KeyCombo.cmd)))
        #expect(ButtonBinding(storage: b.storage) == b)
        let plain = ButtonBinding(trigger: .button(3), click: .launchpad)
        #expect(plain.storage == "b3|launchpad|0")
    }

    @Test func legacyThreePartBindingLoadsWithNoneDefaults() {
        let b = ButtonBinding(storage: "b3|mission|1")
        #expect(b == ButtonBinding(trigger: .button(3), click: .missionControl, gesture: true))
        #expect(b?.hold == ButtonAction.none && b?.doubleClick == ButtonAction.none)
        #expect(ButtonBinding(storage: "b3|mission|0|bogus|none") == nil)
        #expect(ButtonBinding(storage: "sl|left|0|desktop|desktop") == ButtonBinding(trigger: .scrollLeft, click: .spaceLeft))
    }

    @Test func settingsRoundTripAndLegacyStore() {
        let store = InputSettingsStore(defaults: actDefaults())
        var s = ButtonShortcutsSettings()
        s.bindings = [ButtonBinding(trigger: .button(4), click: .none, hold: .launchpad, doubleClick: .showDesktop)]
        s.holdMs = 450
        s.doubleMs = 200
        store.saveButtons(s)
        #expect(store.loadButtons() == s.sanitized)

        let legacy = actDefaults()
        legacy.set(["b3|mission|1"], forKey: "input.buttons.bindings")
        let l = InputSettingsStore(defaults: legacy).loadButtons()
        #expect(l.holdMs == 300 && l.doubleMs == 250)
        #expect(l.bindings == [ButtonBinding(trigger: .button(3), click: .missionControl, gesture: true)])
    }

    @Test func timingsAreClamped() {
        var s = ButtonShortcutsSettings()
        s.holdMs = 1
        s.doubleMs = 99999
        #expect(s.sanitized.holdMs == ButtonShortcutsSettings.holdRange.lowerBound)
        #expect(s.sanitized.doubleMs == ButtonShortcutsSettings.doubleRange.upperBound)
        #expect(ButtonShortcutsSettings().holdMs == 300 && ButtonShortcutsSettings().doubleMs == 250)
    }
}

@Suite struct ScrollZoomTests {
    private func sample(_ line: Int64, flags: CGEventFlags = .maskCommand, continuous: Bool = false) -> ScrollSample {
        ScrollSample(vertical: ScrollAxisDelta(line: line, point: line * 10, fixed: Double(line)), isContinuous: continuous, flags: flags)
    }

    @Test func wheelWithCommandZoomsBySign() {
        #expect(ScrollZoom.decision(sample(2), isMouseWheel: true, cmdZoom: true) == .zoomIn)
        #expect(ScrollZoom.decision(sample(-1), isMouseWheel: true, cmdZoom: true) == .zoomOut)
    }

    @Test func trackpadOrNoCommandOrDisabledPasses() {
        #expect(ScrollZoom.decision(sample(2), isMouseWheel: false, cmdZoom: true) == .pass)
        #expect(ScrollZoom.decision(sample(2, flags: []), isMouseWheel: true, cmdZoom: true) == .pass)
        #expect(ScrollZoom.decision(sample(2, flags: [.maskCommand, .maskShift]), isMouseWheel: true, cmdZoom: true) == .pass)
        #expect(ScrollZoom.decision(sample(2), isMouseWheel: true, cmdZoom: false) == .pass)
        #expect(ScrollZoom.decision(ScrollSample(horizontal: ScrollAxisDelta(line: 1, point: 10, fixed: 1), flags: .maskCommand), isMouseWheel: true, cmdZoom: true) == .pass)
        #expect(ScrollZoom.decision(ScrollSample(flags: .maskCommand), isMouseWheel: true, cmdZoom: true) == .pass)
    }

    @Test func magnificationFollowsDecision() {
        #expect(ScrollZoom.magnification(.zoomIn) > 0)
        #expect(ScrollZoom.magnification(.zoomOut) == -ScrollZoom.magnification(.zoomIn))
        #expect(ScrollZoom.magnification(.pass) == 0)
    }

    private func rig(cmdZoom: Bool = true, excepted: Bool = false) -> (InpTapBackend, ActMagnify, ScrollZoomStage) {
        let (hub, be) = actHub()
        let poster = ActMagnify()
        let gate = ExceptionGate(list: AppExceptionList(excepted ? ["com.fig"] : []), resolver: InpResolver("com.fig"))
        let stage = actKeep(ScrollZoomStage(hub: hub, gate: gate, poster: poster, cmdZoom: cmdZoom, clock: { 100 }))
        stage.start()
        return (be, poster, stage)
    }

    @Test func stageDropsCommandWheelAndPostsMagnify() {
        let (be, poster, stage) = rig()
        #expect(be.fire(.scrollWheel, InpEvents.wheel(line: 3, flags: .maskCommand)) == .drop)
        #expect(be.fire(.scrollWheel, InpEvents.wheel(line: -3, flags: .maskCommand)) == .drop)
        #expect(poster.values.count == 2 && poster.values[0] > 0 && poster.values[1] < 0)
        #expect(stage.zoomCount == 2)
    }

    @Test func stagePassesPlainWheelTrackpadAndDisabled() {
        let (be, poster, stage) = rig()
        #expect(be.fire(.scrollWheel, InpEvents.wheel(line: 3)) == .pass)
        #expect(be.fire(.scrollWheel, InpEvents.pixelWheel(v: 30, phase: 2, count: 3)) == .pass)
        stage.cmdZoom = false
        #expect(be.fire(.scrollWheel, InpEvents.wheel(line: 3, flags: .maskCommand)) == .pass)
        #expect(poster.values.isEmpty)
    }

    @Test func stageHonoursExceptions() {
        let (be, poster, _) = rig(excepted: true)
        #expect(be.fire(.scrollWheel, InpEvents.wheel(line: 3, flags: .maskCommand)) == .pass)
        #expect(poster.values.isEmpty)
    }

    @Test func zoomSettingsRoundTripAndDefaultOn() {
        let store = InputSettingsStore(defaults: actDefaults())
        #expect(store.loadZoom().cmdZoom)
        var s = ScrollZoomSettings()
        s.cmdZoom = false
        s.exceptions = AppExceptionList(["com.a.b"])
        store.saveZoom(s)
        #expect(store.loadZoom() == s)
    }
}
