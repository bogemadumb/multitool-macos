import SwiftUI
import MultitulUI

public enum ModuleGroup: String, CaseIterable, Identifiable, Sendable {
    case net, system, clean, displays, windows, input, clip, sound, energy, tools, island

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .net: "Сеть"
        case .system: "Система"
        case .clean: "Очистка"
        case .displays: "Экраны"
        case .windows: "Окна и Dock"
        case .input: "Мышь и клава"
        case .clip: "Буфер и файлы"
        case .sound: "Звук"
        case .energy: "Энергия"
        case .tools: "Инструменты"
        case .island: "Остров"
        }
    }

    public var symbol: String {
        switch self {
        case .net: "network"
        case .system: "cpu"
        case .clean: "trash"
        case .displays: "display"
        case .windows: "macwindow.on.rectangle"
        case .input: "keyboard"
        case .clip: "doc.on.clipboard"
        case .sound: "speaker.wave.2"
        case .energy: "bolt"
        case .tools: "wrench.and.screwdriver"
        case .island: "capsule.portrait"
        }
    }
}

public struct ModuleInfo {
    public let id: ModuleID
    public let group: ModuleGroup
    public let title: String
    public let summary: String
    public let symbol: String
    public let permissions: [Permission]
    public let hotkeys: [HotkeySpec]
    public let enabledByDefault: Bool

    public init(id: ModuleID, group: ModuleGroup, title: String, summary: String = "", symbol: String, permissions: [Permission] = [], hotkeys: [HotkeySpec] = [], enabledByDefault: Bool = false) {
        self.id = id
        self.group = group
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.enabledByDefault = enabledByDefault
    }
}

public enum ModuleID: String, CaseIterable, Identifiable, Sendable {
    case vpn
    case monitorCPU
    case monitorGPU
    case monitorMemory
    case monitorNetwork
    case monitorDisk
    case monitorPower
    case connectedDevices
    case storozh
    case killProcess
    case portManager
    case fanControl
    case diskClean
    case ramClean
    case razbor
    case cleaner
    case uninstaller
    case liveWallpaper
    case staticWallpaper
    case monitorToggle
    case tvScreen
    case brightness
    case extraBrightness
    case keepAwake
    case bluetoothSleep
    case gameMode
    case autoPip
    case quickLauncher
    case quickToggles
    case colorPicker
    case screenOcr
    case screenshot
    case screenRecorder
    case cleaningMode
    case cameraPreview
    case scratchpad
    case mediaTools
    case homebrewManager
    case appUpdates
    case commandBar
    case radialMenu
    case soundOutputSwitcher
    case audioPriority
    case micMute
    case musicBlock
    case mixer
    case clipboardHistory
    case pastePlain
    case urlCleaner
    case dmgInstaller
    case finderCutPaste
    case finderRename
    case shelf
    case scrollInverter
    case scrollHorizontal
    case linearScroll
    case smoothScroll
    case scrollZoom
    case mouseAcceleration
    case mouseClickDebounce
    case keyboardDebounce
    case focusFollowsMouse
    case mouseNavigation
    case mouseButtonShortcuts
    case middleClick
    case superKey
    case quitProtection
    case textSnippets
    case windowLayout
    case windowMaximizer
    case autoQuit
    case spacesOrder
    case dockClick
    case windowSwitcher
    case dockPreview
    case notch
    case notchCalendar
    case notchNotifications
    case notchTimer
    case notchAccessories
    case notchLyrics
    case notchQueue
    case notchLiveEq
    case notchDownloads
    case notchWatch
    case notchMascot
    case demoClock
    case demoHotkey
    case demoAccessibility

    public var id: String { rawValue }

    public var enabledKey: String { "module.\(rawValue).enabled" }

