import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct JobRowView: View {
    let job: JobSnapshot
    var onCancel: (() -> Void)?
    var extra: (title: String, action: () -> Void)?
    @State private var expanded = false

    private var tint: Color {
        switch job.state {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 10) {
                    Text(job.state.title).foregroundStyle(tint)
                    if let onCancel, !job.state.isFinished { Button("Отмена", action: onCancel) }
                    if let extra, job.state.isFinished { Button(extra.title, action: extra.action) }
                    if !job.log.isEmpty { Button(expanded ? "Скрыть лог" : "Лог") { expanded.toggle() } }
                }
            } label: { Text(job.title).lineLimit(1) }
            if job.state == .running {
                ProgressView(value: job.progress ?? 0)
                if !job.detail.isEmpty { Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if case .failed(let m) = job.state { Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if job.state == .succeeded, !job.result.isEmpty { Text(job.result).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            if expanded {
                ScrollView {
                    Text(job.log.suffix(60).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(.vertical, 2)
    }
}

struct JobsSection: View {
    let jobs: [JobSnapshot]
    var onCancel: (Int) -> Void
    var onClear: () -> Void
    var extra: ((JobSnapshot) -> (title: String, action: () -> Void)?)?

    var body: some View {
        if !jobs.isEmpty {
            Section {
                ForEach(jobs.reversed()) { j in
                    JobRowView(job: j, onCancel: { onCancel(j.id) }, extra: extra?(j))
                }
                if jobs.contains(where: { $0.state.isFinished }) { Button("Очистить завершённые", action: onClear) }
            } header: { Text("Задачи") }
        }
    }
}

struct CommandBox: View {
    let command: String
    var openInTerminal: (() -> Void)?

    var body: some View {
        Text(command).font(.callout.monospaced()).textSelection(.enabled)
        Button("Скопировать команду") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            HUD.show("Команда скопирована")
        }
        if let openInTerminal { Button("Открыть в Terminal", action: openInTerminal) }
    }
}

func confirmAlert(_ title: String, _ text: String, ok: String, extraButton: String? = nil) -> Int {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = .warning
    a.addButton(withTitle: ok)
    if let extraButton { a.addButton(withTitle: extraButton) }
    a.addButton(withTitle: "Отмена")
    let r = a.runModal()
    if r == .alertFirstButtonReturn { return 1 }
    if extraButton != nil && r == .alertSecondButtonReturn { return 2 }
    return 0
}
