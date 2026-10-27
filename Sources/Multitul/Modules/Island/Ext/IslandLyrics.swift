import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

final class IslURLSessionHTTP: IslHTTPFetching {
    func get(_ url: URL, headers: [String: String], completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            completion(.success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())))
        }.resume()
    }
}

final class IslLyricsFileStore: IslLyricsStoring {
    private let dir = MultitulPaths.home + "/lyrics"

    private func path(_ key: String) -> String { dir + "/" + key + ".lrc" }

    func load(_ key: String) -> String? { try? String(contentsOfFile: path(key), encoding: .utf8) }

    func save(_ key: String, text: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: path(key), atomically: true, encoding: .utf8)
    }

    func remove(_ key: String) { try? FileManager.default.removeItem(atPath: path(key)) }
}

@MainActor
final class IslandLyricsService: ObservableObject {
    static let shared = IslandLyricsService()

    @Published private(set) var revision = 0
    @Published private(set) var settings: IslLyrSettings
    let engine: IslLyricsEngine
    private let store = IslLyrSettingsStore()
    private var timer: Timer?
    private(set) var running = false

    private init() {
        let s = store.load()
        settings = s
        engine = IslLyricsEngine(provider: IslLrclibProvider(http: IslURLSessionHTTP()), store: IslLyricsFileStore())
        engine.settings = s
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        engine.settings = settings
        engine.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.revision &+= 1 } }
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
        IslandController.shared.accessories.register(IslAccessory(id: "lyrics.line", slot: .musicBelow, order: 20,
                                                                  isActive: { [weak self] in self?.showsUnderTrack ?? false }, view: { AnyView(IslandLyricsLine()) }))
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        engine.onChange = nil
        engine.trackChanged(nil)
        IslandController.shared.accessories.unregister("lyrics.line")
    }

    private func tick() {
        let q = IslLyricsQuery(track: IslandMusic.shared.value.track)
        engine.trackChanged(q)
    }

    var showsUnderTrack: Bool {
        guard running, settings.showUnderTrack, case .ready(let l) = engine.state else { return false }
        return l.isSynced
    }

    func update(_ s: IslLyrSettings) {
        settings = s.sanitized
        store.save(settings)
        engine.settings = settings
        revision &+= 1
    }

    func nudge(_ seconds: Double) {
        var s = settings
        s.userOffset += seconds
        update(s)
    }

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["lrc", "txt"].compactMap { UTType(filenameExtension: $0) }
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if !engine.importText(text) { HUD.show("В файле нет текста песни") }
    }

    func importClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), engine.importText(text) else { HUD.show("В буфере нет текста песни"); return }
    }
}

@MainActor
final class IslandLyricsSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.lyrics) }

    override var availability: IslAvailability { requires(.notchLyrics) }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandLyricsView(service: IslandLyricsService.shared)) }
}

struct IslandLyricsLine: View {
    @ObservedObject private var service = IslandLyricsService.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let elapsed = IslandMusic.shared.value.elapsed(at: ctx.date)
            if let f = service.engine.frame(at: elapsed), !f.line.isEmpty {
                Text(f.line).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1).transition(.opacity)
            } else {
                Text(" ").font(.system(size: 11.5))
            }
        }
    }
}

struct IslandLyricsView: View {
    @ObservedObject var service: IslandLyricsService
    @ObservedObject private var music = IslandMusic.shared

    var body: some View {
        let _ = service.revision
        Group {
            if music.value.track == nil {
                IslEmptyNote(symbol: "quote.bubble", text: "Ничего не играет")
            } else {
                switch service.engine.state {
                case .idle, .loading: IslEmptyNote(symbol: "magnifyingglass", text: "Ищу текст…")
                case .instrumental: IslEmptyNote(symbol: "pianokeys", text: "Инструментальная композиция")
                case .notFound: notFound
                case .failed(let m): IslEmptyNote(symbol: "wifi.exclamationmark", text: "Не удалось найти текст: \(m)")
                case .ready(let lrc): lyrics(lrc)
                }
            }
        }
    }

    private var notFound: some View {
        VStack(spacing: 8) {
            IslEmptyNote(symbol: "text.badge.xmark", text: "Текста нет. Можно загрузить свой")
            HStack {
                Button("Файл .lrc…") { service.importFile() }
                Button("Из буфера") { service.importClipboard() }
            }
        }
    }

    private func lyrics(_ lrc: IslLrc) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let elapsed = music.value.elapsed(at: ctx.date)
            let frame = service.engine.frame(at: elapsed)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(lrc.lines.enumerated()), id: \.offset) { i, line in
                            let current = lrc.isSynced && frame?.index == i
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: current ? 15 : 12.5, weight: current ? .bold : .regular))
                                .foregroundStyle(current ? .white : .white.opacity(lrc.isSynced ? 0.38 : 0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
                }
                .onChange(of: frame?.index) { _, new in
                    if let new { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                IslIconButton(symbol: "minus", size: 9, help: "Текст позже на 0,5 с") { service.nudge(-0.5) }
                IslIconButton(symbol: "plus", size: 9, help: "Текст раньше на 0,5 с") { service.nudge(0.5) }
            }
            .padding(.trailing, 8)
        }
    }
}

struct IslandLyricsSettings: View {
    @ObservedObject var service: IslandLyricsService

    private func binding<T>(_ kp: WritableKeyPath<IslLyrSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        Section {
            Toggle(isOn: binding(\.fetchOnline)) { SettingLabel("Искать тексты онлайн (lrclib.net)", "Уходят название, исполнитель, альбом и длительность. Выключено: только свои тексты и уже найденные") }
            Toggle(isOn: binding(\.showUnderTrack)) { SettingLabel("Строка под названием трека", "Текущая строка песни в разделе «Музыка»") }
            Stepper(value: binding(\.userOffset), in: -10...10, step: 0.5) {
                HStack {
                    SettingLabel("Сдвиг текста", "Плюс — строка появляется раньше")
                    Spacer()
                    Text(String(format: "%+.1f с", service.settings.userOffset)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Button("Сбросить сдвиг") { var s = service.settings; s.userOffset = 0; service.update(s) }
        } header: { Text("Тексты песен") }
        Section {
            Button("Загрузить свой текст…") { service.importFile() }
            Button("Забыть найденный текст") { service.engine.clearCurrent() }
        }
    }
}
