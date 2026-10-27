import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

enum MediaUiOperation: Int, CaseIterable {
    case compress, trim, gif, watermark, audio, convertVideo, images, text, download

    var title: String {
        switch self {
        case .compress: "Сжать видео"
        case .trim: "Обрезать"
        case .gif: "GIF из видео"
        case .watermark: "Водяной знак"
        case .audio: "Звук из файла"
        case .convertVideo: "Конвертировать видео"
        case .images: "Конвертировать картинки"
        case .text: "Текст из файла"
        case .download: "Скачать по ссылке"
        }
    }

    var hint: String {
        switch self {
        case .compress: "Видео уменьшается по качеству или до нужного размера; разрешение подбирается само"
        case .trim: "Без перекодирования режет по ключевым кадрам (быстро), с перекодированием точно"
        case .gif: "Палитра строится под ролик, поэтому цвета лучше, чем у простого конвертера"
        case .watermark: "Картинка или текст в углу видео и фото"
        case .audio: "Достаёт дорожку из видео или перекодирует аудио"
        case .convertVideo: "MP4, MOV, MKV или WebM"
        case .images: "Пачкой, с уменьшением; HEIC, PNG, JPEG, TIFF, BMP, GIF, WebP"
        case .text: "Распознавание Vision; для видео берётся кадр в указанную секунду"
        case .download: "Через yt-dlp, видео или звук"
        }
    }

    var acceptsFiles: Bool { self != .download }
}

struct MediaDraft: Equatable {
    var op = MediaUiOperation.compress
    var useTarget = false
    var quality = 60
    var targetMB = 25
    var trimStart = "0"
    var trimEnd = ""
    var trimReencode = false
    var gif = GifOptions()
    var watermarkIsText = true
    var watermarkText = ""
    var watermarkImage = ""
    var audioFormat = AudioFormat.mp3
    var audioKbps = 192
    var container = VideoContainer.mp4
    var textSecond = "0"
    var url = ""
    var downloadAudioOnly = false
    var downloadHeight = 0
}

@MainActor
final class MediaToolsController: ObservableObject {
    static let shared = MediaToolsController()

    @Published private(set) var revision = 0
    @Published private(set) var settings: MediaSettings
    @Published var draft = MediaDraft()
    @Published var message = ""
    let service: MediaService

    private let store = MediaSettingsStore()
    private let opener = TerminalAppleScriptOpener()
    private var running = false

    private init() {
        let s = MediaSettingsStore().load()
        settings = s
        service = MediaService(runner: SystemManagerRunner(), locator: ToolLocator(files: FileSystemLauncherChecker()), files: SystemMediaFileOps(),
                               images: ImageIOConverter(), ocr: VisionMediaTextExtractor(), settings: s)
        draft.quality = s.quality
        draft.audioKbps = s.audioKbps
        draft.gif.fps = s.gifFps
        draft.gif.width = s.gifWidth
        let previous = service.queue.onFinish
        service.queue.onFinish = { [weak self] snap in
            previous?(snap)
            Task { @MainActor in self?.finished(snap) }
        }
        service.queue.onChange = { [weak self] in self?.revision += 1 }
    }

