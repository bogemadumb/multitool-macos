import SwiftUI
import AppKit
import Combine
import MultitulCore
import MultitulUI

@MainActor
final class IslandLevelsModel: ObservableObject {
    @Published var volume = 0.0
    @Published var muted = false
    @Published var hasVolume = false
}

@MainActor
final class IslandLevelsSection: IslandSectionBase {
    let model = IslandLevelsModel()
    private let driver = IslSystemLevels()
    private var listener: IslVolumeListener?
    private var volumeFilter = IslLevelsChangeFilter()
    private var brightnessFilters: [String: IslLevelsChangeFilter] = [:]
    private var huds: [String: IslActivity] = [:]
    private var rowsWatch: AnyCancellable?

    init() { super.init(IslSectionIDs.levels) }

    override var availability: IslAvailability {
        model.hasVolume || BrightnessController.shared.running ? .available : .unavailable("Нет управления громкостью; включи модуль «Яркость»")
    }

    override var activities: [IslActivity] {
        let now = Date()
        return huds.values.filter { !$0.isExpired(at: now) }
    }

    override func start() {
        readVolume()
        let l = IslVolumeListener { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.volumeEvent() } }
        }
        l.start()
        listener = l
        rowsWatch = BrightnessController.shared.$rows.sink { [weak self] rows in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.brightnessEvent(rows) } }
        }
    }

    override func stop() {
        listener?.stop()
        listener = nil
        rowsWatch = nil
        huds = [:]
        volumeFilter.reset()
        brightnessFilters = [:]
    }

    private func readVolume() {
        let v = driver.outputVolume()
        model.hasVolume = v != nil
        if let v { model.volume = Double(v) }
        model.muted = driver.isMuted() ?? false
    }

    private func volumeEvent() {
        let wasAvailable = model.hasVolume
        readVolume()
        let shown = model.muted ? 0 : model.volume
        if model.hasVolume, volumeFilter.externalChange(shown, now: Date()) {
            huds["hud.volume"] = IslLevelsMath.hudActivity(kind: "volume", section: IslSectionIDs.levels, value: shown, now: Date())
        }
        if wasAvailable != model.hasVolume || huds["hud.volume"] != nil { notify() }
    }

    private func brightnessEvent(_ rows: [BrightnessRow]) {
        guard let row = rows.first(where: { $0.isBuiltin }) ?? rows.first else { return }
        var f = brightnessFilters[row.id] ?? IslLevelsChangeFilter()
        if f.externalChange(row.value, now: Date()) {
            huds["hud.brightness"] = IslLevelsMath.hudActivity(kind: "brightness", section: IslSectionIDs.levels, value: row.value, now: Date())
            notify()
        }
        brightnessFilters[row.id] = f
    }

    func setVolume(_ v: Double) {
        let c = IslLevelsMath.clamp(v)
        volumeFilter.noteLocalChange(until: Date().addingTimeInterval(0.7))
        model.volume = c
        if model.muted, c > 0 { toggleMute() }
        _ = driver.setOutputVolume(Float(c))
    }

    func toggleMute() {
        volumeFilter.noteLocalChange(until: Date().addingTimeInterval(0.7))
        let target = !model.muted
        if driver.setMuted(target) { model.muted = target } else if target { model.volume = 0; _ = driver.setOutputVolume(0) }
    }

    func setBrightness(_ id: String, _ v: Double) {
        var f = brightnessFilters[id] ?? IslLevelsChangeFilter()
        f.noteLocalChange(until: Date().addingTimeInterval(0.7))
        brightnessFilters[id] = f
        BrightnessController.shared.setBrightness(id: id, value: v)
    }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        let symbol = activity.id == "hud.brightness" ? IslLevelsMath.brightnessSymbol(Double(activity.title.dropLast()).map { $0 / 100 } ?? 0.5)
            : IslLevelsMath.volumeSymbol(model.volume, muted: model.muted)
        return AnyView(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(Text(activity.title).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandLevelsView(section: self)) }
}

struct IslandLevelsView: View {
    let section: IslandLevelsSection
    @ObservedObject var model: IslandLevelsModel
    @ObservedObject private var brightness = BrightnessController.shared

