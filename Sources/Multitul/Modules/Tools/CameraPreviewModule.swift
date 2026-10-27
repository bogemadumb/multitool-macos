import SwiftUI
import AppKit
import AVFoundation
import MultitulCore
import MultitulUI

final class CameraPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CameraLayerView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    let message = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private let closeButton = NSButton()

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        message.textColor = NSColor(white: 1, alpha: 0.8)
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.alignment = .center
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        addSubview(message)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Закрыть")
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 1, alpha: 0.85)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.alphaValue = 0
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @objc private func closeTapped() { onClose?() }
    override func mouseEntered(with event: NSEvent) { closeButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.animator().alphaValue = 0 }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        message.frame = bounds.insetBy(dx: 16, dy: 0)
        message.frame.origin.y = (bounds.height - 56) / 2
        message.frame.size.height = 56
        closeButton.frame = NSRect(x: bounds.width - 30, y: bounds.height - 30, width: 22, height: 22)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    func apply(mirror: Bool, circle: Bool) {
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
        layer?.cornerRadius = circle ? min(bounds.width, bounds.height) / 2 : 14
        layer?.cornerCurve = .continuous
    }
}

@MainActor
final class CameraPreviewController: ObservableObject {
    static let shared = CameraPreviewController()

    @Published private(set) var settings = CameraSettings()
    @Published private(set) var state = CameraState.closed
    @Published private(set) var devices: [CameraDevice] = []

    private let store = CameraSettingsStore()
    private let driver = AVCameraDriver()
    private var session: CameraPreviewSession
    private var panel: CameraPanel?
    private var layerView: CameraLayerView?
    private var observers: [NSObjectProtocol] = []
    private var panelObservers: [NSObjectProtocol] = []
    private var running = false
    let spec = CameraHotkeys.toggle

