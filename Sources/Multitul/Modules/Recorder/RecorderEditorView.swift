import SwiftUI
import AppKit
import AVKit
import MultitulCore
import MultitulUI

struct RecPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct RecEditorView: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    RecPlayerView(player: m.player)
                    if m.building { ProgressView().controlSize(.small).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                }
                .frame(minHeight: 280)
                transport
                Divider()
                RecTimelineView(m: m).padding(.horizontal, 12).padding(.vertical, 8)
                statusBar
            }
            Divider()
            inspector.frame(width: 330)
        }
        .sheet(item: $m.region) { mode in RecRegionEditor(m: m, mode: mode) }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { m.togglePlay() } label: { Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                .keyboardShortcut(.space, modifiers: [])
                .help("Пуск и пауза (пробел)")
            Button { m.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.keyboardShortcut(.leftArrow, modifiers: []).help("Кадр назад")
            Button { m.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.keyboardShortcut(.rightArrow, modifiers: []).help("Кадр вперёд")
            Text(RecTimeFormat.precise(m.playhead)).font(Theme.Fonts.mono)
            Text("из \(RecTimeFormat.precise(m.doc.source.duration))").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            Spacer()
            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!m.canUndo).keyboardShortcut("z", modifiers: .command).help("Отменить")
            Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!m.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Вернуть")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let p = m.progress {
                ProgressView(value: p).frame(width: 160)
                Text("\(Int(p * 100))%").font(Theme.Fonts.caption.monospacedDigit())
                Button("Отменить") { m.cancelExport() }.controlSize(.small)
            }
            Text(m.status).font(Theme.Fonts.caption).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Text("Итог: \(RecTimeFormat.precise(m.timeline.outputDuration))").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            SegmentedControl(segments: RecEditorTab.allCases.map(\.title), selection: Binding(get: { RecEditorTab.allCases.firstIndex(of: m.tab) ?? 0 }, set: { m.tab = RecEditorTab.allCases[$0] }))
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch m.tab {
                    case .montage: RecMontagePanel(m: m)
                    case .frame: RecFramePanel(m: m)
                    case .zoom: RecZoomPanel(m: m)
                    case .audio: RecAudioPanel(m: m)
                    case .privacy: RecPrivacyPanel(m: m)
                    case .export: RecExportPanel(m: m)
                    }
                }.padding(12)
            }
        }
    }
}

private func rowLabel(_ t: String) -> some View { Text(t).font(Theme.Fonts.label).foregroundStyle(Theme.muted) }

