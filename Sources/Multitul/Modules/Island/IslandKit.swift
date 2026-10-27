import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct IslSlider: View {
    @Binding var value: Double
    var height: CGFloat = 6
    var tint: Color = .white
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint).frame(width: max(g.size.width * CGFloat(min(max(value, 0), 1)), height))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    onEditing(true)
                    value = min(max(Double(v.location.x / max(g.size.width, 1)), 0), 1)
                }
                .onEnded { _ in onEditing(false) })
        }
        .frame(height: 22)
    }
}

struct IslIconButton: View {
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = .white
    var background: Bool = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size + 14, height: size + 10)
                .background(Color.white.opacity(hover ? 0.18 : (background ? 0.10 : 0)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct IslEqualizer: View {
    var playing: Bool
    var tint: Color = .white
    var bars = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 14, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = t * (3.2 + Double(i) * 0.9) + Double(i) * 1.7
                    let h = playing ? 0.25 + 0.75 * abs(sin(phase)) : 0.2
                    Capsule().fill(tint).frame(width: 2.5, height: 16 * h)
                }
            }
            .frame(height: 16)
        }
    }
}

struct IslEmptyNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.5))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IslTile: View {
    let symbol: String
    let title: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 4)
            .background((active ? Theme.accent.opacity(0.55) : Color.white.opacity(hover ? 0.2 : 0.1)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

@MainActor
class IslandSectionBase: IslSection {
    let descriptor: IslSectionDescriptor
    var onChange: (() -> Void)?

    init(_ id: IslSectionID) {
        descriptor = IslCoreSections.descriptors.first { $0.id == id }!
    }

    var availability: IslAvailability { .available }
    var activities: [IslActivity] { [] }
    func start() {}
    func stop() {}
    func didAppear() {}
    func didDisappear() {}
    func compactLeading(_ activity: IslActivity) -> AnyView? { nil }
    func compactTrailing(_ activity: IslActivity) -> AnyView? { nil }
    func peekView(_ activity: IslActivity) -> AnyView? { nil }
    func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(EmptyView()) }
    func handle(_ intent: IslSectionIntent) -> Bool { false }
    var settingsView: AnyView? { nil }

    func notify() { onChange?() }

    func moduleRunning(_ id: ModuleID) -> Bool { AppController.shared.runtime.isRunning(id) }

    func requires(_ id: ModuleID) -> IslAvailability {
        moduleRunning(id) ? .available : .unavailable("Включи модуль «\(id.info.title)»")
    }
}

