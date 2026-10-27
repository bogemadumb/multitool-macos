import AppKit
import MultitulCore

final class LiveDragProbe: DragPasteboardProbing {
    private let pb = NSPasteboard(name: .drag)
    var changeCount: Int { pb.changeCount }
    var hasContent: Bool { !(pb.pasteboardItems ?? []).isEmpty }
}

enum ShelfPasteboardReader {
    private static let wanted: Set<String> = [PBType.fileURL, PBType.url, "public.url-name", PBType.png, PBType.tiff, PBType.utf8]

    static func read(_ pb: NSPasteboard) -> [PasteboardItemData] {
        (pb.pasteboardItems ?? []).map { item in
            var reps: [String: Data] = [:]
            for t in item.types where wanted.contains(t.rawValue) {
                if t.rawValue == PBType.fileURL, let s = item.string(forType: t), let u = URL(string: s) {
                    let resolved = (u as NSURL).filePathURL ?? u
                    reps[t.rawValue] = Data(resolved.absoluteString.utf8)
                } else if let d = item.data(forType: t) {
                    reps[t.rawValue] = d
                }
            }
            return PasteboardItemData(reps: reps)
        }
    }

    static func receivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }
}

enum ShelfMaterialize {
    static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Shelf" : String(cleaned.prefix(100))
    }

    static func file(data: Data, ext: String, name: String, outDir: String) -> URL? {
        let base = safeName(name)
        let file = ext.isEmpty || base.lowercased().hasSuffix("." + ext) ? base : base + "." + ext
        let path = outDir + "/" + String(UUID().uuidString.prefix(8)) + "/" + file
        guard LiveShelfFileSystem().write(data, to: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func textFile(_ text: String, name: String, outDir: String) -> URL? {
        file(data: Data(text.utf8), ext: "txt", name: name, outDir: outDir)
    }
}

enum ShelfWriters {
    @MainActor
    static func writers(for payloads: [ShelfDragPayload], outDir: String) -> [NSPasteboardWriting] {
        var out: [NSPasteboardWriting] = []
        for p in payloads {
            switch p {
            case .files(let paths):
                out += paths.map { URL(fileURLWithPath: $0) as NSURL }
            case .text(let t):
                let it = NSPasteboardItem()
                it.setString(t, forType: .string)
                out.append(it)
            case .url(let s):
                let it = NSPasteboardItem()
                it.setString(s, forType: .URL)
                it.setString(s, forType: .string)
                out.append(it)
            case .image(let d, let ext, let name):
                let it = NSPasteboardItem()
                if let u = ShelfMaterialize.file(data: d, ext: ext, name: name, outDir: outDir) { it.setString(u.absoluteString, forType: .fileURL) }
                it.setData(d, forType: ext == "png" ? .png : .tiff)
                out.append(it)
            }
        }
        return out
    }

    @MainActor
    static func copy(_ payloads: [ShelfDragPayload], outDir: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(writers(for: payloads, outDir: outDir))
    }
}
