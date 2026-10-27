import SwiftUI
import Charts
import MultitulCore
import MultitulUI

struct FanControlView: View {
    @ObservedObject private var c = FanControlController.shared
    @State private var presetName = ""

    private var snap: FanSnapshot { c.snapshot }

    private func binding<T>(_ kp: WritableKeyPath<FanConfig, T>) -> Binding<T> {
        Binding(get: { snap.config[keyPath: kp] }, set: { v in var n = snap.config; n[keyPath: kp] = v; c.update(n) })
    }

    var body: some View {
        SettingsPage {
            header
            switch snap.state {
            case .stopped:
                Section { EmptyHint(text: FanText.status(.stopped, restorePending: false, asleep: false), symbol: "fan") }
            case .noFans:
                Section {
                    SettingLabel(FanText.noFans, FanText.noFansDetail)
                }
            case .unsupported(let why):
                Section { ToolWarning(text: FanText.status(.unsupported(why), restorePending: false, asleep: false)) }
            default:
                banners
                fansSection
                modeSection
                if snap.config.mode == .curve || snap.config.mode == .auto { sensorSection }
                presetsSection
                tuningSection
            }
        }
        .onAppear { c.viewerAppeared() }
        .onDisappear { c.viewerGone() }
    }

    private var header: some View {
        Section {
            LabeledContent {
                if let t = snap.temperature { Text(SysFormat.temperature(t)).monospacedDigit() }
            } label: {
                SettingLabel("Состояние", FanText.status(snap.state, restorePending: snap.restorePending, asleep: snap.asleep))
            }
            StatusLabel("Бета: \(FanText.unverified)", color: .orange)
        }
    }

    @ViewBuilder private var banners: some View {
        if snap.restorePending || snap.fault != nil {
            Section {
                if snap.restorePending {
                    ToolWarning(text: "Не удалось вернуть вентиляторы системе. Повторяю каждые несколько секунд. Вручную: sudo /usr/local/libexec/multitul-ctl smc fan-auto all")
                }
                if let f = snap.fault { ToolWarning(text: "Управление возвращено системе. \(f.message)") }
            }
        }
    }

