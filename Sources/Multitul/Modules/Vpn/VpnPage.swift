import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct VpnPage: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var traffic: VpnTraffic

    var body: some View {
        SettingsPage {
            VpnAlerts(controller: controller)
            VpnStatusSection(controller: controller, rules: controller.rules, checks: controller.checks)
            VpnNowSection(controller: controller, traffic: traffic, insights: controller.insights, server: controller.server)
            VpnChecksSection(controller: controller, checks: controller.checks)
            VpnAppsSection(insights: controller.insights)
            VpnRecentEvents(insights: controller.insights)
            VpnLinksSection(controller: controller)
            VpnSettings(controller: controller)
        }
        .navigationDestination(for: VpnSub.self) { route in
            switch route {
            case .connections: VpnConnectionsView(controller: controller, model: controller.conns, rules: controller.rules).navigationTitle("Соединения")
            case .rules: VpnRulesView(rules: controller.rules).navigationTitle("Правила")
            case .keys: VpnKeysView(controller: controller, server: controller.server).navigationTitle("Сервер и ключи")
            case .journal: VpnJournalView(insights: controller.insights).navigationTitle("Журнал")
            case .diagnostics: VpnDiagnosticsView(controller: controller, speed: controller.speed, route: controller.route).navigationTitle("Скорость и «где тормозит»")
            }
        }
        .onAppear { traffic.setVisible("page", true) }
        .onDisappear { traffic.setVisible("page", false) }
        .task { await controller.insights.run() }
    }
}

private struct VpnAlerts: View {
    @ObservedObject var controller: VpnController

    var body: some View {
        if controller.controlError != nil || controller.confirmingOff {
            Section {
                if let e = controller.controlError { ToolWarning(text: e) }
                if controller.confirmingOff {
                    ToolWarning(text: "Выключить VPN? Сайты за границей пойдут без туннеля.")
                    HStack {
                        Button("Отмена") { controller.cancelOff() }
                        Button("Выключить", role: .destructive) { controller.confirmOff() }
                    }
                }
            }
        }
    }
}

private struct VpnStatusSection: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var rules: VpnRulesModel
    @ObservedObject var checks: VpnChecksModel

    var body: some View {
        let tone = controller.state.tone.color
        Section {
            Toggle(isOn: Binding(get: { controller.daemonRunning }, set: { _ in controller.toggle() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.title).foregroundStyle(tone)
                    HStack(spacing: 5) {
                        if controller.killSwitchActive { Image(systemName: "lock.shield.fill").foregroundStyle(.green) }
                        Text(controller.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .disabled(controller.busy)
            .help(controller.daemonRunning ? "Выключить VPN" : "Включить VPN")
            Picker("Режим", selection: Binding(get: { controller.currentMode }, set: { controller.setMode($0) })) {
                ForEach(VpnMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!controller.apiOK)
            VpnChipsRow(checks: checks)
            Button { rules.addCurrentSite() } label: {
                Label(rules.siteNote ?? "Этот сайт, напрямую", systemImage: "globe")
            }
            .disabled(rules.busyBrowser || rules.busyWrite)
            .help("Домен из вкладки Safari или Chrome")
        } footer: {
            SectionFooter(controller.directHint ? "Список «всегда через VPS» всё равно идёт через туннель" : "Умный режим: российские сайты напрямую, остальное через VPS. Кнопка «Этот сайт» берёт домен из вкладки Safari или Chrome.")
        }
    }
}

private struct VpnNowSection: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var traffic: VpnTraffic
    @ObservedObject var insights: VpnInsightsModel
    @ObservedObject var server: VpnServerModel

    var body: some View {
        let tone = controller.state.tone.color
        Section("Сейчас") {
            VpnMetricsRows(controller: controller, traffic: traffic, insights: insights, server: server)
            VpnTrafficChart(traffic: traffic, tone: tone)
        }
        Section {
            Picker("Период", selection: Binding(get: { insights.range }, set: { insights.setRange($0) })) {
                ForEach(VpnChartRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VpnHistoryChart(insights: insights, tone: tone)
        } header: { Text(insights.range.heading) }
    }
}

private struct VpnLinksSection: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var conns: VpnConnectionsModel
    @ObservedObject var rules: VpnRulesModel
    @ObservedObject var server: VpnServerModel
    @ObservedObject var insights: VpnInsightsModel

    init(controller: VpnController) {
        self.controller = controller
        conns = controller.conns
        rules = controller.rules
        server = controller.server
        insights = controller.insights
    }

    var body: some View {
        Section("Подробнее") {
            NavigationLink(value: VpnSub.connections) {
                LabeledContent("Соединения", value: conns.rows.isEmpty ? "" : "\(conns.rows.count)")
            }
            NavigationLink(value: VpnSub.rules) {
                LabeledContent("Правила", value: "\(VpnRuleList.items(user: rules.user, alwaysVps: rules.alwaysVps).count)")
            }
            NavigationLink(value: VpnSub.keys) {
                LabeledContent("Сервер и ключи", value: server.keys.isEmpty ? "" : "\(server.keys.count)")
            }
            NavigationLink(value: VpnSub.journal) {
                LabeledContent("Журнал", value: insights.events.isEmpty ? "" : "\(insights.events.count)")
            }
            NavigationLink(value: VpnSub.diagnostics) { Text("Скорость и «где тормозит»") }
        }
    }
}

private struct VpnSettings: View {
    @ObservedObject var controller: VpnController
    @AppStorage(VpnKeys.showShield) private var showShield = true
    @State private var autostart = Autostart.isEnabled()

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.killSwitchEnabled }, set: { controller.setKillSwitch($0) })) {
                SettingLabel("Kill switch", controller.killSwitchActive ? "Включён: если туннель упадёт, интернет блокируется" : "Если туннель упадёт, интернет блокируется (фильтр pf)")
            }
            Toggle(isOn: Binding(get: { controller.watchdogEnabled }, set: { controller.setWatchdog($0) })) {
                SettingLabel("Сторож ядра", "Ядро молчит 60 с: перезапуск; не больше \(3) попыток за 10 минут, дальше только уведомление")
            }
            LabeledContent("Перезапусков за 10 минут", value: "\(controller.attemptsUsed) из 3")
            LabeledContent("Последнее действие сторожа", value: controller.lastAction ?? "не было")
            Toggle(isOn: Binding(get: { controller.notificationsEnabled }, set: { controller.setNotifications($0) })) {
                SettingLabel("Уведомления", "Обрыв, восстановление, перезапуск ядра; одно такое в 10 минут")
            }
        } header: { Text("Защита") }
        Section("Приложение") {
            Toggle(isOn: $showShield) { SettingLabel("Щит в строке меню", "Зелёный, жёлтый, красный или серый по состоянию туннеля") }
            Toggle(isOn: Binding(get: { autostart }, set: { autostart = $0; if !Autostart.set($0) { autostart = Autostart.isEnabled() } })) {
                SettingLabel("Запускать Мультитул при входе", "Общая настройка приложения")
            }
            LabeledContent("Ядро (sing-box)", value: controller.singboxVersion ?? "ядро не отвечает")
            LabeledContent("Ключ clash_api", value: controller.apiError ?? (controller.apiOK ? "подходит" : "не проверен"))
        }
        .onAppear { autostart = Autostart.isEnabled() }
    }
}
