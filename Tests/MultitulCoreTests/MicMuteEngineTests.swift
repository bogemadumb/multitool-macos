import Testing
import Foundation
@testable import MultitulCore

private func make(devices: [AudioDeviceInfo] = [Snd.mic, Snd.usb], scope: MicMuteScope = .allInputs) -> (MicMuteEngine, SndFakeHardware, SndFakeClaims) {
    let h = Snd.hardware(devices, out: "speakers", inp: devices.first { $0.hasInput }?.uid)
    let c = SndFakeClaims()
    return (MicMuteEngine(hardware: h, input: h, store: c, scope: scope), h, c)
}

@Suite struct MicMuteEngineTests {
    @Test func muteSwitchIsUsedWhenTheDeviceHasOne() {
        let (e, h, c) = make()
        h.muteSwitches = ["builtin-mic": false, "usb-headset": false]
        let r = e.setMuted(true)
        #expect(r.muted.sorted() == ["builtin-mic", "usb-headset"])
        #expect(h.muteSwitches.values.allSatisfy { $0 })
        #expect(c.active)
        #expect(c.claims.allSatisfy { $0.kind == .muteSwitch })
    }

    @Test func volumeIsZeroedAndRestored() {
        let (e, h, c) = make()
        h.volumes = ["builtin-mic": 0.8, "usb-headset": 0.35]
        e.setMuted(true)
        #expect(h.volumes["builtin-mic"] == 0)
        #expect(h.volumes["usb-headset"] == 0)
        #expect(c.claims.count == 2)
        let r = e.setMuted(false)
        #expect(r.released.sorted() == ["builtin-mic", "usb-headset"])
        #expect(h.volumes["builtin-mic"] == 0.8)
        #expect(h.volumes["usb-headset"] == 0.35)
        #expect(c.claims.isEmpty)
        #expect(!c.active)
    }

    @Test func muteSwitchIsPreferredOverVolume() {
        let (e, h, _) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": false]
        h.volumes = ["builtin-mic": 0.6]
        e.setMuted(true)
        #expect(h.muteSwitches["builtin-mic"] == true)
        #expect(h.volumes["builtin-mic"] == 0.6)
    }

    @Test func failedSwitchFallsBackToVolume() {
        let (e, h, c) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": false]
        h.failMute = ["builtin-mic"]
        h.volumes = ["builtin-mic": 0.5]
        let r = e.setMuted(true)
        #expect(r.failed.isEmpty)
        #expect(c.claims == [MicClaim(uid: "builtin-mic", kind: .volume, level: 0.5)])
        #expect(h.volumes["builtin-mic"] == 0)
    }

    @Test func deviceWithoutAnyControlIsReported() {
        let (e, _, c) = make(devices: [Snd.mic])
        let r = e.setMuted(true)
        #expect(r.failed == ["builtin-mic"])
        #expect(c.claims.isEmpty)
        #expect(e.isMuted)
    }

    @Test func alreadyMutedByTheUserIsNotClaimed() {
        let (e, h, c) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": true]
        e.setMuted(true)
        #expect(c.claims.isEmpty)
        e.setMuted(false)
        #expect(h.muteSwitches["builtin-mic"] == true)
    }

    @Test func alreadySilentVolumeIsNotOverwrittenOnRelease() {
        let (e, h, c) = make(devices: [Snd.mic])
        h.volumes = ["builtin-mic": 0]
        e.setMuted(true)
        #expect(c.claims.isEmpty)
        e.setMuted(false)
        #expect(h.volumes["builtin-mic"] == 0)
    }

    @Test func deviceAppearingWhileMutedIsMuted() {
        let (e, h, _) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": false]
        e.setMuted(true)
        h.plug(Snd.usb)
        h.muteSwitches["usb-headset"] = false
        let r = e.reassert()
        #expect(r.muted.sorted() == ["builtin-mic", "usb-headset"])
        #expect(h.muteSwitches["usb-headset"] == true)
    }

    @Test func somebodyUnmutingBehindOurBackIsUndone() {
        let (e, h, _) = make(devices: [Snd.mic])
        h.volumes = ["builtin-mic": 0.7]
        e.setMuted(true)
        h.volumes["builtin-mic"] = 0.9
        e.reassert()
        #expect(h.volumes["builtin-mic"] == 0)
        e.setMuted(false)
        #expect(h.volumes["builtin-mic"] == 0.7)
    }

