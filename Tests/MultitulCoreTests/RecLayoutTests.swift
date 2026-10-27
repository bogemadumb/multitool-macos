import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let retina = ShotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let external = ShotDisplay(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)

@Suite struct RecGeometryTests {
    @Test func evenRoundsDown() {
        #expect(RecGeometry.even(101.9) == 100 && RecGeometry.even(100) == 100 && RecGeometry.even(1) == 2)
    }

    @Test func nativePixelSizeUsesScale() {
        let s = RecGeometry.pixelSize(points: CGSize(width: 800, height: 600), scale: 2, resolution: .native)
        #expect(s.width == 1600 && s.height == 1200)
    }

    @Test func oneXIgnoresScale() {
        let s = RecGeometry.pixelSize(points: CGSize(width: 801, height: 601), scale: 2, resolution: .oneX)
        #expect(s.width == 800 && s.height == 600)
    }

    @Test func longSideCapKeepsAspect() {
        let s = RecGeometry.pixelSize(points: CGSize(width: 1512, height: 982), scale: 2, resolution: .p1080)
        #expect(s.width == 1920 && abs(Double(s.height) / Double(s.width) - 982.0 / 1512) < 0.002)
    }

    @Test func capDoesNotUpscale() {
        let s = RecGeometry.pixelSize(points: CGSize(width: 400, height: 300), scale: 1, resolution: .p1440)
        #expect(s.width == 400 && s.height == 300)
    }

    @Test func hardLimitApplies() {
        let s = RecGeometry.pixelSize(points: CGSize(width: 9000, height: 3000), scale: 2, resolution: .native)
        #expect(max(s.width, s.height) <= RecGeometry.maxPixel && s.width % 2 == 0 && s.height % 2 == 0)
    }

    @Test func zeroSizeGivesZero() {
        let s = RecGeometry.pixelSize(points: .zero, scale: 2, resolution: .native)
        #expect(s.width == 0 && s.height == 0)
    }

    @Test func displayPlanCoversWholeDisplay() {
        let p = RecGeometry.plan(mode: .display, rect: CGRect(x: 700, y: 400, width: 10, height: 10), displays: [retina, external], resolution: .native)!
        #expect(p.target == .display(id: 1, sourceRect: nil) && p.pixelWidth == 3024 && p.pixelHeight == 1964 && p.pointRect == retina.frame)
    }

    @Test func displayPlanPicksTheDisplayUnderThePoint() {
        let p = RecGeometry.plan(mode: .display, rect: CGRect(x: 2000, y: 100, width: 1, height: 1), displays: [retina, external], resolution: .native)!
        #expect(p.target == .display(id: 2, sourceRect: nil) && p.pixelWidth == 1920)
    }

    @Test func areaPlanUsesLocalSourceRect() {
        let p = RecGeometry.plan(mode: .area, rect: CGRect(x: 100, y: 50, width: 400, height: 300), displays: [retina, external], resolution: .native)!
        #expect(p.target == .display(id: 1, sourceRect: CGRect(x: 100, y: 50, width: 400, height: 300)) && p.pixelWidth == 800 && p.pixelHeight == 600 && !p.clippedToDisplay)
    }

    @Test func areaOnSecondDisplayIsLocalToIt() {
        let p = RecGeometry.plan(mode: .area, rect: CGRect(x: 1612, y: 100, width: 200, height: 100), displays: [retina, external], resolution: .native)!
        #expect(p.target == .display(id: 2, sourceRect: CGRect(x: 100, y: 100, width: 200, height: 100)) && p.pixelWidth == 200)
    }

    @Test func areaSpanningTwoDisplaysIsClippedToTheBiggerPart() {
        let p = RecGeometry.plan(mode: .area, rect: CGRect(x: 1400, y: 100, width: 400, height: 200), displays: [retina, external], resolution: .native)!
        #expect(p.clippedToDisplay && p.target == .display(id: 2, sourceRect: CGRect(x: 0, y: 100, width: 288, height: 200)))
    }

    @Test func areaOutsideAllDisplaysFails() {
        #expect(RecGeometry.plan(mode: .area, rect: CGRect(x: 9000, y: 9000, width: 50, height: 50), displays: [retina], resolution: .native) == nil)
    }

