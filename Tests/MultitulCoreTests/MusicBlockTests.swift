import Testing
import Foundation
@testable import MultitulCore

private func usable() -> MusicBlockSettings {
    var s = MusicBlockSettings()
    s.replacementPath = "/Applications/Spotify.app"
    s.replacementBundleID = "com.spotify.client"
    return s
}

private func data1(code: UInt16, state: UInt32 = 0x0A, repeatFlag: Bool = false) -> Int {
    Int((UInt32(code) << 16) | (state << 8) | (repeatFlag ? 1 : 0))
}

private let music = "com.apple.Music"

@Suite struct MusicBlockTests {
    @Test func decodesMediaKeyDown() {
        let k = MediaKeyPress.decode(subtype: 8, data1: data1(code: 16))
        #expect(k == MediaKeyPress(code: 16, isDown: true, isRepeat: false))
    }

    @Test func decodesKeyUpAndRepeat() {
        #expect(MediaKeyPress.decode(subtype: 8, data1: data1(code: 17, state: 0x0B))?.isDown == false)
        #expect(MediaKeyPress.decode(subtype: 8, data1: data1(code: 17, repeatFlag: true))?.isRepeat == true)
    }

    @Test func otherSubtypesAreNotMediaKeys() {
        #expect(MediaKeyPress.decode(subtype: 7, data1: data1(code: 16)) == nil)
    }

    @Test func mediaKeyThenMusicLaunchIsBlocked() {
        let l = MusicBlockLogic(settings: usable())
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        let d = l.appLaunched(bundleID: music, pid: 500, at: 100.6, secondsSinceGesture: 50)
        #expect(d == .block(MusicBlockAction(openReplacement: true, startPlayback: true)))
        #expect(l.blockedCount == 1)
    }

