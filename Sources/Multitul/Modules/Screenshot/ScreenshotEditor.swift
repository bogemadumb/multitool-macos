import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ShotEditorModel: ObservableObject {
    @Published var tool = AnnotationTool.arrow
    @Published var color = ShotColor.red
    @Published var stroke = 4.0
    @Published var fontSize = 28.0
    @Published var strength = 0.6
    @Published var filled = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelection = false
    @Published var hasCrop = false
    @Published var padding = 0
    @Published var background = ShotBackground.none
    @Published var watermarkOn = false
    @Published var status = ""
    var perform: (String) -> Void = { _ in }
}

struct ShotEditorToolbar: View {
    @ObservedObject var m: ShotEditorModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(AnnotationTool.allCases, id: \.self) { t in
                    Button { m.tool = t; m.perform("tool") } label: {
                        Image(systemName: t.symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
                            .background(m.tool == t ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(t.title)\(t.key.map { " (\($0.uppercased()))" } ?? "")")
                }
                Divider().frame(height: 20)
                Button { m.perform("undo") } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!m.canUndo).help("Отменить ⌘Z")
                Button { m.perform("redo") } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!m.canRedo).help("Вернуть ⇧⌘Z")
                Button { m.perform("delete") } label: { Image(systemName: "trash") }.disabled(!m.hasSelection).help("Удалить выбранное")
                if m.hasCrop { Button("Сбросить обрезку") { m.perform("resetCrop") } }
                Spacer()
                Button { m.perform("copy") } label: { Label("Копировать", systemImage: "doc.on.doc") }
                Button { m.perform("save") } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
                Button { m.perform("pin") } label: { Image(systemName: "pin") }.help("Закрепить поверх окон")
                Button { m.perform("link") } label: { Image(systemName: "link") }.help("Получить ссылку")
            }
            HStack(spacing: 8) {
                ForEach(ShotColor.palette, id: \.self) { c in
                    Button { m.color = c; m.perform("color") } label: {
                        Circle().fill(Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(m.color == c ? Color.white : Color.black.opacity(0.25), lineWidth: m.color == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 18)
                if m.tool == .text {
                    Text("Размер").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { m.fontSize }, set: { m.fontSize = $0; m.perform("font") }), in: AnnotationStyle.fontRange).frame(width: 120)
                } else if m.tool == .blur || m.tool == .pixelate {
                    Text("Сила").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { m.strength }, set: { m.strength = $0; m.perform("strength") }), in: 0...1).frame(width: 120)
                } else {
                    Text("Толщина").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { m.stroke }, set: { m.stroke = $0; m.perform("stroke") }), in: AnnotationStyle.strokeRange).frame(width: 120)
                }
                if m.tool == .rectangle || m.tool == .ellipse {
                    Toggle("Заливка", isOn: Binding(get: { m.filled }, set: { m.filled = $0; m.perform("fill") })).toggleStyle(.checkbox)
                }
                Spacer()
                Menu {
                    ForEach(ShotBackground.presets, id: \.title) { p in
                        Button(p.title) { m.background = p.value; if m.padding == 0 && !p.value.isNone { m.padding = 48 } }
                    }
                } label: { Label("Фон", systemImage: "square.on.square") }.fixedSize()
                Text("Поля").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(m.padding) }, set: { m.padding = Int($0) }), in: 0...160).frame(width: 90)
                Toggle("Водяной знак", isOn: $m.watermarkOn).toggleStyle(.checkbox)
                Text(m.status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(VisualEffect(material: .headerView, blending: .withinWindow))
    }
}

@MainActor
final class ShotEditorController: NSObject, NSWindowDelegate {
    let model = ShotEditorModel()
    let editor: AnnotationEditor
    let base: CGImage
    var record: ShotRecord?
    private let window: NSWindow
    private let canvas: ShotEditorCanvas
    private weak var controller: ScreenshotController?
    private var dirty = false
    var onClose: ((ShotEditorController) -> Void)?

