import SwiftUI
import AppKit
import Metal
import QuartzCore
import IOKit.ps
import MultitulCore
import MultitulUI

@MainActor
final class XdrOverlayLayer {
    let window: NSWindow
    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let multiply: Bool

    init?(frame: NSRect, device: MTLDevice, queue: MTLCommandQueue, multiply: Bool) {
        self.queue = queue
        self.multiply = multiply
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.frame = CGRect(origin: .zero, size: frame.size)
        layer.contentsGravity = .resize
        if multiply { layer.compositingFilter = "multiply" }
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
    }

    func render(value: Double) {
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: multiply ? 1 : 0.01)
        cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil); window.contentView = nil }
}

@MainActor
final class ExtraBrightnessController: ObservableObject {
    static let shared = ExtraBrightnessController()

    @Published private(set) var availability: XdrAvailability = .unavailable(.noHeadroom)
    @Published private(set) var settings = ExtraBrightnessSettings.load()
    @Published private(set) var isOn = false
    @Published private(set) var boosting = false
    @Published private(set) var note: String?

    private var overlay: XdrOverlayLayer?
    private var trigger: XdrOverlayLayer?
    private var timer: Timer?
    private var factor = 1.0
    private var observer: NSObjectProtocol?
    private var overlayDisplay: UInt32?

    private var isRunning = false

    func start() {
        isRunning = true
        settings = ExtraBrightnessSettings.load()
        refreshAvailability()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func stop() {
        isRunning = false
        isOn = false
        teardown()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    private func screensChanged() {
        refreshAvailability()
        if isOn { rebuild() }
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func builtinScreen() -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { s in
            guard let n = (s.deviceDescription[key] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(n) != 0
        }
    }

    func refreshAvailability() {
        guard let s = builtinScreen() ?? NSScreen.main else { availability = .unavailable(.notBuiltin); return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let id = (s.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        availability = ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: CGDisplayIsBuiltin(id) != 0,
                                                                        potentialEDR: Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue),
                                                                        modelIdentifier: Self.modelIdentifier()))
        if !availability.isAvailable && isOn { setOn(false) }
    }

    func setOn(_ on: Bool) {
        guard isRunning else { return }
        if on {
            guard availability.isAvailable else { note = "Включить нельзя: экран не подходит"; return }
            isOn = true
            note = nil
            rebuild()
        } else {
            isOn = false
            teardown()
        }
    }

    func setLevel(_ v: Double) {
        settings.level = BrightnessStep.clamp(v)
        settings.save()
        if isOn { tick(immediate: true) }
    }

    func setAutoOff(_ on: Bool) {
        settings.autoOffOnBattery = on
        settings.save()
    }

    private func rebuild() {
        teardown()
        guard isOn, let screen = builtinScreen(), let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            note = "Metal недоступен или нет встроенного экрана"
            isOn = false
            return
        }
        let f = screen.frame
        let corner = NSRect(x: f.minX, y: f.minY, width: 1, height: 1)
        guard let ov = XdrOverlayLayer(frame: f, device: device, queue: queue, multiply: true),
              let tr = XdrOverlayLayer(frame: corner, device: device, queue: queue, multiply: false) else { return }
        overlay = ov
        trigger = tr
        factor = 1
        ov.show()
        tr.show()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(immediate: false) }
        }
        tick(immediate: true)
        Log.write("extraBrightness overlay up")
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        overlay?.close()
        trigger?.close()
        overlay = nil
        trigger = nil
        boosting = false
        factor = 1
    }

    private func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    private func tick(immediate: Bool) {
        guard isOn, let overlay, let trigger, let screen = builtinScreen() else { return }
        guard case .available(let maxGain) = availability else { return }
        let allowed = ExtraBrightnessLogic.shouldBoost(enabled: true, available: true, onBattery: onBattery(), autoOffOnBattery: settings.autoOffOnBattery,
                                                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let target = allowed ? ExtraBrightnessLogic.effectiveFactor(target: ExtraBrightnessLogic.gain(level: settings.level, maxGain: maxGain),
                                                                    currentEDR: Double(screen.maximumExtendedDynamicRangeColorComponentValue)) : 1
        let next = immediate ? target : ExtraBrightnessLogic.ramp(current: factor, target: target)
        trigger.render(value: max(next, 1.0001))
        if next != factor || immediate {
            factor = next
            overlay.render(value: next)
        }
        boosting = next > 1.001
        note = allowed ? nil : "Пауза: работа от батареи"
    }
}

@MainActor
final class ExtraBrightnessModule: Module {
    let info = ModuleID.extraBrightness.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(ExtraBrightnessTile()) }

    func start() {
        ExtraBrightnessController.shared.start()
        Log.write("module extraBrightness start")
    }

    func stop() {
        ExtraBrightnessController.shared.stop()
        Log.write("module extraBrightness stop")
    }
}

struct ExtraBrightnessTile: View {
    @ObservedObject private var c = ExtraBrightnessController.shared

    var body: some View {
        QuickTile(symbol: "sun.max.fill", caption: "Яркость+", active: c.isOn, enabled: c.availability.isAvailable,
                  help: c.availability.isAvailable ? "Яркость выше максимума" : "Недоступно на этом экране") {
            if c.availability.isAvailable { c.setOn(!c.isOn) }
        }
    }
}

struct ExtraBrightnessSections: View {
    @ObservedObject private var c = ExtraBrightnessController.shared

    var body: some View {
        Section {
            if c.availability.isAvailable {
                Toggle("Включить", isOn: Binding(get: { c.isOn }, set: { c.setOn($0) }))
            } else {
                LabeledContent("Состояние") { Text("недоступно").foregroundStyle(.secondary) }
            }
            if case .unavailable(let reason) = c.availability {
                Text(reason.text).font(.caption).foregroundStyle(.secondary)
            } else {
                SymbolSlider("Уровень", symbol: "sun.max.fill", value: Binding(get: { c.settings.level * 100 }, set: { c.setLevel($0 / 100) }))
                Toggle("Выключать на батарее и в режиме экономии", isOn: Binding(get: { c.settings.autoOffOnBattery }, set: { c.setAutoOff($0) }))
            }
        } header: { Text("Яркость выше максимума") } footer: {
            SectionFooter([ "Не проверено на железе. Использует HDR-запас XDR-дисплея: греется и ест батарею.",
                            c.isOn ? (c.boosting ? "Усиление включено." : "Ждём запас HDR от macOS.") : nil,
                            c.note ].compactMap { $0 }.joined(separator: " "))
        }
        .onAppear { c.refreshAvailability() }
    }
}
