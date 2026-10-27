import Testing
import Foundation
@testable import MultitulCore

private typealias F = ExtFix

private func sig(_ v: UInt8) -> IslWatSignature { IslWatSignature(cells: [UInt8](repeating: v, count: 256)) }

@Suite struct IslWatSignatureTests {
    @Test func identicalFramesHaveZeroDistance() {
        #expect(sig(100).distance(to: sig(100)) == 0)
    }

    @Test func blackVersusWhiteIsMaximal() {
        #expect(sig(0).distance(to: sig(255)) == 1)
    }

    @Test func distanceIsProportionalToTheDifference() {
        #expect(abs(sig(0).distance(to: sig(51)) - 0.2) < 0.0001)
    }

    @Test func mismatchedSizesAreTreatedAsDifferent() {
        #expect(sig(0).distance(to: IslWatSignature(cells: [0, 0])) == 1)
    }

    @Test func grayFrameIsDownsampledToSixteenBySixteen() {
        var gray = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 { for x in 32..<64 { gray[y * 64 + x] = 200 } }
        let s = IslWatSignature.make(gray: gray, width: 64, height: 64)
        #expect(s?.cells.count == 256 && s?.cells[0] == 0 && s?.cells[15] == 200 && s?.cells[8] == 200 && s?.cells[7] == 0)
    }

    @Test func tinyFramesStillProduceAGrid() {
        #expect(IslWatSignature.make(gray: [10, 20, 30, 40], width: 2, height: 2)?.cells.count == 256)
    }

    @Test func invalidFramesAreRejected() {
        #expect(IslWatSignature.make(gray: [], width: 0, height: 0) == nil)
        #expect(IslWatSignature.make(gray: [1, 2, 3], width: 4, height: 4) == nil)
    }

    @Test func percentIsExtractedFromRecognizedText() {
        #expect(IslWatText.percent(in: "Building… 73%") == 0.73)
        #expect(IslWatText.percent(in: "Progress: 73,5 %") == 0.735)
        #expect(IslWatText.percent(in: "10% then 20%") == 0.2)
        #expect(IslWatText.percent(in: "no numbers") == nil && IslWatText.percent(in: "250%") == nil)
    }

    @Test func completionWordsAreRecognized() {
        #expect(IslWatText.done(in: "Build SUCCEEDED"))
        #expect(IslWatText.done(in: "Build succeeded") && IslWatText.done(in: "Готово") && IslWatText.done(in: "Download completed"))
        #expect(!IslWatText.done(in: "Compiling"))
    }

    @Test func regionRoundTripsThroughItsStoredForm() {
        let r = IslWatRegion(displayID: 69_733_382, x: 100, y: 200, width: 300, height: 40)
        #expect(IslWatRegion(stored: r.stored) == r)
        #expect(IslWatRegion(stored: "1,2,3") == nil && IslWatRegion(stored: "1,0,0,2,2") == nil && IslWatRegion(stored: nil) == nil)
    }
}

@Suite struct IslWatDetectorTests {
    private func detector(_ settle: Double = 30) -> IslWatDetector {
        var s = IslWatSettings()
        s.settleSeconds = settle
        return IslWatDetector(settings: s)
    }

    @Test func beginStartsWatching() {
        var d = detector()
        #expect(d.begin(sig(0), now: F.now) == [.started] && d.phase == .watching && d.isRunning)
    }

