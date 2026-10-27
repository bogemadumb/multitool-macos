import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore
import MultitulUI

final class IslNtfBannerWatcher {
    var onTexts: (([String], AXUIElement) -> Void)?
    private var observer: AXObserver?
    private var running = false

    func start() -> Bool {
        guard !running, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return false }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<IslNtfBannerWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(element)
        }
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return false }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, el, kAXWindowCreatedNotification as CFString, me) == .success else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        running = true
        return true
    }

    func stop() {
        guard running, let obs = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
        running = false
    }

    private func handle(_ element: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            var texts: [String] = []
            Self.collect(element, depth: 0, into: &texts)
            if !texts.isEmpty { self?.onTexts?(texts, element) }
        }
    }

    static func collect(_ el: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 8 else { return }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXStaticTextRole {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] else { return }
        for k in list { collect(k, depth: depth + 1, into: &out) }
    }

    // Best effort: banners differ between macOS releases, so look for a close-like action or button.
    static func dismiss(_ el: AXUIElement) {
        var names: CFArray?
        if AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] {
            if let close = list.first(where: { $0.localizedCaseInsensitiveContains("close") || $0.localizedCaseInsensitiveContains("clear") || $0.contains("Закрыть") }) {
                AXUIElementPerformAction(el, close as CFString)
                return
            }
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] else { return }
        for k in list { dismiss(k) }
    }
}

@MainActor
final class IslandNotificationsService: ObservableObject {
    static let shared = IslandNotificationsService()

    @Published private(set) var revision = 0
    @Published private(set) var settings: IslNtfSettings
    @Published private(set) var sourceNote = ""
    private(set) var center = IslNtfCenter()
    var onChange: (() -> Void)?
    private let store = IslNtfSettingsStore()
    private var db: IslNtfDBReader?
    private let banner = IslNtfBannerWatcher()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var names: [String: String] = [:]
    private var counter = 0
    private(set) var running = false

    private init() { settings = store.load() }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        center.clear()
        attachSources()
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearAll() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearAll() }
        })
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        banner.stop()
        banner.onTexts = nil
        db = nil
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers = []
        center.clear()
        onChange?()
    }

    private func attachSources() {
        db = nil
        banner.stop()
        var notes: [String] = []
        if settings.source != .banners {
            if let path = IslNtfDBReader.defaultPath() {
                let reader = IslNtfDBReader(path: path)
                reader.prime()
                if reader.health == .ok { db = reader } else if settings.source == .database { notes.append("База уведомлений недоступна: нужен «Полный доступ к диску»") }
            } else if settings.source == .database {
                notes.append("База уведомлений не найдена или закрыта: нужен «Полный доступ к диску»")
            }
        }
        if db == nil, settings.source != .database {
            banner.onTexts = { [weak self] texts, el in self?.bannerArrived(texts, el) }
            if !banner.start() { notes.append("Нет источника: выдай «Универсальный доступ» или «Полный доступ к диску» и перезапусти модуль") }
        }
        sourceNote = notes.joined(separator: ". ")
    }

    private func appName(_ bundleID: String) -> String {
        if let n = names[bundleID] { return n }
        var name = IslNtfNames.fallbackName(bundleID)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        names[bundleID] = name
        return name
    }

    private func poll() {
        guard let db else { return }
        var items = db.poll()
        for i in items.indices { items[i].appName = appName(items[i].bundleID) }
        ingest(items)
    }

    private func bannerArrived(_ texts: [String], _ element: AXUIElement) {
        counter += 1
        guard let item = IslNtfBannerParser.item(texts: texts, appName: "", bundleID: "", now: Date(), counter: counter) else { return }
        ingest([item])
        if settings.hideSystemBanner { IslNtfBannerWatcher.dismiss(element) }
    }

    private func ingest(_ items: [IslNtfItem]) {
        guard !items.isEmpty else { return }
        if !center.ingest(items, now: Date(), settings: settings).isEmpty {
            revision &+= 1
            onChange?()
        }
    }

    private func clearAll() {
        center.clear()
        revision &+= 1
        onChange?()
    }

    func clear() { clearAll() }

    func remove(_ id: String) {
        center.remove(id)
        revision &+= 1
        onChange?()
    }

    func open(_ item: IslNtfItem) {
        guard !item.bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        remove(item.id)
    }

    func update(_ s: IslNtfSettings) {
        let sourceChanged = s.source != settings.source
        settings = s.sanitized
        store.save(settings)
        if sourceChanged, running { attachSources() }
        revision &+= 1
    }

    func activity() -> IslActivity? { running ? center.activity(now: Date(), settings: settings) : nil }

    func icon(_ bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

@MainActor
final class IslandNotificationsSection: IslandSectionBase {
    private let service = IslandNotificationsService.shared

    init() { super.init(IslSectionIDs.notifications) }

    override var availability: IslAvailability { requires(.notchNotifications) }

    override var activities: [IslActivity] { service.activity().map { [$0] } ?? [] }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        let icon = service.center.latest.flatMap { service.icon($0.bundleID) }
        return AnyView(Group {
            if let icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) } else { Image(systemName: "bell.badge.fill").font(.system(size: 13)).foregroundStyle(.white) }
        })
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        guard let item = service.center.latest else { return nil }
        let showBody = service.settings.showBody
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            Text(item.headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if showBody, !item.detail.isEmpty { Text(item.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandNotificationsView(service: service)) }
}

