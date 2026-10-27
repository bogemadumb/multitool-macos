import SwiftUI
import AppKit
import CoreServices
import MultitulCore
import MultitulUI

final class IslFileLister: IslDlListing {
    func list(_ folder: String) -> [IslDlFile]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return nil }
        var out: [IslDlFile] = []
        for name in names {
            let path = folder + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            if isDir.boolValue {
                if name.lowercased().hasSuffix(".download") {
                    let (size, total) = Self.safariBundle(path)
                    out.append(IslDlFile(name: name, size: size, modified: modified, isDirectory: true, expectedTotal: total))
                } else {
                    out.append(IslDlFile(name: name, size: 0, modified: modified, isDirectory: true))
                }
            } else {
                out.append(IslDlFile(name: name, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: modified))
            }
        }
        return out
    }

    private static func safariBundle(_ path: String) -> (Int64, Int64?) {
        let fm = FileManager.default
        var size: Int64 = 0
        var total: Int64?
        for item in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            if item == "Info.plist" {
                if let d = fm.contents(atPath: path + "/Info.plist"), let info = IslDlSafariInfo.parse(d) {
                    total = info.total
                    if let so = info.soFar { size = max(size, so) }
                }
                continue
            }
            size += ((try? fm.attributesOfItem(atPath: path + "/" + item))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return (size, total)
    }
}

final class IslFSEventsWatcher: IslDlWatching {
    private var stream: FSEventStreamRef?
    fileprivate var handler: (() -> Void)?

    func start(path: String, onChange: @escaping () -> Void) {
        stop()
        handler = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<IslFSEventsWatcher>.fromOpaque(info).takeUnretainedValue().handler?()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        handler = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

@MainActor
final class IslandDownloadsService: ObservableObject {
    static let shared = IslandDownloadsService()

    @Published private(set) var revision = 0
    @Published private(set) var settings: IslDlSettings
    let monitor: IslDlMonitor
    var onChange: (() -> Void)?
    private let store = IslDlSettingsStore()
    private var timer: Timer?
    private(set) var running = false

    private init() {
        let s = store.load()
        settings = s
        monitor = IslDlMonitor(lister: IslFileLister(), watcher: IslFSEventsWatcher(), settings: s)
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        monitor.update(settings)
        monitor.onEvents = { [weak self] events in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed(events) } }
        }
        monitor.start()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        monitor.onEvents = nil
        monitor.stop()
        onChange?()
    }

    private func tick() {
        monitor.tick()
        if !monitor.detector.active.isEmpty { revision &+= 1 }
    }

    private func changed(_ events: [IslDlEvent]) {
        revision &+= 1
        onChange?()
    }

    func update(_ s: IslDlSettings) {
        settings = s.sanitized
        store.save(settings)
        monitor.update(settings)
        revision &+= 1
    }

    func activity() -> IslActivity? { running ? monitor.activity(now: Date()) : nil }

    var active: [IslDlItem] { monitor.detector.active }

    var finished: [IslDlItem] { monitor.detector.recentFinished }

    var folder: String { settings.resolvedFolder() }

    func reveal(_ item: IslDlItem) {
        let url = URL(fileURLWithPath: folder + "/" + item.name)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
    }
}

@MainActor
final class IslandDownloadsSection: IslandSectionBase {
    private let service = IslandDownloadsService.shared

    init() { super.init(IslSectionIDs.downloads) }

    override var availability: IslAvailability {
        if !moduleRunning(.notchDownloads) { return .unavailable("Включи модуль «Остров: загрузки»") }
        return service.monitor.readable ? .available : .unavailable("Нет доступа к папке загрузок: разреши в настройках системы (Файлы и папки)")
    }

    override var activities: [IslActivity] { service.activity().map { [$0] } ?? [] }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandDownloadRing(service: service))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandDownloadTrailing(service: service))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(HStack(spacing: 10) {
            IslandDownloadRing(service: service)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                IslandDownloadDetail(service: service)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandDownloadsView(service: service)) }
}

struct IslandDownloadRing: View {
    @ObservedObject var service: IslandDownloadsService

