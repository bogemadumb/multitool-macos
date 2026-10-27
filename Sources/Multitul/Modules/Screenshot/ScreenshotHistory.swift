import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ShotHistoryModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var records: [ShotRecord] = []
    @Published private(set) var thumbs: [Int64: NSImage] = [:]
    @Published var selection: Int64?
    weak var controller: ScreenshotController?
    private var task: Task<Void, Never>?

    func reload() {
        guard let h = controller?.history else { records = []; return }
        let q = query
        let found = (try? (q.trimmingCharacters(in: .whitespaces).isEmpty ? h.recent(limit: 300) : h.search(q, limit: 300))) ?? []
        records = found
        for r in found where thumbs[r.id] == nil {
            if let d = try? h.thumbnail(id: r.id), let img = NSImage(data: d) { thumbs[r.id] = img }
        }
    }

    func record(_ id: Int64) -> ShotRecord? { records.first { $0.id == id } }

    func image(for r: ShotRecord) -> CGImage? {
        guard let p = r.path else { return nil }
        return ShotImageOps.load(path: p)
    }

    func edit(_ r: ShotRecord) {
        guard let img = image(for: r) else { controller?.note = "Файл снимка не найден"; return }
        controller?.openEditor(record: r, image: img)
    }

    func pin(_ r: ShotRecord) {
        guard let img = image(for: r) else { return }
        controller?.pin(image: img, record: r, title: r.title)
    }

    func copy(_ r: ShotRecord) {
        guard let img = image(for: r) else { return }
        controller?.copy(img, data: nil)
    }

    func reveal(_ r: ShotRecord) {
        guard let p = r.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func link(_ r: ShotRecord) {
        guard let img = image(for: r) else { return }
        controller?.makeLink(record: r, image: img) { [weak self] _ in self?.reload() }
    }

    func delete(_ r: ShotRecord) {
        controller?.pipeline?.discard(recordID: r.id)
        thumbs[r.id] = nil
        reload()
    }
}

struct ShotHistoryView: View {
    @ObservedObject var model: ShotHistoryModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по названию, приложению и тексту на снимке", text: $model.query)
                    .textFieldStyle(.plain)
                    .onChange(of: model.query) { _, _ in model.reload() }
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Text("\(model.records.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(VisualEffect(material: .headerView, blending: .withinWindow))
            Divider()
            if model.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "История пока пустая" : "Ничего не нашлось").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.records) { r in cell(r) }
                    }.padding(14)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { model.reload() }
    }

    private func cell(_ r: ShotRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08))
                if let t = model.thumbs[r.id] { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selection == r.id ? Color.accentColor : Color.clear, lineWidth: 2))
            Text(r.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                Text(r.mode.title)
                Text("·")
                Text("\(r.width)×\(r.height)")
                if r.linkIsAlive(now: Date()) { Image(systemName: "link") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(Self.format(r.created)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit(r) }
        .onTapGesture { model.selection = r.id }
        .contextMenu {
            Button("Открыть в редакторе") { model.edit(r) }
            Button("Закрепить поверх окон") { model.pin(r) }
            Button("Копировать") { model.copy(r) }
            Button("Получить ссылку") { model.link(r) }
            Button("Показать в Finder") { model.reveal(r) }.disabled(r.path == nil)
            Divider()
            Button("Удалить", role: .destructive) { model.delete(r) }
        }
    }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: d)
    }
}
