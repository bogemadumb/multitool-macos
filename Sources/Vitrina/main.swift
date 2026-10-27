import SwiftUI
import AppKit
import MultitulUI

private func nav(_ id: String, _ title: String, _ symbol: String, _ color: UInt32, badge: Bool = false) -> SidebarEntry {
    SidebarEntry(id: id, title: title, symbol: symbol, badge: badge, color: color)
}

let sidebarSections: [[SidebarEntry]] = [
    [nav("today", "Сегодня", "sun.horizon.fill", 0xFF9F0A)],
    [
        nav("net", "Сеть", "network.badge.shield.half.filled", 0x0A84FF),
        nav("system", "Система", "cpu.fill", 0x6E7B8B, badge: true),
        nav("guard", "Сторож", "binoculars.fill", 0x30D158),
        nav("storage", "Хранилище и очистка", "internaldrive.fill", 0x5E5CE6)
    ],
    [
        nav("displays", "Экраны и обои", "photo.tv", 0x5AC8FA),
        nav("windows", "Окна и Dock", "rectangle.split.2x2.fill", 0x30B0C7),
        nav("input", "Клавиатура и мышь", "computermouse.fill", 0x98989D),
        nav("sound", "Звук", "speaker.wave.3.fill", 0xFF2D92),
        nav("clip", "Буфер и файлы", "doc.on.clipboard.fill", 0xFF6A3D),
        nav("energy", "Энергия", "battery.100percent.bolt", 0x30D158)
    ],
    [
        nav("shots", "Скриншоты и запись", "camera.viewfinder", 0xFF453A),
        nav("cmd", "Палитра и командная строка", "apple.terminal.fill", 0x2C2C30),
        nav("ocr", "Текст с экрана и пипетка", "text.viewfinder", 0x00C7BE),
        nav("pad", "Блокнот", "note.text", 0xFFCC00),
        nav("tidy", "Уборка и камера", "bubbles.and.sparkles.fill", 0x7D7AFF),
        nav("brew", "Медиа, Homebrew, обновления", "arrow.down.app.fill", 0xE8A317),
        nav("pip", "Авто-PiP", "pip.fill", 0x4C6EF5),
        nav("island", "Остров", "platter.filled.top.iphone", 0x1C1C20)
    ],
    [
        nav("keys", "Горячие клавиши", "command.square.fill", 0x8E8E93),
        nav("modules", "Модули", "puzzlepiece.extension.fill", 0x00B4D8),
        nav("perm", "Права", "lock.shield.fill", 0x0A84FF),
        nav("general", "Основные", "gearshape.fill", 0x8E8E93)
    ]
]

struct BrandView: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Мультитул").font(.system(size: 15, weight: .bold))
        }
    }
}

struct SystemPage: View {
    @State private var tab = 0
    @State private var leak = true
    @State private var menuCPU = true
    @State private var night = false

    let load = ChartSeries(values: [30, 40, 35, 60, 55, 80, 70, 90, 75, 110, 95, 85, 100, 78, 90, 65, 80].map { min($0, 100) * 0.9 }, color: Theme.accent, filled: true)
    let mem = ChartSeries(values: [20, 21, 22, 27, 26, 32, 33, 35, 35, 40, 40, 42, 43, 44, 45, 46, 48], color: Theme.warn, dashed: true)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Система", subtitle: "MacBook Air 15 · M4 · 16 ГБ · аптайм 3 д 4 ч", segments: ["Обзор", "Процессы", "История", "Энергия"], selection: $tab)
                HStack(spacing: 12) {
                    MetricCard(label: "Процессор", value: "23", unit: "%", progress: 0.23)
                    MetricCard(label: "Память", value: "11,4", unit: "/ 16 ГБ", progress: 0.71, color: Theme.warn)
                    MetricCard(label: "Диск", value: "84", unit: "ГБ своб.", progress: 0.62)
                    MetricCard(label: "Батарея", value: "78", unit: "% · 6 ч", progress: 0.78, color: Theme.ok)
                }
                HStack(alignment: .top, spacing: 12) {
                    Card(fillHeight: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Нагрузка за час")
                            LineChart(series: [load, mem]).frame(minHeight: 150, maxHeight: .infinity)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Сейчас едят").padding(.bottom, 4)
                            ListRow(title: "Google Chrome Helper", value: "41%", pill: Pill("долго", style: .warn))
                            Divider()
                            ListRow(title: "Code Helper", value: "12%")
                            Divider()
                            ListRow(title: "sing-box", value: "3%", pill: Pill("VPN", style: .ok))
                            Divider()
                            ListRow(title: "Telegram", value: "2%")
                            Divider()
                            ListRow(title: "WindowServer", value: "2%", pill: Pill("система"))
                        }
                    }
                    .frame(width: 330)
                }
                HStack(spacing: 12) {
                    ToggleRow(title: "Детектор утечек памяти", isOn: $leak)
                    ToggleRow(title: "Вывод CPU в menu bar", isOn: $menuCPU)
                    ToggleRow(title: "Уведомления ночью", subtitle: "с 23:00 до 8:00", isOn: $night)
                }
                Card(padding: 10) {
                    VStack(spacing: 0) {
                        SettingsRow(symbol: "keyboard", title: "Быстрая панель", subtitle: "Открывается глобальной клавишей") { KeyCaps("⌃⌥⌘V") }
                        Divider().padding(.leading, 40)
                        SettingsRow(symbol: "lock.shield", title: "Доступность", subtitle: "Нужна для управления окнами") { Pill("выдано", style: .ok) }
                        Divider().padding(.leading, 40)
                        SettingsRow(symbol: "rectangle.dashed.badge.record", title: "Запись экрана", subtitle: "Для OCR и пипетки") { Pill("нет доступа", style: .warn) }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
    }
}