struct IslandNotificationsView: View {
    @ObservedObject var service: IslandNotificationsService

    var body: some View {
        let _ = service.revision
        let items = service.center.items
        VStack(spacing: 4) {
            if items.isEmpty {
                IslEmptyNote(symbol: "bell", text: service.sourceNote.isEmpty ? "Новых уведомлений нет" : service.sourceNote)
            } else {
                HStack {
                    Text("\(items.count) в памяти до блокировки").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button("Очистить") { service.clear() }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 22)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(items) { it in row(it) }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    private func row(_ it: IslNtfItem) -> some View {
        HStack(spacing: 8) {
            if let icon = service.icon(it.bundleID) { Image(nsImage: icon).resizable().frame(width: 22, height: 22) } else { Image(systemName: "bell").frame(width: 22, height: 22).foregroundStyle(.white.opacity(0.6)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(it.headline).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                if service.settings.showBody, !it.detail.isEmpty { Text(it.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Text(IslandExtTime.shortClock(it.date)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            IslIconButton(symbol: "xmark", size: 8, help: "Убрать") { service.remove(it.id) }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { service.open(it) }
        .help("Клик — открыть приложение")
    }
}

struct IslandNotificationsSettings: View {
    @ObservedObject var service: IslandNotificationsService

    private func binding<T>(_ kp: WritableKeyPath<IslNtfSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .accessibility, text: "Для чтения баннеров нужен «Универсальный доступ».")
        ToolsPermissionNote(permission: .fullDiskAccess, text: "Чтение базы уведомлений требует «Полный доступ к диску» (вместо баннеров).")
        Section {
            Picker("Откуда брать уведомления", selection: binding(\.source)) { ForEach(IslNtfSourceChoice.allCases, id: \.self) { Text($0.title).tag($0) } }
            if !service.sourceNote.isEmpty { ToolWarning(text: service.sourceNote) }
            Toggle(isOn: binding(\.hideSystemBanner)) { SettingLabel("Скрывать системный баннер", "Только в режиме баннеров: остров пытается закрыть баннер macOS после копирования") }
            Toggle(isOn: binding(\.showBody)) { SettingLabel("Показывать текст сообщения", "Выключи, если не хочешь, чтобы текст виден был рядом с камерой") }
            IslandStepperRow(symbol: "clock", title: "Сколько держится в закрытом острове", value: binding(\.activityLifetime), range: IslNtfSettings.lifetimeRange, unit: " с")
            IslandStepperRow(symbol: "square.stack.3d.up", title: "Максимум в памяти", value: binding(\.maxItems), range: IslNtfSettings.maxItemsRange)
            IslandStepperRow(symbol: "doc.on.doc", title: "Не повторять одинаковые в течение", value: binding(\.dedupeSeconds), range: 0...120, unit: " с")
        } header: { Text("Уведомления") } footer: {
            SectionFooter("Уведомления хранятся только в памяти и стираются при блокировке экрана.")
        }
    }
}