struct RecMontagePanel: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowLabel("ВЫДЕЛЕНИЕ")
            HStack {
                Button("Начало здесь") { m.markIn() }.keyboardShortcut("i", modifiers: [])
                Button("Конец здесь") { m.markOut() }.keyboardShortcut("o", modifiers: [])
                Button("Снять") { m.clearSelection() }.disabled(m.selection == nil)
            }
            if let s = m.selection {
                Text("\(RecTimeFormat.precise(s.lowerBound)) – \(RecTimeFormat.precise(s.upperBound)) (\(String(format: "%.1f", s.upperBound - s.lowerBound)) с)").font(Theme.Fonts.number)
            } else {
                Text("Выдели участок на дорожке с зажатым ⌥ или кнопками выше").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                Button { m.trimToSelection() } label: { Label("Оставить выделение", systemImage: "scissors") }.disabled(m.selection == nil)
                Button { m.cutSelection() } label: { Label("Вырезать", systemImage: "trash") }.disabled(m.selection == nil)
            }
            Divider()
            rowLabel("ФРАГМЕНТЫ")
            HStack {
                Button { m.split() } label: { Label("Разрезать здесь", systemImage: "square.split.2x1") }.keyboardShortcut("s", modifiers: [])
                Button { m.removeSegmentAtPlayhead() } label: { Label("Удалить фрагмент", systemImage: "minus.circle") }
            }
            Divider()
            rowLabel("СКОРОСТЬ")
            Picker("", selection: Binding(get: { m.currentSpeed }, set: { m.setSpeed($0) })) {
                ForEach(RecTimeline.speedChoices, id: \.self) { Text($0 == 1 ? "Обычная" : "×\(RecTimeFormat.speed($0))").tag($0) }
            }.labelsHidden().frame(width: 150)
            Text(m.selection == nil ? "Меняется у фрагмента под курсором; с выделением — у выделения" : "Применится к выделению").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            Divider()
            HStack {
                Button("Сбросить монтаж") { m.resetMontage() }.disabled(m.timeline.isIdentity)
                Spacer()
                Text("\(m.timeline.segments.count) фр.").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct RecFramePanel: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowLabel("КАДРИРОВАНИЕ")
            HStack {
                Button { m.openRegion(.crop) } label: { Label("Выбрать область", systemImage: "crop") }
                Button("Сбросить") { m.setCrop(.full) }.disabled(m.doc.crop.isFull)
            }
            Picker("Пропорции", selection: Binding(get: { m.doc.aspect }, set: { m.setAspect($0) })) {
                ForEach(RecAspect.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            Text("Размер кадра: \(Int(m.exportPlan.canvas.width))×\(Int(m.exportPlan.canvas.height))").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            Divider()
            rowLabel("ФОН И РАМКА")
            Picker("Фон", selection: Binding(get: { m.doc.style.background }, set: { v in m.editStyle { $0.background = v } })) {
                ForEach(ShotBackground.presets, id: \.title) { Text($0.title).tag($0.value.stored) }
            }.pickerStyle(.menu)
            slider("Поля", value: Double(m.doc.style.padding), range: 0...160) { v in m.editStyle { $0.padding = Int(v) } }
            slider("Скругление", value: Double(m.doc.style.corner), range: 0...80) { v in m.editStyle { $0.corner = Int(v) } }
            Toggle("Тень под рамкой", isOn: Binding(get: { m.doc.style.shadow }, set: { v in m.editStyle { $0.shadow = v } })).toggleStyle(.checkbox)
            Divider()
            rowLabel("КЛИКИ")
            Toggle("Подсвечивать клики кольцом", isOn: Binding(get: { m.doc.style.highlightClicks }, set: { v in m.editStyle { $0.highlightClicks = v } })).toggleStyle(.checkbox)
                .disabled(!m.hasClicks)
            HStack(spacing: 6) {
                ForEach(ShotColor.palette.prefix(6), id: \.self) { c in
                    Button { m.editStyle { $0.clickColor = c.hex } } label: {
                        Circle().fill(Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(m.doc.style.clickColor == c.hex ? Color.white : Color.black.opacity(0.25), lineWidth: m.doc.style.clickColor == c.hex ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
            slider("Размер кольца", value: m.doc.style.clickRadius, range: 0.01...0.1) { v in m.editStyle { $0.clickRadius = v } }
            if !m.hasClicks { Text("В этой записи нет данных о кликах").font(Theme.Fonts.caption).foregroundStyle(Theme.muted) }
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(Theme.Fonts.body).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

struct RecZoomPanel: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Автоприближение включено", isOn: Binding(get: { m.doc.zoomEnabled }, set: { m.setZoomEnabled($0) })).toggleStyle(.switch)
            if !m.hasClicks { Text("Кликов в записи нет: приближения можно добавить вручную").font(Theme.Fonts.caption).foregroundStyle(Theme.muted) }
            rowLabel("ПАРАМЕТРЫ")
            HStack {
                Text("Сила").frame(width: 90, alignment: .leading)
                Slider(value: Binding(get: { m.doc.zoomSettings.level }, set: { v in m.editZoomSettings { $0.level = v } }), in: RecSettings.zoomLevelRange)
                Text(String(format: "×%.1f", m.doc.zoomSettings.level)).font(Theme.Fonts.number).frame(width: 40)
            }
            HStack {
                Text("Удержание").frame(width: 90, alignment: .leading)
                Slider(value: Binding(get: { m.doc.zoomSettings.minHold }, set: { v in m.editZoomSettings { $0.minHold = v } }), in: 0.5...6)
                Text(String(format: "%.1f с", m.doc.zoomSettings.minHold)).font(Theme.Fonts.number).frame(width: 40)
            }
            Picker("Плавность", selection: Binding(get: { m.doc.zoomSettings.easing }, set: { v in m.editZoomSettings { $0.easing = v } })) {
                ForEach(RecEase.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            Toggle("Следовать за курсором", isOn: Binding(get: { m.doc.zoomSettings.follow }, set: { v in m.editZoomSettings { $0.follow = v } })).toggleStyle(.checkbox)
            Toggle("Приближать, когда курсор замер", isOn: Binding(get: { m.doc.zoomSettings.dwell }, set: { v in m.editZoomSettings { $0.dwell = v } })).toggleStyle(.checkbox)
            Toggle("Правые клики тоже", isOn: Binding(get: { m.doc.zoomSettings.rightClicks }, set: { v in m.editZoomSettings { $0.rightClicks = v } })).toggleStyle(.checkbox)
            HStack {
                Button { m.regenerateZoom() } label: { Label("Расставить заново", systemImage: "wand.and.stars") }
                Button { m.addZoomHere() } label: { Label("Добавить здесь", systemImage: "plus.magnifyingglass") }
            }
            Divider()
            rowLabel("ПРИБЛИЖЕНИЯ (\(m.doc.zoom.spans.count))")
            ForEach(Array(m.doc.zoom.spans.enumerated()), id: \.offset) { i, s in
                HStack {
                    Button { m.seek(source: s.holdStart) } label: { Text("\(RecTimeFormat.precise(s.holdStart)) – \(RecTimeFormat.precise(s.holdEnd))").font(Theme.Fonts.number) }.buttonStyle(.plain)
                    Spacer()
                    Stepper(String(format: "×%.1f", s.level), value: Binding(get: { s.level }, set: { m.setZoomLevel(at: i, $0) }), in: RecSettings.zoomLevelRange, step: 0.1).fixedSize()
                    Button { m.removeZoom(at: i) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct RecAudioPanel: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !m.doc.source.hasSystemAudio && !m.doc.source.hasMicrophone {
                Text("В этой записи нет звуковых дорожек").font(Theme.Fonts.body).foregroundStyle(Theme.muted)
            }
            if m.doc.source.hasSystemAudio {
                track("Звук системы", volume: m.doc.audio.systemVolume, muted: m.doc.audio.systemMuted,
                      setVolume: { v in m.editAudio { $0.systemVolume = v } }, setMuted: { v in m.editAudio { $0.systemMuted = v } })
            }
            if m.doc.source.hasMicrophone {
                track("Микрофон", volume: m.doc.audio.micVolume, muted: m.doc.audio.micMuted,
                      setVolume: { v in m.editAudio { $0.micVolume = v } }, setMuted: { v in m.editAudio { $0.micMuted = v } })
            }
            Text("Дорожки хранятся в файле отдельно: громкость и выключение меняют только экспорт и просмотр, исходный файл не трогается.").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
        }
    }

    private func track(_ title: String, volume: Double, muted: Bool, setVolume: @escaping (Double) -> Void, setMuted: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                rowLabel(title.uppercased())
                Spacer()
                Toggle("Выкл.", isOn: Binding(get: { muted }, set: setMuted)).toggleStyle(.checkbox)
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(Theme.muted)
                Slider(value: Binding(get: { volume }, set: setVolume), in: RecAudioMix.volumeRange).disabled(muted)
                Text("\(Int(volume * 100))%").font(Theme.Fonts.number).frame(width: 46)
            }
        }
    }
}

struct RecPrivacyPanel: View {
    @ObservedObject var m: RecEditorModel
    @State private var pixelate = false
    @State private var strength = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Закрой размытием пароли, почту и всё личное: участок скрыт только на выбранное время.").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            Toggle("Пикселизация вместо размытия", isOn: $pixelate).toggleStyle(.checkbox)
            HStack {
                Text("Сила").frame(width: 60, alignment: .leading)
                Slider(value: $strength, in: 0.2...1)
            }
            Button { m.openRegion(.newBlur) } label: { Label("Нарисовать область на кадре", systemImage: "rectangle.dashed") }
            Divider()
            rowLabel("СКРЫТЫЕ УЧАСТКИ (\(m.doc.blurs.count))")
            ForEach(m.doc.blurs) { b in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button { m.seek(source: b.srcStart) } label: { Text("\(RecTimeFormat.precise(b.srcStart)) – \(RecTimeFormat.precise(b.srcEnd))").font(Theme.Fonts.number) }.buttonStyle(.plain)
                        Spacer()
                        Button { m.openRegion(.editBlur(b.id)) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Изменить область")
                        Button { m.removeBlur(b.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                    HStack {
                        Text("С").font(Theme.Fonts.caption)
                        Stepper(RecTimeFormat.precise(b.srcStart), value: Binding(get: { b.srcStart }, set: { v in m.updateBlur(b.id) { $0.srcStart = max(min(v, $0.srcEnd - 0.1), 0) } }), in: 0...m.doc.source.duration, step: 0.25).fixedSize()
                        Text("До").font(Theme.Fonts.caption)
                        Stepper(RecTimeFormat.precise(b.srcEnd), value: Binding(get: { b.srcEnd }, set: { v in m.updateBlur(b.id) { $0.srcEnd = min(max(v, $0.srcStart + 0.1), m.doc.source.duration) } }), in: 0...m.doc.source.duration, step: 0.25).fixedSize()
                    }
                    HStack {
                        Toggle("Пиксели", isOn: Binding(get: { b.pixelate }, set: { v in m.updateBlur(b.id) { $0.pixelate = v } })).toggleStyle(.checkbox)
                        Slider(value: Binding(get: { b.strength }, set: { v in m.updateBlur(b.id) { $0.strength = v } }), in: 0.2...1)
                    }
                }
                .padding(8).background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear { m.pendingBlurStyle = (pixelate, strength) }
        .onChange(of: strength) { _, v in m.pendingBlurStyle = (pixelate, v) }
        .onChange(of: pixelate) { _, v in m.pendingBlurStyle = (v, strength) }
    }
}

struct RecExportPanel: View {
    @ObservedObject var m: RecEditorModel

    var body: some View {
        let plan = m.exportPlan
        VStack(alignment: .leading, spacing: 10) {
            rowLabel("ПРЕСЕТ")
            Picker("", selection: $m.presetID) {
                ForEach(m.allPresets()) { Text($0.title).tag($0.id) }
            }.labelsHidden()
            Text(m.currentPreset.summary).font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            if m.currentPreset.kind == .gif { gifOptions }
            Divider()
            HStack {
                Text("Размер кадра").font(Theme.Fonts.body)
                Spacer()
                Text("\(Int(plan.canvas.width))×\(Int(plan.canvas.height))").font(Theme.Fonts.number)
            }
            HStack {
                Text("Длительность").font(Theme.Fonts.body)
                Spacer()
                Text(RecTimeFormat.precise(plan.outputDuration)).font(Theme.Fonts.number)
            }
            HStack {
                Text("Примерный размер файла").font(Theme.Fonts.body)
                Spacer()
                Text(RecTimeFormat.bytes(plan.estimatedBytes)).font(Theme.Fonts.number)
            }
            if !plan.isGif {
                HStack {
                    Text("Звуковые дорожки").font(Theme.Fonts.body)
                    Spacer()
                    Text(plan.audioGroups.isEmpty ? "нет" : plan.audioGroups.map(\.title).joined(separator: ", ")).font(Theme.Fonts.number)
                }
            }
            ForEach(plan.warnings, id: \.self) { Text($0).font(Theme.Fonts.caption).foregroundStyle(Theme.warn) }
            Divider()
            Button { m.exportToFile() } label: { Label("Сохранить как…", systemImage: "square.and.arrow.down") }.disabled(m.progress != nil || plan.pieces.isEmpty)
            HStack {
                Button { m.exportAndLink() } label: { Label("Получить ссылку", systemImage: "link") }.disabled(m.progress != nil || plan.pieces.isEmpty)
                Button { m.putOnShelf() } label: { Label("На полку", systemImage: "tray") }.disabled(m.lastExport == nil)
            }
            Divider()
            rowLabel("СВОЙ ПРЕСЕТ")
            HStack {
                TextField("Название", text: $m.presetName).textFieldStyle(.roundedBorder)
                Button("Сохранить") { m.saveCurrentPreset() }.disabled(m.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let c = m.controller, c.exportPresets.contains(where: { $0.id == m.presetID }) {
                Button("Удалить этот пресет", role: .destructive) { let id = m.presetID; m.presetID = "web1080"; c.removeExportPreset(id) }
            }
        }
    }

    private var gifOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Кадров в секунду").frame(width: 130, alignment: .leading)
                Picker("", selection: $m.gifDraft.fps) { ForEach(RecGifOptions.fpsChoices, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 80)
            }
            HStack {
                Text("Ширина").frame(width: 130, alignment: .leading)
                Picker("", selection: $m.gifDraft.maxWidth) { ForEach(RecGifOptions.widthChoices, id: \.self) { Text($0 == 0 ? "Как есть" : "\($0) px").tag($0) } }.labelsHidden().frame(width: 110)
            }
            HStack {
                Text("Цветов").frame(width: 130, alignment: .leading)
                Stepper("\(m.gifDraft.colors)", value: $m.gifDraft.colors, in: 8...256, step: 8).fixedSize()
            }
            HStack {
                Text("Сглаживание").frame(width: 130, alignment: .leading)
                Picker("", selection: $m.gifDraft.dither) { ForEach(RecDither.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
            }
            Toggle("Крутить по кругу", isOn: Binding(get: { m.gifDraft.loop == 0 }, set: { m.gifDraft.loop = $0 ? 0 : 1 })).toggleStyle(.checkbox)
        }
    }
}

extension RecTimeFormat {
    static func speed(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
}