struct RootView: View {
    @State private var selection = "system"
    @State private var search = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(sections: sidebarSections, selection: $selection, search: $search, searchPrompt: "Поиск модуля") { BrandView() }
                .navigationSplitViewColumnWidth(224)
        } detail: {
            SystemPage()
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            if !CommandLine.arguments.contains("--no-panel") { openWindow(id: "panel") }
        }
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "panel") } label: { Label("Панель меню", systemImage: "menubar.rectangle") }
            }
        }
    }
}

struct PanelShowcase: View {
    @State private var tiles = [
        QuickTileModel(id: "vpn", symbol: "network", caption: "VPN", active: true),
        QuickTileModel(id: "awake", symbol: "cup.and.saucer", caption: "Не спать"),
        QuickTileModel(id: "mic", symbol: "mic.slash", caption: "Мик выкл", active: true),
        QuickTileModel(id: "game", symbol: "gamecontroller", caption: "Игровой"),
        QuickTileModel(id: "mon", symbol: "display", caption: "Монитор"),
        QuickTileModel(id: "dark", symbol: "circle.lefthalf.filled", caption: "Тёмная"),
        QuickTileModel(id: "ocr", symbol: "text.viewfinder", caption: "OCR"),
        QuickTileModel(id: "pick", symbol: "eyedropper", caption: "Пипетка")
    ]
    @State private var volume = 55.0
    @State private var brightness = 80.0

    var body: some View {
        MenuBarPanel {
            HStack {
                Text("Мультитул").font(.system(size: 14, weight: .bold))
                Spacer()
                Pill("VPN · 48 мс", style: .ok)
            }
            QuickTileGrid(tiles: $tiles)
            HStack(spacing: 8) {
                MetricCard(label: "Claude 5 ч", value: "62%", progress: 0.62, compact: true)
                MetricCard(label: "Неделя", value: "38%", progress: 0.38, color: Theme.ok, compact: true)
            }
            SliderRow(symbol: "speaker.wave.2", value: $volume)
            SliderRow(symbol: "sun.max", value: $brightness)
            HStack {
                Text("Открыть окно").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                KeyCaps("⌃⌥⌘V")
            }
        }
        .padding(16)
    }
}

struct VitrinaApp: App {
    init() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        else if args.contains("--light") { app.appearance = NSAppearance(named: .aqua) }
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        if let i = args.firstIndex(of: "--ids"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { VitrinaApp.layoutWindows(report: path) }
        }
    }

    @MainActor static func layoutWindows(report: String) {
        var out = ""
        let top = (NSScreen.main?.visibleFrame.maxY ?? 900) - 6
        for w in NSApp.windows where w.isVisible && w.canBecomeMain {
            if w.title.contains("Панель") {
                w.setFrameTopLeftPoint(NSPoint(x: 1056, y: top))
                out += "panel \(w.windowNumber)\n"
            } else {
                w.setContentSize(NSSize(width: 1040, height: 800))
                w.setFrameTopLeftPoint(NSPoint(x: 6, y: top))
                out += "main \(w.windowNumber)\n"
            }
        }
        if let main = NSApp.windows.first(where: { !$0.title.contains("Панель") && $0.canBecomeMain }) {
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
        }
        try? out.write(toFile: report, atomically: true, encoding: .utf8)
    }

    var body: some Scene {
        WindowGroup("Витрина Мультитула") { RootView() }
            .defaultSize(width: 1040, height: 800)
        Window("Панель меню", id: "panel") { PanelShowcase() }
            .windowResizability(.contentSize)
    }
}

VitrinaApp.main()