    @Test func windowPlanNeedsAnId() {
        #expect(RecGeometry.plan(mode: .window, rect: CGRect(x: 10, y: 10, width: 500, height: 400), displays: [retina], resolution: .native) == nil)
        let p = RecGeometry.plan(mode: .window, rect: CGRect(x: 10, y: 10, width: 500, height: 400), windowID: 77, displays: [retina], resolution: .native)!
        #expect(p.target == .window(id: 77) && p.pixelWidth == 1000 && p.pixelHeight == 800)
    }

    @Test func emptyDisplaysOrRectFail() {
        #expect(RecGeometry.plan(mode: .display, rect: CGRect(x: 0, y: 0, width: 10, height: 10), displays: [], resolution: .native) == nil)
        #expect(RecGeometry.plan(mode: .area, rect: .zero, displays: [retina], resolution: .native) == nil)
    }

    @Test func tinyAreaIsFlaggedEmpty() {
        let p = RecGeometry.plan(mode: .area, rect: CGRect(x: 5, y: 5, width: 4, height: 4), displays: [retina], resolution: .native)!
        #expect(p.isEmpty)
    }
}

@Suite struct RecTrackLayoutTests {
    @Test func videoOnlyWhenNoAudioRequested() {
        var s = RecSettings()
        s.systemAudio = false
        let l = RecTrackLayout.make(settings: s, micAvailable: true)
        #expect(l.tracks.map(\.kind) == [.video] && !l.hasAudio)
    }

    @Test func systemAudioIsTrackOneMicIsTrackTwo() {
        var s = RecSettings()
        s.microphone = true
        let l = RecTrackLayout.make(settings: s, micAvailable: true)
        #expect(l.tracks.map(\.kind) == [.video, .systemAudio, .microphone] && l.index(of: .microphone) == 2)
        #expect(l.audioTracks.allSatisfy { $0.sampleRate == 48_000 && $0.channels == 2 })
    }

    @Test func unavailableMicIsDroppedWithWarning() {
        var s = RecSettings()
        s.microphone = true
        let l = RecTrackLayout.make(settings: s, micAvailable: false)
        #expect(!l.enabled.contains(.microphone) && l.warnings.count == 1)
    }

    @Test func unavailableSystemAudioIsDroppedWithWarning() {
        let l = RecTrackLayout.make(settings: RecSettings(), micAvailable: true, systemAudioAvailable: false)
        #expect(!l.enabled.contains(.systemAudio) && l.warnings.first?.contains("Звук системы") == true)
    }

    @Test func audioBitrateGrowsWithQuality() {
        let v = RecQuality.allCases.map { RecTrackLayout.audioBitrate(.systemAudio, quality: $0) }
        #expect(v == v.sorted())
        #expect(RecTrackLayout.audioBitrate(.microphone, quality: .high) < RecTrackLayout.audioBitrate(.systemAudio, quality: .max))
    }

    @Test func enabledSetMatchesTracks() {
        var s = RecSettings()
        s.microphone = true
        #expect(RecTrackLayout.make(settings: s, micAvailable: true).enabled == [.video, .systemAudio, .microphone])
    }

    @Test func micResolution() {
        let devs = [AudioDeviceInfo(uid: "a", name: "A", hasInput: true), AudioDeviceInfo(uid: "b", name: "B", hasInput: true)]
        #expect(RecMic.resolve(uid: "", inputs: devs).uid == nil && RecMic.resolve(uid: "", inputs: devs).note == nil)
        #expect(RecMic.resolve(uid: "b", inputs: devs).uid == "b")
        let gone = RecMic.resolve(uid: "zzz", inputs: devs)
        #expect(gone.uid == nil && gone.note != nil)
    }
}

@Suite struct RecEstimateTests {
    @Test func bitrateScalesWithPixels() {
        let a = RecEstimate.videoBitrate(width: 1280, height: 720, fps: 30, quality: .high, codec: .h264)
        let b = RecEstimate.videoBitrate(width: 2560, height: 1440, fps: 30, quality: .high, codec: .h264)
        #expect(b > a * 3 && b < a * 5)
    }