    init(section: IslandLevelsSection) {
        self.section = section
        model = section.model
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasVolume {
                    HStack(spacing: 10) {
                        IslIconButton(symbol: IslLevelsMath.volumeSymbol(model.volume, muted: model.muted), size: 16, help: model.muted ? "Включить звук" : "Выключить звук") { section.toggleMute() }
                        IslSlider(value: Binding(get: { model.muted ? 0 : model.volume }, set: { section.setVolume($0) }))
                        Text("\(IslLevelsMath.percent(model.muted ? 0 : model.volume))%").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7)).frame(width: 40, alignment: .trailing)
                    }
                } else {
                    Text("Выбранное устройство вывода не даёт менять громкость").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(brightness.rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: IslLevelsMath.brightnessSymbol(row.value)).font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 24).foregroundStyle(.white)
                        IslSlider(value: Binding(get: { row.value }, set: { section.setBrightness(row.id, $0) }))
                        Text(row.name).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).frame(width: 40, alignment: .trailing)
                    }
                }
                if !brightness.running {
                    Text("Яркость: включи модуль «Яркость» на странице «Экраны»").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

@MainActor
final class IslandShortcutsSection: IslandSectionBase {
    private let runner = IslShortcutRunner(fs: FileSystemLauncherChecker(), executor: AppLauncherExecutor())
    @Published var message = ""

    init() { super.init(IslSectionIDs.shortcuts) }

    func run(_ item: IslShortcut, close: () -> Void) {
        switch runner.run(item) {
        case .success:
            if case .toggle = item.target { return }
            close()
        case .failure(let e):
            HUD.show(e.message)
        }
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandShortcutsView(section: self, context: context)) }
}

struct IslandShortcutsView: View {
    let section: IslandShortcutsSection
    let context: IslExpandContext
    @ObservedObject private var ctl = IslandController.shared

    var body: some View {
        if ctl.shortcuts.items.isEmpty {
            IslEmptyNote(symbol: "square.grid.2x2", text: "Кнопок пока нет. Добавь их в настройках острова")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(ctl.shortcuts.items) { item in
                        IslTile(symbol: item.symbol, title: item.title) { section.run(item, close: context.closeIsland) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
        }
    }
}

@MainActor
final class IslandMixerSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.mixer) }

    override var availability: IslAvailability {
        if !MixerController.shared.supported { return .unavailable("Нужна macOS 14.2") }
        return requires(.mixer)
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandMixerView()) }
}

struct IslandMixerView: View {
    @ObservedObject private var c = MixerController.shared

    var body: some View {
        let s = c.snapshot
        Group {
            if s.rows.isEmpty {
                IslEmptyNote(symbol: "slider.vertical.3", text: "Сейчас ничего не играет")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.rows) { r in
                            MixerRowView(row: r, options: s.options, maxBoost: s.settings.maxBoost, fine: s.settings.fineSteps, levels: c.levels[r.key],
                                         processing: s.processing.contains(r.key), error: s.errors[r.key], offlineRoute: s.fallbackKeys.contains(r.key), compact: true)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                }
            }
        }
        .onAppear { c.viewerAppeared() }
        .onDisappear { c.viewerDisappeared() }
    }
}

@MainActor
final class IslandClipboardModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    private var picker: ClipPickerModel?
    private var watch: [AnyCancellable] = []

    func attach() {
        let c = ClipboardController.shared
        watch = [c.$lastItem.sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } } },
                 c.$count.sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } } }]
        reload()
    }

    func detach() {
        watch = []
        picker = nil
        items = []
    }

    func reload() {
        let c = ClipboardController.shared
        guard c.running, let store = c.store else { items = []; picker = nil; return }
        let p = ClipPickerModel(store: store, engine: c.engine)
        p.limit = 40
        p.reload()
        picker = p
        items = p.items
    }

    func activate(_ it: ClipItem, plain: Bool) {
        guard let picker else { return }
        let c = ClipboardController.shared
        let out = picker.activate([it], plain: plain, copyOnly: !c.settings.pasteOnPick, target: ClipServices.shared.lastExternal) { result in
            if result == .needsAccessibility { HUD.show("Скопировано. Для вставки нужен Универсальный доступ") }
        }
        if out == .copiedOnly { HUD.show("Скопировано в буфер") }
        c.refreshCounts()
    }

    func togglePin(_ it: ClipItem) {
        picker?.togglePin(it)
        reload()
    }
}

@MainActor
final class IslandClipboardSection: IslandSectionBase {
    let model = IslandClipboardModel()

    init() { super.init(IslSectionIDs.clipboard) }

    override var availability: IslAvailability {
        let c = ClipboardController.shared
        if !moduleRunning(.clipboardHistory) { return .unavailable("Включи модуль «История буфера»") }
        return c.store == nil ? .unavailable("Хранилище буфера недоступно") : .available
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandClipboardView(model: model, context: context)) }
}

struct IslandClipboardView: View {
    @ObservedObject var model: IslandClipboardModel
    let context: IslExpandContext

