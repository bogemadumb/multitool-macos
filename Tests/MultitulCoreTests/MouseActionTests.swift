import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let cmdLeft = KeyCombo(keyCode: Keys.leftBracket, modifiers: KeyCombo.cmd)
private let cmdRight = KeyCombo(keyCode: Keys.rightBracket, modifiers: KeyCombo.cmd)

@Suite struct MouseNavigationResolverTests {
    @Test func safariAndFinderGetBrackets() {
        let s = MouseNavigationSettings()
        #expect(MouseNavDefaults.mapping(for: "com.apple.Safari", settings: s) == MouseNavDefaults.standard)
        #expect(MouseNavDefaults.mapping(for: "com.apple.finder", settings: s) == MouseNavDefaults.standard)
        #expect(MouseNavDefaults.mapping(for: "com.google.Chrome.canary", settings: s) == MouseNavDefaults.standard)
    }

    @Test func unknownAppPassesThroughUnlessAllApps() {
        var s = MouseNavigationSettings()
        #expect(MouseNavDefaults.mapping(for: "com.example.game", settings: s) == nil)
        s.scope = .allApps
        #expect(MouseNavDefaults.mapping(for: "com.example.game", settings: s) == MouseNavDefaults.standard)
    }

    @Test func xcodeAndVsCodeUseTheirOwnKeys() {
        let s = MouseNavigationSettings()
        #expect(MouseNavDefaults.mapping(for: "com.apple.dt.Xcode", settings: s)?.back == KeyCombo(keyCode: Keys.left, modifiers: KeyCombo.ctrl | KeyCombo.cmd))
        #expect(MouseNavDefaults.mapping(for: "com.microsoft.VSCode", settings: s)?.forward == KeyCombo(keyCode: Keys.minus, modifiers: KeyCombo.ctrl | KeyCombo.shift))
    }

    @Test func userRuleBeatsBuiltInAndExceptionsBeatAll() {
        var s = MouseNavigationSettings()
        s.rules = [MouseNavRule(pattern: "com.apple.Safari", back: KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd), forward: nil)]
        #expect(MouseNavDefaults.mapping(for: "com.apple.Safari", settings: s) == MouseNavMapping(back: KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd), forward: nil))
        s.exceptions = AppExceptionList(["com.apple.Safari"])
        #expect(MouseNavDefaults.mapping(for: "com.apple.Safari", settings: s) == nil)
    }

    @Test func wildcardRulesMatchVendorFamilies() {
        let s = MouseNavigationSettings()
        #expect(MouseNavDefaults.mapping(for: "com.jetbrains.intellij", settings: s) != nil)
        #expect(MouseNavDefaults.mapping(for: "org.mozilla.firefox", settings: s) != nil)
    }
}

@Suite struct MouseNavigationStageTests {
    private func rig(_ bundle: String? = "com.apple.Safari", settings: MouseNavigationSettings = MouseNavigationSettings()) -> (InpTapBackend, ActKeys, ActFront, MouseNavigationStage) {
        let (hub, be) = actHub()
        let keys = ActKeys()
        let front = ActFront(bundle)
        let stage = actKeep(MouseNavigationStage(hub: hub, keys: keys, frontmost: front, settings: settings))
        stage.start()
        return (be, keys, front, stage)
    }