    private init() {
        session = CameraPreviewSession(driver: driver)
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        session = CameraPreviewSession(driver: driver, settings: settings)
        session.onChange = { [weak self] in self?.sync() }
        HotkeyManager.shared.register(spec, owner: ModuleID.cameraPreview.rawValue) { [weak self] in self?.toggle() }
        ToolsRouter.shared.register(.cameraPreview) { [weak self] in self?.toggle() }
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            })
        }
        devices = driver.devices()
    }

    func stop() {
        guard running else { return }
        running = false
        close()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        HotkeyManager.shared.unregisterAll(owner: ModuleID.cameraPreview.rawValue)
        ToolsRouter.shared.unregister(.cameraPreview)
    }

    func update(_ s: CameraSettings) {
        settings = s
        store.save(s)
        session.settings = s
        applyLayout(reposition: true)
    }

    func toggle() { state.isWindowOpen ? close() : open() }

    func open() {
        guard running else { return }
        ensurePanel()
        devices = driver.devices()
        session.settings = settings
        session.open()
        applyLayout(reposition: true)
        NSApp.activate(ignoringOtherApps: true)
        panel?.orderFrontRegardless()
    }

    func close() {
        for o in panelObservers { NotificationCenter.default.removeObserver(o) }
        panelObservers = []
        session.close()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        layerView = nil
    }

    func switchDevice(_ id: String) {
        session.switchDevice(to: id)
        var s = settings
        s.preferredDeviceID = id
        settings = s
        store.save(s)
    }

    private func devicesChanged() {
        devices = driver.devices()
        session.devicesChanged()
    }

    private func sync() {
        state = session.state
        layerView?.message.stringValue = message(for: session.state)
        layerView?.message.isHidden = { if case .running = session.state { return true } else { return false } }()
        if case .closed = session.state { panel?.orderOut(nil) }
    }

    private func message(for s: CameraState) -> String {
        switch s {
        case .requesting: "Разреши доступ к камере"
        case .denied: "Нет доступа к камере.\nВыдай его в «Конфиденциальность и безопасность»"
        case .noDevice: "Камера не найдена"
        case .failed: "Камера занята или недоступна"
        default: ""
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let f = CameraWindowGeometry.frame(size: settings.size, shape: settings.shape, corner: settings.corner, in: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let p = CameraPanel(contentRect: f, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = CameraLayerView(session: driver.session)
        v.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        v.onClose = { [weak self] in self?.close() }
        p.contentView = v
        layerView = v
        panel = p
        panelObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: driver.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layerView?.apply(mirror: self?.settings.mirror ?? true, circle: self?.settings.shape == .circle) }
        })
        panelObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layerView?.apply(mirror: self?.settings.mirror ?? true, circle: self?.settings.shape == .circle) }
        })
    }

    private func applyLayout(reposition: Bool) {
        guard let p = panel, let v = layerView else { return }
        p.level = settings.keepOnTop ? .floating : .normal
        if reposition {
            let vis = (p.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            p.setFrame(CameraWindowGeometry.frame(size: settings.size, shape: settings.shape, corner: settings.corner, in: vis), display: true)
        }
        p.aspectRatio = NSSize(width: settings.shape.aspect, height: 1)
        v.apply(mirror: settings.mirror, circle: settings.shape == .circle)
        sync()
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        for d in devices {
            let item = NSMenuItem(title: d.name, action: #selector(MenuTarget.pickDevice(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.representedObject = d.id
            item.state = (state == .running(deviceName: d.name)) ? .on : .off
            m.addItem(item)
        }
        if !devices.isEmpty { m.addItem(.separator()) }
        let mirror = NSMenuItem(title: "Отразить по горизонтали", action: #selector(MenuTarget.toggleMirror), keyEquivalent: "")
        mirror.target = menuTarget
        mirror.state = settings.mirror ? .on : .off
        m.addItem(mirror)
        let close = NSMenuItem(title: "Закрыть", action: #selector(MenuTarget.closeWindow), keyEquivalent: "")
        close.target = menuTarget
        m.addItem(close)
        return m
    }

    private lazy var menuTarget = MenuTarget(owner: self)

    @MainActor
    final class MenuTarget: NSObject {
        unowned let owner: CameraPreviewController
        init(owner: CameraPreviewController) { self.owner = owner }
        @objc func pickDevice(_ item: NSMenuItem) { if let id = item.representedObject as? String { owner.switchDevice(id) } }
        @objc func toggleMirror() { var s = owner.settings; s.mirror.toggle(); owner.update(s) }
        @objc func closeWindow() { owner.close() }
    }
}

@MainActor
final class CameraPreviewModule: Module {
    let info = ModuleID.cameraPreview.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(CameraTile()) }

    func start() { CameraPreviewController.shared.start(); Log.write("module cameraPreview start") }
    func stop() { CameraPreviewController.shared.stop(); Log.write("module cameraPreview stop") }
}

struct CameraTile: View {
    @ObservedObject private var c = CameraPreviewController.shared

    var body: some View {
        QuickTile(symbol: "video", caption: "Камера", active: c.state.isWindowOpen) { c.toggle() }
    }
}

struct CameraPreviewSections: View {
    @ObservedObject private var c = CameraPreviewController.shared

    private func binding<T>(_ kp: WritableKeyPath<CameraSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var status: String {
        switch c.state {
        case .closed: "окно закрыто, камера выключена"
        case .requesting: "ждём разрешения"
        case .running(let n): n
        case .denied: "нет доступа"
        case .noDevice: "камера не найдена"
        case .failed: "камера недоступна"
        }
    }

    var body: some View {
        ToolsPermissionNote(permission: .camera, text: "Нужен доступ к камере. Камера включается только пока окно открыто.")
        Section {
            LabeledContent("Состояние", value: status)
            Button(c.state.isWindowOpen ? "Закрыть окно камеры" : "Показать окно камеры") { c.toggle() }
        } header: { Text("Зеркало камеры") }
        Section("Камера и окно") {
            Picker(selection: binding(\.preferredDeviceID)) {
                Text("Автоматически").tag("")
                ForEach(c.devices) { Text($0.name).tag($0.id) }
            } label: { SettingLabel("Камера", "Если выбранной нет, берётся встроенная") }
            Picker("Размер окна", selection: binding(\.size)) { ForEach(CameraSize.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Форма", selection: binding(\.shape)) { ForEach(CameraShape.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Где появляется", selection: binding(\.corner)) { ForEach(CameraCorner.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle(isOn: binding(\.mirror)) { SettingLabel("Зеркальное изображение", "Как в зеркале; на созвоне собеседник видит без отражения") }
            Toggle(isOn: binding(\.keepOnTop)) { SettingLabel("Поверх всех окон", "Окно с камерой не прячется за другими") }
        }
    }
}
