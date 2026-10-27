import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let cmd = KeyCombo.cmd
private let shift = KeyCombo.shift
private let tab = Keys.tab
private let tick = Keys.backtick

private struct Rig {
    let m: SwitcherKeyMachine
    let c: SwcController
    let t: WndTimers
    let box: WndBox<SwitcherSettings>
}

private func rig(_ edit: (inout SwitcherSettings) -> Void = { _ in }, trusted: Bool = true) -> Rig {
    var s = SwitcherSettings()
    s.appearanceDelayMs = 100
    edit(&s)
    let box = WndBox(s)
    let c = SwcController()
    let t = WndTimers()
    return Rig(m: SwitcherKeyMachine(controller: c, timers: t, settings: { box.value }, trusted: { trusted }), c: c, t: t, box: box)
}

private extension Rig {
    @discardableResult func down(_ code: UInt32, _ mods: UInt32 = cmd, rep: Bool = false, text: String? = nil) -> EventTapAction { m.keyDown(code: code, mods: mods, isRepeat: rep, text: { text }) }
}

@Suite struct SwitcherKeyMachineTests {
    @Test func commandTabStartsAndIsSwallowed() {
        let r = rig()
        #expect(r.down(tab) == .drop)
        #expect(r.c.log == ["begin:apps:fwd"] && r.m.active)
        #expect(r.m.keyUp(code: tab) == .drop)
        #expect(r.m.keyUp(code: tab) == .pass)
    }

    @Test func commandBacktickStartsTheSameAppScope() {
        let r = rig()
        #expect(r.down(tick) == .drop)
        #expect(r.c.log == ["begin:windows:fwd"])
    }

    @Test func shiftTabStartsBackwards() {
        let r = rig()
        #expect(r.down(tab, cmd | shift) == .drop)
        #expect(r.c.log == ["begin:apps:back"])
    }

    @Test func unrelatedKeysPassWhileIdle() {
        let r = rig()
        #expect(r.down(Keys.q) == .pass && r.down(tab, 0) == .pass && r.down(tab, KeyCombo.opt) == .pass)
        #expect(r.c.log.isEmpty && !r.m.active)
    }

    @Test func untrustedAccessKeepsEverythingPassing() {
        let r = rig(trusted: false)
        #expect(r.down(tab) == .pass && r.c.log.isEmpty)
    }

    @Test func tabWhileHeldAdvancesAndShiftTabGoesBack() {
        let r = rig()
        r.down(tab)
        #expect(r.down(tab) == .drop)
        #expect(r.down(tab, cmd | shift) == .drop)
        #expect(r.c.log == ["begin:apps:fwd", "move:1", "move:-1"])
    }

    @Test func holdingTabRepeatsAdvance() {
        let r = rig()
        r.down(tab)
        for _ in 0..<3 { r.down(tab, rep: true) }
        #expect(r.c.log.filter { $0 == "move:1" }.count == 3)
    }

    @Test func releasingTheModifierCommits() {
        let r = rig()
        r.down(tab)
        #expect(r.m.flagsChanged(mods: 0) == .pass)
        #expect(r.c.log == ["begin:apps:fwd", "commit"] && !r.m.active)
    }

    @Test func releasingAnUnrelatedModifierKeepsTheSwitcherOpen() {
        let r = rig()
        r.down(tab, cmd | shift)
        r.m.flagsChanged(mods: cmd)
        #expect(r.m.active && !r.c.log.contains("commit"))
    }

    @Test func panelShowsAfterTheDelayOnly() {
        let r = rig()
        r.down(tab)
        #expect(!r.c.log.contains("present") && r.t.active == 1)
        r.t.fireAll()
        #expect(r.c.log.last == "present" && r.m.presented)
    }

    @Test func aQuickTapNeverShowsThePanel() {
        let r = rig()
        r.down(tab)
        r.m.flagsChanged(mods: 0)
        #expect(r.t.active == 0)
        r.t.fireAll()
        #expect(!r.c.log.contains("present"))
    }

    @Test func zeroDelayPresentsImmediately() {
        let r = rig { $0.appearanceDelayMs = 0 }
        r.down(tab)
        #expect(r.c.log == ["begin:apps:fwd", "present"] && r.t.items.isEmpty)
    }

    @Test func failedBeginSwallowsTheKeyButStaysIdle() {
        let r = rig()
        r.c.beginResult = false
        #expect(r.down(tab) == .drop && !r.m.active && r.t.items.isEmpty)
    }

    @Test func escapeCancelsAndReturnCommits() {
        let r = rig()
        r.down(tab)
        r.down(Keys.escape)
        #expect(r.c.log.last == "cancel" && !r.m.active)
        r.down(tab)
        r.down(Keys.returnKey)
        #expect(r.c.log.last == "commit")
    }

