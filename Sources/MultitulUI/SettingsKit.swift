import SwiftUI

public struct SettingsIcon: View {
    var symbol: String
    var color: Color
    var size: CGFloat
    var off: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    public init(symbol: String, color: Color, size: CGFloat = 26, off: Bool = false) {
        self.symbol = symbol
        self.color = color
        self.size = size
        self.off = off
    }

    public var body: some View {
        let key = "\(symbol)|\(NSColor(color).usingColorSpace(.sRGB)?.hashValue ?? 0)|\(size)|\(off)|\(scheme == .dark)|\(displayScale)"
        Image(nsImage: SettingsIconCache.image(key: key, size: size, scale: displayScale) {
            SettingsIconArt(symbol: symbol, color: color, size: size, off: off).environment(\.colorScheme, scheme)
        })
        .resizable()
        .frame(width: size + 4, height: size + 4)
        .frame(width: size, height: size)
    }
}

@MainActor
enum SettingsIconCache {
    private static var store: [String: NSImage] = [:]

    static func image<V: View>(key: String, size: CGFloat, scale: CGFloat, @ViewBuilder art: () -> V) -> NSImage {
        if let hit = store[key] { return hit }
        let r = ImageRenderer(content: art().padding(2))
        r.scale = max(scale, 2)
        let img = r.nsImage ?? NSImage(size: NSSize(width: size + 4, height: size + 4))
        img.size = NSSize(width: size + 4, height: size + 4)
        store[key] = img
        return img
    }
}

enum IconGlyph {
    private static var store: [String: CGImage] = [:]

    static func image(_ name: String) -> CGImage? {
        if let hit = store[name] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 160, weight: .bold, scale: .large))
        else { return nil }
        let pad = 20
        let w = Int(ceil(img.size.width)) + pad * 2, h = Int(ceil(img.size.height)) + pad * 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceIn)
            return true
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        tinted.draw(in: NSRect(x: pad, y: pad, width: Int(ceil(img.size.width)), height: Int(ceil(img.size.height))))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let rowBytes = rep.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * rowBytes + x * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, let full = rep.cgImage,
              let cut = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        store[name] = cut
        return cut
    }
}

enum IconSwatch {
    static let pairs: [(light: UInt32, dark: UInt32)] = [
        (0x007AFF, 0x0A84FF), (0x34C759, 0x30D158), (0xFF9500, 0xFF9F0A), (0xFF3B30, 0xFF453A), (0xFF2D55, 0xFF375F),
        (0x5856D6, 0x5E5CE6), (0xAF52DE, 0xBF5AF2), (0x32ADE6, 0x32ADE6), (0x30B0C7, 0x30B0C7), (0x00C7BE, 0x00C7BE),
        (0xFFC400, 0xFFCC00), (0x8E8E93, 0x8E8E93), (0x7C7C82, 0x7C7C82), (0x3A3A3C, 0x48484A), (0x1C1C1E, 0x3A3A3C),
        (0xFF6A2F, 0xFF6A3D), (0xF5A100, 0xFF9F0A), (0x3D5AFE, 0x5470F5), (0x00B8D9, 0x00B4D8), (0x7A77FF, 0x7A77FF)
    ]

    private static func parts(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255))
    }

    static func resolve(_ color: Color, dark: Bool) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        let r = Double(c.redComponent) * 255, g = Double(c.greenComponent) * 255, b = Double(c.blueComponent) * 255
        var best = pairs[0], bestD = Double.infinity
        for p in pairs {
            for hex in [p.light, p.dark] {
                let q = parts(hex)
                let d = (q.0 - r) * (q.0 - r) + (q.1 - g) * (q.1 - g) + (q.2 - b) * (q.2 - b)
                if d < bestD { bestD = d; best = p }
            }
        }
        return Color(nsColor: NSColor(hex: dark ? best.dark : best.light))
    }
}

struct SettingsIconArt: View {
    var symbol: String
    var color: Color
    var size: CGFloat
    var off: Bool
    @Environment(\.colorScheme) private var scheme

