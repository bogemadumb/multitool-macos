import Foundation
import CoreGraphics

public struct WndWindow: Equatable, Hashable, Sendable {
    public var key: Int
    public var pid: Int32
    public var bundleID: String?

    public init(key: Int, pid: Int32, bundleID: String? = nil) {
        self.key = key
        self.pid = pid
        self.bundleID = bundleID
    }
}

public protocol WindowDriving: AnyObject {
    func focusedWindow() -> WndWindow?
    func window(at point: CGPoint) -> WndWindow?
    func frame(of window: WndWindow) -> CGRect?
    func setFrame(_ frame: CGRect, of window: WndWindow) -> Bool
    func isManageable(_ window: WndWindow) -> Bool
    func raise(_ window: WndWindow)
    func displays() -> [WndDisplay]
}

public enum WindowLayoutOutcome: Equatable, Sendable {
    case applied(WindowLayoutAction, CGRect)
    case restored(CGRect)
    case nothingToRestore
    case singleDisplay
    case noWindow
    case notManageable
    case ignoredApp
    case noDisplay
    case failed

    public var isSuccess: Bool {
        switch self {
        case .applied, .restored: true
        default: false
        }
    }

    public var message: String? {
        switch self {
        case .nothingToRestore: "Нечего возвращать: окно не двигали"
        case .singleDisplay: "Подключён один дисплей"
        case .noWindow: "Нет активного окна"
        case .notManageable: "Это окно нельзя двигать"
        case .failed: "Приложение не дало изменить окно"
        default: nil
        }
    }
}

public final class WindowLayoutEngine {
    public private(set) var history = WindowHistory()
    private let driver: WindowDriving
    private let settingsProvider: () -> WindowLayoutSettings

    public init(driver: WindowDriving, settings: @escaping () -> WindowLayoutSettings) {
        self.driver = driver
        self.settingsProvider = settings
    }

    public func forget(_ window: WndWindow) { history.forget(window.key) }

    @discardableResult
    public func perform(_ pressed: WindowLayoutAction) -> WindowLayoutOutcome {
        guard let w = driver.focusedWindow() else { return .noWindow }
        return perform(pressed, on: w)
    }

    @discardableResult
    public func perform(_ pressed: WindowLayoutAction, on w: WndWindow) -> WindowLayoutOutcome {
        let s = settingsProvider()
        if s.ignoredApps.contains(w.bundleID) { return .ignoredApp }
        guard driver.isManageable(w), let current = driver.frame(of: w) else { return .notManageable }
        let displays = driver.displays()
        guard let src = DisplayMap.index(containing: current, in: displays) else { return .noDisplay }
        let record = history.continuing(current, for: w.key)
        switch pressed {
        case .restore:
            return restore(w, current: current, displays: displays)
        case .nextDisplay, .previousDisplay:
            guard let dst = DisplayMap.step(from: src, by: pressed == .nextDisplay ? 1 : -1, in: displays) else { return .singleDisplay }
            return move(w, current: current, record: record, pressed: pressed, from: src, to: dst, displays: displays, settings: s)
        default:
            var effective = pressed
            var index = src
            switch WindowLayoutPlanner.resolve(pressed, record: record, mode: s.repeatMode) {
            case .place(let a):
                effective = a
            case .cross(let a, let dir):
                if let n = DisplayMap.neighbour(of: src, direction: dir, in: displays) {
                    effective = a
                    index = n
                }
            }
            return place(effective, pressed: pressed, on: w, displayIndex: index, reference: current, record: record, displays: displays, settings: s)
        }
    }

    @discardableResult
    public func place(_ action: WindowLayoutAction, on w: WndWindow, displayIndex: Int, reference: CGRect) -> WindowLayoutOutcome {
        let s = settingsProvider()
        if s.ignoredApp(w) { return .ignoredApp }
        guard driver.isManageable(w) else { return .notManageable }
        let displays = driver.displays()
        guard displays.indices.contains(displayIndex) else { return .noDisplay }
        let record = history.continuing(reference, for: w.key)
        return place(action, pressed: action, on: w, displayIndex: displayIndex, reference: reference, record: record, displays: displays, settings: s)
    }