    @Test func arrowsNavigate() {
        let r = rig()
        r.down(tab)
        r.down(Keys.left); r.down(Keys.right); r.down(Keys.up); r.down(Keys.down)
        #expect(Array(r.c.log.dropFirst()) == ["move:-1", "move:1", "vert:-1", "vert:1"])
    }

    @Test func actionKeysCloseQuitMinimizeHide() {
        let r = rig()
        r.down(tab)
        r.down(Keys.w); r.down(Keys.q); r.down(Keys.m); r.down(Keys.h)
        #expect(Array(r.c.log.dropFirst()) == ["close", "quit", "minimize", "hide"])
    }

    @Test func actionKeysIgnoreAutoRepeat() {
        let r = rig()
        r.down(tab)
        r.down(Keys.w, rep: true); r.down(Keys.q, rep: true)
        #expect(r.c.log == ["begin:apps:fwd"])
    }

    @Test func actionKeysNeedOnlyTheHeldModifiers() {
        let r = rig()
        r.down(tab)
        r.down(Keys.w, cmd | KeyCombo.ctrl)
        #expect(r.c.log == ["begin:apps:fwd"])
    }

    @Test func everyOtherKeyIsSwallowedWhileOpen() {
        let r = rig()
        r.down(tab)
        #expect(r.down(0) == .drop && r.down(Keys.space) == .drop)
        #expect(r.m.keyUp(code: 0) == .drop)
    }

    @Test func searchStartsWithSAndTypesLetters() {
        let r = rig()
        r.down(tab)
        r.down(Keys.s)
        #expect(r.c.log.last == "search" && r.m.searching && r.m.pinned)
        r.down(Keys.w, text: "w")
        r.down(Keys.q, text: "q")
        #expect(r.c.log.suffix(2) == ["q+w", "q+q"] && !r.c.log.contains("close") && !r.c.log.contains("quit"))
    }

    @Test func searchAcceptsCyrillicText() {
        let r = rig()
        r.down(tab); r.down(Keys.s)
        r.down(0, text: "ф")
        #expect(r.c.log.last == "q+ф")
    }

    @Test func searchIgnoresControlCharacters() {
        let r = rig()
        r.down(tab); r.down(Keys.s)
        r.down(0, text: "\u{F700}"); r.down(0, text: nil)
        #expect(!r.c.log.contains { $0.hasPrefix("q+") })
    }

    @Test func backspaceEditsTheQueryOnlyInSearch() {
        let r = rig()
        r.down(tab)
        r.down(Keys.backspace)
        #expect(!r.c.log.contains("q-"))
        r.down(Keys.s)
        r.down(Keys.backspace)
        #expect(r.c.log.last == "q-")
    }

    @Test func pinnedSearchSurvivesReleasingTheModifier() {
        let r = rig()
        r.down(tab); r.down(Keys.s)
        r.m.flagsChanged(mods: 0)
        #expect(r.m.active && !r.c.log.contains("commit"))
        #expect(r.down(Keys.returnKey, 0) == .drop)
        #expect(r.c.log.last == "commit" && !r.m.active)
    }

    @Test func unpinnedSearchCommitsOnRelease() {
        let r = rig { $0.searchPin = false }
        r.down(tab); r.down(Keys.s)
        #expect(r.m.searching && !r.m.pinned)
        r.m.flagsChanged(mods: 0)
        #expect(r.c.log.last == "commit")
    }

    @Test func escapeClearsTheQueryBeforeCancelling() {
        let r = rig()
        r.down(tab); r.down(Keys.s)
        r.c.clearResult = true
        r.down(Keys.escape, 0)
        #expect(r.m.active && r.c.log.last == "qclear")
        r.c.clearResult = false
        r.down(Keys.escape, 0)
        #expect(r.c.log.last == "cancel" && !r.m.active)
    }

    @Test func pinnedPanelTakesPlainTabAndShiftTab() {
        let r = rig()
        r.down(tab); r.down(Keys.s)
        r.m.flagsChanged(mods: 0)
        r.down(tab, 0); r.down(tab, shift)
        #expect(r.c.log.suffix(2) == ["move:1", "move:-1"])
    }

    @Test func clickOutsideThePresentedPanelCancels() {
        let r = rig()
        r.down(tab)
        r.t.fireAll()
        r.c.inside = true
        #expect(r.m.mouseDown(at: .zero) == .pass && r.m.active)
        r.c.inside = false
        #expect(r.m.mouseDown(at: .zero) == .pass && r.c.log.last == "cancel" && !r.m.active)
    }

