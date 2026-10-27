import Foundation

public struct SavedColor: Codable, Equatable, Hashable, Sendable {
    public var rgba: String
    public var space: String
    public var name: String
    public var stamp: Double

    public init(color: RGBAColor, name: String = "", stamp: Double = 0) {
        let c = color.clamped
        rgba = String(format: "%02X%02X%02X%02X", c.red8, c.green8, c.blue8, c.alpha8)
        space = color.space.rawValue
        self.name = name
        self.stamp = stamp
    }

    public var color: RGBAColor? {
        guard let c = ColorParser.parseHex(rgba) else { return nil }
        return RGBAColor(r: c.r, g: c.g, b: c.b, a: c.a, space: ColorSpaceKind(rawValue: space) ?? .srgb)
    }

    public var sameColor: String { rgba + space }
}

public final class ColorHistoryStore {
    public static let historyKey = "colorPicker.history"
    public static let favoritesKey = "colorPicker.favorites"
    public static let favoritesLimit = 60
    public static let limitRange = 5...200

    private let kv: KeyValueStoring
    private let clock: ToolsClock
    public private(set) var history: [SavedColor]
    public private(set) var favorites: [SavedColor]
    public var limit: Int { didSet { limit = ToolsClamp.int(limit, Self.limitRange); trim(); save() } }

    public init(_ kv: KeyValueStoring, limit: Int = 30, clock: ToolsClock = SystemToolsClock()) {
        self.kv = kv
        self.clock = clock
        self.limit = ToolsClamp.int(limit, Self.limitRange)
        history = ColorHistoryStore.load(kv, Self.historyKey)
        favorites = ColorHistoryStore.load(kv, Self.favoritesKey)
        trim()
    }

    private static func load(_ kv: KeyValueStoring, _ key: String) -> [SavedColor] {
        guard let s = kv.object(forKey: key) as? String, let list = try? JSONDecoder().decode([SavedColor].self, from: Data(s.utf8)) else { return [] }
        return list.filter { $0.color != nil }
    }

    private func save() {
        func enc(_ l: [SavedColor]) -> String? {
            l.isEmpty ? nil : (try? JSONEncoder().encode(l)).map { String(decoding: $0, as: UTF8.self) }
        }
        if let h = enc(history) { kv.set(h, forKey: Self.historyKey) } else { kv.removeObject(forKey: Self.historyKey) }
        if let f = enc(favorites) { kv.set(f, forKey: Self.favoritesKey) } else { kv.removeObject(forKey: Self.favoritesKey) }
    }

    private func trim() {
        if history.count > limit { history = Array(history.prefix(limit)) }
        if favorites.count > Self.favoritesLimit { favorites = Array(favorites.prefix(Self.favoritesLimit)) }
    }

    public func record(_ color: RGBAColor) {
        let item = SavedColor(color: color, stamp: clock.now.timeIntervalSince1970)
        history.removeAll { $0.sameColor == item.sameColor }
        history.insert(item, at: 0)
        trim()
        save()
    }

    public func isFavorite(_ color: RGBAColor) -> Bool {
        let key = SavedColor(color: color).sameColor
        return favorites.contains { $0.sameColor == key }
    }

    @discardableResult
    public func toggleFavorite(_ color: RGBAColor, name: String = "") -> Bool {
        let item = SavedColor(color: color, name: name, stamp: clock.now.timeIntervalSince1970)
        if let i = favorites.firstIndex(where: { $0.sameColor == item.sameColor }) {
            favorites.remove(at: i)
            save()
            return false
        }
        favorites.insert(item, at: 0)
        trim()
        save()
        return true
    }

    public func rename(favorite color: RGBAColor, to name: String) {
        let key = SavedColor(color: color).sameColor
        guard let i = favorites.firstIndex(where: { $0.sameColor == key }) else { return }
        favorites[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    public func moveFavorite(from: Int, to: Int) {
        guard favorites.indices.contains(from), favorites.indices.contains(to), from != to else { return }
        favorites.insert(favorites.remove(at: from), at: to)
        save()
    }

    public func remove(historyAt index: Int) {
        guard history.indices.contains(index) else { return }
        history.remove(at: index)
        save()
    }

    public func clearHistory() {
        history = []
        save()
    }
}