    private var fansSection: some View {
        Section("Вентиляторы") {
            ForEach(snap.fans) { fan in
                let r = snap.readings.first { $0.index == fan.index }
                let target = snap.targets[fan.index] ?? r?.target
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text("\(r.map { FanText.rpm($0.actual) } ?? "—"), цель \(target.map { FanText.rpm($0) } ?? "—")").monospacedDigit()
                    } label: {
                        if r?.manual == true { StatusLabel("Вентилятор \(fan.index + 1), ручной", color: .green) } else { Text("Вентилятор \(fan.index + 1)") }
                    }
                    ProgressView(value: min(max(r.map { ($0.actual - fan.minRpm) / max(fan.maxRpm - fan.minRpm, 1) } ?? 0, 0), 1))
                    Text("\(Int(fan.minRpm))–\(Int(fan.maxRpm)) об/мин").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeSection: some View {
        let modes = FanControlMode.allCases
        return Section {
            Picker("Режим", selection: Binding(get: { snap.config.mode }, set: { c.setMode($0) })) {
                ForEach(modes, id: \.self) { Text($0.title).tag($0) }
            }
            switch snap.config.mode {
            case .auto:
                EmptyView()
            case .manualRpm:
                let lo = snap.fans.map(\.minRpm).min() ?? 0
                let hi = snap.fans.map(\.maxRpm).max() ?? 10000
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { Double(snap.config.manualRpm) }, set: { v in var n = snap.config; n.manualRpm = Int(v / 50) * 50; c.update(n) }), in: lo...hi)
                            .frame(minWidth: 110, maxWidth: 220)
                        Text("\(snap.config.manualRpm) об/мин").monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                    }
                } label: { Text("Обороты") }
            case .manualPercent:
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { Double(snap.config.manualPercent) }, set: { v in var n = snap.config; n.manualPercent = Int(v); c.update(n) }), in: 0...100)
                            .frame(minWidth: 110, maxWidth: 220)
                        Text("\(snap.config.manualPercent)%").monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                    }
                } label: { Text("Проценты") }
            case .curve:
                FanCurveEditor(config: Binding(get: { snap.config }, set: { c.update($0) }), temperature: snap.temperature)
            }
        } header: { Text("Режим") } footer: {
            switch snap.config.mode {
            case .auto: SectionFooter("Вентиляторами управляет система. Режимы «Обороты», «Проценты» и «Кривая» берут управление на себя и сами возвращают его при сбое.")
            case .manualRpm: SectionFooter("Значение приводится к пределам каждого вентилятора: ниже минимума не опускается.")
            case .manualPercent: SectionFooter("0% — минимальные обороты вентилятора, 100% — максимальные.")
            case .curve: EmptyView()
            }
        }
    }

    private var sensorSection: some View {
        Section {
            Picker(selection: binding(\.source)) {
                ForEach(FanSensorSource.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Датчик для кривой", "Какая группа датчиков температуры управляет оборотами") }
            Picker(selection: binding(\.aggregate)) {
                ForEach(FanAggregate.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Как считать группу", "Если датчиков несколько") }
        }
    }

    private var presetsSection: some View {
        Section("Пресеты") {
            ForEach(c.presets) { p in
                LabeledContent {
                    HStack {
                        Button("Применить") { c.applyPreset(p.id) }
                        if !p.builtIn { Button("Удалить") { c.deletePreset(p.id) } }
                    }
                } label: {
                    if c.activePreset == p.id { StatusLabel("\(p.name), выбран", color: .green) } else { Text(p.name) }
                }
            }
            TextField("Название нового пресета", text: $presetName)
            Button("Сохранить текущие настройки") {
                c.savePreset(name: presetName)
                presetName = ""
            }
            .disabled(FanPresets.cleanName(presetName).isEmpty)
        }
    }

    private var tuningSection: some View {
        Section {
            Stepper(value: binding(\.hysteresis), in: FanConfig.hysteresisRange, step: 0.5) {
                HStack {
                    SettingLabel("Гистерезис, °C", "Скорость не падает, пока температура не снизилась больше этого значения")
                    Spacer()
                    Text(String(format: "%.1f", snap.config.hysteresis)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            StepperSetting("Разгон, об/мин в секунду", "0: без ограничения", value: binding(\.rampUp), in: FanConfig.rampRange, step: 50)
            StepperSetting("Сброс, об/мин в секунду", "0: без ограничения", value: binding(\.rampDown), in: FanConfig.rampRange, step: 50)
            Toggle(isOn: binding(\.resumeOnLaunch)) {
                SettingLabel("Возобновлять при запуске", "По умолчанию выключено: после перезапуска Мультитула вентиляторы остаются у системы")
            }
        } header: { Text("Тонкая настройка") } footer: {
            SectionFooter("Возврат системе: при выходе, сне, пропаже датчиков, росте тепловой нагрузки, сбое записи и зависании. \(FanText.helperHint)")
        }
    }
}

struct FanCurveEditor: View {
    @Binding var config: FanConfig
    var temperature: Double?

    private var points: [FanCurvePoint] { config.curve }

    private func set(_ new: [FanCurvePoint]) {
        var c = config
        c.curve = new
        config = c
    }

    var body: some View {
        FanCurvePreview(points: points, temperature: temperature).frame(height: 140)
        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
            LabeledContent {
                HStack(spacing: 12) {
                    Stepper("\(Int(p.temp)) °C", value: Binding(get: { p.temp }, set: { v in var n = points; n[i].temp = v; set(n) }), in: FanCurve.tempRange, step: 1)
                    Stepper("\(Int(p.percent))%", value: Binding(get: { p.percent }, set: { v in var n = points; n[i].percent = v; set(n) }), in: FanCurve.percentRange, step: 5)
                    Button("Убрать") { var n = points; n.remove(at: i); if !n.isEmpty { set(n) } }.disabled(points.count <= 1)
                }
            } label: { Text("Точка \(i + 1)") }
        }
        Button("Добавить точку") {
            let last = points.last ?? FanCurvePoint(temp: 60, percent: 50)
            set(points + [FanCurvePoint(temp: min(last.temp + 5, FanCurve.tempRange.upperBound), percent: min(last.percent + 10, 100))])
        }
        .disabled(points.count >= FanCurve.maxPoints)
        Button("Сбросить кривую") { set(FanCurve.defaultPoints) }
        if let t = temperature, let p = FanCurve.percent(at: t, in: points) {
            LabeledContent("Сейчас", value: "\(SysFormat.temperature(t)), \(Int(p.rounded()))%")
        }
        Text("Ось Y: процент между минимумом и максимумом каждого вентилятора. Левее первой точки и правее последней значение держится постоянным.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct FanCurvePreview: View {
    var points: [FanCurvePoint]
    var temperature: Double?

    var body: some View {
        let t0 = FanCurve.tempRange.lowerBound, t1 = FanCurve.tempRange.upperBound
        let pts = FanCurve.normalized(points)
        let line: [(Double, Double)] = pts.isEmpty ? [] : [(t0, pts[0].percent)] + pts.map { ($0.temp, $0.percent) } + [(t1, pts[pts.count - 1].percent)]
        Chart {
            ForEach(Array(line.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Температура", p.0), y: .value("Процент", p.1))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("Температура", p.temp), y: .value("Процент", p.percent))
                    .foregroundStyle(Color.accentColor)
            }
            if let t = temperature, t >= t0, t <= t1 {
                RuleMark(x: .value("Сейчас", t))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: t0...t1)
        .chartYScale(domain: 0...100)
    }
}