    var body: some View {
        Group {
            if model.items.isEmpty {
                IslEmptyNote(symbol: "doc.on.clipboard", text: "История пока пуста")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { it in
                            IslandClipRow(item: it) {
                                context.closeIsland()
                                model.activate(it, plain: NSEvent.modifierFlags.contains(.shift))
                            } pin: { model.togglePin(it) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }
}

struct IslandClipRow: View {
    let item: ClipItem
    let action: () -> Void
    let pin: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.kind.symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.white.opacity(0.7))
            Text(item.title.isEmpty ? item.kind.title : item.title).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 6)
            if let s = item.sourceName { Text(s).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1) }
            Button(action: pin) { Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 11)).foregroundStyle(item.pinned ? Theme.accent : .white.opacity(hover ? 0.6 : 0)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(hover ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

@MainActor
final class IslandShotsModel: ObservableObject {
    @Published private(set) var records: [ShotRecord] = []
    @Published private(set) var thumbs: [Int64: NSImage] = [:]

    func reload() {
        guard let h = ScreenshotController.shared.history else { records = []; return }
        let found = (try? h.recent(limit: 8)) ?? []
        for r in found where thumbs[r.id] == nil {
            if let d = try? h.thumbnail(id: r.id), let img = NSImage(data: d) { thumbs[r.id] = img }
        }
        records = found
    }

    func clear() {
        records = []
        thumbs = [:]
    }

    private func image(_ r: ShotRecord) -> CGImage? { r.path.flatMap { ShotImageOps.load(path: $0) } }

    func copy(_ r: ShotRecord) {
        guard let img = image(r) else { HUD.show("Файл снимка не найден"); return }
        ScreenshotController.shared.copy(img, data: nil)
    }

    func edit(_ r: ShotRecord) {
        guard let img = image(r) else { HUD.show("Файл снимка не найден"); return }
        ScreenshotController.shared.openEditor(record: r, image: img)
    }

    func reveal(_ r: ShotRecord) {
        guard let p = r.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}

@MainActor
final class IslandShotsSection: IslandSectionBase {
    let model = IslandShotsModel()
    private(set) var tracker = IslShotTracker()
    private var subscription: Int?

    init() { super.init(IslSectionIDs.shots) }

    override var availability: IslAvailability {
        moduleRunning(.screenshot) || moduleRunning(.screenRecorder) ? .available : .unavailable("Включи модуль «Скриншоты» или «Запись экрана»")
    }

    override var activities: [IslActivity] { tracker.activities(now: Date()) }

    override func start() {
        subscription = ScreenshotController.shared.events.subscribe { [weak self] e in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tracker.apply(e, now: Date())
                    if case .captured = e { self.model.reload() }
                    self.notify()
                }
            }
        }
    }

    override func stop() {
        if let s = subscription { ScreenshotController.shared.events.unsubscribe(s) }
        subscription = nil
        tracker = IslShotTracker()
        model.clear()
    }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        if activity.id == "recording" { return AnyView(IslandRecordDot(paused: activity.token == "paused")) }
        return AnyView(Image(systemName: "camera.viewfinder").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        if activity.id == "recording" { return AnyView(IslandRecordClock(tracker: tracker)) }
        return AnyView(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ok))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandShotsView(section: self, context: context)) }
}

struct IslandRecordDot: View {
    var paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: paused)) { ctx in
            let on = paused || Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle().fill(paused ? Theme.warn : Theme.danger).frame(width: 9, height: 9).opacity(on ? 1 : 0.35)
        }
    }
}

struct IslandRecordClock: View {
    let tracker: IslShotTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(IslTimeFormat.clock(tracker.elapsed(at: ctx.date))).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
    }
}

struct IslandShotsView: View {
    let section: IslandShotsSection
    let context: IslExpandContext
    @ObservedObject var model: IslandShotsModel
    @ObservedObject private var recorder = RecorderController.shared