    @Test func hevcIsCheaperThanH264() {
        let a = RecEstimate.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .high, codec: .h264)
        let b = RecEstimate.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .high, codec: .hevc)
        #expect(b < a)
    }

    @Test func sixtyFpsCostsMoreButLessThanDouble() {
        let a = RecEstimate.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .high, codec: .h264)
        let b = RecEstimate.videoBitrate(width: 1920, height: 1080, fps: 60, quality: .high, codec: .h264)
        #expect(b > a && b < a * 2)
    }

    @Test func bitrateIsClamped() {
        #expect(RecEstimate.videoBitrate(width: 16, height: 16, fps: 24, quality: .low, codec: .hevc) == RecEstimate.minBitrate)
        #expect(RecEstimate.videoBitrate(width: 8192, height: 8192, fps: 60, quality: .max, codec: .h264) == RecEstimate.maxBitrate)
        #expect(RecEstimate.videoBitrate(width: 0, height: 100, fps: 30, quality: .high, codec: .h264) == RecEstimate.minBitrate)
    }

    @Test func qualityOrdersBitrates() {
        let v = RecQuality.allCases.map { RecEstimate.videoBitrate(width: 1920, height: 1080, fps: 30, quality: $0, codec: .h264) }
        #expect(v == v.sorted() && Set(v).count == 4)
    }

    @Test func sizeIncludesAudioTracks() {
        var s = RecSettings()
        s.microphone = true
        let l = RecTrackLayout.make(settings: s, micAvailable: true)
        let withAudio = RecEstimate.bytes(seconds: 60, videoBitrate: 4_000_000, layout: l)
        let silent = RecEstimate.bytes(seconds: 60, videoBitrate: 4_000_000, layout: RecTrackLayout(tracks: [l.tracks[0]], warnings: []))
        #expect(withAudio > silent && silent > 30_000_000 && silent < 31_500_000)
    }

    @Test func zeroOrNegativeDurationIsZero() {
        let l = RecTrackLayout(tracks: [], warnings: [])
        #expect(RecEstimate.bytes(seconds: 0, videoBitrate: 1_000_000, layout: l) == 0 && RecEstimate.bytes(seconds: -5, videoBitrate: 1_000_000, layout: l) == 0)
    }

    @Test func secondsFittingFromFreeSpace() {
        let l = RecTrackLayout(tracks: [], warnings: [])
        let t = RecEstimate.secondsFitting(freeBytes: 1_000_000_000, reserveBytes: 500_000_000, videoBitrate: 8_000_000, layout: l)
        #expect(t > 450 && t < 500)
        #expect(RecEstimate.secondsFitting(freeBytes: 100, reserveBytes: 500, videoBitrate: 8_000_000, layout: l) == 0)
    }

    @Test func gifSizeGrowsWithFrames() {
        #expect(RecEstimate.gifBytes(width: 480, height: 270, frames: 100) > RecEstimate.gifBytes(width: 480, height: 270, frames: 50))
        #expect(RecEstimate.gifBytes(width: 480, height: 270, frames: 50, colors: 16) < RecEstimate.gifBytes(width: 480, height: 270, frames: 50, colors: 256))
    }
}

@Suite struct RecGuardTests {
    @Test func okWhenWithinLimits() {
        #expect(RecGuard.check(elapsed: 100, maxMinutes: 10, freeBytes: 5_000_000_000, minFreeMegabytes: 500) == .ok)
    }

    @Test func durationLimitTriggers() {
        #expect(RecGuard.check(elapsed: 600, maxMinutes: 10, freeBytes: nil, minFreeMegabytes: 500) == .durationLimit)
        #expect(RecGuard.check(elapsed: 99999, maxMinutes: 0, freeBytes: nil, minFreeMegabytes: 0) == .ok)
    }

    @Test func lowDiskTriggers() {
        #expect(RecGuard.check(elapsed: 5, maxMinutes: 0, freeBytes: 100_000_000, minFreeMegabytes: 500) == .lowDisk)
        #expect(RecGuard.check(elapsed: 5, maxMinutes: 0, freeBytes: 100_000_000, minFreeMegabytes: 0) == .ok)
    }

    @Test func unknownFreeSpaceDoesNotStop() {
        #expect(RecGuard.check(elapsed: 5, maxMinutes: 0, freeBytes: nil, minFreeMegabytes: 500) == .ok)
    }
}
