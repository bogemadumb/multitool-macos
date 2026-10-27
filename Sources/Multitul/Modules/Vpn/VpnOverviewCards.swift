import SwiftUI
import Charts
import MultitulCore
import MultitulCtlCore
import MultitulUI

extension VpnCheckStatus {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .pending, .skipped: .secondary
        }
    }
}

extension VpnLevel {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .alarm: .red
        }
    }
}

extension VpnRoute {
    var color: Color {
        switch self {
        case .vps: .green
        case .direct: .blue
        case .local: .secondary
        case .block: .red
        }
    }
}

extension VpnConnRow {
    var routeLabel: String { route.label }
    var startedStamp: Double { started?.timeIntervalSince1970 ?? 0 }
}

struct VpnRouteLabel: View {
    let route: VpnRoute

    var body: some View { StatusLabel(route.label, color: route.color) }
}

struct VpnChipsRow: View {
    @ObservedObject var checks: VpnChecksModel

    var body: some View {
        let chips = checks.chips
        if !chips.isEmpty {
            LabeledContent("Проверки связи") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                            StatusLabel(c.text, color: c.status.color).lineLimit(1).fixedSize()
                        }
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                            StatusLabel(c.text, color: c.status.color).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

struct VpnMetricsRows: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var traffic: VpnTraffic
    @ObservedObject var insights: VpnInsightsModel
    @ObservedObject var server: VpnServerModel

    private func valueText(_ v: String, _ u: String) -> String { u.isEmpty ? v : "\(v) \(u)" }

    var body: some View {
        let down = VpnFormat.rate(traffic.downBps)
        let ping = VpnFormat.ping(controller.delayMs)
        let today = VpnFormat.bytes(insights.todayTotal)
        let month = server.health.flatMap { VpnServerLogic.monthTotal($0) }
        LabeledContent {
            Text(valueText(down.value, down.unit)).monospacedDigit()
        } label: { SettingLabel("Скорость", "отдача \(VpnFormat.speed(traffic.upBps))") }
        LabeledContent {
            Text(valueText(ping.value, ping.unit)).monospacedDigit()
        } label: { SettingLabel("Пинг", insights.avgDelay.map { "в среднем \($0) мс за час" } ?? "нет замеров") }
        LabeledContent {
            Text(today).monospacedDigit()
        } label: { SettingLabel("Трафик сегодня", "через VPS \(VpnFormat.bytes(insights.todayVPS)), напрямую \(VpnFormat.bytes(insights.todayDirect))") }
        LabeledContent {
            Text(month.map { VpnFormat.bytes($0) } ?? "—").monospacedDigit()
        } label: { SettingLabel("Сервер за месяц", server.health?.vnstat.map { "приём \(VpnFormat.bytes($0.rx)), отдача \(VpnFormat.bytes($0.tx))" } ?? "опрос сервера") }
    }
}

struct VpnTrafficChart: View {
    @ObservedObject var traffic: VpnTraffic
    var tone: Color

