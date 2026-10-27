import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import CoreBluetooth
import UserNotifications

public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, inputMonitoring, automation, notifications
    case fullDiskAccess, camera, microphone, calendars, bluetooth, systemAudio, appManagement

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: "Универсальный доступ"
        case .screenRecording: "Запись экрана"
        case .inputMonitoring: "Мониторинг ввода"
        case .automation: "Автоматизация"
        case .notifications: "Уведомления"
        case .fullDiskAccess: "Полный доступ к диску"
        case .camera: "Камера"
        case .microphone: "Микрофон"
        case .calendars: "Календари"
        case .bluetooth: "Bluetooth"
        case .systemAudio: "Звук системы"
        case .appManagement: "Управление приложениями"
        }
    }

    public var symbol: String {
        switch self {
        case .accessibility: "accessibility.fill"
        case .screenRecording: "rectangle.inset.filled.badge.record"
        case .inputMonitoring: "keyboard.fill"
        case .automation: "gearshape.2.fill"
        case .notifications: "bell.badge.fill"
        case .fullDiskAccess: "internaldrive.fill"
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .calendars: "calendar"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .systemAudio: "waveform"
        case .appManagement: "app.badge.checkmark"
        }
    }

    public var settingsURL: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        switch self {
        case .accessibility: return base + "Accessibility"
        case .screenRecording: return base + "ScreenCapture"
        case .inputMonitoring: return base + "ListenEvent"
        case .automation: return base + "Automation"
        case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .fullDiskAccess: return base + "AllFiles"
        case .camera: return base + "Camera"
        case .microphone: return base + "Microphone"
        case .calendars: return base + "Calendars"
        case .bluetooth: return base + "Bluetooth"
        case .systemAudio: return base + "AudioCapture"
        case .appManagement: return base + "AppBundles"
        }
    }
}

public enum PermissionStatus: Equatable, Sendable {
    case granted, denied, undetermined, unknown

    public var label: String {
        switch self {
        case .granted: "выдано"
        case .denied: "нет доступа"
        case .undetermined: "не запрошено"
        case .unknown: "не проверяется"
        }
    }
}

@MainActor
public final class Permissions: ObservableObject {
    public static let shared = Permissions()

    @Published public private(set) var status: [Permission: PermissionStatus] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func state(_ p: Permission) -> PermissionStatus { status[p] ?? .unknown }

    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    public func refresh() {
        var s: [Permission: PermissionStatus] = [:]
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied
        s[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .denied
        s[.automation] = .unknown
        s[.systemAudio] = .unknown
        s[.appManagement] = .unknown
        s[.fullDiskAccess] = Self.probeFullDiskAccess() ? .granted : .denied
        s[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        s[.microphone] = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        s[.calendars] = Self.mapCalendar(EKEventStore.authorizationStatus(for: .event))
        s[.bluetooth] = Self.mapBluetooth(CBCentralManager.authorization)
        s[.notifications] = status[.notifications] ?? .unknown
        status = s
        refreshNotifications()
    }

    private func refreshNotifications() {
        guard Bundle.main.bundleIdentifier == "dev.multitool.app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Log.write("notification settings auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)")
            let v: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: v = .granted
            case .denied: v = .denied
            case .notDetermined: v = .undetermined
            @unknown default: v = .unknown
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.status[.notifications] != v { self.status[.notifications] = v }
                }
            }
        }
    }

    private var btProbe: CBCentralManager?
    private let eventStore = EKEventStore()

    public func openSettings(_ p: Permission) {
        if state(p) == .undetermined, request(p) { return }
        switch p {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .notifications:
            Notifier.shared.requestAuthorization()
        default:
            break
        }
        if let url = URL(string: p.settingsURL) { NSWorkspace.shared.open(url) }
    }

    private func request(_ p: Permission) -> Bool {
        let done: @Sendable (Bool) -> Void = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Permissions.shared.refresh() } }
        }
        switch p {
        case .camera: AVCaptureDevice.requestAccess(for: .video, completionHandler: done)
        case .microphone: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        case .calendars: eventStore.requestFullAccessToEvents { granted, _ in done(granted) }
        case .bluetooth:
            btProbe = CBCentralManager(delegate: nil, queue: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.refresh() } }
        default: return false
        }
        Log.write("permission request \(p.rawValue)")
        return true
    }

    private static func probeFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let protected = ["/Library/Safari", "/Library/Mail", "/Library/Messages",
                         "/Library/Application Support/com.apple.TCC"]
        return protected.contains { (try? FileManager.default.contentsOfDirectory(atPath: home + $0)) != nil }
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .unknown
        }
    }

    private static func mapCalendar(_ s: EKAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .fullAccess, .authorized, .writeOnly: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .unknown
        }
    }

    private static func mapBluetooth(_ s: CBManagerAuthorization) -> PermissionStatus {
        switch s {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .unknown
        }
    }
}