    @Test func staticPictureNeverTriggers() {
        var d = detector()
        _ = d.begin(sig(10), now: F.now)
        for i in 1...100 { #expect(d.feed(sig(10), now: F.at(Double(i * 2))).isEmpty) }
        #expect(d.phase == .watching && d.changes == 0)
    }

    @Test func firstChangeIsAnnouncedOnce() {
        var d = detector()
        _ = d.begin(sig(10), now: F.now)
        #expect(d.feed(sig(60), now: F.at(2)) == [.changed])
        #expect(d.feed(sig(110), now: F.at(4)).isEmpty)
        #expect(d.phase == .changing && d.changes == 2)
    }

    @Test func settlesAfterTheQuietPeriod() {
        var d = detector(30)
        _ = d.begin(sig(10), now: F.now)
        _ = d.feed(sig(60), now: F.at(2))
        #expect(d.feed(sig(60), now: F.at(31)).isEmpty)
        let e = d.feed(sig(60), now: F.at(32))
        #expect(e == [.settled(after: 30)] && d.phase == .settled && !d.isRunning)
    }

    @Test func aNewChangeRestartsTheQuietPeriod() {
        var d = detector(30)
        _ = d.begin(sig(10), now: F.now)
        _ = d.feed(sig(60), now: F.at(2))
        _ = d.feed(sig(110), now: F.at(20))
        #expect(d.feed(sig(110), now: F.at(40)).isEmpty)
        #expect(d.feed(sig(110), now: F.at(50)).count == 1)
    }

    @Test func settledReportsHowLongTheChangeLasted() {
        var d = detector(10)
        _ = d.begin(sig(10), now: F.now)
        _ = d.feed(sig(60), now: F.at(5))
        _ = d.feed(sig(110), now: F.at(25))
        let e = d.feed(sig(110), now: F.at(40))
        #expect(e == [.settled(after: 35)])
    }

    @Test func tinyNoiseBelowTheSensitivityIsIgnored() {
        var d = detector()
        _ = d.begin(sig(100), now: F.now)
        #expect(d.feed(sig(102), now: F.at(2)).isEmpty && d.phase == .watching)
    }

    @Test func sensitivityControlsTheThreshold() {
        var s = IslWatSettings()
        s.sensitivity = 0.2
        var d = IslWatDetector(settings: s)
        _ = d.begin(sig(100), now: F.now)
        #expect(d.feed(sig(150), now: F.at(2)).isEmpty)
        #expect(d.feed(sig(210), now: F.at(4)) == [.changed])
    }

    @Test func textChangeCountsEvenWhenPixelsBarelyMove() {
        var d = detector()
        _ = d.begin(sig(100), text: "Compiling 10%", now: F.now)
        let e = d.feed(sig(100), text: "Compiling 11%", now: F.at(2))
        #expect(e.contains(.changed) && e.contains(.progress(0.11)))
    }

    @Test func textReadingCanBeDisabled() {
        var s = IslWatSettings()
        s.readText = false
        var d = IslWatDetector(settings: s)
        _ = d.begin(sig(100), text: "a", now: F.now)
        #expect(d.feed(sig(100), text: "b", now: F.at(2)).isEmpty)
    }

    @Test func progressIsReportedOnlyWhenItChanges() {
        var d = detector()
        _ = d.begin(sig(100), text: "50%", now: F.now)
        #expect(d.progress == 0.5)
        let same = d.feed(sig(100), text: "50%", now: F.at(2))
        #expect(same.isEmpty)
        #expect(d.feed(sig(100), text: "60%", now: F.at(4)).contains(.progress(0.6)))
    }

    @Test func noFramesDoNotChangeAnything() {
        var d = detector()
        _ = d.begin(sig(100), now: F.now)
        #expect(d.feed(nil, now: F.at(2)).isEmpty && d.phase == .watching)
    }

    @Test func feedingAfterSettlingIsIgnoredUntilARestart() {
        var d = detector(5)
        _ = d.begin(sig(0), now: F.now)
        _ = d.feed(sig(100), now: F.at(1))
        _ = d.feed(sig(100), now: F.at(10))
        #expect(d.phase == .settled && d.feed(sig(200), now: F.at(11)).isEmpty)
        #expect(d.begin(sig(200), now: F.at(12)) == [.started] && d.phase == .watching && d.changes == 0)
    }

    @Test func stopReturnsToIdle() {
        var d = detector()
        _ = d.begin(sig(0), now: F.now)
        d.stop()
        #expect(d.phase == .idle && d.feed(sig(100), now: F.at(1)).isEmpty)
    }

    @Test func settingsAreClampedAndRoundTrip() {
        var s = IslWatSettings()
        s.settleSeconds = 1
        s.interval = 100
        s.sensitivity = 0
        let c = s.sanitized
        #expect(c.settleSeconds == 5 && c.interval == 30 && c.sensitivity == 0.002)
        let kv = WndMemoryStore()
        var custom = IslWatSettings()
        custom.settleSeconds = 60
        custom.stopAfterSettled = false
        IslWatSettingsStore(kv).save(custom)
        #expect(IslWatSettingsStore(kv).load() == custom)
        IslWatSettingsStore(kv).save(IslWatSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func activitiesCoverWatchingChangingAndSettled() {
        var d = detector(5)
        #expect(IslWatActivityFactory.activity(d, settledAt: nil, now: F.now) == nil)
        _ = d.begin(sig(0), text: "40%", now: F.now)
        #expect(IslWatActivityFactory.activity(d, settledAt: nil, now: F.now)?.title == "Наблюдение: 40%")
        _ = d.feed(sig(200), text: "", now: F.at(1))
        #expect(IslWatActivityFactory.activity(d, settledAt: nil, now: F.at(1))?.token == "run|changing")
        _ = d.feed(sig(200), text: "", now: F.at(10))
        let a = IslWatActivityFactory.activity(d, settledAt: F.at(10), now: F.at(11))
        #expect(a?.peeks == true && a?.priority == IslPriority.watch && a?.title == "Область перестала меняться")
        #expect(IslWatActivityFactory.activity(d, settledAt: F.at(10), now: F.at(21)) == nil)
    }
}

@Suite struct IslMscMachineTests {
    private func machine(_ s: IslMscSettings = IslMscSettings()) -> IslMscMachine { IslMscMachine(settings: s) }
    private let calm = { 0.5 }

    @Test func atRestItIsHiddenByDefault() {
        var m = machine()
        let f = m.update(IslMscSignals(), now: F.now, random: calm)
        #expect(f.mood == .resting && !f.visible)
    }

    @Test func atRestItCanStayVisible() {
        var s = IslMscSettings()
        s.visibleAtRest = true
        var m = machine(s)
        #expect(m.update(IslMscSignals(), now: F.now, random: calm).visible)
    }

    @Test func musicMakesItDance() {
        var m = machine()
        var sig = IslMscSignals()
        sig.musicPlaying = true
        let f = m.update(sig, now: F.now, random: calm)
        #expect(f.mood == .dancing && f.visible)
    }

    @Test func eachSignalMapsToItsMood() {
        let cases: [(WritableKeyPath<IslMscSignals, Bool>, IslMscMood)] = [(\.musicPlaying, .dancing), (\.timerRunning, .focused), (\.downloadActive, .downloading),
                                                                          (\.micActive, .listening), (\.keepAwake, .awake), (\.agentWorking, .working), (\.calendarImminent, .alarmed)]
        for (key, mood) in cases {
            var m = machine()
            var sig = IslMscSignals()
            sig[keyPath: key] = true
            #expect(m.update(sig, now: F.now, random: calm).mood == mood, "\(mood)")
        }
    }

    @Test func recentEventsMapToShortLivedMoods() {
        var shot = IslMscSignals()
        shot.shotAt = F.at(-1)
        var done = IslMscSignals()
        done.downloadDoneAt = F.at(-1)
        var alert = IslMscSignals()
        alert.timerAlertAt = F.at(-1)
        #expect(machine().reaction(shot, now: F.now) == .camera)
        #expect(machine().reaction(done, now: F.now) == .celebrating)
        #expect(machine().reaction(alert, now: F.now) == .alarmed)
    }

    @Test func eventMoodsExpire() {
        var shot = IslMscSignals()
        shot.shotAt = F.at(-4)
        var done = IslMscSignals()
        done.downloadDoneAt = F.at(-5)
        var alert = IslMscSignals()
        alert.timerAlertAt = F.at(-9)
        #expect(machine().reaction(shot, now: F.now) == nil && machine().reaction(done, now: F.now) == nil && machine().reaction(alert, now: F.now) == nil)
    }

    @Test func eventsInTheFutureAreIgnored() {
        var shot = IslMscSignals()
        shot.shotAt = F.at(5)
        #expect(machine().reaction(shot, now: F.now) == nil)
    }

    @Test func priorityOrderIsAlarmFirstThenCelebrationThenCamera() {
        var sig = IslMscSignals()
        sig.musicPlaying = true
        sig.timerRunning = true
        sig.micActive = true
        sig.shotAt = F.at(-1)
        sig.downloadDoneAt = F.at(-1)
        sig.timerAlertAt = F.at(-1)
        let m = machine()
        #expect(m.reaction(sig, now: F.now) == .alarmed)
        sig.timerAlertAt = nil
        #expect(m.reaction(sig, now: F.now) == .celebrating)
        sig.downloadDoneAt = nil
        #expect(m.reaction(sig, now: F.now) == .camera)
        sig.shotAt = nil
        #expect(m.reaction(sig, now: F.now) == .listening)
        sig.micActive = false
        #expect(m.reaction(sig, now: F.now) == .focused)
        sig.timerRunning = false
        #expect(m.reaction(sig, now: F.now) == .dancing)
    }

    @Test func disabledReactionsAreSkipped() {
        var s = IslMscSettings()
        s.reactToMusic = false
        s.reactToTimer = false
        s.reactToDownloads = false
        s.reactToShots = false
        s.reactToMic = false
        s.reactToKeepAwake = false
        var sig = IslMscSignals()
        sig.musicPlaying = true
        sig.timerRunning = true
        sig.downloadActive = true
        sig.micActive = true
        sig.keepAwake = true
        sig.shotAt = F.at(-1)
        #expect(machine(s).reaction(sig, now: F.now) == nil)
    }

    @Test func moodHoldsBrieflyBeforeFallingBackToRest() {
        var m = machine()
        var sig = IslMscSignals()
        sig.musicPlaying = true
        _ = m.update(sig, now: F.now, random: calm)
        sig.musicPlaying = false
        #expect(m.update(sig, now: F.at(0.5), random: calm).mood == .dancing)
        #expect(m.update(sig, now: F.at(2), random: calm).mood == .resting)
    }

    @Test func alarmInterruptsAHeldMood() {
        var m = machine()
        var sig = IslMscSignals()
        sig.musicPlaying = true
        _ = m.update(sig, now: F.now, random: calm)
        sig.timerAlertAt = F.at(0.2)
        #expect(m.update(sig, now: F.at(0.3), random: calm).mood == .alarmed)
    }

    @Test func visitsNeverHappenWhenDisabled() {
        var s = IslMscSettings()
        s.visits = .never
        var m = machine(s)
        for t in stride(from: 0.0, through: 7200, by: 30) { #expect(m.update(IslMscSignals(), now: F.at(t), random: calm).mood == .resting) }
    }

    @Test func aVisitStartsAfterTheScheduledDelayAndEnds() {
        var m = machine()
        _ = m.update(IslMscSignals(), now: F.now, random: calm)
        #expect(m.update(IslMscSignals(), now: F.at(599), random: calm).mood == .resting)
        let visit = m.update(IslMscSignals(), now: F.at(600), random: calm)
        #expect(visit.mood == .visiting && visit.visible)
        #expect(m.update(IslMscSignals(), now: F.at(605), random: calm).mood == .visiting)
        #expect(m.update(IslMscSignals(), now: F.at(607), random: calm).mood == .resting)
    }

    @Test func randomnessSpreadsTheDelayBetweenHalfAndOneAndAHalfOfTheMean() {
        var early = machine()
        _ = early.update(IslMscSignals(), now: F.now, random: { 0 })
        #expect(early.update(IslMscSignals(), now: F.at(300), random: { 0 }).mood == .visiting)
        var late = machine()
        _ = late.update(IslMscSignals(), now: F.now, random: { 1 })
        #expect(late.update(IslMscSignals(), now: F.at(899), random: { 1 }).mood == .resting)
        #expect(late.update(IslMscSignals(), now: F.at(900), random: { 1 }).mood == .visiting)
    }

    @Test func visitFrequencyFollowsTheSetting() {
        #expect(IslMscVisits.never.meanInterval == nil)
        #expect(IslMscVisits.rare.meanInterval! > IslMscVisits.normal.meanInterval! && IslMscVisits.normal.meanInterval! > IslMscVisits.often.meanInterval!)
    }

    @Test func aReactionCancelsAVisit() {
        var m = machine()
        _ = m.update(IslMscSignals(), now: F.now, random: calm)
        _ = m.update(IslMscSignals(), now: F.at(600), random: calm)
        var sig = IslMscSignals()
        sig.micActive = true
        #expect(m.update(sig, now: F.at(601), random: calm).mood == .listening)
        sig.micActive = false
        #expect(m.update(sig, now: F.at(610), random: calm).mood == .resting)
    }

    @Test func resetReturnsToRest() {
        var m = machine()
        var sig = IslMscSignals()
        sig.musicPlaying = true
        _ = m.update(sig, now: F.now, random: calm)
        m.reset()
        #expect(m.mood == .resting)
    }

    @Test func settingsRoundTripAndPrefix() {
        let kv = WndMemoryStore()
        var s = IslMscSettings()
        s.style = .robot
        s.shape = .drop
        s.palette = .pink
        s.side = .left
        s.visits = .often
        s.visibleAtRest = true
        s.visitSeconds = 10
        s.reactToMic = false
        IslMscSettingsStore(kv).save(s)
        #expect(IslMscSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("notch.mascot.") })
        IslMscSettingsStore(kv).save(IslMscSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func unknownStoredEnumValuesFallBackToDefaults() {
        let kv = WndMemoryStore()
        kv.set("hologram", forKey: "notch.mascot.style")
        kv.set("neon", forKey: "notch.mascot.palette")
        let s = IslMscSettingsStore(kv).load()
        #expect(s.style == .minimal && s.palette == .blue)
    }

    @Test func everyChoiceHasATitleAndPalettesHaveValidColors() {
        for v in IslMscStyle.allCases { #expect(!v.title.isEmpty) }
        for v in IslMscShape.allCases { #expect(!v.title.isEmpty) }
        for v in IslMscSide.allCases { #expect(!v.title.isEmpty) }
        for v in IslMscVisits.allCases { #expect(!v.title.isEmpty) }
        for v in IslMscMood.allCases { #expect(!v.title.isEmpty) }
        for p in IslMscPalette.allCases { #expect(!p.title.isEmpty && (0...1).contains(p.rgb.r) && (0...1).contains(p.rgb.g) && (0...1).contains(p.rgb.b)) }
    }
}

@Suite struct IslMscAnimatorTests {
    @Test func everyReactionHasAProp() {
        for m in IslMscMood.allCases where m != .resting && m != .visiting { #expect(IslMscAnimator.prop(for: m) != .none, "\(m)") }
        #expect(IslMscAnimator.prop(for: .resting) == .none && IslMscAnimator.prop(for: .visiting) == .none)
    }

    @Test func blinkHappensOncePerCycle() {
        #expect(IslMscAnimator.eyeOpen(mood: .dancing, t: 1) > 0.5)
        #expect(IslMscAnimator.eyeOpen(mood: .dancing, t: 3.95) < 0.2)
        #expect(IslMscAnimator.eyeOpen(mood: .dancing, t: 4.5) > 0.5)
    }

    @Test func sleepingEyesAreMostlyClosed() {
        #expect(IslMscAnimator.eyeOpen(mood: .resting, t: 1) < 0.3)
    }

    @Test func posesStayWithinSaneBounds() {
        for m in IslMscMood.allCases {
            for t in stride(from: 0.0, through: 20, by: 0.37) {
                let p = IslMscAnimator.pose(mood: m, t: t)
                #expect(p.bounce >= 0 && p.bounce <= 0.4 && abs(p.tilt) <= 16 && (0...1).contains(p.eyeOpen) && (0...1).contains(p.mouth))
            }
        }
    }

    @Test func nonFiniteTimeDoesNotProduceNaN() {
        let p = IslMscAnimator.pose(mood: .dancing, t: .nan)
        #expect(p.bounce.isFinite && p.tilt.isFinite)
    }

    @Test func celebrationBouncesMoreThanRest() {
        let rest = (0..<50).map { IslMscAnimator.pose(mood: .resting, t: Double($0) * 0.1).bounce }.max()!
        let party = (0..<50).map { IslMscAnimator.pose(mood: .celebrating, t: Double($0) * 0.1).bounce }.max()!
        #expect(party > rest * 5)
    }
}