    @Test func unpluggedClaimedDeviceGetsItsLevelWhenItReturns() {
        let (e, h, c) = make()
        h.volumes = ["builtin-mic": 0.4, "usb-headset": 0.9]
        e.setMuted(true)
        h.unplug("usb-headset")
        let r = e.setMuted(false)
        #expect(r.pending == ["usb-headset"])
        #expect(c.claims.map(\.uid) == ["usb-headset"])
        h.plug(Snd.usb)
        h.volumes["usb-headset"] = 0
        let back = e.reassert()
        #expect(back.released == ["usb-headset"])
        #expect(h.volumes["usb-headset"] == 0.9)
        #expect(c.claims.isEmpty)
    }

    @Test func defaultInputScopeTouchesOnlyTheDefault() {
        let (e, h, c) = make(scope: .defaultInput)
        h.muteSwitches = ["builtin-mic": false, "usb-headset": false]
        e.setMuted(true)
        #expect(h.muteSwitches["builtin-mic"] == true)
        #expect(h.muteSwitches["usb-headset"] == false)
        #expect(c.claims.map(\.uid) == ["builtin-mic"])
    }

    @Test func narrowingTheScopeReleasesTheRest() {
        let (e, h, c) = make()
        h.muteSwitches = ["builtin-mic": false, "usb-headset": false]
        e.setMuted(true)
        e.scope = .defaultInput
        let r = e.reassert()
        #expect(r.released == ["usb-headset"])
        #expect(h.muteSwitches["usb-headset"] == false)
        #expect(c.claims.map(\.uid) == ["builtin-mic"])
    }

    @Test func stateSurvivesRestartThroughTheStore() {
        let (e, h, c) = make(devices: [Snd.mic])
        h.volumes = ["builtin-mic": 0.6]
        e.setMuted(true)
        let again = MicMuteEngine(hardware: h, input: h, store: c)
        #expect(again.isMuted)
        h.volumes["builtin-mic"] = 0.3
        again.reassert()
        #expect(h.volumes["builtin-mic"] == 0)
        again.setMuted(false)
        #expect(h.volumes["builtin-mic"] == 0.6)
    }

    @Test func toggleFlips() {
        let (e, h, _) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": false]
        e.toggle()
        #expect(e.isMuted)
        e.toggle()
        #expect(!e.isMuted)
        #expect(h.muteSwitches["builtin-mic"] == false)
    }

    @Test func failedReleaseKeepsTheClaim() {
        let (e, h, c) = make(devices: [Snd.mic])
        h.muteSwitches = ["builtin-mic": false]
        e.setMuted(true)
        h.failMute = ["builtin-mic"]
        let r = e.setMuted(false)
        #expect(r.failed == ["builtin-mic"])
        #expect(c.claims.count == 1)
        h.failMute = []
        e.reassert()
        #expect(c.claims.isEmpty)
        #expect(h.muteSwitches["builtin-mic"] == false)
    }

    @Test func outputOnlyAndHiddenDevicesAreNotTouched() {
        let (e, h, _) = make(devices: [Snd.mic, Snd.speakers, Snd.hiddenTap])
        h.volumes = ["builtin-mic": 0.5, "speakers": 0.5, "tap": 0.5]
        e.setMuted(true)
        #expect(h.volumes["speakers"] == 0.5)
        #expect(h.volumes["tap"] == 0.5)
    }

    @Test func claimStoreRoundTripsThroughDefaults() {
        let suite = "multitul.test.\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let s = MicDefaultsStore(defaults: d)
        s.active = true
        s.claims = [MicClaim(uid: "a", kind: .volume, level: 0.5), MicClaim(uid: "b", kind: .muteSwitch)]
        let s2 = MicDefaultsStore(defaults: d)
        #expect(s2.active)
        #expect(s2.claims.count == 2)
        #expect(s2.claims[0] == MicClaim(uid: "a", kind: .volume, level: 0.5))
        s2.active = false
        s2.claims = []
        #expect(d.object(forKey: "micMute.active") == nil)
        #expect(d.object(forKey: "micMute.claims") == nil)
    }
}
