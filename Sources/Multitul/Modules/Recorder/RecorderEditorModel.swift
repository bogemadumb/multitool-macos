import SwiftUI
import AppKit
import AVFoundation
import MultitulCore
import MultitulUI

enum RecEditorTab: String, CaseIterable {
    case montage, frame, zoom, audio, privacy, export

    var title: String {
        switch self {
        case .montage: "Монтаж"
        case .frame: "Кадр"
        case .zoom: "Зум"
        case .audio: "Звук"
        case .privacy: "Скрытие"
        case .export: "Экспорт"
        }
    }
}

enum RecRegionMode: Identifiable, Equatable {
    case crop
    case newBlur
    case editBlur(Int)

    var id: String {
        switch self {
        case .crop: "crop"
        case .newBlur: "new"
        case .editBlur(let i): "blur\(i)"
        }
    }
}

@MainActor
final class RecEditorModel: ObservableObject {
    @Published private(set) var session: RecEditSession
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var selection: ClosedRange<Double>?
    @Published var tab = RecEditorTab.montage
    @Published var status = ""
    @Published var progress: Double?
    @Published var presetID = "web1080"
    @Published var gifDraft = RecGifOptions()
    @Published var presetName = ""
    @Published var region: RecRegionMode?
    @Published private(set) var stillFrame: CGImage?
    @Published private(set) var lastExport: String?
    @Published private(set) var building = false

    let player = AVPlayer()
    let url: URL
    let record: RecRecord?
    let log: RecInputLog
    let clicks: [RecInputEvent]
    weak var controller: RecorderController?
    var pendingBlurStyle: (pixelate: Bool, strength: Double) = (false, 0.8)

    private var observer: Any?
    private var scrubbing = false
    private var rebuild: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var exporter: RecExporter?
    private var endObserver: NSObjectProtocol?