    var body: some View {
        let s = IslDlActivityFactory.summary(service.monitor.detector.items)
        ZStack {
            if let p = s?.progress {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: p).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            } else {
                Image(systemName: s == nil ? "checkmark.circle.fill" : "arrow.down.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(s == nil ? Theme.ok : .white)
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct IslandDownloadTrailing: View {
    @ObservedObject var service: IslandDownloadsService

    var body: some View {
        if let s = IslDlActivityFactory.summary(service.monitor.detector.items) {
            Text(s.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? IslDlFormat.bytes(s.bytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        } else {
            Text("Готово").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.ok)
        }
    }
}

struct IslandDownloadDetail: View {
    @ObservedObject var service: IslandDownloadsService

    var body: some View {
        if let s = IslDlActivityFactory.summary(service.monitor.detector.items) {
            Text(IslDlFormat.bytes(s.bytes) + (s.speed > 1024 ? " · " + IslDlFormat.speed(s.speed) : "")).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
        } else {
            Text("Загрузка завершена").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct IslandDownloadsView: View {
    @ObservedObject var service: IslandDownloadsService

    var body: some View {
        let _ = service.revision
        let active = service.active
        let done = service.finished
        Group {
            if active.isEmpty && done.isEmpty {
                IslEmptyNote(symbol: "arrow.down.circle", text: "Сейчас ничего не скачивается\nСлежу за папкой: \((service.folder as NSString).lastPathComponent)")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(active) { row($0) }
                        ForEach(done) { row($0) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ it: IslDlItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: it.state == .completed ? "checkmark.circle.fill" : (it.state == .stalled ? "pause.circle" : "arrow.down.circle")).font(.system(size: 13))
                    .foregroundStyle(it.state == .completed ? Theme.ok : (it.state == .stalled ? Theme.warn : .white))
                Text(it.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(detail(it)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
            if it.isActive {
                if let p = it.progress { IslSlider(value: .constant(p), height: 3).allowsHitTesting(false).frame(height: 6) }
                else { ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(.white) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if it.state == .completed { service.reveal(it) } }
        .help(it.state == .completed ? "Показать в Finder" : it.browser.title)
    }

    private func detail(_ it: IslDlItem) -> String {
        switch it.state {
        case .completed: return IslDlFormat.bytes(it.bytes)
        case .stalled: return "стоит · " + IslDlFormat.bytes(it.bytes)
        case .cancelled: return "отменена"
        case .downloading:
            var s = IslDlFormat.bytes(it.bytes)
            if let t = it.expectedTotal { s += " из " + IslDlFormat.bytes(t) }
            if it.speed > 1024 { s += " · " + IslDlFormat.speed(it.speed) }
            if let t = it.expectedTotal, let eta = IslDlFormat.eta(remaining: t - it.bytes, speed: it.speed) { s += " · " + eta }
            return s
        }
    }
}

struct IslandDownloadsSettings: View {
    @ObservedObject var service: IslandDownloadsService
    @State private var folder = ""

    private func binding<T>(_ kp: WritableKeyPath<IslDlSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 12) {
                    Button("Выбрать…") { pick() }
                    Button("Загрузки") { var s = service.settings; s.folder = ""; service.update(s) }
                }
            } label: { SettingLabel("Следить за папкой", service.folder) }
            Toggle(isOn: binding(\.showCompleted)) { SettingLabel("Показывать завершённые", "Короткое сообщение «готово» и список последних") }
            Toggle(isOn: binding(\.trackPlainFiles)) { SettingLabel("Ловить и обычные файлы", "Файл без временного суффикса браузера, который растёт, а потом перестаёт (AirDrop, копирование)") }
            if service.settings.trackPlainFiles {
                IslandStepperRow(symbol: "ruler", title: "Игнорировать файлы меньше", value: binding(\.minPlainKB), range: 0...102_400, unit: " КБ")
            }
        } header: { Text("Загрузки") } footer: {
            SectionFooter("Браузеры: Chrome, Edge, Brave, Arc, Vivaldi (.crdownload), Safari (.download), Firefox (.part), Opera (.opdownload). Прогресс в процентах есть только у Safari, у остальных видны размер и скорость.")
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.directoryURL = URL(fileURLWithPath: service.folder)
        if p.runModal() == .OK, let u = p.url { var s = service.settings; s.folder = u.path; service.update(s) }
    }
}