    var jobs: [JobSnapshot] { service.queue.jobs }
    var tools: MediaToolPaths { service.tools }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        service.settings = settings
        service.refreshTools()
        revision += 1
    }

    func stop() {
        guard running else { return }
        running = false
        service.cancelAll()
    }

    func update(_ s: MediaSettings) {
        settings = s.sanitized
        store.save(settings)
        service.settings = settings
        revision += 1
    }

    func recheckTools() { service.refreshTools(); revision += 1 }

    func openInstallInTerminal() {
        guard let cmd = service.installHint else { return }
        if !opener.open(command: cmd) { HUD.show("Не удалось открыть Terminal") }
    }

    private func finished(_ snap: JobSnapshot) {
        guard let (title, body) = MediaService.finishMessage(snap), settings.notifyWhenDone, snap.kind == "media" || snap.kind == "download" else { return }
        Notifier.shared.post(title: title, body: body, id: "media-\(snap.id)")
        if settings.revealWhenDone, case .succeeded = snap.state, snap.kind == "media" { reveal(snap.result) }
    }

    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.show("Скопировано")
    }

    func operation() -> MediaOperation? {
        let d = draft
        switch d.op {
        case .compress:
            var o = VideoCompressOptions(settings: settings, mode: d.useTarget ? .targetSize(Int64(max(d.targetMB, 1)) * 1_048_576) : .quality(d.quality))
            o.audioKbps = settings.audioKbps
            return .compress(o)
        case .trim:
            guard let start = MediaTime.parse(d.trimStart) else { message = "Начало: не разобрал время"; return nil }
            var end: Double?
            if !d.trimEnd.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let e = MediaTime.parse(d.trimEnd) else { message = "Конец: не разобрал время"; return nil }
                end = e
            }
            return .trim(TrimOptions(start: start, end: end, reencode: d.trimReencode))
        case .gif: return .gif(d.gif)
        case .watermark:
            var o: WatermarkOptions
            if d.watermarkIsText { o = WatermarkOptions(source: .text(d.watermarkText)) } else { o = WatermarkOptions(source: .image(d.watermarkImage)) }
            o.corner = settings.watermarkCorner
            o.scalePercent = settings.watermarkScale
            o.opacityPercent = settings.watermarkOpacity
            return .watermark(o)
        case .audio: return .extractAudio(d.audioFormat, kbps: d.audioKbps)
        case .convertVideo: return .convertVideo(d.container)
        case .images: return .convertImage(ImageConvertOptions(settings: settings))
        case .text: return .extractText(at: MediaTime.parse(d.textSecond) ?? 0)
        case .download: return nil
        }
    }

    func submit(paths: [String]) {
        guard draft.op.acceptsFiles, let op = operation() else { return }
        let r = service.submitBatch(op, inputs: paths)
        if let first = r.rejected.first { message = "\((first.key as NSString).lastPathComponent): \(first.value.message)" } else { message = "" }
        if r.jobs.isEmpty && r.rejected.isEmpty { message = "Нет файлов" }
        revision += 1
    }

    func download() {
        let folder = settings.outputFolder.isEmpty ? NSHomeDirectory() + "/Downloads" : settings.outputFolder
        let mode: YtDlpArgs.Mode = draft.downloadAudioOnly ? .audio(.m4a) : (draft.downloadHeight > 0 ? .maxHeight(draft.downloadHeight) : .bestVideo)
        do {
            try service.submitDownload(url: draft.url, mode: mode, folder: folder)
            message = ""
        } catch let e as MediaError {
            message = e.message
        } catch {
            message = "\(error)"
        }
        revision += 1
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        submit(paths: p.urls.map(\.path))
    }

    func chooseWatermarkImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { draft.watermarkImage = u.path }
    }

    func chooseOutputFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { var s = settings; s.outputFolder = u.path; update(s) }
    }
}

@MainActor
final class MediaToolsModule: Module {
    let info = ModuleID.mediaTools.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { MediaToolsController.shared.start(); Log.write("module mediaTools start") }
    func stop() { MediaToolsController.shared.stop(); Log.write("module mediaTools stop") }
}

struct MediaToolsSections: View {
    @ObservedObject private var c = MediaToolsController.shared
    @State private var dropping = false

    private var toolsLine: String {
        let t = c.tools
        return "ffmpeg: \(t.ffmpeg ?? "нет") · yt-dlp: \(t.ytDlp ?? "нет")"
    }