    init(controller: RecorderController, record: RecRecord?, url: URL, document: RecEditDocument, log: RecInputLog) {
        self.controller = controller
        self.record = record
        self.url = url
        self.log = log
        clicks = log.clicks
        session = RecEditSession(document: document)
        gifDraft = RecPresets.export.first { $0.id == "gifLight" }?.gif ?? RecGifOptions()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.timeTick(t) }
        }
    }

    deinit {
        if let o = observer { player.removeTimeObserver(o) }
    }

    var doc: RecEditDocument { session.document }
    var timeline: RecTimeline { session.document.timeline }
    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }
    var hasClicks: Bool { !clicks.isEmpty }

    static let previewPreset = RecExportPreset(id: "preview", title: "Просмотр", container: .mp4, codec: .h264, maxLongSide: 1280, quality: .low)

    func allPresets() -> [RecExportPreset] { RecPresets.export + (controller?.exportPresets ?? []) }

    var currentPreset: RecExportPreset {
        var p = RecPresets.exportPreset(id: presetID, custom: controller?.exportPresets ?? [])
        if p.kind == .gif { p.gif = gifDraft }
        return p
    }

    var exportPlan: RecExportPlan { RecExportPlanner.make(document: doc, preset: currentPreset, hasInputLog: hasClicks) }

    // MARK: player

    func start() { scheduleRebuild(immediately: true) }

    private func timeTick(_ t: CMTime) {
        guard !scrubbing, t.isValid, t.seconds.isFinite else { return }
        playhead = timeline.outputToSource(t.seconds)
        isPlaying = player.rate != 0
        if isPlaying, t.seconds >= timeline.outputDuration - 0.02 {
            player.pause()
            isPlaying = false
        }
    }

    private func scheduleRebuild(immediately: Bool = false) {
        rebuild?.cancel()
        let keep = playhead
        rebuild = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 220_000_000) }
            guard !Task.isCancelled else { return }
            await self?.rebuildPlayer(keep: keep)
        }
    }

    private func rebuildPlayer(keep: Double) async {
        let plan = RecExportPlanner.make(document: doc, preset: Self.previewPreset, hasInputLog: hasClicks)
        guard !plan.pieces.isEmpty else { return }
        building = true
        defer { building = false }
        do {
            let built = try await RecCompositionBuilder.build(asset: AVURLAsset(url: url), plan: plan, log: log, includeAudio: true)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            if !built.audioTracks.isEmpty { item.audioMix = RecCompositionBuilder.audioMix(for: built.audioTracks) }
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = player.rate != 0
            player.replaceCurrentItem(with: item)
            let out = timeline.sourceToOutput(timeline.snapToKept(source: keep) ?? 0) ?? 0
            await player.seek(to: CMTime(seconds: out, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            status = "Просмотр не собрался: \(error)"
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if timeline.outputDuration - (timeline.sourceToOutput(playhead) ?? 0) < 0.05 { seek(source: timeline.segments.first?.srcStart ?? 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(source t: Double) {
        let s = timeline.snapToKept(source: min(max(t, 0), doc.source.duration)) ?? 0
        playhead = s
        let out = timeline.sourceToOutput(s) ?? 0
        player.seek(to: CMTime(seconds: out, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to t: Double) {
        scrubbing = true
        seek(source: t)
    }

    func endScrub() { scrubbing = false }

    func step(frames: Int) {
        let dt = 1.0 / Double(max(doc.source.fps, 1)) * Double(frames)
        seek(source: playhead + dt)
    }

    // MARK: editing

    private func commit(_ body: (inout RecEditSession) -> Bool) {
        var s = session
        guard body(&s) else { return }
        session = s
        scheduleRebuild()
        schedulePersist()
    }

    private func schedulePersist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        controller?.saveDocument(record: record, document: doc)
    }

    func undo() { commit { $0.undo() } }
    func redo() { commit { $0.redo() } }

    func markIn() {
        let end = selection?.upperBound ?? doc.source.duration
        selection = min(playhead, end)...max(playhead, end)
    }

    func markOut() {
        let start = selection?.lowerBound ?? 0
        selection = min(playhead, start)...max(playhead, start)
    }

    func clearSelection() { selection = nil }
    func split() { let t = playhead; commit { $0.split(at: t) } }

    func cutSelection() {
        guard let r = selection else { return }
        commit { $0.cut(from: r.lowerBound, to: r.upperBound) }
        selection = nil
    }

    func trimToSelection() {
        guard let r = selection else { return }
        commit { $0.trim(from: r.lowerBound, to: r.upperBound) }
        selection = nil
    }

    func removeSegmentAtPlayhead() {
        guard let i = timeline.segmentIndex(atSource: playhead) else { return }
        let id = timeline.segments[i].id
        commit { $0.edit { $0.timeline.remove(segmentID: id) } }
    }

    func setSpeed(_ v: Double) {
        if let r = selection {
            commit { $0.setSpeed(from: r.lowerBound, to: r.upperBound, speed: v) }
        } else if let i = timeline.segmentIndex(atSource: playhead) {
            let id = timeline.segments[i].id
            commit { $0.edit { $0.timeline.setSpeed(segmentID: id, speed: v) } }
        }
    }

    var currentSpeed: Double {
        if let i = timeline.segmentIndex(atSource: playhead) { return timeline.segments[i].speed }
        return 1
    }

    func resetMontage() { commit { $0.edit { $0.timeline.reset(); return true } } }

    func setCrop(_ r: RecNormRect) { commit { $0.setCrop(r) } }

    func setAspect(_ a: RecAspect) {
        let r = RecCropMath.fit(aspect: a, in: doc.crop.isFull ? .full : doc.crop, source: doc.source.size)
        commit { $0.edit { d in d.aspect = a; d.crop = r; return true } }
    }

    func editAspect(_ a: RecAspect) {
        commit { $0.edit { d in d.aspect = a; return true } }
    }

    func editStyle(_ body: @escaping (inout RecFrameStyle) -> Void) {
        var st = doc.style
        body(&st)
        commit { $0.setStyle(st) }
    }

    func editAudio(_ body: (inout RecAudioMix) -> Void) {
        var a = doc.audio
        body(&a)
        commit { $0.setAudio(a) }
    }

    func setZoomEnabled(_ on: Bool) {
        commit { $0.edit { d in
            d.zoomEnabled = on
            if on && d.zoom.spans.isEmpty { d.regenerateZoom(log: log) }
            return true
        } }
    }

    func editZoomSettings(_ body: @escaping (inout RecZoomSettings) -> Void) {
        commit { $0.edit { d in
            body(&d.zoomSettings)
            d.zoomSettings = d.zoomSettings.sanitized
            return true
        } }
    }

    func regenerateZoom() {
        commit { $0.edit { d in
            d.zoomEnabled = true
            d.regenerateZoom(log: log)
            return true
        } }
        status = doc.zoom.spans.isEmpty ? "Кликов для приближения не нашлось" : "Приближений: \(doc.zoom.spans.count)"
    }

    func removeZoom(at i: Int) {
        commit { $0.edit { d in
            guard d.zoom.spans.indices.contains(i) else { return false }
            d.zoom.spans.remove(at: i)
            return true
        } }
    }

    func addZoomHere() {
        let t = playhead
        let c = log.cursor(at: t) ?? (0.5, 0.5)
        commit { $0.edit { d in
            let s = d.zoomSettings
            let center = RecZoomMath.clampCenter(c, scale: s.level)
            let start = max(t - s.rampIn, 0)
            let holdStart = start + s.rampIn
            let holdEnd = min(holdStart + 3, d.source.duration)
            let end = min(holdEnd + s.rampOut, d.source.duration)
            guard end - start > 0.4 else { return false }
            let span = RecZoomSpan(start: start, holdStart: holdStart, holdEnd: max(holdEnd, holdStart), end: end, level: s.level, path: [RecZoomPoint(t: holdStart, cx: center.x, cy: center.y)])
            guard !d.zoom.spans.contains(where: { $0.start < end && span.start < $0.end }) else { return false }
            d.zoom = RecZoomTimeline(spans: d.zoom.spans + [span], easing: s.easing, panDuration: s.panDuration)
            d.zoomEnabled = true
            return true
        } }
    }

    func setZoomLevel(at i: Int, _ level: Double) {
        commit { $0.edit { d in
            guard d.zoom.spans.indices.contains(i) else { return false }
            d.zoom.spans[i].level = ToolsClamp.double(level, RecSettings.zoomLevelRange)
            return true
        } }
    }

    func addBlur(_ rect: RecNormRect, pixelate: Bool, strength: Double) {
        let t = playhead
        commit { $0.edit { d in
            _ = d.addBlur(rect: rect, from: t, to: min(t + 3, d.source.duration), strength: strength, pixelate: pixelate)
            return true
        } }
    }

    func updateBlur(_ id: Int, _ body: @escaping (inout RecBlurRegion) -> Void) {
        commit { $0.edit { d in
            guard let i = d.blurs.firstIndex(where: { $0.id == id }) else { return false }
            body(&d.blurs[i])
            d.blurs[i].rect = d.blurs[i].rect.sanitized
            if d.blurs[i].srcEnd < d.blurs[i].srcStart + 0.1 { d.blurs[i].srcEnd = d.blurs[i].srcStart + 0.1 }
            return true
        } }
    }

    func removeBlur(_ id: Int) { commit { $0.edit { $0.removeBlur(id: id); return true } } }

    // MARK: region sheet

    func openRegion(_ mode: RecRegionMode) {
        player.pause()
        isPlaying = false
        let t = playhead
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        Task { @MainActor in
            stillFrame = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            region = mode
        }
    }

    // MARK: export

    func exportToFile() {
        let preset = currentPreset
        let plan = exportPlan
        guard !plan.pieces.isEmpty else { status = "Нечего экспортировать"; return }
        let panel = NSSavePanel()
        let dir = controller?.settings.resolvedDirectory() ?? NSHomeDirectory()
        panel.directoryURL = URL(fileURLWithPath: dir)
        let base = (record?.title ?? "Запись") + " (монтаж)"
        panel.nameFieldStringValue = ShotNaming.uniqueFileName(base: base, ext: preset.fileExtension) { FileManager.default.fileExists(atPath: dir + "/" + $0) }
        panel.canCreateDirectories = true
        panel.prompt = "Экспортировать"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run(plan: plan, to: dest) { [weak self] ok in
            guard ok, let self else { return }
            self.lastExport = dest.path
            HUD.show("Экспорт готов")
            self.controller?.addExported(path: dest.path, source: self.doc.source, plan: plan, title: dest.deletingPathExtension().lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    func exportAndLink() {
        let plan = exportPlan
        guard !plan.pieces.isEmpty else { return }
        let tmp = URL(fileURLWithPath: MultitulPaths.recCacheDir + "/link-" + String(UUID().uuidString.prefix(8)) + "." + plan.preset.fileExtension)
        try? FileManager.default.createDirectory(atPath: MultitulPaths.recCacheDir, withIntermediateDirectories: true)
        run(plan: plan, to: tmp) { [weak self] ok in
            guard ok, let self else { return }
            self.status = "Загружаю…"
            self.controller?.makeLink(path: tmp.path, record: self.record) { [weak self] text in
                self?.status = text
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    func putOnShelf() {
        guard let p = lastExport, let svc = ShelfController.shared.service else { status = "Сначала сохрани файл; модуль «Полка» должен быть включён"; return }
        _ = svc.addPaths([p], owned: false, source: "dev.multitool.app")
        HUD.show("Файл на полке")
    }

    private func run(plan: RecExportPlan, to dest: URL, done: @escaping (Bool) -> Void) {
        let ex = RecExporter()
        exporter = ex
        progress = 0
        status = "Экспорт…"
        let log = log
        let src = url
        Task { @MainActor in
            do {
                if plan.isGif {
                    _ = try await ex.exportGIF(source: src, plan: plan, log: log, destination: dest, progress: { p in Task { @MainActor in self.progress = p } })
                } else {
                    try await ex.exportVideo(source: src, plan: plan, log: log, destination: dest, progress: { p in Task { @MainActor in self.progress = p } })
                }
                status = "Готово: \(dest.lastPathComponent)"
                progress = nil
                done(true)
            } catch {
                status = "Экспорт не получился: \(error)"
                progress = nil
                done(false)
            }
            exporter = nil
        }
    }

    func cancelExport() { exporter?.cancel() }

    func saveCurrentPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var p = currentPreset
        p.id = RecPresets.safeID(name.isEmpty ? "custom" : name) + String(Int(Date().timeIntervalSince1970) % 100_000)
        p.title = name
        p.summary = "Мой пресет"
        controller?.saveExportPreset(p)
        presetID = p.id.isEmpty ? presetID : p.sanitized.id
        presetName = ""
    }

    func close() {
        player.pause()
        rebuild?.cancel()
        saveTask?.cancel()
        exporter?.cancel()
        persist()
        player.replaceCurrentItem(with: nil)
    }
}

@MainActor
final class RecEditorController: NSObject, NSWindowDelegate {
    let model: RecEditorModel
    private let window: NSWindow
    var onClose: ((RecEditorController) -> Void)?

    init(controller: RecorderController, record: RecRecord?, url: URL, document: RecEditDocument, log: RecInputLog) {
        model = RecEditorModel(controller: controller, record: record, url: url, document: document, log: log)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Редактор записи" + (record.map { " — \($0.title)" } ?? " — \(url.lastPathComponent)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 600)
        window.contentView = NSHostingView(rootView: RecEditorView(m: model))
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.start()
    }

    func close() {
        model.close()
        window.orderOut(nil)
        window.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        onClose?(self)
    }
}
