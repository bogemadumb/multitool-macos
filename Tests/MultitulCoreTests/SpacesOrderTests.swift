import Testing
import Foundation
@testable import MultitulCore

final class WndDockPref: DockPreferenceDriving {
    var value: DockRearrange
    var writes: [Bool?] = []
    var restarts = 0
    var failWrite = false
    var failRestart = false

    init(_ v: DockRearrange) { value = v }

    func readRearrange() -> DockRearrange { value }

    func writeRearrange(_ v: Bool?) -> Bool {
        guard !failWrite else { return false }
        writes.append(v)
        switch v {
        case .some(true): value = .on
        case .some(false): value = .off
        case .none: value = .absent
        }
        return true
    }

    func restartDock() -> Bool {
        restarts += 1
        return !failRestart
    }
}

private func rig(_ initial: DockRearrange) -> (WndDockPref, WndMemoryStore, SpacesOrderHold) {
    let p = WndDockPref(initial)
    let s = WndMemoryStore()
    return (p, s, SpacesOrderHold(driver: p, store: s))
}

@Suite struct SpacesOrderHoldTests {
    @Test func holdFromTheSystemDefaultTurnsRearrangingOff() {
        let (p, _, h) = rig(.absent)
        #expect(h.hold() == .held)
        #expect(p.writes == [false] && p.restarts == 1 && p.value == .off)
        #expect(h.marker == .wasAbsent && h.isHolding)
    }

    @Test func holdRemembersAnExplicitOn() {
        let (p, _, h) = rig(.on)
        #expect(h.hold() == .held)
        #expect(h.marker == .wasOn && p.value == .off)
    }

    @Test func alreadyOffIsNotTouched() {
        let (p, _, h) = rig(.off)
        #expect(h.hold() == .held)
        #expect(p.writes.isEmpty && p.restarts == 0 && h.marker == .alreadyOff)
    }

    @Test func releaseOfTheDefaultRemovesTheKey() {
        let (p, _, h) = rig(.absent)
        h.hold()
        #expect(h.release() == .released)
        #expect(p.writes == [false, nil] && p.restarts == 2 && p.value == .absent && !h.isHolding)
    }

    @Test func releaseOfAnExplicitOnWritesTrueBack() {
        let (p, _, h) = rig(.on)
        h.hold()
        h.release()
        #expect(p.value == .on && p.writes == [false, true])
    }

    @Test func releaseWhenItWasAlreadyOffLeavesItOff() {
        let (p, _, h) = rig(.off)
        h.hold()
        #expect(h.release() == .released)
        #expect(p.value == .off && p.writes.isEmpty && p.restarts == 0 && !h.isHolding)
    }

    @Test func releaseWithoutAHoldDoesNothing() {
        let (p, _, h) = rig(.on)
        #expect(h.release() == .nothingToRelease)
        #expect(p.writes.isEmpty && p.restarts == 0)
    }

    @Test func holdingTwiceIsHarmless() {
        let (p, _, h) = rig(.absent)
        h.hold()
        #expect(h.hold() == .alreadyHeld)
        #expect(p.writes == [false] && p.restarts == 1)
    }

    @Test func aManagedPreferenceIsNeverOverwritten() {
        let (p, _, h) = rig(.managed)
        #expect(h.hold() == .blockedByProfile)
        #expect(p.writes.isEmpty && !h.isHolding)
    }

    @Test func unreadablePreferenceFails() {
        let (_, _, h) = rig(.unknown)
        if case .failed = h.hold() {} else { Issue.record("expected failure") }
        #expect(!h.isHolding)
    }

    @Test func failedWriteRollsTheMarkerBack() {
        let (p, _, h) = rig(.absent)
        p.failWrite = true
        if case .failed = h.hold() {} else { Issue.record("expected failure") }
        #expect(!h.isHolding)
    }

    @Test func failedRestartKeepsTheMarkerSoTheStateCanBeRecovered() {
        let (p, _, h) = rig(.absent)
        p.failRestart = true
        if case .failed = h.hold() {} else { Issue.record("expected failure") }
        #expect(h.isHolding && h.marker == .wasAbsent)
    }

    @Test func markerSurvivesInTheStoreAcrossInstances() {
        let (p, s, h) = rig(.on)
        h.hold()
        let again = SpacesOrderHold(driver: p, store: s)
        #expect(again.marker == .wasOn)
        again.release()
        #expect(p.value == .on)
    }

    @Test func crashBeforeTheWriteIsRecoveredByTheNextHold() {
        let (p, s, h) = rig(.on)
        s.set(SpacesRestore.wasOn.rawValue, forKey: SpacesOrderHold.markerKey)
        #expect(h.hold() == .held)
        #expect(p.value == .off && h.marker == .wasOn)
    }

    @Test func staleMarkerFromACrashIsReleasedOnLaunch() {
        let (p, s, _) = rig(.off)
        s.set(SpacesRestore.wasAbsent.rawValue, forKey: SpacesOrderHold.markerKey)
        let h = SpacesOrderHold(driver: p, store: s)
        #expect(h.release() == .released)
        #expect(p.value == .absent && !h.isHolding)
    }

    @Test func userTurningRearrangingBackOnIsRespectedOnRelease() {
        let (p, _, h) = rig(.absent)
        h.hold()
        p.value = .on
        let writesBefore = p.writes.count
        #expect(h.release() == .userTookBack)
        #expect(p.writes.count == writesBefore && p.value == .on && !h.isHolding)
    }

    @Test func reconcileNoticesTheUserTakingControlBack() {
        let (p, _, h) = rig(.absent)
        h.hold()
        #expect(h.reconcile() == nil)
        p.value = .on
        #expect(h.userOverrode())
        #expect(h.reconcile() == .userTookBack)
        #expect(!h.isHolding)
    }

    @Test func reconcileIgnoresTheAlreadyOffCase() {
        let (p, _, h) = rig(.off)
        h.hold()
        p.value = .on
        #expect(!h.userOverrode() && h.reconcile() == nil && h.isHolding)
    }

    @Test func reconcileWithoutAHoldDoesNothing() {
        let (_, _, h) = rig(.on)
        #expect(h.reconcile() == nil)
    }

    @Test func releaseUnderAProfileClearsTheMarkerWithoutWriting() {
        let (p, _, h) = rig(.absent)
        h.hold()
        p.value = .managed
        let writes = p.writes.count
        #expect(h.release() == .blockedByProfile)
        #expect(p.writes.count == writes && !h.isHolding)
    }

    @Test func failedWriteOnReleaseKeepsTheMarker() {
        let (p, _, h) = rig(.on)
        h.hold()
        p.failWrite = true
        if case .failed = h.release() {} else { Issue.record("expected failure") }
        #expect(h.isHolding)
    }

    @Test func holdReleaseHoldCycleIsRepeatable() {
        let (p, _, h) = rig(.absent)
        for _ in 0..<3 {
            #expect(h.hold() == .held)
            #expect(p.value == .off)
            #expect(h.release() == .released)
            #expect(p.value == .absent)
        }
    }

    @Test func markerKeyIsAscii() {
        #expect(SpacesOrderHold.markerKey.allSatisfy { $0.isASCII })
        #expect(SpacesRestore.allCasesForTest.allSatisfy { $0.rawValue.allSatisfy { $0.isASCII } })
    }
}

private extension SpacesRestore {
    static var allCasesForTest: [SpacesRestore] { [.alreadyOff, .wasAbsent, .wasOn] }
}