    var body: some View {
        let _ = c.revision
        Section {
            LabeledContent("Статус", value: c.tools.canProcess ? "ffmpeg найден" : "нужен ffmpeg")
            LabeledContent("Инструменты", value: toolsLine)
        } header: { Text("Медиа-инструменты") }
        if !c.tools.canProcess {
            Section {
                Text("Не найдено: " + c.service.missingTools.map(\.name).joined(separator: ", "))
                if let cmd = c.service.installHint {
                    CommandBox(command: cmd) { c.openInstallInTerminal() }
                }
                Button("Проверить ещё раз") { c.recheckTools() }
            } footer: {
                SectionFooter("Поставь через Homebrew. Конвертация картинок и распознавание текста с картинок работают и без ffmpeg.")
            }
        }
        Section {
            Picker("Операция", selection: Binding(get: { c.draft.op.rawValue }, set: { c.draft.op = MediaUiOperation(rawValue: $0) ?? .compress })) {
                ForEach(MediaUiOperation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            options
        } header: { Text("Операция") } footer: { SectionFooter(c.draft.op.hint) }
        if c.draft.op.acceptsFiles { dropZone } else { downloadSection }
        if !c.message.isEmpty { Section { ToolWarning(text: c.message) } }
        JobsSection(jobs: c.jobs, onCancel: { c.service.cancel($0) }, onClear: { c.service.queue.clearFinished(); c.recheckTools() }) { job in
            guard case .succeeded = job.state, !job.result.isEmpty else { return nil }
            if job.kind == "media", MediaFormats.kind(of: job.result) != .unknown || FileManager.default.fileExists(atPath: job.result) {
                return ("Показать", { c.reveal(job.result) })
            }
            return job.kind == "media" ? ("Копировать", { c.copy(job.result) }) : ("Показать", { c.reveal(job.result) })
        }
        Section {
            NavigationLink(value: ToolRoute.mediaSettings) { Text("Параметры медиа") }
        }
    }

    private func setting<T>(_ kp: WritableKeyPath<MediaSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    @ViewBuilder private var options: some View {
        switch c.draft.op {
        case .compress:
            Picker("Режим", selection: $c.draft.useTarget) { Text("По качеству").tag(false); Text("До размера").tag(true) }.pickerStyle(.segmented)
            if c.draft.useTarget {
                StepperSetting("Целевой размер", value: $c.draft.targetMB, in: 1...20000, step: 5, unit: " МБ")
            } else {
                StepperSetting("Качество", value: $c.draft.quality, in: MediaSettings.qualityRange, step: 5)
            }
        case .trim:
            FieldSetting("Начало", text: $c.draft.trimStart, prompt: "0 или 1:30")
            FieldSetting("Конец", text: $c.draft.trimEnd, prompt: "пусто — до конца")
            Toggle("Перекодировать (точная обрезка)", isOn: $c.draft.trimReencode)
        case .gif:
            StepperSetting("Кадров в секунду", value: $c.draft.gif.fps, in: MediaSettings.gifFpsRange)
            StepperSetting("Ширина", value: $c.draft.gif.width, in: MediaSettings.gifWidthRange, step: 40, unit: " пикс.")
            StepperSetting("С секунды", value: Binding(get: { Int(c.draft.gif.start) }, set: { c.draft.gif.start = Double($0) }), in: 0...36000)
            StepperSetting("Длина", value: Binding(get: { Int(c.draft.gif.duration) }, set: { c.draft.gif.duration = Double($0) }), in: 1...60, unit: " с")
        case .watermark:
            Picker("Источник", selection: $c.draft.watermarkIsText) { Text("Текст").tag(true); Text("Картинка").tag(false) }.pickerStyle(.segmented)
            if c.draft.watermarkIsText {
                FieldSetting("Текст водяного знака", text: $c.draft.watermarkText)
            } else {
                LabeledContent {
                    Button("Выбрать…") { c.chooseWatermarkImage() }
                } label: { Text(c.draft.watermarkImage.isEmpty ? "Картинка не выбрана" : (c.draft.watermarkImage as NSString).lastPathComponent).foregroundStyle(.secondary) }
            }
            Picker("Угол", selection: setting(\.watermarkCorner)) {
                ForEach(WatermarkCorner.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            StepperSetting("Размер", value: setting(\.watermarkScale), in: MediaSettings.watermarkScaleRange, step: 5, unit: "%")
            StepperSetting("Непрозрачность", value: setting(\.watermarkOpacity), in: MediaSettings.watermarkOpacityRange, step: 10, unit: "%")
        case .audio:
            Picker("Формат", selection: $c.draft.audioFormat) { ForEach(AudioFormat.allCases, id: \.self) { Text($0.title).tag($0) } }
            if !c.draft.audioFormat.isLossless { StepperSetting("Битрейт", value: $c.draft.audioKbps, in: MediaSettings.audioRange, step: 32, unit: " кбит/с") }
        case .convertVideo:
            Picker("Контейнер", selection: $c.draft.container) { ForEach(VideoContainer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
        case .images:
            Picker("Формат", selection: setting(\.imageFormat)) {
                ForEach(ImageTarget.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            StepperSetting("Качество", value: setting(\.imageQuality), in: MediaSettings.imageQualityRange, step: 5)
            StepperSetting("Длинная сторона до", value: setting(\.imageMaxSide), in: MediaSettings.maxSideRange, step: 256, unit: " пикс.", zeroText: "как есть")
        case .text:
            FieldSetting("Секунда кадра для видео", text: $c.draft.textSecond)
        case .download:
            Toggle("Только звук (M4A)", isOn: $c.draft.downloadAudioOnly)
            if !c.draft.downloadAudioOnly {
                Picker("Качество", selection: $c.draft.downloadHeight) {
                    Text("Лучшее").tag(0)
                    ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("до \($0) p").tag($0) }
                }
            }
        }
    }

    private var dropZone: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").imageScale(.large).foregroundStyle(dropping ? Color.accentColor : Color.secondary)
                Text("Перетащи файлы сюда или выбери")
                Spacer()
                Button("Выбрать файлы…") { c.chooseFiles() }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
                let collector = DropCollector(count: providers.count) { paths in Task { @MainActor in c.submit(paths: paths) } }
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in collector.add(url?.path) }
                }
                return !providers.isEmpty
            }
        }
    }

    private var downloadSection: some View {
        Section {
            TextField("Ссылка", text: $c.draft.url, prompt: Text("https://…")).onSubmit { c.download() }
            Button("Скачать") { c.download() }.disabled(c.tools.ytDlp == nil || c.draft.url.isEmpty)
        } header: { Text("Скачать по ссылке") } footer: {
            if c.tools.ytDlp == nil { SectionFooter("yt-dlp не найден: brew install yt-dlp", color: .orange) }
        }
    }
}

struct MediaSettingsPage: View {
    @ObservedObject private var c = MediaToolsController.shared

    private func binding<T>(_ kp: WritableKeyPath<MediaSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        let _ = c.revision
        SettingsPage {
            Section("Результат") {
                LabeledContent {
                    HStack(spacing: 12) {
                        Button("Выбрать…") { c.chooseOutputFolder() }
                        if !c.settings.outputFolder.isEmpty { Button("Сбросить") { var s = c.settings; s.outputFolder = ""; c.update(s) } }
                    }
                } label: { SettingLabel("Папка результата", c.settings.outputFolder.isEmpty ? "Рядом с исходным файлом" : c.settings.outputFolder) }
                Toggle(isOn: binding(\.overwriteExisting)) { SettingLabel("Перезаписывать существующий файл", "Выключено: к имени добавляется номер") }
                Toggle(isOn: binding(\.stripMetadata)) { SettingLabel("Убирать метаданные", "Геотеги, камера, дата съёмки не попадают в результат") }
                Toggle(isOn: binding(\.notifyWhenDone)) { SettingLabel("Уведомлять о завершении", "Готово или ошибка по каждой задаче") }
                Toggle(isOn: binding(\.revealWhenDone)) { SettingLabel("Показывать результат в Finder", "После успешной задачи") }
            }
            Section("Кодирование") {
                Picker(selection: binding(\.codec)) { ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) } } label: { SettingLabel("Кодек", "H.265 вдвое меньше, но не везде играет") }
                Picker(selection: binding(\.preset)) { ForEach(MediaSettings.presets, id: \.self) { Text($0).tag($0) } } label: { SettingLabel("Скорость кодирования", "Медленнее: меньше файл при том же качестве") }
                StepperSetting("Звук в видео", value: binding(\.audioKbps), in: MediaSettings.audioRange, step: 32, unit: " кбит/с")
                StepperSetting("Предел высоты", value: binding(\.maxHeight), in: 0...4320, step: 360, unit: " p", zeroText: "без предела")
                StepperSetting("Одновременных задач", "Применяется после перезапуска", value: binding(\.parallelJobs), in: MediaSettings.parallelRange)
                Toggle(isOn: binding(\.hardwareEncoder)) { SettingLabel("Аппаратное кодирование", "VideoToolbox: быстро и без нагрузки на процессор, файл крупнее") }
            }
        }
    }
}

private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var remaining: Int
    private let done: ([String]) -> Void

    init(count: Int, done: @escaping ([String]) -> Void) {
        remaining = count
        self.done = done
    }

    func add(_ path: String?) {
        lock.lock()
        if let path { paths.append(path) }
        remaining -= 1
        let finished = remaining == 0
        let all = paths
        lock.unlock()
        if finished { done(all.sorted()) }
    }
}
