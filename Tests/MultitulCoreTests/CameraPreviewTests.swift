import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func rig(_ configure: (TlsCamera) -> Void = { _ in }, settings: CameraSettings = CameraSettings()) -> (CameraPreviewSession, TlsCamera) {
    let cam = TlsCamera()
    configure(cam)
    return (CameraPreviewSession(driver: cam, settings: settings), cam)
}

@Suite struct CameraDeviceChooserTests {
    private let list = [CameraDevice(id: "ext", name: "Logitech"), CameraDevice(id: "built", name: "FaceTime", isBuiltIn: true), CameraDevice(id: "phone", name: "iPhone")]

    @Test func preferredWinsWhenPresent() {
        #expect(CameraDeviceChooser.choose(preferred: "phone", from: list)?.id == "phone")
    }

    @Test func builtInIsTheFallback() {
        #expect(CameraDeviceChooser.choose(preferred: "", from: list)?.id == "built")
        #expect(CameraDeviceChooser.choose(preferred: "unplugged", from: list)?.id == "built")
    }

    @Test func firstDeviceWhenThereIsNoBuiltIn() {
        #expect(CameraDeviceChooser.choose(preferred: "", from: [list[0], list[2]])?.id == "ext")
    }

    @Test func nothingWhenEmpty() {
        #expect(CameraDeviceChooser.choose(preferred: "x", from: []) == nil)
    }
}

@Suite struct CameraSessionTests {
    @Test func cameraStartsOnlyWhenTheWindowOpens() {
        let (s, cam) = rig()
        #expect(s.state == .closed && !cam.running && cam.started.isEmpty)
        s.open()
        #expect(s.state == .running(deviceName: "FaceTime") && cam.running && cam.started == ["built"])
    }

    @Test func closingStopsTheCamera() {
        let (s, cam) = rig()
        s.open()
        s.close()
        #expect(s.state == .closed && !cam.running && cam.stops == 1 && s.activeDeviceID == nil)
    }

    @Test func toggleOpensAndCloses() {
        let (s, cam) = rig()
        s.toggle()
        #expect(cam.running)
        s.toggle()
        #expect(!cam.running && s.state == .closed)
    }

    @Test func deniedAccessNeverStartsTheCamera() {
        let (s, cam) = rig { $0.auth = .denied }
        s.open()
        #expect(s.state == .denied && cam.started.isEmpty && !cam.running)
        #expect(s.state.isWindowOpen)
    }

    @Test func firstUseAsksAndStartsAfterGrant() {
        let (s, cam) = rig { $0.auth = .notDetermined }
        s.open()
        #expect(s.state == .requesting && cam.started.isEmpty)
        cam.pending?(true)
        #expect(s.state == .running(deviceName: "FaceTime"))
    }

    @Test func refusedPromptEndsInDenied() {
        let (s, cam) = rig { $0.auth = .notDetermined }
        s.open()
        cam.pending?(false)
        #expect(s.state == .denied && !cam.running)
    }

    @Test func closingWhileThePromptIsOpenIgnoresALateGrant() {
        let (s, cam) = rig { $0.auth = .notDetermined }
        s.open()
        s.close()
        cam.pending?(true)
        #expect(s.state == .closed && !cam.running)
    }

    @Test func noCameraAtAll() {
        let (s, cam) = rig { $0.list = [] }
        s.open()
        #expect(s.state == .noDevice && !cam.running)
    }

    @Test func startFailureIsAState() {
        let (s, cam) = rig { $0.failStart = true }
        s.open()
        #expect(s.state == .failed && !cam.running)
    }

    @Test func retryAfterAFailure() {
        let (s, cam) = rig { $0.failStart = true }
        s.open()
        cam.failStart = false
        s.open()
        #expect(s.state == .running(deviceName: "FaceTime"))
    }

    @Test func openWhileRunningDoesNotRestart() {
        let (s, cam) = rig()
        s.open()
        s.open()
        #expect(cam.started.count == 1)
    }

    @Test func preferredDeviceIsUsed() {
        var set = CameraSettings()
        set.preferredDeviceID = "ext"
        let (s, cam) = rig(settings: set)
        s.open()
        #expect(cam.started == ["ext"] && s.state == .running(deviceName: "Logitech"))
    }

    @Test func switchingDeviceRestartsOnTheNewOne() {
        let (s, cam) = rig()
        s.open()
        s.switchDevice(to: "ext")
        #expect(cam.started == ["built", "ext"] && s.activeDeviceID == "ext" && s.settings.preferredDeviceID == "ext")
        #expect(cam.running)
    }

    @Test func switchingWhileClosedDoesNothing() {
        let (s, cam) = rig()
        s.switchDevice(to: "ext")
        #expect(cam.started.isEmpty && s.state == .closed)
    }

    @Test func unplugActiveCameraFallsBack() {
        var set = CameraSettings()
        set.preferredDeviceID = "ext"
        let (s, cam) = rig(settings: set)
        s.open()
        cam.list.removeAll { $0.id == "ext" }
        s.devicesChanged()
        #expect(s.activeDeviceID == "built" && cam.running)
    }