    private static let boxy: [String: CGFloat] = [
        "apple.terminal.fill": 0.84, "arrow.down.app.fill": 0.86, "note.text": 0.86, "pip.fill": 0.9, "capsule.fill": 0.9,
        "rectangle.split.2x2.fill": 0.9, "cpu.fill": 0.92, "internaldrive.fill": 0.94, "photo.tv": 0.92, "tv.fill": 0.92,
        "display": 0.92, "doc.on.clipboard.fill": 0.94, "lock.fill": 0.9, "circle.lefthalf.filled": 0.94, "command": 0.92,
        "gearshape.fill": 0.96, "record.circle.fill": 0.96, "lock.shield.fill": 0.96
    ]

    private var tileColor: Color {
        let dark = scheme == .dark
        if off { return dark ? Color(red: 0x63 / 255, green: 0x63 / 255, blue: 0x68 / 255) : Color(red: 0x9D / 255, green: 0x9D / 255, blue: 0xA3 / 255) }
        return IconSwatch.resolve(color, dark: dark)
    }

    var body: some View {
        let name = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "puzzlepiece.extension"
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(tileColor)
            if let g = IconGlyph.image(name) {
                let gw = CGFloat(g.width), gh = CGFloat(g.height)
                let k = size * 0.7 * (Self.boxy[name] ?? 1) / max(gw, gh)
                Image(decorative: g, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: gw * k, height: gh * k)
            }
        }
        .frame(width: size, height: size)
    }
}

public enum IconPalette {
    private static func key(_ symbol: String) -> String {
        symbol.split(separator: ".").filter { $0 != "fill" && $0 != "slash" }.joined(separator: ".")
    }

    private static let table: [String: UInt32] = [
        "shield.lefthalf": 0x007AFF, "shield": 0x007AFF, "cup.and.saucer": 0xFF9500, "moon.stars": 0x5856D6,
        "moon": 0x5856D6, "sun.max": 0xFF9500, "play": 0x5856D6, "gamecontroller": 0xAF52DE, "display": 0x34C759,
        "tv": 0x30B0C7, "camera.viewfinder": 0xFF3B30, "record.circle": 0xFF2D55, "eyedropper.full": 0x30B0C7,
        "eyedropper": 0x30B0C7, "text.viewfinder": 0x00C7BE, "circle.lefthalf": 0x5856D6, "circle.lefthalf.filled": 0x5856D6, "lock": 0xFF9500,
        "magnifyingglass": 0x007AFF, "pip": 0x3D5AFE, "clock": 0xFF9500, "sparkles": 0x7A77FF, "video": 0x30B0C7,
        "note.text": 0xFFC400, "square.grid.2x2": 0x00B8D9, "textformat.abc": 0xFF6A2F, "doc.on.clipboard": 0xFF6A2F,
        "link": 0x32ADE6, "tray.and.arrow.down": 0x5856D6, "hifispeaker.2": 0xFF2D55, "mic": 0xFF9500,
        "gauge.with.dots.needle.33percent": 0x34C759, "bell": 0xFF3B30, "menubar.dock.rectangle": 0x8E8E93,
        "eject": 0x8E8E93, "trash": 0xFF3B30, "arrow.clockwise": 0x007AFF, "eye": 0x5856D6, "bolt": 0x34C759,
        "network": 0x007AFF
    ]

    public static func color(for symbol: String) -> Color {
        let hex = table[key(symbol)] ?? 0x0A84FF
        return Color(nsColor: NSColor(hex: hex))
    }
}

public struct ScrollAnchor: Equatable {
    public let id: String
    public let nonce = UUID()
    public init(_ id: String) { self.id = id }
}

private struct ScrollAnchorKey: EnvironmentKey {
    static let defaultValue: ScrollAnchor? = nil
}

public extension EnvironmentValues {
    var scrollAnchor: ScrollAnchor? {
        get { self[ScrollAnchorKey.self] }
        set { self[ScrollAnchorKey.self] = newValue }
    }
}

struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}

public struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.scrollAnchor) private var anchor

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    private func jump(_ proxy: ScrollViewProxy, _ a: ScrollAnchor?) {
        guard let a else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation { proxy.scrollTo(a.id, anchor: .top) }
        }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Form { content() }
                .formStyle(.grouped)
                .labelStyle(FixedIconLabelStyle())
                .onAppear { jump(proxy, anchor) }
                .onChange(of: anchor) { _, a in jump(proxy, a) }
        }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
    }
}

public struct SettingLabel: View {
    var title: String
    var subtitle: String?

    public init(_ title: String, _ subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

public struct SectionFooter: View {
    var text: String
    var color: Color

    public init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
