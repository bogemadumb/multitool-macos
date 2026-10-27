import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

enum WallpaperThumbs {
    nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func make(_ url: URL, maxPixel: Int = 320) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct WallpaperThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            let key = url.path as NSString
            if let hit = WallpaperThumbs.cache.object(forKey: key) { image = hit; return }
            let u = url
            let img = await Task.detached(priority: .utility) { WallpaperThumbs.make(u) }.value
            if let img { WallpaperThumbs.cache.setObject(img, forKey: key) }
            image = img
        }
    }
}

struct StaticWallpaperView: View {
    @ObservedObject private var live = LiveWallpaperController.shared
    @State private var sources = StaticWallpaperLibrary.loadSources()
    @State private var images: [URL] = []
    @State private var target = "all"
    @State private var note: String?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        SettingsPage {
            Section {
                Button("Добавить картинки…") { pick(folders: false) }
                Button("Добавить папку…") { pick(folders: true) }
                Picker("Экран", selection: $target) {
                    Text("Все экраны").tag("all")
                    ForEach(live.screens) { Text($0.name).tag($0.id) }
                }
                ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                    LabeledContent {
                        Button { remove(i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    } label: {
                        Label(s.path, systemImage: s.isFolder ? "folder" : "photo").lineLimit(1).truncationMode(.middle)
                    }
                }
            } header: { Text("Источники") } footer: {
                SectionFooter(note ?? "Нажми на картинку, чтобы поставить её на выбранный экран. Там, где идут живые обои, статичные не применяются: приложение предложит отключить живые на этом экране.")
            }
            Section {
                if images.isEmpty {
                    ContentUnavailableView("Картинок нет", systemImage: "photo.on.rectangle", description: Text("Добавь картинки или папку: здесь появятся миниатюры."))
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(images, id: \.self) { u in
                            Button { apply(u) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    WallpaperThumb(url: u)
                                    Text(u.deletingPathExtension().lastPathComponent).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: { Text("Картинки") }
        }
        .onAppear { reload() }
    }

    private func reload() { images = StaticWallpaperLibrary.images(from: sources) }

    private func pick(folders: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = !folders
        p.canChooseFiles = !folders
        p.canChooseDirectories = folders
        if !folders { p.allowedContentTypes = [.image] }
        guard p.runModal() == .OK else { return }
        sources = StaticWallpaperLibrary.adding(p.urls, to: sources)
        StaticWallpaperLibrary.saveSources(sources)
        reload()
    }

    private func remove(_ i: Int) {
        guard sources.indices.contains(i) else { return }
        sources.remove(at: i)
        StaticWallpaperLibrary.saveSources(sources)
        reload()
    }

    private func apply(_ url: URL) {
        let screens = NSScreen.screens.filter { target == "all" || ScreenIdentity.id(for: $0) == target }
        guard !screens.isEmpty else { note = "Экран не найден"; return }
        var done = 0
        for screen in screens {
            let id = ScreenIdentity.id(for: screen)
            if WallpaperExclusion.staticDecision(screenID: id, liveEnabled: live.isRunning, excluded: live.excluded) == .blockedByLive {
                let a = NSAlert()
                a.messageText = "На экране «\(screen.localizedName)» идут живые обои"
                a.informativeText = "Статичные обои будут не видны под видео. Отключить живые обои на этом экране и поставить картинку?"
                a.addButton(withTitle: "Отключить живые и поставить")
                a.addButton(withTitle: "Пропустить экран")
                guard a.runModal() == .alertFirstButtonReturn else { continue }
                live.setScreen(id, enabled: false)
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                done += 1
                Log.write("static wallpaper set \(url.lastPathComponent) screen=\(screen.localizedName)")
            } catch {
                note = "Не удалось поставить на «\(screen.localizedName)»: \(error.localizedDescription)"
            }
        }
        if done > 0 { note = "Поставлено на экранов: \(done)" }
    }
}