    public var info: ModuleInfo {
        switch self {
        case .vpn:
            ModuleInfo(id: self, group: .net, title: "VPN", summary: "Свой VPN: состояние, режимы, соединения, правила, kill switch, сторож ядра", symbol: "shield.lefthalf.filled",
                       permissions: [.notifications, .automation],
                       hotkeys: [HotkeySpec(id: "vpn.open", title: "VPN: открыть раздел «Сеть»", defaultCombo: KeyCombo(keyCode: 9, modifiers: KeyCombo.opt | KeyCombo.cmd))])
        case .monitorCPU:
            ModuleInfo(id: self, group: .system, title: "Монитор: процессор", summary: "Загрузка и температура CPU, по-ядерная матрица, прожорливые процессы, история", symbol: "cpu",
                       hotkeys: [HotkeySpec(id: "monitor.open", title: "Система: открыть раздел", defaultCombo: KeyCombo(keyCode: 1, modifiers: KeyCombo.opt | KeyCombo.cmd))])
        case .monitorGPU:
            ModuleInfo(id: self, group: .system, title: "Монитор: графика", summary: "Загрузка и температура GPU с историей", symbol: "display.and.arrow.down")
        case .monitorMemory:
            ModuleInfo(id: self, group: .system, title: "Монитор: память", summary: "Использование, давление, своп, состав памяти, топ процессов", symbol: "memorychip.fill")
        case .monitorNetwork:
            ModuleInfo(id: self, group: .system, title: "Монитор: сеть", summary: "Скорость загрузки и отдачи, итоги за сеанс, локальный IP, топ процессов по сети", symbol: "arrow.up.arrow.down")
        case .monitorDisk:
            ModuleInfo(id: self, group: .system, title: "Монитор: диск", summary: "Свободное место, чтение и запись, SMART, напоминание об извлечении внешних дисков", symbol: "internaldrive")
        case .monitorPower:
            ModuleInfo(id: self, group: .system, title: "Монитор: питание", summary: "Батарея, здоровье, потребление, адаптер, температура, энергоёмкие приложения", symbol: "battery.100percent")
        case .connectedDevices:
            ModuleInfo(id: self, group: .system, title: "Подключённые устройства", summary: "Список внешних USB-устройств", symbol: "cable.connector")
        case .storozh:
            ModuleInfo(id: self, group: .system, title: "Сторож", summary: "7 детекторов аномалий (процессор, память, своп, утечки, батарея, диск, тепло), тихий перезапуск, уведомления с кнопками, снимки для Claude",
                       symbol: "gauge.with.dots.needle.33percent", permissions: [.notifications])
        case .killProcess:
            ModuleInfo(id: self, group: .system, title: "Завершение процессов", summary: "Поиск, принудительный выход, перезапуск, завершение вместе с дочерними; группы по приложению", symbol: "xmark.octagon.fill")
        case .portManager:
            ModuleInfo(id: self, group: .system, title: "Менеджер портов", summary: "Кто слушает TCP- и UDP-порты; остановить процесс одним нажатием", symbol: "point.3.filled.connected.trianglepath.dotted")
        case .fanControl:
            ModuleInfo(id: self, group: .system, title: "Управление вентиляторами", summary: "Бета, не проверено на железе. Ручные обороты (об/мин или %) и кривые «температура → обороты» с гистерезисом и плавным разгоном, пресеты; запись через root-помощник multitul-ctl. Сам возвращает вентиляторы системе при выходе, сне, пропаже датчиков, росте нагрузки и зависании. На Маке без вентиляторов ничего не делает",
                       symbol: "fan")
        case .diskClean:
            ModuleInfo(id: self, group: .clean, title: "Очистка диска", summary: "15 категорий в трёх уровнях (Безопасно / Проверь / Никогда): кэши, Корзина, npm, brew, Xcode, Docker, Telegram, Загрузки, модели HF; всё через Корзину с проверкой служб",
                       symbol: "internaldrive.badge.minus", permissions: [.fullDiskAccess])
        case .ramClean:
            ModuleInfo(id: self, group: .clean, title: "Очистка оперативки", summary: "purge, тяжёлые фоновые приложения, простаивающие сессии Claude, брошенные dev-серверы",
                       symbol: "memorychip.fill")
        case .razbor:
            ModuleInfo(id: self, group: .clean, title: "Разбор", summary: "Брошенные диски VM, рабочие папки с рекомендацией, старые venv и node_modules, модели HF, uv cache prune, сверка с архивом на домашнем сервере",
                       symbol: "chart.pie", permissions: [.fullDiskAccess])
        case .cleaner:
            ModuleInfo(id: self, group: .clean, title: "Чистка Мака", summary: "Остатки удалённых приложений, кэши, логи, бесхозный автозапуск, старые бэкапы iOS, забытые скриншоты, мусор Xcode, Корзина; расписание безопасной автоочистки",
                       symbol: "sparkles", permissions: [.fullDiskAccess, .notifications])
        case .uninstaller:
            ModuleInfo(id: self, group: .clean, title: "Удаление приложений", summary: "Перетащи приложение или выбери из списка: все его файлы с размерами, выбрать и убрать в Корзину; Apple и системные защищены",
                       symbol: "trash.square", permissions: [.fullDiskAccess])
        case .liveWallpaper:
            ModuleInfo(id: self, group: .displays, title: "Живые обои", summary: "Видео на рабочем столе всех экранов и Spaces: белый/чёрный, день/ночь по солнцу СПб, пауза на батарее, при блокировке и когда окна закрывают экран; экран блокировки по желанию",
                       symbol: "play.rectangle")
        case .staticWallpaper:
            ModuleInfo(id: self, group: .displays, title: "Статичные обои", summary: "Выбор картинок или папки, миниатюры, установка обоев на нужный экран без Системных настроек",
                       symbol: "photo.on.rectangle")
        case .monitorToggle:
            ModuleInfo(id: self, group: .displays, title: "Переключатель монитора", summary: "Убирает внешний монитор из раскладки macOS и возвращает его (окна и курсор не уезжают на выключенный экран); аварийный возврат отдельным файлом",
                       symbol: "display",
                       hotkeys: [HotkeySpec(id: "monitorToggle.toggle", title: "Монитор: выключить / включить внешний", defaultCombo: .none)])
        case .tvScreen:
            ModuleInfo(id: self, group: .displays, title: "Телевизор как второй экран", summary: "Виртуальный экран DeskPad уходит на Samsung по сети: H.264 со звуком через BlackHole (плеер ТВ) или быстрый режим без звука (браузер ТВ); звук на ТВ и обратно; экран Acer на ТВ",
                       symbol: "tv", permissions: [.screenRecording, .microphone])
        case .brightness:
            ModuleInfo(id: self, group: .displays, title: "Яркость мониторов", summary: "Яркость каждого экрана: встроенного (системно), внешних по DDC или программным затемнением; клавиши яркости на экран под курсором, мелкие шаги, индикатор, подсветка клавиатуры",
                       symbol: "sun.max", permissions: [.accessibility],
                       hotkeys: BrightnessHotkeys.all)
        case .extraBrightness:
            ModuleInfo(id: self, group: .displays, title: "Яркость выше максимума", summary: "Запас HDR XDR-дисплея (MacBook Pro 14/16) для яркости выше обычного; на других экранах недоступно. Не проверено на железе",
                       symbol: "sun.max.fill")
        case .keepAwake:
            ModuleInfo(id: self, group: .energy, title: "Keep Awake", summary: "Не даёт Маку засыпать: на таймер, бессрочно, до выхода из приложения, с закрытой крышкой, по условиям (внешний монитор, питание, приложения); защита батареи",
                       symbol: "cup.and.saucer", permissions: [.notifications],
                       hotkeys: [KeepAwakeHotkeys.toggle])
        case .bluetoothSleep:
            ModuleInfo(id: self, group: .energy, title: "Bluetooth на время сна", summary: "Выключает Bluetooth, когда Мак засыпает, и включает при пробуждении, только если выключил сам",
                       symbol: "dot.radiowaves.left.and.right", permissions: [.bluetooth])
        case .gameMode:
            ModuleInfo(id: self, group: .energy, title: "Игровой режим", summary: "Одной кнопкой: F1–F12 как обычные клавиши, активные углы выключены, Mac Mouse Fix и Atoll закрыты; выключение возвращает всё назад",
                       symbol: "gamecontroller", permissions: [.notifications],
                       hotkeys: [GameModeHotkeys.toggle])
        case .autoPip:
            ModuleInfo(id: self, group: .tools, title: "Авто-PiP", summary: "Ушёл из Safari (другое приложение, вкладка, рабочий стол) — играющее видео уходит в «картинка в картинке»; вернулся — PiP выключается",
                       symbol: "pip", permissions: [.automation])
        case .quickLauncher:
            ModuleInfo(id: self, group: .tools, title: "Быстрая палитра", summary: "Плавающая панель с избранным: инструменты Мультитула, переключатели, приложения, ссылки и скрипты; стрелки и Return открывают, цифры 1–9 запускают сразу; у каждого из девяти пунктов может быть своё сочетание",
                       symbol: "square.grid.2x2", hotkeys: LauncherHotkeys.all)
        case .quickToggles:
            ModuleInfo(id: self, group: .tools, title: "Быстрые переключатели", summary: "Однокликовые действия: тёмная тема, скрыть иконки рабочего стола, извлечь все внешние диски, очистить Корзину (с подтверждением), перезапустить Finder, заблокировать экран, выключить дисплей, запустить заставку",
                       symbol: "switch.2", permissions: [.automation])
        case .colorPicker:
            ModuleInfo(id: self, group: .tools, title: "Пипетка", summary: "Цвет любого пикселя на экране с лупой: копируется как HEX, RGB, HSL, HSB, CMYK, код SwiftUI/NSColor/UIColor, OKLCH или Lab; стрелки двигают выбор, Return копирует и закрывает, C копирует и оставляет; история, избранное, контраст WCAG",
                       symbol: "eyedropper", permissions: [.screenRecording], hotkeys: [ToolsHotkeys.colorPick])
        case .screenOcr:
            ModuleInfo(id: self, group: .tools, title: "Текст с экрана", summary: "Выделяешь область, распознанный текст копируется (офлайн, Vision, русский и английский); QR-код показывает содержимое: скопировать или открыть; опция «убрать переносы строк»",
                       symbol: "text.viewfinder", permissions: [.screenRecording], hotkeys: [ToolsHotkeys.ocrCapture])
        case .screenshot:
            ModuleInfo(id: self, group: .tools, title: "Скриншоты", summary: "Область, окно, весь экран, все экраны и прокручиваемая страница; заморозка картинки при выборе, лупа с координатами пикселя, таймер. После съёмки плашка: копировать, сохранить, редактор, закрепить поверх окон, перетащить, поделиться, удалить; редактор со стрелками, фигурами, текстом, маркером, размытием, шагами и обрезкой; история с поиском по тексту на снимках; временная ссылка на 1, 6 или 24 часа",
                       symbol: "camera.viewfinder", permissions: [.screenRecording], hotkeys: ShotHotkeys.all)
        case .screenRecorder:
            ModuleInfo(id: self, group: .tools, title: "Запись экрана", summary: "Запись области, окна или всего экрана (качество, 30 и 60 к/с, H.264 или HEVC, обратный отсчёт, пауза) с отдельными дорожками звука системы и микрофона; индикатор с таймером в строке меню. После записи редактор: обрезка, вырезание фрагментов, скорость, кадрирование, громкость дорожек, автоприближение по кликам, размытие приватных мест, фон и скругление рамки; экспорт в MP4, MOV и GIF с пресетами; история и временная ссылка",
                       symbol: "record.circle", permissions: [.screenRecording, .systemAudio, .microphone], hotkeys: RecHotkeys.all)
        case .cleaningMode:
            ModuleInfo(id: self, group: .tools, title: "Режим уборки", summary: "Блокирует клавиатуру, пока протираешь Мак; мышь и тачпад работают (по желанию блокируются тоже). Чёрный экран или индикатор в углу; выход: пять раз нажать Escape",
                       symbol: "sparkles", permissions: [.accessibility], hotkeys: [ToolsHotkeys.cleaningToggle])
        case .cameraPreview:
            ModuleInfo(id: self, group: .tools, title: "Зеркало камеры", summary: "Плавающее окно с изображением с камеры: проверить, как выглядишь, перед созвоном. Камера включена только пока окно открыто; размер, форма, отражение, выбор камеры",
                       symbol: "video", permissions: [.camera], hotkeys: [CameraHotkeys.toggle])
        case .scratchpad:
            ModuleInfo(id: self, group: .tools, title: "Блокнот", summary: "Плавающие заметки во вкладках с автосохранением и Markdown-превью, экспорт; автоочистка после периода без правок и закрытие по клику снаружи",
                       symbol: "note.text", hotkeys: [ScratchpadHotkeys.toggle])
        case .mediaTools:
            ModuleInfo(id: self, group: .tools, title: "Медиа-инструменты", summary: "Сжатие видео (по качеству или целевому размеру, разрешение подбирается), обрезка, GIF из видео, звук из видео, водяные знаки, пачечная конвертация картинок, текст с картинки или кадра, скачивание через yt-dlp; ffmpeg ищется в /opt/homebrew и /usr/local, всё локально",
                       symbol: "film.stack")
        case .homebrewManager:
            ModuleInfo(id: self, group: .tools, title: "Менеджер Homebrew", summary: "Установленные формулы и casks, обновления (одно или все), поиск, установка и удаление, службы, листья и лишние зависимости, закрепление версий, очистка кэша; brew запускается от твоего имени, когда нужен пароль, команда открывается в Terminal",
                       symbol: "shippingbox", permissions: [.automation])
        case .appUpdates:
            ModuleInfo(id: self, group: .tools, title: "Обновления приложений", summary: "Единый список приложений с новой версией: сайты разработчиков (Sparkle), Mac App Store, Homebrew casks; обновляются из исходного источника; уведомление о новых, пропуск версии и игнор приложения",
                       symbol: "arrow.down.app", permissions: [.appManagement, .notifications])
        case .soundOutputSwitcher:
            ModuleInfo(id: self, group: .sound, title: "Переключатель вывода", summary: "Сочетание переходит к следующему отмеченному устройству вывода (динамики, наушники, AirPods, HDMI); в настройках отмечаешь, какие входят в цикл; список устройств в панели menu bar",
                       symbol: "hifispeaker.2", hotkeys: [SoundHotkeys.outputNext])
        case .audioPriority:
            ModuleInfo(id: self, group: .sound, title: "Приоритеты устройств", summary: "Упорядоченные списки для вывода и ввода: подключилось устройство выше текущего, оно становится активным; отключилось, подхватывает следующее; список игнорируемых",
                       symbol: "list.number")
        case .micMute:
            ModuleInfo(id: self, group: .sound, title: "Выключение микрофона", summary: "Глушит все микрофоны Мака сразу, в любом приложении, одним кликом или сочетанием; красный перечёркнутый микрофон в menu bar; прежняя громкость возвращается при включении",
                       symbol: "mic.slash", hotkeys: [SoundHotkeys.micToggle])
        case .musicBlock:
            ModuleInfo(id: self, group: .sound, title: "Запрет запуска Музыки", summary: "Не даёт приложению «Музыка» открыться само после медиа-клавиш (бывает при отключении Bluetooth-наушников); можно указать приложение-замену и запускать воспроизведение в нём",
                       symbol: "music.note", permissions: [.accessibility])
        case .mixer:
            ModuleInfo(id: self, group: .sound, title: "Микшер", summary: "Отдельная громкость каждого приложения, усиление до 400% с ограничителем против перегруза, заглушение, вывод приложения на другое устройство (в том числе AirPlay), индикаторы уровня и карточка в menu bar; настройки запоминаются по приложению",
                       symbol: "slider.vertical.3", permissions: [.systemAudio], hotkeys: MixHotkeys.all)
        case .clipboardHistory:
            ModuleInfo(id: self, group: .clip, title: "История буфера", summary: "Запоминает скопированное (текст, по желанию картинки, файлы, цвета), палитра с поиском, закреплением и вставкой в прошлое приложение; пропускает пароли и секретные копии; лимиты по числу, размеру и сроку",
                       symbol: "doc.on.clipboard", permissions: [.accessibility],
                       hotkeys: [ClipHotkeys.picker])
        case .pastePlain:
            ModuleInfo(id: self, group: .clip, title: "Вставка без форматирования", summary: "Вставляет скопированный текст без шрифтов и цветов; оригинал с форматированием остаётся в буфере",
                       symbol: "textformat.abc", permissions: [.accessibility],
                       hotkeys: [ClipHotkeys.pastePlain])
        case .urlCleaner:
            ModuleInfo(id: self, group: .clip, title: "Чистка ссылок", summary: "Убирает из ссылок трекинговые параметры (utm_*, fbclid, gclid, yclid и правила для сайтов) при копировании или вручную; по желанию раскрывает ссылки-переходники",
                       symbol: "link", hotkeys: [ClipHotkeys.cleanUrl])
        case .dmgInstaller:
            ModuleInfo(id: self, group: .clip, title: "Установка из dmg", summary: "Смонтировали образ с одним приложением: предлагает скопировать его в Программы, извлечь образ и убрать dmg в Корзину; проверяет подпись",
                       symbol: "externaldrive.badge.plus", permissions: [.notifications, .appManagement])
        case .finderCutPaste:
            ModuleInfo(id: self, group: .clip, title: "Вырезать и вставить в Finder", summary: "В Finder ⌘X вырезает файлы, ⌘V перемещает их в открытую папку; в текстовых полях клавиши обычные; ⌘V с картинкой в буфере сохраняет PNG",
                       symbol: "scissors", permissions: [.accessibility, .automation])
        case .finderRename:
            ModuleInfo(id: self, group: .clip, title: "Переименование в Finder", summary: "Клавиша (по умолчанию не назначена) запускает переименование выделенного файла в Finder; в текстовых полях не мешает",
                       symbol: "pencil.line", permissions: [.accessibility],
                       hotkeys: [ClipHotkeys.finderRename])
        case .shelf:
            ModuleInfo(id: self, group: .clip, title: "Полка", summary: "Плавающая полка для файлов, папок, картинок, ссылок и текста: бросил, открыл нужное окно, вытащил; открывается сочетанием, встряхиванием мыши при перетаскивании или под значком в menu bar; закреплённое переживает перезапуск",
                       symbol: "tray.and.arrow.down",
                       hotkeys: [ShelfHotkeys.toggle])
        case .scrollInverter:
            ModuleInfo(id: self, group: .input, title: "Направление скролла мыши", summary: "Отдельно разворачивает колесо мыши (вертикаль и горизонталь независимо), не трогая тачпад: на тачпаде остаётся «натуральная» прокрутка, на колесе как в Windows; исключения по приложениям",
                       symbol: "arrow.up.arrow.down", permissions: [.accessibility])
        case .scrollHorizontal:
            ModuleInfo(id: self, group: .input, title: "Горизонтальный скролл по клавише", summary: "Пока держишь выбранную клавишу (по умолчанию Shift), вертикальное движение колеса мыши превращается в горизонтальное: листать широкую таблицу вбок",
                       symbol: "arrow.left.and.right", permissions: [.accessibility])
        case .linearScroll:
            ModuleInfo(id: self, group: .input, title: "Линейный скролл", summary: "Один щелчок колеса всегда прокручивает одинаковое число строк, как бы быстро ни крутил: убирает «разгон» прокрутки; число строк настраивается",
                       symbol: "line.3.horizontal.decrease", permissions: [.accessibility])
        case .smoothScroll:
            ModuleInfo(id: self, group: .input, title: "Плавная прокрутка", summary: "Каждый щелчок колеса мыши превращается в короткое плавное скольжение, как на тачпаде; скорость, отзывчивость и длина выбега; исключения для 3D- и дизайн-приложений; тачпад не затрагивается",
                       symbol: "scroll", permissions: [.accessibility])
        case .scrollZoom:
            ModuleInfo(id: self, group: .input, title: "Зум по ⌘ + колесо", summary: "Колесо мыши с зажатым ⌘ масштабирует содержимое, как щипок на тачпаде (Safari, Карты, Просмотр, Figma и другие); тачпад не затрагивается; работает независимо от плавной прокрутки; исключения по приложениям",
                       symbol: "plus.magnifyingglass", permissions: [.accessibility])
        case .mouseAcceleration:
            ModuleInfo(id: self, group: .input, title: "Ускорение курсора", summary: "Выключает разгон курсора мыши: движение строго пропорционально движению руки (игры, точная графика); прежние значения возвращаются при выключении, выходе и после сбоя",
                       symbol: "cursorarrow.motionlines")
        case .mouseClickDebounce:
            ModuleInfo(id: self, group: .input, title: "Фильтр дребезга кнопок мыши", summary: "Игнорирует случайные быстрые двойные клики от изношенной кнопки, не замедляя обычные и настоящие двойные; интервал и кнопки задаются",
                       symbol: "cursorarrow.click.badge.clock", permissions: [.accessibility])
        case .keyboardDebounce:
            ModuleInfo(id: self, group: .input, title: "Фильтр залипания клавиш", summary: "Отфильтровывает слишком быстрые повторы одной и той же клавиши, когда клавиатура «двоит» буквы: общее окно в миллисекундах и свои значения для клавиш (0 = не фильтровать), список приложений-исключений",
                       symbol: "keyboard.badge.eye", permissions: [.accessibility, .inputMonitoring])
        case .focusFollowsMouse:
            ModuleInfo(id: self, group: .input, title: "Фокус за курсором", summary: "Окно под курсором выходит вперёд, как только курсор постоял над ним (по умолчанию 250 мс); поднимать окно или только отдавать фокус; список приложений-исключений",
                       symbol: "macwindow.and.cursorarrow", permissions: [.accessibility])
        case .mouseNavigation:
            ModuleInfo(id: self, group: .input, title: "Боковые кнопки мыши: назад и вперёд", summary: "Кнопки «Назад» и «Вперёд» мыши листают страницы в Finder, браузерах и редакторах; свои сочетания для отдельных приложений, список исключений",
                       symbol: "arrow.left.arrow.right", permissions: [.accessibility])
        case .mouseButtonShortcuts:
            ModuleInfo(id: self, group: .input, title: "Действия на кнопки мыши", summary: "Любая дополнительная кнопка или наклон колеса вбок нажимает своё сочетание; отдельные действия на удержание и двойной клик; зажатая кнопка и движение: влево и вправо рабочие столы, вверх Mission Control, вниз App Exposé; короткий клик работает как прежде",
                       symbol: "computermouse", permissions: [.accessibility])
        case .middleClick:
            ModuleInfo(id: self, group: .input, title: "Средний клик на тачпаде", summary: "Нажатие тремя пальцами работает как нажатие колеса мыши: ссылка в новой вкладке, закрыть вкладку; по желанию лёгкий тап тоже кликает; при включённом перетаскивании тремя пальцами нужно четыре",
                       symbol: "hand.point.up.left", permissions: [.accessibility])
        case .superKey:
            ModuleInfo(id: self, group: .input, title: "Супер-клавиша", summary: "Caps Lock или правый модификатор превращается в набор модификаторов (например, ⌃⌥⌘): держишь её и жмёшь любую клавишу; отдельное действие на короткое нажатие, долгое удержание включает Caps Lock; приложения, где она выключена",
                       symbol: "capslock", permissions: [.accessibility, .inputMonitoring])
        case .quitProtection:
            ModuleInfo(id: self, group: .input, title: "Защита от случайных ⌘Q и ⌘W", summary: "Ловит ⌘Q и ⌘W и пропускает после подтверждения: удержание, двойное нажатие или дополнительный модификатор; отдельно для Q и W и для каждого приложения (все, кроме выбранных, или только выбранные)",
                       symbol: "xmark.shield", permissions: [.accessibility, .inputMonitoring])
        case .textSnippets:
            ModuleInfo(id: self, group: .input, title: "Быстрые вставки текста", summary: "Набираешь короткий триггер (например, ;адрес), и после пробела, Tab или Return он заменяется длинным текстом; переменные {{date}}, {{time}}, {{datetime}}, {{clipboard}} с форматами и часовым поясом; библиотека с поиском",
                       symbol: "text.insert", permissions: [.accessibility, .inputMonitoring],
                       hotkeys: [SnippetHotkeys.library])
        case .windowLayout:
            ModuleInfo(id: self, group: .windows, title: "Раскладка окон", summary: "Окно прижимается к половине, трети, четверти, шестой доле, центру или на весь экран сочетанием, перетаскиванием к краю экрана (с подсветкой), жестом с модификаторами или «кольцом»; возврат прежнего размера, перенос на другой дисплей, отступы, свои макеты",
                       symbol: "rectangle.split.2x2", permissions: [.accessibility],
                       hotkeys: WindowHotkeys.all)
        case .windowMaximizer:
            ModuleInfo(id: self, group: .windows, title: "Зелёная кнопка: максимум", summary: "Зелёная кнопка разворачивает окно на всю рабочую область, а не уводит в полноэкранный Space; список приложений, где кнопка остаётся стандартной; второй клик возвращает прежний размер",
                       symbol: "arrow.up.left.and.arrow.down.right", permissions: [.accessibility])
        case .autoQuit:
            ModuleInfo(id: self, group: .windows, title: "Выход при закрытии последнего окна", summary: "Закрыл последнее окно (⌘W или красная кнопка) — приложение завершается само, как в Windows; диалоги «Сохранить?» остаются, меню-бар утилиты и список исключений не трогаются",
                       symbol: "power", permissions: [.accessibility])
        case .spacesOrder:
            ModuleInfo(id: self, group: .windows, title: "Фиксированный порядок рабочих столов", summary: "Отключает в macOS перестановку Spaces по последнему использованию, чтобы Desktop 1, 2, 3 стояли на своих местах; при выключении прежняя настройка возвращается",
                       symbol: "rectangle.3.group")
        case .dockClick:
            ModuleInfo(id: self, group: .windows, title: "Клик по значку в Dock", summary: "Клик по значку уже активного приложения сворачивает его окна (второй клик возвращает) или прячет приложение; отдельно перебор окон приложения по кругу",
                       symbol: "dock.rectangle", permissions: [.accessibility])
        case .windowSwitcher:
            ModuleInfo(id: self, group: .windows, title: "Переключатель окон", summary: "Заменяет ⌘Tab: не приложения, а окна с живыми превью, свёрнутые и скрытые тоже; ⌘` листает окна текущего приложения; поиск по названию (S), закрыть окно (W), выйти из приложения (Q), свернуть (M); фильтры по рабочему столу и дисплею, правила для приложений",
                       symbol: "rectangle.on.rectangle", permissions: [.accessibility, .screenRecording])
        case .dockPreview:
            ModuleInfo(id: self, group: .windows, title: "Превью окон из Dock", summary: "Наводишь курсор на значок запущенного приложения в Dock — над ним всплывает панель с миниатюрами его окон; клик открывает окно, × закрывает, можно свернуть, отправить на другой дисплей или прижать к краю; задержки, прозрачность, исключения",
                       symbol: "dock.arrow.up.rectangle", permissions: [.accessibility, .screenRecording])
        case .commandBar:
            ModuleInfo(id: self, group: .tools, title: "Командная строка", summary: "Одно поле поверх всего: ищет приложения, окна, файлы в выбранных папках, историю буфера, сниппеты и пункты меню активного приложения; считает, переводит единицы и валюты, ищет эмодзи, запускает скрипты и быстрые ссылки, завершает процессы и открывает удаление приложений; для каждого пункта можно дать имена и сочетание",
                       symbol: "magnifyingglass", permissions: [.accessibility], hotkeys: CommandBarHotkeys.all)
        case .radialMenu:
            ModuleInfo(id: self, group: .tools, title: "Радиальное меню", summary: "Колесо до 12 действий вокруг курсора: приложения, файлы, ссылки, сочетания клавиш, подменю. Держишь сочетание, наводишь на сектор, отпускаешь; короткое нажатие оставляет колесо открытым. Вызывается сочетанием, боковой кнопкой мыши или тапом четырьмя пальцами; несколько профилей",
                       symbol: "circle.hexagongrid", permissions: [.accessibility])
        case .notch:
            ModuleInfo(id: self, group: .island, title: "Остров", summary: "Панель вокруг выреза камеры (на Маках без выреза — капсула): музыка с обложкой и перемоткой, громкость и яркость, ярлыки, микшер, буфер, снимки, полка, показатели системы, инструменты. Открывается наведением, прокруткой вниз или сочетанием; заменяет Atoll",
                       symbol: "capsule.portrait", permissions: [.accessibility], hotkeys: IslHotkeys.all)
        case .notchCalendar:
            ModuleInfo(id: self, group: .island, title: "Остров: календарь", summary: "Месяц, ближайшие встречи и напоминания в острове; за час до события в закрытом острове идёт обратный отсчёт, во время события — сколько осталось. Календари только читаются",
                       symbol: "calendar", permissions: [.calendars])
        case .notchNotifications:
            ModuleInfo(id: self, group: .island, title: "Остров: уведомления", summary: "Новые системные уведомления дублируются в острове; сообщения держатся в памяти и стираются при блокировке экрана; можно скрыть системный баннер",
                       symbol: "bell.badge", permissions: [.accessibility, .fullDiskAccess])
        case .notchTimer:
            ModuleInfo(id: self, group: .island, title: "Остров: таймер", summary: "Таймер, секундомер и рабочие сессии «помодоро» (фокус, короткий и длинный перерыв); обратный отсчёт рядом с камерой, звук по окончании",
                       symbol: "timer", hotkeys: IslTmrHotkeys.all)
        case .notchAccessories:
            ModuleInfo(id: self, group: .island, title: "Остров: аксессуары", summary: "Подключённые наушники, клавиатура и мышь с зарядом; остров мигает при подключении и один раз предупреждает, когда заряд упал до 20%",
                       symbol: "airpodspro", permissions: [.bluetooth])
        case .notchLyrics:
            ModuleInfo(id: self, group: .island, title: "Остров: тексты песен", summary: "Текст играющей песни строка за строкой синхронно с музыкой; тексты ищутся онлайн через lrclib.net (уходят название, исполнитель, альбом и длительность); можно импортировать свои",
                       symbol: "quote.bubble")
        case .notchQueue:
            ModuleInfo(id: self, group: .island, title: "Остров: очередь", summary: "Следующие треки в плеере, если плеер сам отдаёт очередь (Музыка); клик по треку включает его",
                       symbol: "list.bullet", permissions: [.automation])
        case .notchLiveEq:
            ModuleInfo(id: self, group: .island, title: "Остров: живой эквалайзер", summary: "Полоски в острове двигаются в такт реальному звуку плеера вместо обычной анимации; нужен включённый «Микшер» и право записи системного звука",
                       symbol: "waveform", permissions: [.systemAudio])
        case .notchDownloads:
            ModuleInfo(id: self, group: .island, title: "Остров: загрузки", summary: "Файлы, которые скачиваются в папку загрузок (Chrome, Safari, Firefox и другие), прямо в острове: размер, скорость, прогресс, готово",
                       symbol: "arrow.down.circle")
        case .notchWatch:
            ModuleInfo(id: self, group: .island, title: "Остров: наблюдение", summary: "Выбираешь область экрана (прогресс-бар, статус сборки, счёт), остров следит за ней и сообщает, когда она изменилась и когда перестала меняться (картинка стоит 30 секунд)",
                       symbol: "eye", permissions: [.screenRecording])
        case .notchMascot:
            ModuleInfo(id: self, group: .island, title: "Остров: маскот", summary: "Маленький друг в острове: отдыхает, иногда заходит в гости, реагирует на музыку, таймер, загрузки, скриншоты, микрофон и режим без сна; стили, формы, цвета, сторона и частота появлений",
                       symbol: "face.smiling")
        case .demoClock:
            ModuleInfo(id: self, group: .tools, title: "Демо: часы", summary: "Плитка в панели и карточка с часами", symbol: "clock", enabledByDefault: true)
        case .demoHotkey:
            ModuleInfo(id: self, group: .input, title: "Демо: горячая клавиша", summary: "Показывает уведомление по сочетанию", symbol: "keyboard.badge.ellipsis",
                       permissions: [.notifications],
                       hotkeys: [HotkeySpec(id: "demoHotkey.fire", title: "Демо: показать уведомление", defaultCombo: KeyCombo(keyCode: 38, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd))])
        case .demoAccessibility:
            ModuleInfo(id: self, group: .windows, title: "Демо: активное окно", summary: "Заголовок окна переднего приложения через Accessibility", symbol: "macwindow",
                       permissions: [.accessibility])
        }
    }
}

@MainActor
public protocol Module: AnyObject {
    var info: ModuleInfo { get }
    func start()
    func stop()
    var settingsView: AnyView { get }
    var quickTile: AnyView? { get }
    var panelCard: AnyView? { get }
    var wantsCard: Bool { get }
    var panelPresentation: PanelPresentation { get }
}

public extension Module {
    var id: ModuleID { info.id }
    var group: ModuleGroup { info.group }
    var title: String { info.title }
    var symbol: String { info.symbol }
    var permissions: [Permission] { info.permissions }
    var quickTile: AnyView? { nil }
    var panelCard: AnyView? { nil }
    var wantsCard: Bool { true }
    var panelPresentation: PanelPresentation { .quick }
}
