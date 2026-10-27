import Foundation

public enum DockRearrange: Equatable, Sendable {
    case absent
    case on
    case off
    case managed
    case unknown
}

public protocol DockPreferenceDriving: AnyObject {
    func readRearrange() -> DockRearrange
    func writeRearrange(_ value: Bool?) -> Bool
    func restartDock() -> Bool
}

public enum SpacesRestore: String, Sendable {
    case alreadyOff
    case wasAbsent
    case wasOn
}

public enum SpacesOrderResult: Equatable, Sendable {
    case held
    case alreadyHeld
    case released
    case nothingToRelease
    case userTookBack
    case blockedByProfile
    case failed(String)
}

public final class SpacesOrderHold {
    public static let markerKey = "spacesOrder.restore"
    private let driver: DockPreferenceDriving
    private let store: KeyValueStoring

    public init(driver: DockPreferenceDriving, store: KeyValueStoring) {
        self.driver = driver
        self.store = store
    }

    public var marker: SpacesRestore? {
        (store.object(forKey: Self.markerKey) as? String).flatMap(SpacesRestore.init(rawValue:))
    }

    public var isHolding: Bool { marker != nil }

    private func setMarker(_ m: SpacesRestore?) {
        if let m { store.set(m.rawValue, forKey: Self.markerKey) } else { store.removeObject(forKey: Self.markerKey) }
    }

    @discardableResult
    public func hold() -> SpacesOrderResult {
        let current = driver.readRearrange()
        if marker != nil {
            if current == .on || current == .absent { return rewrite(current) }
            return .alreadyHeld
        }
        switch current {
        case .managed: return .blockedByProfile
        case .unknown: return .failed("не удалось прочитать настройку Dock")
        case .off:
            setMarker(.alreadyOff)
            return .held
        case .on, .absent:
            return rewrite(current)
        }
    }

    private func rewrite(_ current: DockRearrange) -> SpacesOrderResult {
        let created = marker == nil
        if created { setMarker(current == .on ? .wasOn : .wasAbsent) }
        guard driver.writeRearrange(false) else {
            if created { setMarker(nil) }
            return .failed("запись настройки Dock не удалась")
        }
        guard driver.restartDock() else { return .failed("Dock не перезапустился") }
        return .held
    }

    @discardableResult
    public func release() -> SpacesOrderResult {
        guard let m = marker else { return .nothingToRelease }
        switch m {
        case .alreadyOff:
            setMarker(nil)
            return .released
        case .wasAbsent, .wasOn:
            let current = driver.readRearrange()
            if current == .managed { setMarker(nil); return .blockedByProfile }
            if current == .on || current == .absent {
                setMarker(nil)
                return .userTookBack
            }
            guard driver.writeRearrange(m == .wasOn ? true : nil) else { return .failed("запись настройки Dock не удалась") }
            setMarker(nil)
            guard driver.restartDock() else { return .failed("Dock не перезапустился") }
            return .released
        }
    }

    public func userOverrode() -> Bool {
        guard let m = marker, m != .alreadyOff else { return false }
        let current = driver.readRearrange()
        return current == .on || current == .absent
    }

    @discardableResult
    public func reconcile() -> SpacesOrderResult? {
        guard userOverrode() else { return nil }
        setMarker(nil)
        return .userTookBack
    }
}