    @Test func backButtonPostsCommandBracketAndSwallowsPair() {
        let (be, keys, _, _) = rig()
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3)) == .drop)
        #expect(keys.posts.count == 1 && keys.posts[0].code == Keys.leftBracket && keys.posts[0].flags == .maskCommand)
        #expect(be.fire(.otherMouseUp, ActEvents.other(.otherMouseUp, button: 3)) == .drop)
        #expect(keys.posts.count == 1)
    }

    @Test func forwardButtonPostsRightBracket() {
        let (be, keys, _, _) = rig()
        be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 4))
        #expect(keys.codes() == [Keys.rightBracket])
    }

    @Test func swapExchangesButtons() {
        var s = MouseNavigationSettings()
        s.swapButtons = true
        let (be, keys, _, _) = rig(settings: s)
        be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3))
        #expect(keys.codes() == [Keys.rightBracket])
    }

    @Test func middleAndUnknownAppPass() {
        let (be, keys, front, _) = rig()
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 2)) == .pass)
        front.set("com.example.unknown")
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3)) == .pass)
        #expect(be.fire(.otherMouseUp, ActEvents.other(.otherMouseUp, button: 3)) == .pass)
        #expect(keys.posts.isEmpty)
    }

    @Test func nilComboMeansButtonStaysNormalInThatApp() {
        var s = MouseNavigationSettings()
        s.rules = [MouseNavRule(pattern: "com.apple.Safari", back: nil, forward: cmdRight)]
        let (be, keys, _, _) = rig(settings: s)
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3)) == .pass)
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 4)) == .drop)
        #expect(keys.codes() == [Keys.rightBracket])
    }

    @Test func upIsSwallowedEvenIfAppChangedMeanwhile() {
        let (be, _, front, _) = rig()
        be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3))
        front.set("com.example.unknown")
        #expect(be.fire(.otherMouseUp, ActEvents.other(.otherMouseUp, button: 3)) == .drop)
    }

    @Test func stopUnsubscribesAndForgets() {
        let (be, _, _, stage) = rig()
        be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3))
        stage.stop()
        #expect(!stage.isRunning)
        #expect(!be.starts.isEmpty && be.stops >= 1)
    }

    @Test func syntheticPostsAreNeverReprocessed() {
        let (be, keys, _, _) = rig()
        let e = ActEvents.other(.otherMouseDown, button: 3)
        EventTapHub.markSynthetic(e)
        #expect(be.fire(.otherMouseDown, e) == .pass)
        #expect(keys.posts.isEmpty)
    }
}

@Suite struct ButtonShortcutEngineTests {
    private func rig(_ bindings: [ButtonBinding], bundle: String? = "com.example.app") -> (ButtonShortcutEngine, ActKeys, ActMouse) {
        var s = ButtonShortcutsSettings()
        s.bindings = bindings
        let keys = ActKeys()
        let mouse = ActMouse()
        let e = ButtonShortcutEngine(settings: s, keys: keys, mouse: mouse, frontmostBundle: { bundle })
        return (e, keys, mouse)
    }

    private let closeTab = ButtonAction.shortcut(KeyCombo(keyCode: Keys.w, modifiers: KeyCombo.cmd))

