import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let info = RecSourceInfo(width: 2880, height: 1800, duration: 60, fps: 30, scale: 2, hasSystemAudio: true, hasMicrophone: true)

private func doc() -> RecEditDocument { RecEditDocument(source: info) }
private func preset(_ id: String) -> RecExportPreset { RecPresets.export.first { $0.id == id }! }

@Suite struct RecPresetTests {
    @Test func exportPresetIDsAreUniqueAsciiAndCoverVideoAndGif() {
        let ids = RecPresets.export.map(\.id)
        #expect(Set(ids).count == ids.count && ids.allSatisfy { $0.allSatisfy(\.isASCII) })
        #expect(RecPresets.export.contains { $0.kind == .gif } && RecPresets.export.contains { $0.kind == .video })
    }

    @Test func capturePresetIDsAreUnique() {
        let ids = RecPresets.capture.map(\.id)
        #expect(Set(ids).count == ids.count && ids.contains("standard"))
    }

    @Test func capturePresetAppliesItsSettings() {
        var s = RecSettings()
        RecPresets.capturePreset(id: "smooth")!.apply(&s)
        #expect(s.fps == 60 && s.codec == .hevc && s.container == .mov)
        RecPresets.capturePreset(id: "silent")!.apply(&s)
        #expect(!s.systemAudio && !s.microphone && s.fps == 30)
        RecPresets.capturePreset(id: "tutorial")!.apply(&s)
        #expect(s.microphone && s.systemAudio && s.resolution == .p1080)
    }

    @Test func everyCapturePresetProducesValidSettings() {
        for p in RecPresets.capture {
            var s = RecSettings()
            p.apply(&s)
            #expect(s == s.sanitized)
        }
    }

    @Test func unknownCapturePresetIsNil() {
        #expect(RecPresets.capturePreset(id: "nope") == nil)
    }

    @Test func gifPresetsDisableAudio() {
        for p in RecPresets.export where p.kind == .gif { #expect(!p.includeAudio && p.fileExtension == "gif") }
    }

    @Test func fileExtensionFollowsTheContainer() {
        #expect(preset("source").fileExtension == "mov" && preset("web1080").fileExtension == "mp4")
    }

    @Test func unknownPresetFallsBackToWeb() {
        #expect(RecPresets.exportPreset(id: "zzz").id == "web1080")
        let custom = RecExportPreset(id: "mine", title: "Моя")
        #expect(RecPresets.exportPreset(id: "mine", custom: [custom]).title == "Моя")
    }

    @Test func safeIDStripsEverythingButAsciiWordCharacters() {
        #expect(RecPresets.safeID("Мой пресет!") == "custom")
        #expect(RecPresets.safeID("my preset/1") == "mypreset1")
        #expect(RecPresets.safeID(String(repeating: "a", count: 100)).count == 40)
    }

    @Test func presetSanitizeClamps() {
        let p = RecExportPreset(id: "x", title: " ", maxLongSide: 50, fps: 500).sanitized
        #expect(p.maxLongSide == 160 && p.fps == 60 && p.title == "x")
    }

    @Test func customPresetsRoundTripThroughTheStore() {
        let kv = WndMemoryStore()
        let store = RecPresetStore(kv)
        store.upsert(RecExportPreset(id: "mine", title: "Моя", maxLongSide: 1000, fps: 20))
        store.upsert(RecExportPreset(id: "other", title: "Другая"))
        let back = RecPresetStore(kv).load()
        #expect(back.map(\.id) == ["mine", "other"] && back[0].title == "Моя" && back[0].maxLongSide == 1000)
    }

    @Test func upsertReplacesByID() {
        let store = RecPresetStore(WndMemoryStore())
        store.upsert(RecExportPreset(id: "mine", title: "A"))
        let list = store.upsert(RecExportPreset(id: "mine", title: "B"))
        #expect(list.count == 1 && list[0].title == "B")
    }

    @Test func builtInIDsCannotBeOverwritten() {
        let store = RecPresetStore(WndMemoryStore())
        let h1 = store.upsert(RecExportPreset(id: "web1080", title: "hack"))
        #expect(h1.isEmpty)
    }

    @Test func removeDeletesAndEmptyStoreClearsTheKey() {
        let kv = WndMemoryStore()
        let store = RecPresetStore(kv)
        store.upsert(RecExportPreset(id: "mine", title: "A"))
        #expect(kv.values[RecPresetStore.key] != nil)
        let h2 = store.remove(id: "mine")
        #expect(h2.isEmpty && kv.values[RecPresetStore.key] == nil)
    }

    @Test func corruptStoreValueLoadsAsEmpty() {
        let kv = WndMemoryStore()
        kv.values[RecPresetStore.key] = "{not json"
        #expect(RecPresetStore(kv).load().isEmpty)
    }
}

@Suite struct RecExportPlanTests {
    @Test func piecesFollowTheTimeline() {
        var d = doc()
        d.timeline.cut(from: 10, to: 20)
        d.timeline.setSpeed(from: 30, to: 40, speed: 2)
        let p = RecExportPlanner.pieces(d.timeline)
        #expect(p.count == 4)
        #expect(p[0].srcStart == 0 && p[0].outStart == 0 && p[0].outDuration == 10)
        #expect(p[1].srcStart == 20 && p[1].outStart == 10 && p[1].outDuration == 10)
        #expect(p[2].speed == 2 && p[2].outStart == 20 && p[2].outDuration == 5 && p[2].srcDuration == 10)
        #expect(p[3].outStart == 25 && abs(p[3].outDuration - 20) < 1e-9)
    }

