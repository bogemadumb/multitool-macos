import Testing
import Foundation
@testable import MultitulCore

@Suite struct RecModelsTests {
    @Test func defaultsAreSane() {
        let s = RecSettings()
        #expect(s.fps == 30 && s.codec == .h264 && s.container == .mp4 && s.systemAudio && !s.microphone && s.countdownSeconds == 3)
        #expect(s.afterRecord == .editor && !s.addToShelf)
    }

    @Test func settingsRoundTripThroughStore() {
        let kv = WndMemoryStore()
        var s = RecSettings()
        s.fps = 60
        s.codec = .hevc
        s.container = .mov
        s.quality = .max
        s.microphone = true
        s.micDeviceUID = "BuiltInMic"
        s.saveDirectory = "~/Movies/Test"
        s.zoomLevel = 2.4
        s.editorBackground = .solid(ShotColor(10, 20, 30))
        RecSettingsStore(kv).save(s)
        #expect(RecSettingsStore(kv).load() == s.sanitized)
    }

    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        RecSettingsStore(kv).save(RecSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func settingsKeysUseRecorderPrefixAndAscii() {
        let kv = WndMemoryStore()
        var s = RecSettings()
        s.fps = 60
        s.nameTemplate = "Запись {date}"
        RecSettingsStore(kv).save(s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("recorder.") && $0.allSatisfy(\.isASCII) })
    }

    @Test func sanitizeClampsRanges() {
        var s = RecSettings()
        s.fps = 17
        s.countdownSeconds = 400
        s.historyLimit = 1
        s.maxMinutes = -4
        s.zoomLevel = 99
        s.editorPadding = 9999
        s.nameTemplate = "   "
        let c = s.sanitized
        #expect(c.fps == 30 && c.countdownSeconds == 60 && c.historyLimit == 10 && c.maxMinutes == 0)
        #expect(c.zoomLevel == 4.0 && c.editorPadding == 400 && c.nameTemplate == RecSettings.defaultTemplate)
    }

    @Test func loadSkipsGarbageValues() {
        let kv = WndMemoryStore()
        kv.values["recorder.codec"] = "vp9"
        kv.values["recorder.mode"] = 12
        kv.values["recorder.fps"] = "fast"
        let s = RecSettingsStore(kv).load()
        #expect(s.codec == .h264 && s.mode == .area && s.fps == 30)
    }

    @Test func directoryResolution() {
        var s = RecSettings()
        #expect(s.resolvedDirectory(home: "/Users/x") == "/Users/x/Movies/Screen Recordings")
        s.saveDirectory = "~/Desktop/Rec"
        #expect(s.resolvedDirectory(home: "/Users/x") == "/Users/x/Desktop/Rec")
        s.saveDirectory = "/Volumes/Disk/Rec"
        #expect(s.resolvedDirectory(home: "/Users/x") == "/Volumes/Disk/Rec")
    }

    @Test func hotkeysAreUnassignedAndUnique() {
        #expect(RecHotkeys.all.count == 8)
        #expect(RecHotkeys.all.allSatisfy { $0.defaultCombo.isNone && $0.id.hasPrefix("recorder.") && $0.id.allSatisfy(\.isASCII) })
        #expect(Set(RecHotkeys.all.map(\.id)).count == RecHotkeys.all.count)
    }

    @Test func hintComboIsControlOptionCommandFive() {
        let c = HotkeyHints.effective(RecHotkeys.toggle)
        #expect(c.keyCode == 23 && c.modifiers == (KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd))
        #expect(HotkeyHints.effective(RecHotkeys.stop).isNone)
    }

    @Test func moduleIsRegisteredOffByDefault() {
        let i = ModuleID.screenRecorder.info
        #expect(!i.enabledByDefault && i.group == .tools && i.hotkeys.count == 8)
        #expect(i.permissions.contains(.screenRecording) && i.permissions.contains(.systemAudio) && i.permissions.contains(.microphone))
        #expect(ModuleID.screenRecorder.enabledKey == "module.screenRecorder.enabled")
    }

    @Test func modeMapsToScreenshotModes() {
        #expect(RecMode.area.shotMode == .area && RecMode.window.shotMode == .window && RecMode.display.shotMode == .screen)
        #expect(RecMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func qualityBitsAreIncreasing() {
        let v = RecQuality.allCases.map(\.bitsPerPixel)
        #expect(v == v.sorted() && Set(v).count == 4)
    }

    @Test func containerMimeAndExtension() {
        #expect(RecContainer.mp4.mimeType == "video/mp4" && RecContainer.mov.mimeType == "video/quicktime" && RecContainer.mov.fileExtension == "mov")
    }

    @Test func eventHubCarriesRecordingEvents() {
        let hub = ShotEventHub()
        var got: [ShotEvent] = []
        hub.subscribe { got.append($0) }
        hub.emit(.recordingStarted)
        hub.emit(.recordingPaused)
        hub.emit(.recordingResumed)
        hub.emit(.recordingStopped(path: "/tmp/a.mp4"))
        hub.emit(.recordingFailed(reason: "x"))
        #expect(got.count == 5 && got[3] == .recordingStopped(path: "/tmp/a.mp4"))
    }
}
