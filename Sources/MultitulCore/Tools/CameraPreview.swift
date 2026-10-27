import Foundation
import CoreGraphics

public enum CameraShape: String, CaseIterable, Sendable {
    case rounded, circle

    public var title: String { self == .rounded ? "Прямоугольник" : "Круг" }
    public var aspect: Double { self == .circle ? 1 : 16.0 / 9.0 }
}

public enum CameraSize: String, CaseIterable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "Маленькое"
        case .medium: "Среднее"
        case .large: "Большое"
        }
    }

    public var width: Double {
        switch self {
        case .small: 220
        case .medium: 340
        case .large: 520
        }
    }
}

public enum CameraCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    public var title: String {
        switch self {
        case .topLeft: "Слева сверху"
        case .topRight: "Справа сверху"
        case .bottomLeft: "Слева снизу"
        case .bottomRight: "Справа снизу"
        case .center: "По центру"
        }
    }
}

public struct CameraSettings: Equatable, Sendable {
    public var mirror = true
    public var size = CameraSize.medium
    public var shape = CameraShape.rounded
    public var corner = CameraCorner.bottomRight
    public var preferredDeviceID = ""
    public var keepOnTop = true

    public init() {}
}

public final class CameraSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> CameraSettings {
        var s = CameraSettings()
        let p = "cameraPreview."
        s.mirror = a.bool(p + "mirror", s.mirror)
        if let v = a.string(p + "size"), let x = CameraSize(rawValue: v) { s.size = x }
        if let v = a.string(p + "shape"), let x = CameraShape(rawValue: v) { s.shape = x }
        if let v = a.string(p + "corner"), let x = CameraCorner(rawValue: v) { s.corner = x }
        s.preferredDeviceID = a.string(p + "device") ?? ""
        s.keepOnTop = a.bool(p + "keepOnTop", s.keepOnTop)
        return s
    }

    public func save(_ s: CameraSettings) {
        let b = CameraSettings()
        let p = "cameraPreview."
        a.put(p + "mirror", s.mirror, b.mirror)
        a.put(p + "size", s.size.rawValue, b.size.rawValue)
        a.put(p + "shape", s.shape.rawValue, b.shape.rawValue)
        a.put(p + "corner", s.corner.rawValue, b.corner.rawValue)
        a.put(p + "device", s.preferredDeviceID, b.preferredDeviceID)
        a.put(p + "keepOnTop", s.keepOnTop, b.keepOnTop)
    }
}

public struct CameraDevice: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

public enum CameraAuthorization: Equatable, Sendable {
    case authorized, denied, notDetermined
}

public enum CameraDeviceChooser {
    public static func choose(preferred: String, from devices: [CameraDevice]) -> CameraDevice? {
        if !preferred.isEmpty, let d = devices.first(where: { $0.id == preferred }) { return d }
        return devices.first(where: { $0.isBuiltIn }) ?? devices.first
    }
}

public protocol CameraDriving: AnyObject {
    func authorization() -> CameraAuthorization
    func requestAccess(_ completion: @escaping (Bool) -> Void)
    func devices() -> [CameraDevice]
    func start(deviceID: String) -> Bool
    func stop()
    var isRunning: Bool { get }
}

public enum CameraState: Equatable, Sendable {
    case closed, requesting, running(deviceName: String), denied, noDevice, failed

    public var isWindowOpen: Bool { self != .closed }
}

public final class CameraPreviewSession {
    public private(set) var state = CameraState.closed
    public private(set) var activeDeviceID: String?
    public var settings: CameraSettings
    public var onChange: (() -> Void)?
    private let driver: CameraDriving

    public init(driver: CameraDriving, settings: CameraSettings = CameraSettings()) {
        self.driver = driver
        self.settings = settings
    }

    public func open() {
        guard state == .closed || state == .denied || state == .noDevice || state == .failed else { return }
        switch driver.authorization() {
        case .authorized: begin()
        case .denied: set(.denied)
        case .notDetermined:
            set(.requesting)
            driver.requestAccess { [weak self] ok in
                guard let self, self.state == .requesting else { return }
                if ok { self.begin() } else { self.set(.denied) }
            }
        }
    }

    public func close() {
        driver.stop()
        activeDeviceID = nil
        set(.closed)
    }

    public func toggle() {
        if state == .closed { open() } else { close() }
    }

    public func switchDevice(to id: String) {
        guard state.isWindowOpen else { return }
        settings.preferredDeviceID = id
        driver.stop()
        begin()
    }

    public func devicesChanged() {
        guard state.isWindowOpen, state != .requesting, state != .denied else { return }
        let list = driver.devices()
        if case .running = state, let id = activeDeviceID, list.contains(where: { $0.id == id }) { return }
        driver.stop()
        begin()
    }

    private func begin() {
        let list = driver.devices()
        guard let d = CameraDeviceChooser.choose(preferred: settings.preferredDeviceID, from: list) else {
            activeDeviceID = nil
            set(.noDevice)
            return
        }
        if driver.start(deviceID: d.id) {
            activeDeviceID = d.id
            set(.running(deviceName: d.name))
        } else {
            activeDeviceID = nil
            set(.failed)
        }
    }

    private func set(_ s: CameraState) {
        state = s
        onChange?()
    }
}

public enum CameraWindowGeometry {
    public static let margin = 24.0

    public static func size(_ size: CameraSize, shape: CameraShape) -> CGSize {
        CGSize(width: size.width, height: (size.width / shape.aspect).rounded())
    }

    public static func frame(size: CameraSize, shape: CameraShape, corner: CameraCorner, in visible: CGRect) -> CGRect {
        var s = Self.size(size, shape: shape)
        let maxW = max(visible.width - margin * 2, 80), maxH = max(visible.height - margin * 2, 80)
        if s.width > maxW || s.height > maxH {
            let k = min(maxW / s.width, maxH / s.height)
            s = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        }
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft: x = visible.minX + margin; y = visible.maxY - margin - s.height
        case .topRight: x = visible.maxX - margin - s.width; y = visible.maxY - margin - s.height
        case .bottomLeft: x = visible.minX + margin; y = visible.minY + margin
        case .bottomRight: x = visible.maxX - margin - s.width; y = visible.minY + margin
        case .center: x = visible.midX - s.width / 2; y = visible.midY - s.height / 2
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: s)
    }

    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX), max(visible.maxX - f.width, visible.minX))
        f.origin.y = min(max(f.origin.y, visible.minY), max(visible.maxY - f.height, visible.minY))
        return f
    }
}

public enum CameraHotkeys {
    public static let toggle = HotkeySpec(id: "cameraPreview.toggle", title: "Зеркало камеры: показать или скрыть", defaultCombo: .none)
}