    @Test func piecesTileTheOutputWithoutGaps() {
        var d = doc()
        d.timeline.cut(from: 5, to: 9)
        d.timeline.setSpeed(from: 12, to: 24, speed: 3)
        d.timeline.setSpeed(from: 30, to: 33, speed: 0.5)
        let p = RecExportPlanner.pieces(d.timeline)
        for i in 1..<p.count { #expect(abs(p[i].outStart - (p[i - 1].outStart + p[i - 1].outDuration)) < 1e-9) }
        #expect(abs((p.last!.outStart + p.last!.outDuration) - d.timeline.outputDuration) < 1e-9)
    }

    @Test func untouchedDocumentNeedsNoCompositor() {
        #expect(!RecExportPlanner.needsCompositor(doc(), hasLog: false))
    }

    @Test func compositorIsNeededForEveryVisualEdit() {
        var crop = doc(); crop.crop = RecNormRect(x: 0, y: 0, w: 0.5, h: 0.5)
        var style = doc(); style.style.padding = 10
        var blur = doc(); _ = blur.addBlur(rect: .full, from: 0, to: 5)
        var zoom = doc(); zoom.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 0, holdStart: 1, holdEnd: 2, end: 3, level: 2, path: [])])
        for d in [crop, style, blur, zoom] { #expect(RecExportPlanner.needsCompositor(d, hasLog: false)) }
        #expect(RecExportPlanner.needsCompositor(doc(), hasLog: true))
    }

    @Test func compositorSkippedWhenClickHighlightIsOff() {
        var d = doc()
        d.style.highlightClicks = false
        #expect(!RecExportPlanner.needsCompositor(d, hasLog: true))
    }

    @Test func webPresetScalesDownAndKeepsAudioMixed() {
        let plan = RecExportPlanner.make(document: doc(), preset: preset("web1080"))
        #expect(plan.canvas == CGSize(width: 1920, height: 1200) && plan.fps == 30 && plan.audioGroups.count == 1 && plan.audioGroups[0].channels.count == 2)
        #expect(plan.outputDuration == 60 && plan.pieces.count == 1 && !plan.isGif)
    }

    @Test func sourcePresetKeepsTracksSeparate() {
        let plan = RecExportPlanner.make(document: doc(), preset: preset("source"))
        #expect(plan.canvas == CGSize(width: 2880, height: 1800) && plan.audioGroups.count == 2)
        #expect(plan.audioGroups.map { $0.channels[0].kind } == [.systemAudio, .microphone] && plan.audioGroups.map { $0.channels[0].sourceTrackIndex } == [0, 1])
    }