    private func place(_ effective: WindowLayoutAction, pressed: WindowLayoutAction, on w: WndWindow, displayIndex: Int, reference: CGRect, record: WindowRecord?, displays: [WndDisplay], settings s: WindowLayoutSettings) -> WindowLayoutOutcome {
        let display = displays[displayIndex]
        let current = driver.frame(of: w) ?? reference
        guard let target = WindowGeometry.rect(for: effective, current: current, visible: display.visible, gaps: s.gaps, marginPercent: s.marginPercent, custom: s.customRect(for: effective)) else { return .failed }
        return commit(target, effective: effective, pressed: pressed, window: w, display: display, original: record == nil ? reference : nil)
    }

    private func move(_ w: WndWindow, current: CGRect, record: WindowRecord?, pressed: WindowLayoutAction, from src: Int, to dst: Int, displays: [WndDisplay], settings s: WindowLayoutSettings) -> WindowLayoutOutcome {
        let target: CGRect
        var effective = pressed
        if let r = record, let placed = WindowGeometry.rect(for: r.effective, current: current, visible: displays[dst].visible, gaps: s.gaps, marginPercent: s.marginPercent, custom: s.customRect(for: r.effective)) {
            target = placed
            effective = r.effective
        } else {
            target = DisplayMap.transfer(current, from: displays[src], to: displays[dst], gaps: s.gaps)
        }
        return commit(target, effective: effective, pressed: pressed, window: w, display: displays[dst], original: record == nil ? current : nil)
    }

    private func restore(_ w: WndWindow, current: CGRect, displays: [WndDisplay]) -> WindowLayoutOutcome {
        guard let original = history.popOriginal(for: w.key) else { return .nothingToRestore }
        history.clearRecord(for: w.key)
        let target = DisplayMap.reposition(original, displays: displays)
        guard driver.setFrame(target, of: w) else { return .failed }
        let actual = driver.frame(of: w) ?? target
        return .restored(actual)
    }

    private func commit(_ target: CGRect, effective: WindowLayoutAction, pressed: WindowLayoutAction, window w: WndWindow, display: WndDisplay, original: CGRect?) -> WindowLayoutOutcome {
        guard driver.setFrame(target, of: w) else { return .failed }
        if let original { history.pushOriginal(original, for: w.key) }
        var actual = driver.frame(of: w) ?? target
        if !WindowGeometry.approxSize(actual.size, target.size) {
            let settled = WindowGeometry.settle(target: target, actualSize: actual.size, area: display.visible)
            if !WindowGeometry.approxEqual(settled, actual, tolerance: 1), driver.setFrame(settled, of: w) {
                actual = driver.frame(of: w) ?? settled
            }
        }
        history.setRecord(WindowRecord(pressed: pressed, effective: effective, requested: target, actual: actual, displayID: display.id), for: w.key)
        return .applied(effective, actual)
    }

    public func previewFrame(for action: WindowLayoutAction, at pointer: CGPoint) -> (frame: CGRect, display: WndDisplay)? {
        let s = settingsProvider()
        let displays = driver.displays()
        guard let i = DisplayMap.index(containing: pointer, in: displays),
              let f = WindowGeometry.rect(for: action, current: displays[i].visible, visible: displays[i].visible, gaps: s.gaps, marginPercent: s.marginPercent, custom: s.customRect(for: action)) else { return nil }
        return (f, displays[i])
    }

    public func cursorDestination(from pointer: CGPoint) -> CGPoint? {
        DisplayMap.cursorDestination(from: pointer, displays: driver.displays())
    }
}

extension WindowLayoutSettings {
    func ignoredApp(_ w: WndWindow) -> Bool { ignoredApps.contains(w.bundleID) }
}