    init(controller: ScreenshotController, image: CGImage, record: ShotRecord?, document: AnnotationDocument?) {
        self.controller = controller
        base = image
        self.record = record
        let doc = (document?.canvasWidth == image.width && document?.canvasHeight == image.height) ? document! : AnnotationDocument(canvasWidth: image.width, canvasHeight: image.height)
        editor = AnnotationEditor(document: doc)
        canvas = ShotEditorCanvas(base: image, editor: editor)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        let w = controller.settings.watermark
        model.watermarkOn = w.isActive
        model.background = controller.settings.background
        model.perform = { [weak self] cmd in self?.command(cmd) }
        canvas.onChange = { [weak self] in self?.sync(markDirty: true) }
        canvas.onCommand = { [weak self] cmd in self?.command(cmd) }
        let host = NSHostingView(rootView: ShotEditorToolbar(m: model))
        let root = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor), host.leadingAnchor.constraint(equalTo: root.leadingAnchor), host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: host.bottomAnchor), canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        window.title = "Редактор снимка" + (record.map { " — \($0.title)" } ?? "")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.delegate = self
        window.center()
        editor.tool = .arrow
        sync(markDirty: false)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    private func sync(markDirty: Bool) {
        if markDirty && (editor.canUndo || editor.canRedo || !editor.document.isEmpty) { dirty = true }
        model.canUndo = editor.canUndo
        model.canRedo = editor.canRedo
        model.hasSelection = editor.selection != nil
        model.hasCrop = editor.document.crop != nil
        model.tool = editor.tool
        if let it = editor.selectedItem, editor.tool == .select {
            model.color = it.style.color.withAlpha(1)
        }
    }

    private func command(_ cmd: String) {
        switch cmd {
        case "tool":
            editor.tool = model.tool
        case "toolKey":
            model.tool = editor.tool
        case "color": editor.setColor(model.color)
        case "stroke": editor.setStrokeWidth(model.stroke)
        case "font": editor.setFontSize(model.fontSize)
        case "strength": editor.setStrength(model.strength)
        case "fill": editor.setFilled(model.filled)
        case "undo": editor.undo()
        case "redo": editor.redo()
        case "delete": editor.deleteSelection()
        case "resetCrop": editor.setCrop(nil)
        case "copy": exportThen { [weak self] img in self?.controller?.copy(img, data: nil); self?.model.status = "Скопировано" }
        case "save": exportThen { [weak self] img in self?.save(img) }
        case "pin": exportThen { [weak self] img in self?.controller?.pin(image: img, record: self?.record, title: self?.record?.title ?? "Снимок") }
        case "link": exportThen { [weak self] img in
            self?.model.status = "Загружаю…"
            self?.controller?.makeLink(record: self?.record, image: img) { text in self?.model.status = text ?? "" }
        }
        case "close": window.performClose(nil)
        default: break
        }
        canvas.commitTextIfNeeded()
        canvas.invalidate()
        sync(markDirty: cmd != "tool")
    }

    func exportImage() -> CGImage? {
        canvas.commitTextIfNeeded()
        guard let annotated = ShotRenderer.render(base: base, document: editor.document) else { return nil }
        let s = controller?.settings ?? ShotSettings()
        var wm = s.watermark
        wm.enabled = model.watermarkOn && !wm.text.isEmpty
        if model.padding == 0 && !wm.isActive { return annotated }
        return ShotRenderer.compose(annotated, padding: model.padding, scale: NSScreen.main?.backingScaleFactor ?? 2, background: model.background, cornerRadius: s.backgroundCorner, watermark: wm) ?? annotated
    }

    private func exportThen(_ body: (CGImage) -> Void) {
        guard let img = exportImage() else { model.status = "Не удалось собрать картинку"; return }
        body(img)
    }

    private func save(_ img: CGImage) {
        guard let c = controller else { return }
        let doc = editor.document.isEmpty ? nil : editor.document
        if let r = c.saveEdited(record: record, image: img, document: doc) {
            record = r
            dirty = false
            model.status = "Сохранено: \((r.path as NSString?)?.lastPathComponent ?? "")"
        } else {
            model.status = "Не удалось сохранить"
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty, !editor.document.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "Сохранить изменения?"
        a.informativeText = "В снимке есть пометки, которые ещё не сохранены."
        a.addButton(withTitle: "Сохранить")
        a.addButton(withTitle: "Не сохранять")
        a.addButton(withTitle: "Отмена")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let img = exportImage() { save(img) }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