    @Test func fpsNeverExceedsTheSource() {
        var s = info
        s.fps = 24
        let plan = RecExportPlanner.make(document: RecEditDocument(source: s), preset: preset("web1080"))
        #expect(plan.fps == 24)
    }

    @Test func mutedTrackIsLeftOut() {
        var d = doc()
        d.audio.micMuted = true
        let plan = RecExportPlanner.make(document: d, preset: preset("source"))
        #expect(plan.audioGroups.count == 1 && plan.audioGroups[0].channels[0].kind == .systemAudio)
    }

    @Test func volumeBecomesGain() {
        var d = doc()
        d.audio.systemVolume = 0.5
        let plan = RecExportPlanner.make(document: d, preset: preset("web1080"))
        #expect(plan.audioGroups[0].channels.first { $0.kind == .systemAudio }?.gain == 0.5)
    }

    @Test func allTracksMutedWarnsAndWritesNoAudio() {
        var d = doc()
        d.audio.systemMuted = true
        d.audio.micMuted = true
        let plan = RecExportPlanner.make(document: d, preset: preset("web1080"))
        #expect(plan.audioGroups.isEmpty && plan.warnings.contains { $0.contains("тишина") })
    }

    @Test func missingMicTrackIsNotPlanned() {
        var s = info
        s.hasMicrophone = false
        let plan = RecExportPlanner.make(document: RecEditDocument(source: s), preset: preset("source"))
        #expect(plan.audioGroups.count == 1)
    }

    @Test func silentSourceHasNoAudioGroups() {
        var s = info
        s.hasSystemAudio = false
        s.hasMicrophone = false
        let plan = RecExportPlanner.make(document: RecEditDocument(source: s), preset: preset("web1080"))
        #expect(plan.audioGroups.isEmpty && plan.warnings.isEmpty)
    }

    @Test func gifPlanHasNoAudioAndAGifTimeline() {
        let plan = RecExportPlanner.make(document: doc(), preset: preset("gifLight"))
        #expect(plan.isGif && plan.audioGroups.isEmpty && plan.gif != nil && plan.canvas.width == 480)
        #expect(plan.gif!.times.count == 600 && !plan.gif!.truncated)
    }

    @Test func shortGifIsNotTruncated() {
        var d = doc()
        d.timeline.trim(from: 10, to: 20)
        let plan = RecExportPlanner.make(document: d, preset: preset("gifLight"))
        #expect(plan.gif!.times.count == 100 && !plan.gif!.truncated && plan.gif!.delays.reduce(0, +) == 1000)
    }

    @Test func bitrateFollowsQualityAndCanvas() {
        let a = RecExportPlanner.make(document: doc(), preset: preset("messenger"))
        let b = RecExportPlanner.make(document: doc(), preset: preset("web1080"))
        #expect(a.videoBitrate < b.videoBitrate)
    }

    @Test func estimatedBytesGrowWithDuration() {
        var d = doc()
        let full = RecExportPlanner.make(document: d, preset: preset("web1080")).estimatedBytes
        d.timeline.trim(from: 0, to: 30)
        let half = RecExportPlanner.make(document: d, preset: preset("web1080")).estimatedBytes
        #expect(abs(Double(half) / Double(full) - 0.5) < 0.01)
    }

    @Test func paddedCanvasIsScaledAsAWhole() {
        var d = doc()
        d.style.padding = 40
        let plan = RecExportPlanner.make(document: d, preset: preset("web1080"))
        #expect(plan.canvas.width == 1920 && Int(plan.canvas.height) % 2 == 0)
    }

    @Test func emptyTimelineWarns() {
        let plan = RecExportPlanner.make(document: RecEditDocument(source: RecSourceInfo(width: 100, height: 100, duration: 0)), preset: preset("web1080"))
        #expect(plan.warnings.contains { $0.contains("ни одного фрагмента") } && plan.pieces.isEmpty)
    }

    @Test func planKeepsASanitizedCopyOfTheDocument() {
        var d = doc()
        d.crop = RecNormRect(x: 5, y: 5, w: 5, h: 5)
        let plan = RecExportPlanner.make(document: d, preset: preset("web1080"))
        #expect(plan.document.crop.w <= 1)
    }
}
