import Testing
import Foundation
@testable import MultitulCore

@Suite struct IslLevelsMathTests {
    @Test func clampHandlesJunk() {
        #expect(IslLevelsMath.clamp(-1) == 0 && IslLevelsMath.clamp(2) == 1 && IslLevelsMath.clamp(.nan) == 0 && IslLevelsMath.clamp(0.3) == 0.3)
    }

    @Test func stepsAreSixteenths() {
        #expect(IslLevelsMath.stepped(0.5, up: true, fine: false) == 0.5625)
        #expect(IslLevelsMath.stepped(0.5, up: false, fine: false) == 0.4375)
    }

    @Test func finerStepsAreSixtyFourths() {
        #expect(IslLevelsMath.stepped(0.5, up: true, fine: true) == 0.515625)
    }

    @Test func unalignedValuesSnapToTheNextGridLine() {
        #expect(IslLevelsMath.stepped(0.52, up: true, fine: false) == 0.5625)
        #expect(IslLevelsMath.stepped(0.52, up: false, fine: false) == 0.5)
    }

    @Test func stepsStopAtTheEnds() {
        #expect(IslLevelsMath.stepped(1, up: true, fine: false) == 1)
        #expect(IslLevelsMath.stepped(0, up: false, fine: false) == 0)
        var v = 0.0
        for _ in 0..<40 { v = IslLevelsMath.stepped(v, up: true, fine: false) }
        #expect(v == 1)
    }

    @Test func sixteenStepsGoFromZeroToFull() {
        var v = 0.0
        for _ in 0..<16 { v = IslLevelsMath.stepped(v, up: true, fine: false) }
        #expect(v == 1)
    }

    @Test func percentRounds() {
        #expect(IslLevelsMath.percent(0.456) == 46 && IslLevelsMath.percent(1.5) == 100 && IslLevelsMath.percent(-1) == 0)
    }

    @Test func volumeSymbolsFollowTheLevel() {
        #expect(IslLevelsMath.volumeSymbol(0, muted: false) == "speaker.slash.fill")
        #expect(IslLevelsMath.volumeSymbol(0.8, muted: true) == "speaker.slash.fill")
        #expect(IslLevelsMath.volumeSymbol(0.2, muted: false) == "speaker.wave.1.fill")
        #expect(IslLevelsMath.volumeSymbol(0.5, muted: false) == "speaker.wave.2.fill")
        #expect(IslLevelsMath.volumeSymbol(0.9, muted: false) == "speaker.wave.3.fill")
    }

    @Test func brightnessSymbols() {
        #expect(IslLevelsMath.brightnessSymbol(0.1) == "sun.min.fill" && IslLevelsMath.brightnessSymbol(0.8) == "sun.max.fill")
    }

    @Test func hudActivityIsShortLivedAndTransient() {
        let a = IslLevelsMath.hudActivity(kind: "volume", section: IslSectionIDs.levels, value: 0.5, now: IslFix.at(0))
        #expect(a.id == "hud.volume" && a.title == "50%" && a.priority == IslPriority.levelsHud && !a.peeks)
        #expect(!a.isExpired(at: IslFix.at(1.5)) && a.isExpired(at: IslFix.at(1.7)))
    }

    @Test func hudBeatsMusicAndThenYieldsBack() {
        var arb = IslArbiter()
        let music = IslFix.activity("music", "music", priority: IslPriority.music)
        _ = arb.resolve([music], now: IslFix.at(0))
        let hud = IslLevelsMath.hudActivity(kind: "volume", section: IslSectionIDs.levels, value: 0.3, now: IslFix.at(1))
        #expect(arb.resolve([music, hud], now: IslFix.at(1.1)).winner?.id == "hud.volume")
        #expect(arb.resolve([music, hud], now: IslFix.at(3)).winner?.id == "music")
    }
}

@Suite struct IslChangeFilterTests {
    @Test func theFirstReadingIsOnlyRemembered() {
        var f = IslLevelsChangeFilter()
        let first = f.externalChange(0.5, now: IslFix.at(0))
        #expect(!first)
    }

    @Test func aRealChangeIsReported() {
        var f = IslLevelsChangeFilter()
        _ = f.externalChange(0.5, now: IslFix.at(0))
        let changed = f.externalChange(0.6, now: IslFix.at(1))
        #expect(changed)
    }

    @Test func tinyJitterIsIgnored() {
        var f = IslLevelsChangeFilter()
        _ = f.externalChange(0.5, now: IslFix.at(0))
        let jitter = f.externalChange(0.501, now: IslFix.at(1))
        #expect(!jitter)
    }

    @Test func ownChangesAreSuppressedForAWhile() {
        var f = IslLevelsChangeFilter()
        _ = f.externalChange(0.5, now: IslFix.at(0))
        f.noteLocalChange(until: IslFix.at(2))
        let during = f.externalChange(0.7, now: IslFix.at(1))
        let after = f.externalChange(0.9, now: IslFix.at(3))
        #expect(!during)
        #expect(after)
    }

    @Test func resetForgetsTheBaseline() {
        var f = IslLevelsChangeFilter()
        _ = f.externalChange(0.5, now: IslFix.at(0))
        f.reset()
        let again = f.externalChange(0.9, now: IslFix.at(1))
        #expect(!again)
    }
}

@Suite struct IslFakeLevelsTests {
    @Test func protocolRoundTrip() {
        let l = IslFakeLevels()
        #expect(l.setOutputVolume(0.25) && l.outputVolume() == 0.25)
        #expect(l.setMuted(true) && l.isMuted() == true)
    }

    @Test func missingVolumeIsRepresentable() {
        let l = IslFakeLevels()
        l.volume = nil
        l.muted = nil
        #expect(l.outputVolume() == nil && l.isMuted() == nil)
    }
}

@Suite struct IslStatsFormatTests {
    @Test func lineSkipsMissingValues() {
        #expect(IslStatsFormat.line(cpu: 0.25, memoryUsed: nil, down: nil, up: nil) == "CPU 25%")
        #expect(IslStatsFormat.line(cpu: nil, memoryUsed: nil, down: nil, up: nil).isEmpty)
    }

    @Test func lineJoinsEverything() {
        let s = IslStatsFormat.line(cpu: 0.5, memoryUsed: 0.8, down: 2048, up: 1024)
        #expect(s.contains("CPU 50%") && s.contains("RAM 80%") && s.contains("↓") && s.contains("↑"))
    }

    @Test func batteryTexts() {
        #expect(IslStatsFormat.batteryText(percent: nil, charging: false, onAC: false, minutes: nil) == "Нет батареи")
        #expect(IslStatsFormat.batteryText(percent: 80, charging: true, onAC: true, minutes: 30) == "80%, заряжается")
        #expect(IslStatsFormat.batteryText(percent: 100, charging: false, onAC: true, minutes: nil) == "100%, от сети")
        #expect(IslStatsFormat.batteryText(percent: 40, charging: false, onAC: false, minutes: 95).hasPrefix("40%, ещё"))
        #expect(IslStatsFormat.batteryText(percent: 40, charging: false, onAC: false, minutes: nil) == "40%")
    }
}
