import SwiftUI
import AppKit
import Quartz
import MultitulCore

@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self else { return }
        panel.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

extension ShelfController: ShelfActionHandling {
    private var outDir: String { MultitulPaths.shelfOutDir }

    private func entries(_ ids: [Int64]) -> [ShelfItem] {
        guard let service else { return [] }
        let set = Set(ids)
        return service.items.filter { set.contains($0.id) }
    }

    private func fileURLs(_ ids: [Int64]) -> [URL] {
        guard let service else { return [] }
        var out: [URL] = []
        for it in entries(ids) {
            switch it.kind {
            case .file, .folder:
                if let p = service.resolve(it).path { out.append(URL(fileURLWithPath: p)) }
            case .image:
                if let p = service.payload(of: it.id), let d = p.data, let u = ShelfMaterialize.file(data: d, ext: it.ext ?? "png", name: it.title, outDir: outDir) { out.append(u) }
            case .text:
                if let b = service.payload(of: it.id)?.body, let u = ShelfMaterialize.textFile(b, name: it.title, outDir: outDir) { out.append(u) }
            case .url:
                if let b = service.payload(of: it.id)?.body, let u = ShelfMaterialize.textFile(b, name: it.title, outDir: outDir) { out.append(u) }
            }
        }
        return out
    }

    func open(_ ids: [Int64]) {
        guard let service else { return }
        for it in entries(ids) {
            switch it.kind {
            case .url:
                if let b = service.payload(of: it.id)?.body, let u = URL(string: b) { NSWorkspace.shared.open(u) }
            default:
                for u in fileURLs([it.id]) { NSWorkspace.shared.open(u) }
            }
        }
        warnMissing(ids)
    }

    func reveal(_ ids: [Int64]) {
        guard let service else { return }
        let urls = entries(ids).filter { $0.kind.isPath }.compactMap { service.resolve($0).path }.map { URL(fileURLWithPath: $0) }
        if urls.isEmpty { HUD.show("Файл не найден") } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func quickLook(_ ids: [Int64]) {
        let urls = fileURLs(ids)
        if urls.isEmpty { HUD.show("Нечего показывать") } else { quickLook.show(urls) }
    }

    func copy(_ ids: [Int64]) {
        guard let service else { return }
        let plan = service.dragPlan(ids)
        if plan.payloads.isEmpty { HUD.show("Файл не найден"); return }
        ShelfWriters.copy(plan.payloads, outDir: outDir)
        HUD.show("Скопировано")
    }

    private func shareItems(_ ids: [Int64]) -> [Any] {
        guard let service else { return [] }
        var out: [Any] = []
        for p in service.dragPlan(ids).payloads {
            switch p {
            case .files(let paths): out += paths.map { URL(fileURLWithPath: $0) }
            case .text(let t): out.append(t)
            case .url(let s): out.append(URL(string: s) ?? s as Any)
            case .image(let d, _, _): if let img = NSImage(data: d) { out.append(img) }
            }
        }
        return out
    }

    func share(_ ids: [Int64]) {
        let items = shareItems(ids)
        guard !items.isEmpty, let view = panel?.panel?.contentView else { HUD.show("Нечего отправлять"); return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 30, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    func airDrop(_ ids: [Int64]) {
        let items = shareItems(ids)
        guard !items.isEmpty, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: items) else { HUD.show("AirDrop недоступен"); return }
        s.perform(withItems: items)
    }

    func compress(_ ids: [Int64]) {
        guard let service, let model else { return }
        let paths = service.resolvedPaths(ids)
        guard !paths.isEmpty else { HUD.show("Сжимать нечего: файлы не найдены"); return }
        model.busy = "Сжатие…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ShelfArchiver.live().compress(paths)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    model.busy = nil
                    switch r {
                    case .success(let zip):
                        self?.service?.addPaths([zip], owned: true)
                        HUD.show("Архив на полке")
                    case .failure(let e):
                        HUD.show("Не удалось сжать")
                        Log.write("shelf zip failed: \(e)")
                    }
                }
            }
        }
    }

    func remove(_ ids: [Int64]) { service?.remove(ids) }

    func clearAll() { service?.clear(keepPinned: true) }

    func closeShelf() { panel?.hide() }

    func dragEnded(ids: [Int64], accepted: Bool) {
        guard let service else { return }
        let r = service.dragCompleted(ids: ids, accepted: accepted)
        model?.refresh()
        if r.closeShelf { panel?.hide(after: 0.3) }
    }

    func writers(for ids: [Int64]) -> [NSPasteboardWriting] {
        guard let service else { return [] }
        let plan = service.dragPlan(ids)
        if !plan.missing.isEmpty { HUD.show("Не найдено: \(plan.missing.count)") }
        return ShelfWriters.writers(for: plan.payloads, outDir: outDir)
    }

    private func warnMissing(_ ids: [Int64]) {
        guard let service else { return }
        if entries(ids).contains(where: { $0.kind.isPath && service.resolve($0).isMissing }) { HUD.show("Файл не найден") }
    }
}