    @Test func plainButtonFiresOnDownAndSwallowsUp() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .button(3), click: closeTab)])
        #expect(e.buttonDown(3, at: .zero, flags: []) == .drop)
        #expect(keys.posts.count == 1 && keys.posts[0].code == Keys.w && keys.posts[0].flags == .maskCommand)
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.posts.count == 1)
        #expect(e.buttonUp(3, at: .zero) == .pass)
    }

    @Test func unboundButtonsAndNoneActionPass() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .button(4), click: .none)])
        #expect(e.buttonDown(3, at: .zero, flags: []) == .pass)
        #expect(e.buttonDown(4, at: .zero, flags: []) == .pass)
        #expect(e.buttonDown(0, at: .zero, flags: []) == .pass)
        #expect(keys.posts.isEmpty)
    }

    @Test func gestureLeftRightUpDown() {
        let cases: [(Double, Double, UInt32)] = [(-70, 3, Keys.left), (80, -2, Keys.right), (4, -90, Keys.up), (-3, 100, Keys.down)]
        for (dx, dy, code) in cases {
            let (e, keys, _) = rig([ButtonBinding(trigger: .button(3), click: closeTab, gesture: true)])
            #expect(e.buttonDown(3, at: .zero, flags: []) == .drop)
            #expect(keys.posts.isEmpty)
            #expect(e.buttonDragged(3, dx: dx, dy: dy) == .drop)
            #expect(keys.codes() == [code])
            #expect(keys.posts[0].flags == .maskControl)
            #expect(e.buttonUp(3, at: .zero) == .drop)
            #expect(keys.codes() == [code])
        }
    }

    @Test func gestureAccumulatesSmallMovesAndFiresOnce() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .button(3), click: .none, gesture: true)])
        e.buttonDown(3, at: .zero, flags: [])
        for _ in 0..<5 { _ = e.buttonDragged(3, dx: -15, dy: 0) }
        #expect(keys.codes() == [Keys.left])
        for _ in 0..<10 { _ = e.buttonDragged(3, dx: -15, dy: 0) }
        #expect(keys.codes() == [Keys.left])
    }

    @Test func shortClickOnGestureButtonRunsClick() {
        let (e, keys, mouse) = rig([ButtonBinding(trigger: .button(3), click: closeTab, gesture: true)])
        e.buttonDown(3, at: .zero, flags: [])
        _ = e.buttonDragged(3, dx: 3, dy: 2)
        #expect(e.buttonUp(3, at: .zero) == .drop)
        #expect(keys.codes() == [Keys.w])
        #expect(mouse.posts.isEmpty)
    }

    @Test func shortClickWithoutClickActionReplaysOriginal() {
        let (e, keys, mouse) = rig([ButtonBinding(trigger: .button(3), click: .none, gesture: true)])
        e.buttonDown(3, at: CGPoint(x: 1, y: 2), flags: .maskShift)
        #expect(e.buttonUp(3, at: CGPoint(x: 1, y: 2)) == .drop)
        #expect(keys.posts.isEmpty)
        #expect(mouse.posts.map(\.down) == [true, false] && mouse.posts.allSatisfy { $0.button == 3 })
        #expect(mouse.posts[0].flags == .maskShift)
    }

    @Test func gestuedButtonDoesNotClickAfterGesture() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .button(3), click: closeTab, gesture: true)])
        e.buttonDown(3, at: .zero, flags: [])
        _ = e.buttonDragged(3, dx: 100, dy: 0)
        e.buttonUp(3, at: .zero)
        #expect(keys.codes() == [Keys.right])
    }

    @Test func middleClickActionPostsPair() {
        let (e, _, mouse) = rig([ButtonBinding(trigger: .button(4), click: .middleClick)])
        e.buttonDown(4, at: CGPoint(x: 7, y: 8), flags: [])
        #expect(mouse.posts.map(\.down) == [true, false] && mouse.posts.allSatisfy { $0.button == 2 && $0.point == CGPoint(x: 7, y: 8) })
    }

    @Test func horizontalWheelFiresWithCooldown() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .scrollLeft, click: .spaceLeft), ButtonBinding(trigger: .scrollRight, click: .spaceRight)])
        #expect(e.horizontalScroll(delta: 1, at: 100, location: .zero, flags: []) == .drop)
        #expect(e.horizontalScroll(delta: 1, at: 100.1, location: .zero, flags: []) == .drop)
        #expect(keys.codes() == [Keys.left])
        #expect(e.horizontalScroll(delta: -1, at: 100.1, location: .zero, flags: []) == .drop)
        #expect(e.horizontalScroll(delta: 1, at: 100.5, location: .zero, flags: []) == .drop)
        #expect(keys.codes() == [Keys.left, Keys.right, Keys.left])
    }

    @Test func unboundWheelDirectionPasses() {
        let (e, keys, _) = rig([ButtonBinding(trigger: .scrollLeft, click: .spaceLeft)])
        #expect(e.horizontalScroll(delta: -1, at: 1, location: .zero, flags: []) == .pass)
        #expect(keys.posts.isEmpty)
    }

    @Test func exceptionsSkipEverything() {
        var s = ButtonShortcutsSettings()
        s.bindings = [ButtonBinding(trigger: .button(3), click: .spaceLeft)]
        s.exceptions = AppExceptionList(["com.game"])
        let e = ButtonShortcutEngine(settings: s, keys: ActKeys(), mouse: ActMouse(), frontmostBundle: { "com.game" })
        #expect(e.buttonDown(3, at: .zero, flags: []) == .pass)
    }

    @Test func learnModeReportsNextButtonOnceAndSwallowsPair() {
        let (e, keys, _) = rig([])
        var got: [ButtonTrigger] = []
        e.onLearn = { got.append($0) }
        #expect(e.buttonDown(5, at: .zero, flags: []) == .drop)
        #expect(e.buttonUp(5, at: .zero) == .drop)
        #expect(got == [.button(5)])
        #expect(e.buttonDown(5, at: .zero, flags: []) == .pass)
        #expect(keys.posts.isEmpty)
    }

    @Test func learnModeCatchesWheelTilt() {
        let (e, _, _) = rig([])
        var got: [ButtonTrigger] = []
        e.onLearn = { got.append($0) }
        #expect(e.horizontalScroll(delta: -3, at: 1, location: .zero, flags: []) == .drop)
        #expect(got == [.scrollRight])
    }
}

