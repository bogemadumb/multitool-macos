import SwiftUI
import AppKit
@preconcurrency import MultitulCore
import MultitulUI

final class IslNSScriptRunner: IslScriptRunning {
    func run(_ source: String) -> IslScriptOutput {
        guard let script = NSAppleScript(source: source) else { return .failure(code: -1, message: "Скрипт не собран") }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            return .failure(code: (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1, message: (err[NSAppleScript.errorMessage] as? String) ?? "")
        }
        return .text(result.stringValue ?? "")
    }
}

@MainActor
final class IslandQueueService: ObservableObject {
    static let shared = IslandQueueService()

    @Published private(set) var result: IslQueueResult?
    @Published private(set) var app: IslQueueApp?
    @Published private(set) var settings: IslQueueSettings
    private let store = IslQueueSettingsStore()
    private let provider: IslQueueProviding = IslQueueProvider(runner: IslNSScriptRunner())
    private let queue = DispatchQueue(label: "dev.multitool.app.island.queue")
    private var timer: Timer?
    private var visible = 0
    private var loading = false
    private var lastIdentity: String?
    private(set) var running = false

    private init() { settings = store.load() }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        result = nil
        visible = 0
    }

    func viewerAppeared() {
        visible += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: Double(settings.refreshSeconds), repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerDisappeared() {
        visible = max(visible - 1, 0)
        if visible == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard running, !loading else { return }
        let music = IslandMusic.shared.value
        guard let a = IslQueueApp(bundleID: music.track?.bundleID) else {
            app = nil
            result = music.track == nil ? .stopped : .unsupported("\(music.track?.appName ?? "Этот плеер") не отдаёт очередь")
            return
        }
        app = a
        loading = true
        let limit = settings.limit
        let p = provider
        queue.async {
            let r = p.upNext(app: a, limit: limit)
            DispatchQueue.main.async { MainActor.assumeIsolated { IslandQueueService.shared.apply(r) } }
        }
    }

    private func apply(_ r: IslQueueResult) {
        loading = false
        if running { result = r }
    }

    func play(_ item: IslQueueItem) {
        guard let a = app else { return }
        let p = provider
        queue.async {
            _ = p.play(app: a, position: item.position)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { IslandQueueService.shared.refresh() } }
        }
    }

    func update(_ s: IslQueueSettings) {
        settings = s.sanitized
        store.save(settings)
        timer?.invalidate()
        timer = nil
        if visible > 0 { viewerAppeared(); visible -= 1 }
    }
}

@MainActor
final class IslandQueueSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.queue) }

    override var availability: IslAvailability { requires(.notchQueue) }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandQueueView(service: IslandQueueService.shared)) }
}

struct IslandQueueView: View {
    @ObservedObject var service: IslandQueueService
    @ObservedObject private var music = IslandMusic.shared

    var body: some View {
        Group {
            switch service.result {
            case .items(let items, _)?:
                list(items)
            case nil:
                IslEmptyNote(symbol: "list.bullet", text: "Читаю очередь…")
            case let r?:
                IslEmptyNote(symbol: "list.bullet", text: IslQueueFormat.note(r, app: service.app) ?? "Очередь пуста")
            }
        }
        .onAppear { service.viewerAppeared() }
        .onDisappear { service.viewerDisappeared() }
        .onChange(of: music.value.track?.identity) { _, _ in service.refresh() }
    }

    private func list(_ items: [IslQueueItem]) -> some View {
        VStack(spacing: 2) {
            if let n = IslQueueFormat.note(service.result ?? .stopped, app: service.app) {
                Text(n).font(.system(size: 10)).foregroundStyle(Theme.warn).lineLimit(1).padding(.horizontal, 20)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Text("\(item.position)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.35)).frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                if !item.artist.isEmpty { Text(item.artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                            }
                            Spacer()
                            if let d = item.duration { Text(IslTimeFormat.clock(d)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45)) }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .onTapGesture { service.play(item) }
                        .help("Клик — включить этот трек")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

struct IslandQueueSettings: View {
    @ObservedObject var service: IslandQueueService

    private func binding<T>(_ kp: WritableKeyPath<IslQueueSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .automation, text: "Для чтения очереди Мультитулу нужно разрешение управлять «Музыкой» (Автоматизация).")
        Section {
            IslandStepperRow(symbol: "list.number", title: "Сколько треков показывать", value: binding(\.limit), range: IslQueueSettings.limitRange)
            IslandStepperRow(symbol: "arrow.clockwise", title: "Обновлять раз в", subtitle: "Только пока раздел открыт", value: binding(\.refreshSeconds), range: 2...60, unit: " с")
        } header: { Text("Очередь") } footer: {
            SectionFooter("Очередь отдаёт только приложение «Музыка» (порядок текущего плейлиста). Spotify и браузеры очередь наружу не отдают.")
        }
    }
}