    @Test func launchWithoutMediaKeyIsAllowed() {
        let l = MusicBlockLogic(settings: usable())
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 10, secondsSinceGesture: 99) == .allow(.noMediaKey))
    }

    @Test func staleMediaKeyIsAllowed() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 100 + MusicBlockSettings.armWindow + 0.1, secondsSinceGesture: 99) == .allow(.keyExpired))
    }

    @Test func clickAfterTheKeyMeansTheUserOpenedIt() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 101, secondsSinceGesture: 0.4) == .allow(.userGesture))
    }

    @Test func clickBeforeTheKeyDoesNotProtectTheLaunch() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 100.5, secondsSinceGesture: 3) == .block(MusicBlockAction(openReplacement: false, startPlayback: false)))
    }

    @Test func otherAppsAreNeverBlocked() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        #expect(l.appLaunched(bundleID: "com.spotify.client", pid: 1, at: 100.2, secondsSinceGesture: 9) == .allow(.notMusicApp))
        #expect(l.appLaunched(bundleID: nil, pid: 2, at: 100.2, secondsSinceGesture: 9) == .allow(.notMusicApp))
    }

    @Test func legacyITunesIsBlockedToo() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 17, isDown: true, isRepeat: false), at: 5)
        if case .block = l.appLaunched(bundleID: "com.apple.iTunes", pid: 1, at: 5.5, secondsSinceGesture: 9) {} else { Issue.record("iTunes not blocked") }
    }

    @Test func oneKeyExplainsOneLaunch() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        _ = l.appLaunched(bundleID: music, pid: 1, at: 100.4, secondsSinceGesture: 9)
        #expect(l.appLaunched(bundleID: music, pid: 2, at: 100.9, secondsSinceGesture: 9) == .allow(.noMediaKey))
    }

    @Test func didLaunchForTheSameProcessIsNotJudgedTwice() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        _ = l.appLaunched(bundleID: music, pid: 7, at: 100.4, secondsSinceGesture: 9)
        #expect(l.appLaunched(bundleID: music, pid: 7, at: 103, secondsSinceGesture: 9) == .allow(.alreadyJudged))
    }

    @Test func failedTerminationLetsDidLaunchTryAgain() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 100)
        _ = l.appLaunched(bundleID: music, pid: 7, at: 100.4, secondsSinceGesture: 9)
        l.cancelBlock(pid: 7)
        #expect(l.blockedCount == 0)
        if case .block = l.appLaunched(bundleID: music, pid: 7, at: 100.9, secondsSinceGesture: 9) {} else { Issue.record("not retried") }
    }

    @Test func nonLaunchingKeysAndReleasesDoNotArm() {
        let l = MusicBlockLogic()
        l.keyPressed(MediaKeyPress(code: 16, isDown: false, isRepeat: false), at: 100)
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: true), at: 100)
        l.keyPressed(MediaKeyPress(code: 0, isDown: true, isRepeat: false), at: 100)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 100.2, secondsSinceGesture: 9) == .allow(.noMediaKey))
    }

    @Test func playbackStartsOnlyForPlayPause() {
        let l = MusicBlockLogic(settings: usable())
        l.keyPressed(MediaKeyPress(code: MediaKeyPress.next, isDown: true, isRepeat: false), at: 1)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 1.2, secondsSinceGesture: 9) == .block(MusicBlockAction(openReplacement: true, startPlayback: false)))
    }

    @Test func playbackCanBeSwitchedOff() {
        var s = usable()
        s.playInReplacement = false
        let l = MusicBlockLogic(settings: s)
        l.keyPressed(MediaKeyPress(code: MediaKeyPress.play, isDown: true, isRepeat: false), at: 1)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 1.2, secondsSinceGesture: 9) == .block(MusicBlockAction(openReplacement: true, startPlayback: false)))
    }

    @Test func replacementCannotBeTheBlockedApp() {
        #expect(!MusicBlockLogic.replacementUsable("/System/Applications/Music.app", bundleID: "com.apple.Music"))
        #expect(!MusicBlockLogic.replacementUsable("", bundleID: "com.spotify.client"))
        #expect(!MusicBlockLogic.replacementUsable("/Applications/X.app", bundleID: ""))
        #expect(MusicBlockLogic.replacementUsable("/Applications/Spotify.app", bundleID: "com.spotify.client"))
        var s = usable()
        s.replacementBundleID = "com.apple.iTunes"
        let l = MusicBlockLogic(settings: s)
        l.keyPressed(MediaKeyPress(code: 16, isDown: true, isRepeat: false), at: 1)
        #expect(l.appLaunched(bundleID: music, pid: 1, at: 1.2, secondsSinceGesture: 9) == .block(MusicBlockAction(openReplacement: false, startPlayback: false)))
    }

    @Test func bundleIDsWithQuotesAreRefusedForScripting() {
        #expect(MusicBlockLogic.isSafeBundleID("com.spotify.client"))
        #expect(!MusicBlockLogic.isSafeBundleID("a\" & (do shell script \"x\") & \""))
        #expect(!MusicBlockLogic.isSafeBundleID(""))
    }

    @Test func retryOnlyWhenTheCommandNeverArrived() {
        #expect(MusicPlaybackRetry.shouldRetry(status: -600, attempt: 0))
        #expect(MusicPlaybackRetry.shouldRetry(status: -609, attempt: 1))
        #expect(!MusicPlaybackRetry.shouldRetry(status: -600, attempt: 2))
        #expect(!MusicPlaybackRetry.shouldRetry(status: -1712, attempt: 0))
    }

    @Test func settingsRoundTrip() {
        let suite = "multitul.test.\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let store = MusicBlockStore(defaults: d)
        #expect(store.load() == MusicBlockSettings())
        var s = usable()
        s.playInReplacement = false
        store.save(s)
        #expect(store.load() == s)
        store.save(MusicBlockSettings())
        #expect(d.object(forKey: "musicBlock.replacementPath") == nil)
        #expect(d.object(forKey: "musicBlock.playInReplacement") == nil)
    }
}
