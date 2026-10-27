import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class RecHistoryModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var records: [RecRecord] = []
    @Published private(set) var thumbs: [Int64: NSImage] = [:]
    @Published var selection: Int64?
    @Published var status = ""
    weak var controller: RecorderController?

    func reload() {
        guard let h = controller?.history else { records = []; return }
        let q = query
        let found = (try? (q.trimmingCharacters(in: .whitespaces).isEmpty ? h.recent(limit: 300) : h.search(q, limit: 300))) ?? []
        records = found
        for r in found where thumbs[r.id] == nil {
            if let d = try? h.thumbnail(id: r.id), let img = NSImage(data: d) { thumbs[r.id] = img }
        }
    }

    func exists(_ r: RecRecord) -> Bool { r.path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    func edit(_ r: RecRecord) { controller?.openEditor(r) }
    func play(_ r: RecRecord) { if let p = r.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    func reveal(_ r: RecRecord) { if let p = r.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }

    func link(_ r: RecRecord) {
        guard let p = r.path else { return }
        status = "Загружаю…"
        controller?.makeLink(path: p, record: r) { [weak self] text in
            self?.status = text
            self?.reload()
        }
    }

    func pin(_ r: RecRecord) {
        try? controller?.history?.setPinned(id: r.id, !r.pinned)
        reload()
    }

    func delete(_ r: RecRecord, withFile: Bool) {
        controller?.deleteRecord(r, moveFileToTrash: withFile)
        thumbs[r.id] = nil
        reload()
    }
}

struct RecHistoryView: View {
    @ObservedObject var model: RecHistoryModel
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по названию и приложению", text: $model.query)
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
                    Image(systemName: "record.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "Записей пока нет" : "Ничего не нашлось").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) { ForEach(model.records) { cell($0) } }.padding(14)
                }
            }
            if !model.status.isEmpty {
                Divider()
                Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).padding(6)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { model.reload() }
    }

    private func cell(_ r: RecRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08))
                if let t = model.thumbs[r.id] { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                Text(RecTimeFormat.clock(r.duration)).font(.system(size: 10, weight: .semibold).monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(6)
            }
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selection == r.id ? Color.accentColor : Color.clear, lineWidth: 2))
            Text(r.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                Text(r.mode.title)
                Text("·")
                Text("\(r.width)×\(r.height)")
                Text("·")
                Text(RecTimeFormat.bytes(r.bytes))
                if r.hasSystemAudio { Image(systemName: "speaker.wave.2") }
                if r.hasMicrophone { Image(systemName: "mic") }
                if r.pinned { Image(systemName: "pin.fill") }
                if r.linkIsAlive(now: Date()) { Image(systemName: "link") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.exists(r) ? Self.format(r.created) : "Файл не найден").font(.system(size: 10)).foregroundStyle(model.exists(r) ? Color.secondary : Theme.warn)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit(r) }
        .onTapGesture { model.selection = r.id }
        .contextMenu {
            Button("Открыть в редакторе") { model.edit(r) }.disabled(!model.exists(r))
            Button("Воспроизвести") { model.play(r) }.disabled(!model.exists(r))
            Button("Получить ссылку") { model.link(r) }.disabled(!model.exists(r))
            Button("Показать в Finder") { model.reveal(r) }.disabled(!model.exists(r))
            Button(r.pinned ? "Открепить" : "Закрепить в истории") { model.pin(r) }
            Divider()
            Button("Убрать из истории") { model.delete(r, withFile: false) }
            Button("Удалить вместе с файлом", role: .destructive) { model.delete(r, withFile: true) }
        }
    }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: d)
    }
}
