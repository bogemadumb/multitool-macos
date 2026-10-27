import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

private struct VpnQRItem: Identifiable {
    let id = UUID()
    let name: String
    let link: String
}

struct VpnKeysView: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var server: VpnServerModel
    @State private var qr: VpnQRItem?
    @State private var revoking: VpnKeyRow?
    @State private var linkError: String?
    @State private var copiedName: String?

    var body: some View {
        SettingsPage {
            if server.notice != nil || linkError != nil || server.keysError != nil {
                Section {
                    if let e = server.notice { ToolWarning(text: e) }
                    if let e = linkError { ToolWarning(text: e) }
                    if let e = server.keysError { ToolWarning(text: e) }
                }
            }
            VpnServerSection(server: server)
            Section {
                if server.keys.isEmpty && server.keysError == nil {
                    if server.loadingKeys {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Опрашиваю сервер…").foregroundStyle(.secondary) }
                    } else {
                        ContentUnavailableView("Ключей нет", systemImage: "key").frame(maxWidth: .infinity, minHeight: 110)
                    }
                } else if server.keys.isEmpty && !server.loadingKeys {
                    ContentUnavailableView("Сервер не ответил", systemImage: "wifi.exclamationmark", description: Text("Нажми «Обновить», чтобы повторить")).frame(maxWidth: .infinity, minHeight: 110)
                }
                ForEach(server.keys) { k in keyRow(k) }
                Button { Task { await server.refreshKeys(force: true) } } label: {
                    Label(server.keysAt.map { "Обновить, обновлено в \(VpnEventGrouping.timeText($0))" } ?? "Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(server.loadingKeys)
            } header: { Text("Ключи") } footer: {
                SectionFooter("У каждого устройства свой ключ: отзываешь один, остальные работают.")
            }
            VpnNewKeySection(server: server) { name, link in qr = VpnQRItem(name: name, link: link) }
        }
        .task { await server.refreshKeys() }
        .sheet(item: $qr) { item in
            VpnQRSheet(item: item.name, link: item.link, clipboard: controller.clipboard) { qr = nil }
        }
        .confirmationDialog(revoking.map { "Отозвать ключ «\($0.label)»?" } ?? "", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Отозвать", role: .destructive) {
                if let k = revoking { Task { server.notice = await server.revoke(k.name) } }
                revoking = nil
            }
            Button("Отмена", role: .cancel) { revoking = nil }
        } message: {
            Text("Устройство с этим ключом сразу потеряет доступ. Остальные ключи не заденет.")
        }
    }

    private func keyRow(_ k: VpnKeyRow) -> some View {
        let busy = server.busyName == k.name
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                StatusLabel(k.label, color: k.online ? .green : .secondary).fontWeight(.semibold)
                Text(k.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.small) }
            }
            Text("За месяц: приём \(VpnFormat.bytes(k.down)), отдача \(VpnFormat.bytes(k.up)). В сети: \(VpnServerLogic.relative(k.lastSeen, now: Date())). Ограничения: \(VpnServerLogic.limits(k)).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("QR") { showQR(k) }
                Button(copiedName == k.name ? "Скопировано, сотрётся через минуту" : "Скопировать ссылку") { copyLink(k) }
                Button("Отозвать", role: .destructive) { revoking = k }
                    .disabled(!VpnServerLogic.canRevoke(k.name))
                    .help(k.name == "mac" ? "Это ключ этого Мака" : "Отозвать ключ")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.vertical, 2)
    }

    private func showQR(_ k: VpnKeyRow) {
        linkError = nil
        Task {
            switch await server.link(k.name) {
            case .success(let l): qr = VpnQRItem(name: k.label, link: l)
            case .failure(let e): linkError = e.text
            }
        }
    }

    private func copyLink(_ k: VpnKeyRow) {
        linkError = nil
        Task {
            switch await server.link(k.name) {
            case .success(let l):
                controller.clipboard.copy(l)
                copiedName = k.name
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if copiedName == k.name { copiedName = nil }
            case .failure(let e): linkError = e.text
            }
        }
    }
}

private struct VpnNewKeySection: View {
    @ObservedObject var server: VpnServerModel
    let onCreated: (String, String) -> Void
    @State private var name = ""
    @State private var noTorrent = true
    @State private var error: String?

    private var problem: String? { VpnServerLogic.nameError(name, existing: server.keys.map(\.name)) }
    private var canCreate: Bool { !name.isEmpty && problem == nil && !server.creating }

    private func create() {
        guard canCreate else { return }
        let n = name
        error = nil
        Task {
            switch await server.add(n, noTorrent: noTorrent) {
            case .ok(let link, let restart):
                name = ""
                server.notice = restart ? "Ключ создан, но правило торрентов применится только после перезапуска xray на сервере" : nil
                onCreated(n, link)
            case .createdNoLink(let m):
                name = ""
                error = m
            case .failed(let m):
                error = m
            }
        }
    }

    var body: some View {
        Section {
            TextField("Имя латиницей", text: $name, prompt: Text("например, friend-iphone"))
                .onSubmit(create)
            Toggle("Блокировать торренты", isOn: $noTorrent)
            if let p = problem { ToolWarning(text: p) }
            if let e = error { ToolWarning(text: e) }
            Button(action: create) {
                HStack(spacing: 6) {
                    if server.creating { ProgressView().controlSize(.small) }
                    Text(server.creating ? "Создаю…" : "Создать ключ")
                }
            }
            .disabled(!canCreate)
        } header: { Text("Новый ключ") } footer: {
            SectionFooter("Ключ добавляется на лету, соединения других устройств не рвутся. Откроется QR и ссылка.")
        }
    }
}

private struct VpnQRSheet: View {
    let item: String
    let link: String
    let clipboard: VpnSecretClipboard
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Ключ «\(item)»").font(.headline)
            if let img = VpnQR.cgImage(link) {
                Image(decorative: img, scale: 2)
                    .interpolation(.none).resizable()
                    .frame(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Не удалось нарисовать QR").foregroundStyle(.red)
            }
            Text("Камерой в клиенте VLESS (Streisand, V2Box, Hiddify, v2rayNG) или ссылкой в клиент на компьютере.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 280)
            HStack {
                Button(copied ? "Скопировано, сотрётся через минуту" : "Скопировать ссылку") {
                    clipboard.copy(link)
                    copied = true
                }
                Button("Закрыть", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 340)
    }
}