    @Test func unplugEverythingShowsNoDevice() {
        let (s, cam) = rig()
        s.open()
        cam.list = []
        s.devicesChanged()
        #expect(s.state == .noDevice && !cam.running)
    }

    @Test func plugInRecoversFromNoDevice() {
        let (s, cam) = rig { $0.list = [] }
        s.open()
        cam.list = [CameraDevice(id: "new", name: "USB", isBuiltIn: false)]
        s.devicesChanged()
        #expect(s.state == .running(deviceName: "USB"))
    }

    @Test func unrelatedDeviceChangesKeepTheStream() {
        let (s, cam) = rig()
        s.open()
        cam.list.append(CameraDevice(id: "extra", name: "Another"))
        s.devicesChanged()
        #expect(cam.started == ["built"] && cam.stops == 0)
    }

    @Test func deviceChangesWhileClosedNeverStartTheCamera() {
        let (s, cam) = rig()
        s.devicesChanged()
        #expect(cam.started.isEmpty && !cam.running)
    }

    @Test func changeCallbackFiresOnEveryTransition() {
        let (s, _) = rig()
        var n = 0
        s.onChange = { n += 1 }
        s.open(); s.close()
        #expect(n == 2)
    }
}

@Suite struct CameraGeometryTests {
    private let screen = CGRect(x: 0, y: 25, width: 1500, height: 900)

    @Test func cornersRespectTheMargin() {
        let m = CameraWindowGeometry.margin
        let size = CameraWindowGeometry.size(.medium, shape: .rounded)
        let br = CameraWindowGeometry.frame(size: .medium, shape: .rounded, corner: .bottomRight, in: screen)
        #expect(br.maxX == screen.maxX - m && br.minY == screen.minY + m && br.size == size)
        let tl = CameraWindowGeometry.frame(size: .medium, shape: .rounded, corner: .topLeft, in: screen)
        #expect(tl.minX == screen.minX + m && tl.maxY == screen.maxY - m)
        let tr = CameraWindowGeometry.frame(size: .medium, shape: .rounded, corner: .topRight, in: screen)
        #expect(tr.maxX == screen.maxX - m && tr.maxY == screen.maxY - m)
        let bl = CameraWindowGeometry.frame(size: .medium, shape: .rounded, corner: .bottomLeft, in: screen)
        #expect(bl.minX == screen.minX + m && bl.minY == screen.minY + m)
    }

    @Test func centerIsCentered() {
        let f = CameraWindowGeometry.frame(size: .large, shape: .rounded, corner: .center, in: screen)
        #expect(abs(f.midX - screen.midX) <= 1 && abs(f.midY - screen.midY) <= 1)
    }

    @Test func circleIsSquare() {
        let s = CameraWindowGeometry.size(.small, shape: .circle)
        #expect(s.width == s.height && s.width == CameraSize.small.width)
        let r = CameraWindowGeometry.size(.small, shape: .rounded)
        #expect(abs(r.width / r.height - 16.0 / 9.0) < 0.02)
    }

    @Test func sizesAreOrdered() {
        #expect(CameraSize.small.width < CameraSize.medium.width && CameraSize.medium.width < CameraSize.large.width)
    }

    @Test func oversizedWindowShrinksToFitTinyScreens() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let f = CameraWindowGeometry.frame(size: .large, shape: .rounded, corner: .bottomRight, in: tiny)
        #expect(f.width <= tiny.width - 48 + 1 && f.height <= tiny.height - 48 + 1)
        #expect(tiny.contains(f))
    }

    @Test func draggedFrameIsClampedBackOnScreen() {
        let off = CGRect(x: 1400, y: -50, width: 340, height: 191)
        let c = CameraWindowGeometry.clamped(off, in: screen)
        #expect(screen.contains(c) && c.size == off.size)
        #expect(CameraWindowGeometry.clamped(CGRect(x: 100, y: 100, width: 340, height: 191), in: screen).origin == CGPoint(x: 100, y: 100))
    }
}

@Suite struct CameraSettingsStoreTests {
    @Test func defaultsAreMirroredMediumBottomRight() {
        let s = CameraSettings()
        #expect(s.mirror && s.size == .medium && s.shape == .rounded && s.corner == .bottomRight && s.keepOnTop && s.preferredDeviceID.isEmpty)
    }

    @Test func roundTripWritesOnlyDifferences() {
        let kv = WndMemoryStore()
        let store = CameraSettingsStore(kv)
        store.save(CameraSettings())
        #expect(kv.values.isEmpty)
        var s = CameraSettings()
        s.mirror = false; s.size = .large; s.shape = .circle; s.corner = .topLeft; s.preferredDeviceID = "abc"; s.keepOnTop = false
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("cameraPreview.") })
    }

    @Test func unknownValuesFallBack() {
        let kv = WndMemoryStore()
        kv.set("huge", forKey: "cameraPreview.size")
        kv.set("hex", forKey: "cameraPreview.shape")
        #expect(CameraSettingsStore(kv).load() == CameraSettings())
    }
}