    init(section: IslandShotsSection, context: IslExpandContext) {
        self.section = section
        self.context = context
        model = section.model
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if section.moduleRunning(.screenshot) {
                    IslTile(symbol: "viewfinder", title: "Область") { context.closeIsland(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ScreenshotController.shared.begin(.area) } }
                    IslTile(symbol: "macwindow", title: "Окно") { context.closeIsland(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ScreenshotController.shared.begin(.window) } }
                    IslTile(symbol: "display", title: "Экран") { context.closeIsland(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ScreenshotController.shared.begin(.screen) } }
                }
                if section.moduleRunning(.screenRecorder) {
                    IslTile(symbol: recorder.state.isActive ? "stop.circle.fill" : "record.circle", title: recorder.state.isActive ? "Стоп" : "Запись", active: recorder.state.isActive) {
                        if recorder.state.isActive { recorder.toggle() } else { context.closeIsland(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { recorder.toggle() } }
                    }
                }
            }
            if model.records.isEmpty {
                IslEmptyNote(symbol: "camera.viewfinder", text: "Снимков пока нет")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.records) { r in
                            Group {
                                if let img = model.thumbs[r.id] { Image(nsImage: img).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
                            }
                            .frame(width: 88, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { model.copy(r) }
                            .contextMenu {
                                Button("Копировать") { model.copy(r) }
                                Button("Править") { context.closeIsland(); model.edit(r) }
                                Button("Показать в Finder") { model.reveal(r) }
                            }
                            .help("Клик — скопировать, правый клик — меню")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 60)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onAppear { model.reload() }
    }
}

@MainActor
final class IslandShelfSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.shelf) }

    override var availability: IslAvailability {
        let c = ShelfController.shared
        if !moduleRunning(.shelf) { return .unavailable("Включи модуль «Полка»") }
        return c.model == nil ? .unavailable("Хранилище полки недоступно") : .available
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView {
        guard let m = ShelfController.shared.model else { return AnyView(IslEmptyNote(symbol: "tray", text: "Полка недоступна")) }
        return AnyView(ShelfView(model: m, showClose: false, embedded: true))
    }
}

@MainActor
final class IslandStatsSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.stats) }

    override var availability: IslAvailability {
        SystemHub.shared.enabled.isEmpty ? .unavailable("Включи любой модуль мониторинга (процессор, память, сеть…)") : .available
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandStatsView()) }
}

struct IslandStatsView: View {
    @ObservedObject private var hub = SystemHub.shared

    var body: some View {
        let s = hub.snapshot
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                if let c = s.cpu { stat("cpu", "Процессор", "\(SysFormat.percent(c.total))%", c.total, extra: s.temps.cpu.map(SysFormat.temperature)) }
                if let g = s.gpu { stat("display", "Графика", "\(SysFormat.percent(g.utilization))%", g.utilization, extra: nil) }
                if let m = s.memory { stat("memorychip", "Память", "\(SysFormat.percent(m.composition.usedFraction))%", m.composition.usedFraction, extra: nil) }
                if let n = s.network {
                    stat("arrow.up.arrow.down", "Сеть", "↓ \(SysFormat.rateShort(n.downBps))", nil, extra: "↑ \(SysFormat.rateShort(n.upBps))")
                }
                if let b = s.battery, b.hasBattery {
                    stat(b.isCharging ? "battery.100.bolt" : "battery.75", "Батарея", IslStatsFormat.batteryText(percent: b.percent, charging: b.isCharging, onAC: b.onAC, minutes: b.timeRemainingMin), b.percent.map { Double($0) / 100 }, extra: nil)
                }
                if let d = s.disk { stat("internaldrive", "Диск", "↓ \(SysFormat.rateShort(d.readBps))", nil, extra: "↑ \(SysFormat.rateShort(d.writeBps))") }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .onAppear { hub.panelAppeared() }
        .onDisappear { hub.panelDisappeared() }
    }

    private func stat(_ symbol: String, _ title: String, _ value: String, _ fraction: Double?, extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.6))
            Text(value).font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            if let fraction { IslSlider(value: .constant(fraction), height: 4).allowsHitTesting(false).frame(height: 8) }
            if let extra { Text(extra).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.55)) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
final class IslandToolsSection: IslandSectionBase {
    init() { super.init(IslSectionIDs.tools) }

    var tools: [LauncherTool] { IslToolsCatalog.tools { ToolsRouter.shared.isAvailable($0) } }

    override var availability: IslAvailability {
        tools.isEmpty && !moduleRunning(.quickToggles) ? .unavailable("Включи модули инструментов") : .available
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandToolsView(section: self, context: context)) }
}

struct IslandToolsView: View {
    let section: IslandToolsSection
    let context: IslExpandContext
    @ObservedObject private var toggles = QuickTogglesController.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(section.tools) { t in
                    IslTile(symbol: t.symbol, title: t.title) {
                        context.closeIsland()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ToolsRouter.shared.run(t) }
                    }
                }
                if section.moduleRunning(.quickToggles) {
                    ForEach(IslToolsCatalog.toggles) { t in
                        IslTile(symbol: t.symbol, title: t.caption, active: toggles.state(t)) { toggles.perform(t) }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }
}
