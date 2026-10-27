import Foundation

public enum ShelfKind: String, CaseIterable, Sendable {
    case file, folder, text, url, image

    public var title: String {
        switch self {
        case .file: "Файл"
        case .folder: "Папка"
        case .text: "Текст"
        case .url: "Ссылка"
        case .image: "Изображение"
        }
    }

    public var symbol: String {
        switch self {
        case .file: "doc"
        case .folder: "folder"
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        }
    }

    public var isPath: Bool { self == .file || self == .folder }
}

public struct ShelfItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: ShelfKind
    public var hash: String
    public var title: String
    public var detail: String
    public var created: Date
    public var pinned: Bool
    public var size: Int
    public var path: String?
    public var owned: Bool
    public var ext: String?
    public var sourceBundle: String?

    public init(id: Int64, kind: ShelfKind, hash: String, title: String, detail: String = "", created: Date, pinned: Bool = false, size: Int = 0,
                path: String? = nil, owned: Bool = false, ext: String? = nil, sourceBundle: String? = nil) {
        self.id = id
        self.kind = kind
        self.hash = hash
        self.title = title
        self.detail = detail
        self.created = created
        self.pinned = pinned
        self.size = size
        self.path = path
        self.owned = owned
        self.ext = ext
        self.sourceBundle = sourceBundle
    }
}

public struct ShelfPayload: Equatable, Sendable {
    public var bookmark: Data?
    public var body: String?
    public var data: Data?

    public init(bookmark: Data? = nil, body: String? = nil, data: Data? = nil) {
        self.bookmark = bookmark
        self.body = body
        self.data = data
    }
}

public struct ShelfCandidate: Equatable, Sendable {
    public var kind: ShelfKind
    public var hash: String
    public var title: String
    public var detail: String
    public var size: Int
    public var path: String?
    public var owned: Bool
    public var ext: String?
    public var sourceBundle: String?
    public var payload: ShelfPayload

    public init(kind: ShelfKind, hash: String, title: String, detail: String = "", size: Int = 0, path: String? = nil, owned: Bool = false,
                ext: String? = nil, sourceBundle: String? = nil, payload: ShelfPayload = ShelfPayload()) {
        self.kind = kind
        self.hash = hash
        self.title = title
        self.detail = detail
        self.size = size
        self.path = path
        self.owned = owned
        self.ext = ext
        self.sourceBundle = sourceBundle
        self.payload = payload
    }
}

public enum ShelfIncoming: Equatable, Sendable {
    case file(path: String, owned: Bool)
    case text(String)
    case url(String, title: String?)
    case image(Data, ext: String, name: String?)
}

public struct ShelfAddResult: Equatable, Sendable {
    public var added: [Int64] = []
    public var deduped: [Int64] = []
    public var skipped = 0
    public var ids: [Int64] { added + deduped }
    public init() {}
}

public enum ShelfFileState: Equatable, Sendable {
    case ok(path: String)
    case relocated(path: String)
    case missing(lastPath: String?)

    public var path: String? {
        switch self {
        case .ok(let p), .relocated(let p): p
        case .missing: nil
        }
    }

    public var isMissing: Bool { if case .missing = self { true } else { false } }
}

public enum ShelfDragPayload: Equatable, Sendable {
    case files([String])
    case text(String)
    case url(String)
    case image(Data, ext: String, name: String)
}

public enum ShakeSensitivity: String, CaseIterable, Sendable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: "Низкая"
        case .medium: "Средняя"
        case .high: "Высокая"
        }
    }
}

public enum ShelfPlacementMode: String, CaseIterable, Sendable {
    case nearCursor, leftEdge, rightEdge

    public var title: String {
        switch self {
        case .nearCursor: "Рядом с курсором"
        case .leftEdge: "У левого края"
        case .rightEdge: "У правого края"
        }
    }
}

public enum ShelfOpenReason: String, Sendable {
    case hotkey, shake, menuBarDrag, menuBarClick, tile, embedded

    public var isAutomatic: Bool { self == .shake || self == .menuBarDrag }
}

public struct ShelfSettings: Equatable, Sendable {
    public var closeAfterDrop = false
    public var deleteAfterDrop = false
    public var shakeEnabled = true
    public var shakeSensitivity = ShakeSensitivity.medium
    public var excludedApps: [String] = []
    public var menuBarIcon = true
    public var menuBarDrop = true
    public var placement = ShelfPlacementMode.nearCursor
    public var autoHideEmpty = true

    public init() {}

    public var sanitized: ShelfSettings {
        var s = self
        var seen = Set<String>()
        s.excludedApps = excludedApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return s
    }
}

public enum ShelfHotkeys {
    public static let toggle = HotkeySpec(id: "shelf.toggle", title: "Полка: показать или скрыть", defaultCombo: .none)
}

public enum ShelfLimits {
    public static let maxItems = 200
    public static let maxTextBytes = 2_000_000
    public static let maxImageBytes = 40_000_000
    public static let titleLength = 80
}