@Suite struct ButtonShortcutStageTests {
    private func rig(_ bindings: [ButtonBinding]) -> (InpTapBackend, ActKeys, ActMouse) {
        var s = ButtonShortcutsSettings()
        s.bindings = bindings
        let (hub, be) = actHub()
        let keys = ActKeys()
        let mouse = ActMouse()
        let engine = ButtonShortcutEngine(settings: s, keys: keys, mouse: mouse, frontmostBundle: { nil })
        actKeep(ButtonShortcutsStage(hub: hub, engine: engine, clock: { 100 })).start()
        return (be, keys, mouse)
    }

    @Test func dragEventsFlowThroughTheHub() {
        let (be, keys, _) = rig([ButtonBinding(trigger: .button(3), click: .none, gesture: true)])
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3)) == .drop)
        #expect(be.fire(.otherMouseDragged, ActEvents.other(.otherMouseDragged, button: 3, dx: 0, dy: -80)) == .drop)
        #expect(be.fire(.otherMouseUp, ActEvents.other(.otherMouseUp, button: 3)) == .drop)
        #expect(keys.codes() == [Keys.up])
    }

    @Test func mouseWheelTiltFiresButTrackpadAndVerticalDoNot() {
        let (be, keys, _) = rig([ButtonBinding(trigger: .scrollLeft, click: .spaceLeft)])
        #expect(be.fire(.scrollWheel, ActEvents.tilt(2)) == .drop)
        #expect(keys.codes() == [Keys.left])
        #expect(be.fire(.scrollWheel, ActEvents.tilt(2, continuous: true)) == .pass)
        #expect(be.fire(.scrollWheel, ActEvents.vertical(3)) == .pass)
        #expect(keys.codes() == [Keys.left])
    }

    @Test func buttonShortcutsOutrankNavigationOnTheSameButton() {
        let (hub, be) = actHub()
        let keys = ActKeys()
        let mouse = ActMouse()
        var s = ButtonShortcutsSettings()
        s.bindings = [ButtonBinding(trigger: .button(3), click: .shortcut(KeyCombo(keyCode: Keys.w, modifiers: KeyCombo.cmd)))]
        actKeep(ButtonShortcutsStage(hub: hub, engine: ButtonShortcutEngine(settings: s, keys: keys, mouse: mouse, frontmostBundle: { nil }))).start()
        actKeep(MouseNavigationStage(hub: hub, keys: keys, frontmost: ActFront("com.apple.Safari"))).start()
        #expect(be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 3)) == .drop)
        #expect(keys.codes() == [Keys.w])
        be.fire(.otherMouseDown, ActEvents.other(.otherMouseDown, button: 4))
        #expect(keys.codes() == [Keys.w, Keys.rightBracket])
    }
}
