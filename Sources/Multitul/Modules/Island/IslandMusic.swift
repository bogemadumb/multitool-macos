import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class IslandMusic: ObservableObject {
    static let shared = IslandMusic()

    let service: IslNowPlayingService
    @Published private(set) var revision = 0
    var onNotify: ((IslNowPlayingChange) -> Void)?

    private var images = IslLRUCache<String, NSImage>(capacity: 8)
    private var tints: [String: Color] = [:]
    private var icons: [String: NSImage] = [:]
    private var timer: Timer?
    private var started = false

    private init() {
        service = IslNowPlayingService(drivers: [IslMediaRemoteDriver(), IslPlayerNotificationDriver()])
        service.onChange = { [weak self] change in
            guard let self else { return }
            self.revision &+= 1
            self.onNotify?(change)
        }
    }

    var value: IslNowPlaying { service.value }
    var notes: [String] { service.healthNotes }

    func start() {
        guard !started else { return }
        started = true
        service.start()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.service.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        service.stop()
        images.removeAll()
        tints = [:]
        revision &+= 1
    }

    func artwork() -> NSImage? {
        guard let t = value.track else { return nil }
        if let img = images.get(t.artworkKey) { return img }
        guard let data = service.currentArtwork, let img = NSImage(data: data) else { return nil }
        images.set(t.artworkKey, img)
        if let c = IslandColors.average(of: img) { tints[t.artworkKey] = c }
        return img
    }

    var tint: Color {
        guard let t = value.track else { return .white }
        _ = artwork()
        return tints[t.artworkKey] ?? .white
    }

    func appIcon() -> NSImage? {
        guard let b = value.track?.bundleID else { return nil }
        if let i = icons[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        icons[b] = img
        return img
    }

    func openSourceApp() {
        guard let b = value.track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    func toggle() { service.send(.toggle) }
    func seek(to t: TimeInterval) { service.send(.seek(t)) }
    func skip(_ s: TimeInterval) { service.skip(by: s) }

    func next() {
        service.send(.next)
        refreshSoon()
    }

    func previous() {
        service.send(.previous)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in MainActor.assumeIsolated { self?.service.refresh() } }
    }
}

struct IslScrubber: View {
    let np: IslNowPlaying
    var tint: Color
    var onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        if let d = np.duration, d > 0 {
            TimelineView(.animation(minimumInterval: 0.25, paused: !np.isPlaying || drag != nil)) { ctx in
                let progress = drag ?? np.progress(at: ctx.date)
                let elapsed = progress * d
                VStack(spacing: 1) {
                    IslSlider(value: Binding(get: { progress }, set: { drag = $0 }), tint: tint) { editing in
                        if !editing, let v = drag { onSeek(v * d); drag = nil }
                    }
                    HStack {
                        Text(IslTimeFormat.clock(elapsed))
                        Spacer()
                        Text(IslTimeFormat.remaining(max(d - elapsed, 0)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
        } else {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("В эфире")
                Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct IslArtwork: View {
    @ObservedObject var music: IslandMusic
    var size: CGFloat
    var radius: CGFloat = 12

    var body: some View {
        Group {
            if let img = music.artwork() {
                Image(nsImage: img).resizable().scaledToFill()
            } else if let icon = music.appIcon() {
                Image(nsImage: icon).resizable().scaledToFit().padding(size * 0.14)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct IslandMusicView: View {
    @ObservedObject var music = IslandMusic.shared
    @ObservedObject var ctl = IslandController.shared
    @ObservedObject private var eq = IslandEqService.shared
    @ObservedObject private var lyrics = IslandLyricsService.shared
    let context: IslExpandContext

    var body: some View {
        let np = music.value
        if let track = np.track {
            let side = min(context.size.height - context.topInset - 24, 150)
            HStack(alignment: .top, spacing: 14) {
                IslArtwork(music: music, size: max(side, 80))
                    .shadow(color: music.tint.opacity(0.35), radius: 14, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title.isEmpty ? "Без названия" : track.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    if !track.subtitle.isEmpty { Text(track.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                    Button { music.openSourceApp() } label: {
                        HStack(spacing: 5) {
                            if let icon = music.appIcon() { Image(nsImage: icon).resizable().frame(width: 12, height: 12) }
                            Text(track.appName ?? "Плеер").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(ctl.accessories.active(in: .musicBelow)) { a in a.view() }
                    Spacer(minLength: 2)
                    IslScrubber(np: np, tint: music.tint) { music.seek(to: $0) }
                    controls(np)
                }
                let side = ctl.accessories.active(in: .musicSide)
                if !side.isEmpty {
                    VStack(spacing: 6) { ForEach(side) { a in a.view() } }.frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .padding(.top, 4)
        } else {
            VStack {
                IslEmptyNote(symbol: "music.note", text: "Ничего не играет")
                if let n = music.notes.first { Text(n).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center).padding(.horizontal, 24) }
            }
        }
    }

    private func controls(_ np: IslNowPlaying) -> some View {
        HStack(spacing: 6) {
            Spacer()
            IslIconButton(symbol: "gobackward.15", size: 14, help: "Назад на 15 секунд") { music.skip(-15) }
            IslIconButton(symbol: "backward.fill", size: 16, help: "Предыдущий") { music.previous() }
            IslIconButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 20, background: true, help: np.isPlaying ? "Пауза" : "Играть") { music.toggle() }
            IslIconButton(symbol: "forward.fill", size: 16, help: "Следующий") { music.next() }
            IslIconButton(symbol: "goforward.15", size: 14, help: "Вперёд на 15 секунд") { music.skip(15) }
            Spacer()
        }
    }
}

@MainActor
final class IslandMusicSection: IslandSectionBase {
    private let music = IslandMusic.shared

    init() { super.init(IslSectionIDs.music) }

    override var activities: [IslActivity] { IslActivityFactory.music(music.value, now: Date()).map { [$0] } ?? [] }

    override func start() {
        music.onNotify = { [weak self] _ in self?.notify() }
        music.start()
    }

    override func stop() {
        music.onNotify = nil
        music.stop()
    }

    override func compactLeading(_ activity: IslActivity) -> AnyView? { AnyView(IslArtwork(music: music, size: 22, radius: 5)) }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandMusicEQ(music: music))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? { AnyView(IslandMusicPeek(music: music)) }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandMusicView(context: context)) }
}

struct IslandMusicPeek: View {
    @ObservedObject var music: IslandMusic

    var body: some View {
        if let t = music.value.track {
            HStack(spacing: 10) {
                IslArtwork(music: music, size: 30, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(t.artist.isEmpty ? t.subtitle : t.artist).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: music.value.isPlaying ? "waveform" : "pause.fill").foregroundStyle(music.tint)
            }
            .padding(.horizontal, 14)
        }
    }
}

struct IslandMusicEQ: View {
    @ObservedObject var music: IslandMusic
    @ObservedObject private var eq = IslandEqService.shared

    var body: some View {
        if eq.live { IslandSpectrumBars(count: eq.settings.compactBars, tint: music.tint) } else { IslEqualizer(playing: music.value.isPlaying, tint: music.tint) }
    }
}