    var body: some View {
        let down = traffic.downHistory
        let up = traffic.upHistory
        let peak = max(down.max() ?? 0, up.max() ?? 0, 50_000)
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(Array(down.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("Время", i), y: .value("Скорость", v), series: .value("Поток", "Приём"))
                        .foregroundStyle(by: .value("Поток", "Приём"))
                        .opacity(0.2)
                    LineMark(x: .value("Время", i), y: .value("Скорость", v), series: .value("Поток", "Приём"))
                        .foregroundStyle(by: .value("Поток", "Приём"))
                }
                ForEach(Array(up.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Время", i), y: .value("Скорость", v), series: .value("Поток", "Отдача"))
                        .foregroundStyle(by: .value("Поток", "Отдача"))
                }
            }
            .chartForegroundStyleScale(["Приём": tone, "Отдача": Color.accentColor])
            .chartYScale(domain: 0...peak)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, peak / 2, peak]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(VpnFormat.speed(v.as(Double.self) ?? 0)).font(.caption2) }
                }
            }
            .frame(height: 120)
            HStack {
                Text("Приём и отдача за 5 минут")
                Spacer(minLength: 4)
                Text("за сессию: приём \(VpnFormat.bytes(traffic.sessionDown)), отдача \(VpnFormat.bytes(traffic.sessionUp))").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

struct VpnHistoryChart: View {
    @ObservedObject var insights: VpnInsightsModel
    var tone: Color

    var body: some View {
        let pts: [(Int, VpnBucket)] = insights.buckets.enumerated().compactMap { i, b in b.map { (i, $0) } }
        let peak = max(pts.map { $0.1.down }.max() ?? 0, 50_000)
        VStack(alignment: .leading, spacing: 6) {
            if !insights.available {
                ContentUnavailableView("История недоступна", systemImage: "externaldrive.badge.exclamationmark", description: Text("Не открылась база Мультитула"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if pts.isEmpty {
                ContentUnavailableView("Замеров нет", systemImage: "chart.bar", description: Text(insights.sampleCount == 0 ? "Замеры пишет сборщик каждые 10 секунд" : "За этот период замеров нет"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(pts, id: \.0) { p in
                    BarMark(x: .value("Время", p.0), y: .value("Скорость", p.1.down))
                        .foregroundStyle(p.1.drop ? Color.red : tone)
                }
                .chartXScale(domain: 0...max(insights.buckets.count - 1, 1))
                .chartYScale(domain: 0...peak)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, peak / 2, peak]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text(VpnFormat.speed(v.as(Double.self) ?? 0)).font(.caption2) }
                    }
                }
                .frame(height: 120)
                Text("Красным обозначены обрывы")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VpnRouteResult: View {
    @ObservedObject var route: VpnRouteModel
    let verdict: VpnRouteVerdict

    private var tone: Color {
        switch verdict.kind {
        case .ok: .green
        case .serverDown, .routerDown: .red
        default: .orange
        }
    }

    private func color(_ s: VpnHopStatus) -> Color {
        switch s {
        case .ok: .green
        case .warn: .orange
        case .unknown: .secondary
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.title).fontWeight(.semibold).foregroundStyle(tone)
                Text(verdict.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: { Text("Вердикт") }
        Section("Участки пути") {
            ForEach(route.hops) { h in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(h.ms.map { "\($0) мс" } ?? "—").monospacedDigit()
                        Text(h.delta.map { $0 > 0 ? "+\($0)" : "" } ?? "")
                            .monospacedDigit().foregroundStyle(color(h.status)).frame(minWidth: 40, alignment: .trailing)
                    }
                } label: {
                    HStack(spacing: 8) {
                        StatusLabel(h.name, color: color(h.status))
                        Text(h.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }
}

struct VpnDiagnosticsView: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var speed: VpnSpeedModel
    @ObservedObject var route: VpnRouteModel

    private var speedText: String {
        switch speed.phase {
        case .idle: return "Тест скорости"
        case .running(let v): return "\(VpnSpeedMath.format(v)) МБ/с…"
        case .done(let v): return "\(VpnSpeedMath.format(v)) МБ/с"
        case .failed: return "Тест не удался"
        }
    }

    var body: some View {
        SettingsPage {
            Section {
                Button { controller.runSpeedTest() } label: {
                    Label(speedText, systemImage: "speedometer")
                }
                .disabled(speed.isRunning || !controller.apiOK)
                .help("Скачивает 25 МБ с speed.cloudflare.com через туннель")
                Button { controller.measureRoute() } label: {
                    Label(route.running ? "Измеряю…" : "Где тормозит?", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .disabled(route.running)
                .help("Мак, роутер, провайдер, VPS, сайт")
            } header: { Text("Диагностика") } footer: {
                SectionFooter(route.measuredAt.map { "Последний замер пути в \(VpnEventGrouping.timeText($0))" } ?? "Тест скорости качает 25 МБ через туннель. «Где тормозит» меряет путь от Мака до сайта по участкам.")
            }
            if let v = route.verdict { VpnRouteResult(route: route, verdict: v) }
        }
    }
}

struct VpnChecksSection: View {
    @ObservedObject var controller: VpnController
    @ObservedObject var checks: VpnChecksModel

    var body: some View {
        Section {
            ForEach(checks.items) { it in
                LabeledContent {
                    Text(it.text).foregroundStyle(it.status == .fail ? Color.red : Color.secondary).lineLimit(1)
                } label: { StatusLabel(it.name, color: it.status.color) }
            }
            if let a = checks.externalAddress { LabeledContent("Внешний адрес", value: a) }
            Button(checks.running ? "Проверяю…" : "Проверить сейчас") { controller.runChecksNow() }
                .disabled(checks.running || !controller.daemonRunning)
        } header: { Text("Проверки связи") }
    }
}

struct VpnServerSection: View {
    @ObservedObject var server: VpnServerModel

    private func row(_ title: String, _ value: String, _ level: VpnLevel = .ok, bar: Double? = nil) -> some View {
        VStack(spacing: 4) {
            LabeledContent(title) {
                Text(value).foregroundStyle(level == .ok ? Color.secondary : level.color).monospacedDigit()
            }
            if let bar { ProgressView(value: min(max(bar, 0), 1)).tint(level == .ok ? Color.accentColor : level.color) }
        }
    }

    var body: some View {
        Section {
            if let h = server.health {
                let lv = VpnServerLogic.levels(h, now: Date())
                row("xray", h.xray ? "работает" : "не работает", lv.xray)
                row("nginx", h.nginx ? "работает" : "не работает", lv.nginx)
                row("Процессор", "\(Int(h.cpuPercent.rounded())) %", lv.cpu, bar: h.cpuPercent / 100)
                row("Нагрузка", h.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " · ") + " (\(h.cpus) яд.)", lv.load)
                row("Память", "\(VpnFormat.bytes(h.ramUsed)) из \(VpnFormat.bytes(h.ramTotal))", lv.ram, bar: h.ramTotal > 0 ? h.ramUsed / h.ramTotal : 0)
                row("Диск", "свободно \(VpnFormat.bytes(h.diskFree)) из \(VpnFormat.bytes(h.diskTotal))", lv.disk,
                    bar: h.diskTotal > 0 ? 1 - h.diskFree / h.diskTotal : 0)
                row("Работает без перезагрузки", VpnServerLogic.uptimeText(h.uptime))
                row("Сертификат", VpnServerLogic.certDays(h, now: Date()).map { "ещё \($0) дн." } ?? "не определён", lv.cert)
                if let e = server.healthError { ToolWarning(text: e) }
            } else if let e = server.healthError {
                ToolWarning(text: e)
            } else if server.loadingHealth {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Опрашиваю сервер…").foregroundStyle(.secondary) }
            } else {
                Text("Нажми обновить, чтобы опросить сервер").foregroundStyle(.secondary)
            }
            Button { Task { await server.refreshHealth(force: true) } } label: {
                Label(server.healthAt.map { "Обновить, опрошен в \(VpnEventGrouping.timeText($0))" } ?? "Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(server.loadingHealth)
        } header: { Text("Сервер \(VpnEndpoint.serverAddress)") }
        .task { await server.refreshHealth() }
    }
}

struct VpnAppsSection: View {
    @ObservedObject var insights: VpnInsightsModel

    var body: some View {
        Section {
            if insights.apps.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "app.dashed", description: Text("Считается по соединениям ядра раз в 10 секунд"))
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart {
                    ForEach(insights.apps) { a in
                        BarMark(x: .value("Трафик", a.vps), y: .value("Приложение", a.process))
                            .foregroundStyle(by: .value("Путь", "Через VPS"))
                        BarMark(x: .value("Трафик", a.direct), y: .value("Приложение", a.process))
                            .foregroundStyle(by: .value("Путь", "Напрямую"))
                            .annotation(position: .trailing) {
                                Text(VpnFormat.bytes(a.total)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                    }
                }
                .chartForegroundStyleScale(["Через VPS": Color.green, "Напрямую": Color.blue])
                .chartXAxis(.hidden)
                .frame(height: max(90, CGFloat(insights.apps.count) * 30))
            }
        } header: { Text("Трафик по приложениям, сегодня") }
    }
}

struct VpnEventLine: View {
    let e: VpnEventRow

    private var tone: Color {
        switch e.kind {
        case "leak": .red
        case "watchdog": .blue
        case "speed": .secondary
        default: .orange
        }
    }

    var durationText: String {
        if e.isOpen { return "идёт" }
        guard VpnEventKind.isDrop(e.kind), let d = e.duration else { return "" }
        return VpnFormat.span(d)
    }

    var body: some View {
        LabeledContent {
            Text(durationText).foregroundStyle(e.isOpen ? Color.red : Color.secondary).monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                StatusLabel("\(VpnEventGrouping.timeText(e.start)) · \(VpnEventKind.title(e.kind))", color: tone)
                Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct VpnRecentEvents: View {
    @ObservedObject var insights: VpnInsightsModel

    var body: some View {
        let list = Array(insights.events.filter { $0.kind != "speed" }.prefix(4))
        Section {
            if list.isEmpty {
                Text("Обрывов, перезапусков и утечек не было").foregroundStyle(.secondary)
            } else {
                ForEach(list) { e in VpnEventLine(e: e) }
            }
        } header: { Text("Последние события") }
    }
}