    @Test func clickBeforeThePanelAppearsIsIgnored() {
        let r = rig()
        r.down(tab)
        r.m.mouseDown(at: .zero)
        #expect(r.m.active)
    }

    @Test func missedModifierReleaseCancelsInsteadOfStickingForever() {
        let r = rig()
        r.down(tab)
        #expect(r.down(Keys.left, 0) == .pass)
        #expect(r.c.log.last == "cancel" && !r.m.active)
    }

    @Test func tapDisabledResetCancelsTheSession() {
        let r = rig()
        r.down(tab)
        r.m.reset()
        #expect(r.c.log.last == "cancel" && !r.m.active && r.t.active == 0)
    }

    @Test func externalPanelCloseResetsTheMachine() {
        let r = rig()
        r.down(tab)
        r.m.panelClosedExternally()
        #expect(!r.m.active)
        #expect(r.m.flagsChanged(mods: 0) == .pass && !r.c.log.contains("commit"))
    }

    @Test func customTriggerHoldsItsOwnModifier() {
        let r = rig { $0.takeOverSystem = false }
        #expect(r.down(tab, cmd) == .pass)
        #expect(r.down(tab, KeyCombo.opt) == .drop)
        r.m.flagsChanged(mods: cmd)
        #expect(r.c.log.last == "commit")
    }

    @Test func repeatedKeyDownOfTheTriggerAfterReleaseIsStillSwallowed() {
        let r = rig()
        r.down(tab)
        r.m.flagsChanged(mods: 0)
        #expect(r.down(tab, 0, rep: true) == .drop)
    }

    @Test func machineWantsTextOnlyWhileSearching() {
        let r = rig()
        #expect(!r.m.wantsText)
        r.down(tab)
        #expect(!r.m.wantsText)
        r.down(Keys.s)
        #expect(r.m.wantsText)
    }
}

@Suite struct SwitcherStageTests {
    private func rig() -> (SwitcherStage, SwcController, InpTapBackend, EventTapHub, WndTimers) {
        let (hub, be) = actHub()
        let c = SwcController()
        let t = WndTimers()
        let m = SwitcherKeyMachine(controller: c, timers: t, settings: { SwitcherSettings() }, trusted: { true })
        return (SwitcherStage(hub: hub, machine: m), c, be, hub, t)
    }

    @Test func startSubscribesAndStopUnsubscribes() {
        let (stage, _, _, hub, _) = rig()
        stage.start()
        stage.start()
        #expect(stage.isRunning && hub.subscriberCount == 1)
        stage.stop()
        #expect(!stage.isRunning && hub.subscriberCount == 0)
    }

    @Test func commandTabEventIsDropped() {
        let (stage, c, be, _, _) = rig()
        stage.start()
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand)) == .drop)
        #expect(c.log == ["begin:apps:fwd"])
        #expect(be.fire(.keyUp, ActEvents.key(UInt16(Keys.tab), down: false, flags: .maskCommand)) == .drop)
    }

    @Test func releaseCommitsThroughTheHub() {
        let (stage, c, be, _, _) = rig()
        stage.start()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand))
        #expect(be.fire(.flagsChanged, ActEvents.flags(55, raw: 0)) == .pass)
        #expect(c.log.last == "commit")
    }

    @Test func plainKeysAndSyntheticEventsAreNotTouched() {
        let (stage, c, be, _, _) = rig()
        stage.start()
        #expect(be.fire(.keyDown, ActEvents.key(0, down: true)) == .pass)
        let synth = ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand)
        EventTapHub.markSynthetic(synth)
        #expect(be.fire(.keyDown, synth) == .pass && c.log.isEmpty)
    }

    @Test func searchTextComesFromTheEventUnicode() {
        let (stage, c, be, _, _) = rig()
        stage.start()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand))
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.s), down: true, flags: .maskCommand))
        be.fire(.keyDown, ActEvents.key(0, down: true, flags: .maskCommand, chars: "ф"))
        #expect(c.log.last == "q+ф")
    }

    @Test func tapResetCancelsAnOpenSession() {
        let (stage, c, be, _, _) = rig()
        stage.start()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand))
        be.onDisabled?(.tapDisabledByTimeout)
        #expect(c.log.last == "cancel")
    }

    @Test func switcherSitsBetweenSuperKeyAndQuitProtection() {
        let (stage, _, be, hub, _) = rig()
        stage.start()
        var order: [String] = []
        _ = hub.subscribe(types: [.keyDown], priority: InputPriority.superKey) { _, _ in order.append("super"); return .pass }
        _ = hub.subscribe(types: [.keyDown], priority: InputPriority.quitProtection, seesDropped: false) { _, _ in order.append("quit"); return .pass }
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.tab), down: true, flags: .maskCommand))
        #expect(order == ["super"])
    }
}
