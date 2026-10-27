import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct BrightnessOSDView: View {
    var symbol: String
    var value: Double

    var body: some View {
        let filled = BrightnessStep.filledSegments(value)
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
            HStack(spacing: 2) {
                ForEach(0..<BrightnessStep.osdSegments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i < filled ? Color.primary : Color.primary.opacity(0.22)).frame(width: 7, height: 12)
                }
            }
            Text("\(BrightnessStep.percent(value))%").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background { VisualEffect(material: .hudWindow) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
enum BrightnessOSD {
    private static var panel: NSPanel?
    private static var host: NSHostingView<BrightnessOSDView>?
    private static var hideTask: DispatchWorkItem?

    static func show(symbol: String, value: Double, displayID: UInt32?) {
        let view = BrightnessOSDView(symbol: symbol, value: value)
        let h = host ?? NSHostingView(rootView: view)
        h.rootView = view
        host = h
        let size = h.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = h
        p.setContentSize(size)
        let screen = displayID.flatMap(screen(for:)) ?? NSScreen.main
        if let s = screen {
            p.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY + s.frame.height * 0.12))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideTask?.cancel()
        let w = DispatchWorkItem { fadeOut() }
        hideTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }

    private static func fadeOut() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } }
        })
    }

    static func screen(for displayID: UInt32) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }
    }
}
